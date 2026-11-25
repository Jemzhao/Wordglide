// Adapted from Hover Translate. Copyright (c) 2026 Kianzzz.
// Distributed under the MIT License; see THIRD_PARTY_NOTICES.md.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision
import NaturalLanguage
import CoreML

private final class OCRJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var activeRequest: VNRecognizeTextRequest?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func activate(_ request: VNRecognizeTextRequest) {
        lock.lock(); activeRequest = request; let shouldCancel = stopped; lock.unlock()
        if shouldCancel { request.cancel() }
    }
    func cancel() {
        lock.lock(); stopped = true; let request = activeRequest; lock.unlock()
        request?.cancel()
    }
}

private final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); let cancelled = stopped; lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

// An immutable AX proxy to another process can cross the capture queue.
// Never permit an in-process AppKit/SwiftUI object into that queue.
private struct ExternalAXElement: @unchecked Sendable {
    let value: AXUIElement
    init(_ element: AXUIElement) throws {
        try TextCapture.requireExternalElement(element)
        value = element
    }
}

enum CaptureError: LocalizedError {
    case protectedText, nothingSelected, noScreenPermission, noAccessibilityPermission, ownApplication, inputTooLong
    var errorDescription: String? {
        switch self {
        case .protectedText: return "此处是受保护的输入区域，已跳过识别。"
        case .nothingSelected: return "当前应用没有提供可读取的选中文字。可以先复制，再用菜单中的“翻译剪贴板”。"
        case .noScreenPermission: return "需要屏幕录制权限才能识别图片中的文字。"
        case .noAccessibilityPermission: return "请先在设置中允许辅助功能，以便在 OCR 前排除密码和受保护区域。"
        case .ownApplication: return "已跳过 Wordglide 自身的界面。"
        case .inputTooLong: return "选中文字超过 \(TextLogic.maximumInputLength) 字，请缩小选区后再试。"
        }
    }
}

struct SelectedCapture: Sendable {
    let text: CapturedText
    let replacement: ReplacementTarget?
}

struct AccessibleHoverCapture: Sendable {
    let capture: CapturedText
    let hitTextRange: Bool

    var allowsOCRFallback: Bool {
        let language = TextLogic.hoverLanguage(of: capture.text)
        if language == .english { return capture.isPartialParagraph }
        // A control or image description can differ from the visible text.
        // A matched text range is stronger evidence to skip English-only OCR.
        return !hitTextRange || language != .unsupported
    }
}

enum TextCapture {
    static let queue = DispatchQueue(label: "app.wordglide.capture", qos: .userInitiated)
    static let ocrQueue = DispatchQueue(label: "app.wordglide.ocr", qos: .userInitiated)

    private static func perform<T: Sendable>(_ operation: @escaping @Sendable (CaptureCancellation) throws -> T) async throws -> T {
        let cancellation = CaptureCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let result = try operation(cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    @MainActor
    static func elementAt(_ point: CGPoint) -> AXUIElement? {
        // A system-wide hit can resolve into this process. AppKit then invokes
        // our SwiftUI accessibility tree synchronously on the calling thread.
        // It must therefore run on the UI thread, even for a global hover.
        precondition(Thread.isMainThread)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success else { return nil }
        if let element { AXUIElementSetMessagingTimeout(element, 0.25) }
        return element
    }

    static func requireExternalElement(_ element: AXUIElement) throws {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            throw CaptureError.ownApplication
        }
    }

    static func isProtected(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let protected = attribute(element, "AXProtectedContent") as? Bool ?? false
        return role == "AXSecureTextField" || subrole == "AXSecureTextField" || protected
    }

    /// Only external AX proxies belong on the capture queue. Bound the walk so a
    /// broken accessibility tree cannot recurse forever or enter our own UI.
    private static func ancestry(_ element: AXUIElement, cancellation: CaptureCancellation) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current = element
        for _ in 0..<8 {
            try cancellation.check()
            try requireExternalElement(current)
            AXUIElementSetMessagingTimeout(current, 0.2)
            if isProtected(current) { throw CaptureError.protectedText }
            result.append(current)
            let role = attribute(current, kAXRoleAttribute) as? String ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            guard let ref = attribute(current, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { break }
            let parent = ref as! AXUIElement
            if result.contains(where: { CFEqual($0, parent) }) { break }
            current = parent
        }
        return result
    }

    static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func selected(pid: pid_t, fallbackPoint: CGPoint) async throws -> SelectedCapture {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { throw CaptureError.ownApplication }
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        return try await perform { cancellation in
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                guard let ref = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                    throw CaptureError.nothingSelected
                }
                let focused = ref as! AXUIElement
                var owner: pid_t = 0
                guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { throw CaptureError.nothingSelected }
                _ = try ancestry(focused, cancellation: cancellation)
                guard let raw = attribute(focused, kAXSelectedTextAttribute) as? String,
                      !TextLogic.clean(raw).isEmpty else {
                    throw CaptureError.nothingSelected
                }
                guard raw.count <= TextLogic.maximumInputLength else { throw CaptureError.inputTooLong }
                try cancellation.check()
                var rect = ScreenGeometry.pointerAnchor(fallbackPoint)
                if let range = attribute(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
                    var value: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
                       let value, CFGetTypeID(value) == AXValueGetTypeID() {
                        var selectionBounds = CGRect.zero
                        if AXValueGetValue(value as! AXValue, .cgRect, &selectionBounds),
                           selectionBounds.width > 0, selectionBounds.height > 0,
                           !selectionBounds.isInfinite, !selectionBounds.isNull { rect = selectionBounds }
                    }
                }
                let replacement = ReplacementTarget.capture(element: focused, pid: pid, selected: raw)
                return SelectedCapture(
                    text: CapturedText(text: TextLogic.clean(raw), bounds: rect, method: "选中文字"),
                    replacement: replacement)
        }
    }

    private static func parameterized(_ element: AXUIElement, _ name: CFString, _ parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name, parameter, &result) == .success else { return nil }
        return result
    }

    private static func textBounds(_ reference: CFTypeRef?) -> CGRect? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(reference as! AXValue, .cgRect, &rect),
              rect.height > 0, !rect.isNull, !rect.isInfinite else { return nil }
        return rect
    }

    private static func textHit(_ element: AXUIElement, at point: CGPoint) -> (offset: Int, bounds: CGRect)? {
        var position = point
        guard let pointValue = AXValueCreate(.cgPoint, &position),
              let reference = parameterized(element, kAXRangeForPositionParameterizedAttribute as CFString, pointValue),
              CFGetTypeID(reference) == AXValueGetTypeID(),
              let rect = textBounds(parameterized(element, kAXBoundsForRangeParameterizedAttribute as CFString, reference)),
              rect.insetBy(dx: -6, dy: -5).contains(point) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(reference as! AXValue, .cfRange, &range) else { return nil }
        return (range.location, rect)
    }

    private static func paragraphFromTextMarker(_ element: AXUIElement, at point: CGPoint) -> AccessibleHoverCapture? {
        // Read-only web text may expose text markers without a numeric range
        // for the pointer. Start within the hit element's own visible text.
        guard let hitRange = parameterized(element, kAXTextMarkerRangeForUIElementParameterizedAttribute as CFString, element),
              CFGetTypeID(hitRange) == AXTextMarkerRangeGetTypeID(),
              let hitBounds = textBounds(parameterized(element, kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString, hitRange)),
              hitBounds.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(hitRange as! AXTextMarkerRange)
        let end = AXTextMarkerRangeCopyEndMarker(hitRange as! AXTextMarkerRange)
        guard !CFEqual(start, end) else { return nil }
        var position = point
        let markerAtPoint = AXValueCreate(.cgPoint, &position).flatMap {
            parameterized(element, kAXTextMarkerForPositionParameterizedAttribute as CFString, $0)
        }
        let marker: CFTypeRef
        if let markerAtPoint, CFGetTypeID(markerAtPoint) == AXTextMarkerGetTypeID() {
            marker = markerAtPoint
        } else {
            // Move inside the hit text when possible so a left-biased provider
            // does not resolve its boundary to the preceding paragraph.
            let next = parameterized(element, kAXNextTextMarkerForTextMarkerParameterizedAttribute as CFString, start)
            marker = next.flatMap { CFGetTypeID($0) == AXTextMarkerGetTypeID() && !CFEqual($0, end) ? $0 : nil } ?? start
        }
        guard let paragraphRange = parameterized(element, kAXParagraphTextMarkerRangeForTextMarkerParameterizedAttribute as CFString, marker),
              CFGetTypeID(paragraphRange) == AXTextMarkerRangeGetTypeID(),
              let rect = textBounds(parameterized(element, kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString, paragraphRange)),
              rect.insetBy(dx: -4, dy: -4).contains(point),
              let raw = parameterized(element, kAXStringForTextMarkerRangeParameterizedAttribute as CFString, paragraphRange) as? String,
              raw.utf16.count <= 250_000, !raw.contains("\u{FFFC}") else { return nil }
        let text = TextLogic.clean(raw)
        guard !text.isEmpty, text.count <= TextLogic.maximumHoverLength else { return nil }
        return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: rect, method: "系统取词 · 段落"), hitTextRange: true)
    }

    private static func accessibleParagraph(_ elements: [AXUIElement], at point: CGPoint,
                                            cancellation: CaptureCancellation) throws -> AccessibleHoverCapture? {
        let labelsAndControls: Set<String> = ["AXHeading", "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                                              "AXPopUpButton", "AXMenuButton", "AXTab", "AXImage"]
        var textElements: [(AXUIElement, String)] = []
        for element in elements {
            try cancellation.check()
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" || role == "AXWindow" || role == "AXApplication" { break }
            if labelsAndControls.contains(role) { return nil }
            if ["AXStaticText", "AXParagraph", "AXTextArea", "AXTextField"].contains(role) {
                textElements.append((element, role))
            }
        }

        var fallback: AccessibleHoverCapture?
        for (element, role) in textElements {
            try cancellation.check()
            guard let rect = bounds(element), rect.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            if role == "AXStaticText" || role == "AXParagraph",
               let paragraph = paragraphFromTextMarker(element, at: point) { return paragraph }
            guard let raw = attribute(element, kAXValueAttribute) as? String,
                  raw.utf16.count <= 250_000 else { continue }
            if role == "AXParagraph", let text = TextLogic.segment(raw, utf16Offset: 0, scope: .paragraph),
               text == TextLogic.clean(raw), !text.contains("\u{FFFC}") {
                return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: rect, method: "系统取词 · 段落"), hitTextRange: true)
            }
            if let hit = textHit(element, at: point) {
                if role != "AXStaticText",
                   let text = TextLogic.segment(raw, utf16Offset: hit.offset, scope: .paragraph), !text.contains("\u{FFFC}") {
                    return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: hit.bounds, method: "系统取词 · 段落"), hitTextRange: true)
                }
                if fallback == nil, let sentence = TextLogic.segment(raw, utf16Offset: hit.offset, scope: .sentence),
                   !sentence.contains("\u{FFFC}") {
                    fallback = AccessibleHoverCapture(capture: CapturedText(text: sentence, bounds: hit.bounds,
                        method: "系统取词 · 句子", isPartialParagraph: true), hitTextRange: true)
                }
            }
            if fallback == nil, role == "AXStaticText" || role == "AXParagraph", rect.height <= 130 {
                let text = TextLogic.clean(raw)
                guard !text.isEmpty, text.count <= TextLogic.maximumHoverLength,
                      !text.contains(where: \.isNewline), !text.contains("\u{FFFC}") else { continue }
                fallback = AccessibleHoverCapture(capture: CapturedText(text: text, bounds: rect,
                    method: "系统取词", isPartialParagraph: true), hitTextRange: false)
            }
        }
        return fallback
    }

    @MainActor
    static func accessible(at point: CGPoint, scope: HoverRecognitionScope) async throws -> AccessibleHoverCapture? {
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard let hit = elementAt(point) else { return nil }
        let remote = try ExternalAXElement(hit)
        try Task.checkCancellation()
        return try await perform { cancellation in
                let elements = try ancestry(remote.value, cancellation: cancellation)
                if scope == .paragraph,
                   let paragraph = try accessibleParagraph(elements, at: point, cancellation: cancellation) { return paragraph }
                let fallbackScope: HoverRecognitionScope = scope == .paragraph ? .sentence : scope
                let compactRoles: Set<String> = ["AXStaticText", "AXButton", "AXMenuItem", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXHeading", "AXTextField", "AXCell", "AXTab", "AXRow", "AXImage"]
                for element in elements {
                    try cancellation.check()
                    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                    if role == "AXWindow" || role == "AXApplication" { break }
                    let candidates = [attribute(element, kAXValueAttribute) as? String,
                                      attribute(element, kAXTitleAttribute) as? String,
                                      attribute(element, kAXDescriptionAttribute) as? String]
                    guard let raw = candidates.compactMap({ $0 }).first(where: { !TextLogic.clean($0).isEmpty }) else { continue }
                    // Avoid passing enormous document values through a tokenizer.
                    // Local OCR can still resolve text around this pointer.
                    guard raw.utf16.count <= 250_000 else { continue }
                    let text = TextLogic.clean(raw)
                    guard let rect = bounds(element), rect.insetBy(dx: -4, dy: -4).contains(point) else { continue }
                    if let hit = textHit(element, at: point),
                       let result = TextLogic.segment(raw, utf16Offset: hit.offset, scope: fallbackScope) {
                        return AccessibleHoverCapture(
                            capture: CapturedText(text: result, bounds: hit.bounds, method: "系统取词"),
                            hitTextRange: true)
                    }
                    // UI controls, system menus and labels often expose a title or description,
                    // not a text value. Large document containers still go through local OCR.
                    let compact = rect.height <= 130 && text.count <= 500 && text.components(separatedBy: .newlines).count <= 4
                    if compact && compactRoles.contains(role) {
                        if fallbackScope != .word || text.split(whereSeparator: { $0.isWhitespace }).count == 1 {
                            return AccessibleHoverCapture(
                                capture: CapturedText(text: text, bounds: rect, method: "系统取词 · 控件 / 菜单"),
                                hitTextRange: false)
                        }
                    }
                }
                return nil
        }
    }

    @MainActor
    static func ocr(at point: CGPoint, scope: HoverRecognitionScope) async throws -> CapturedText? {
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard AXIsProcessTrusted() else { throw CaptureError.noAccessibilityPermission }
        // Run this even when OCR is called directly without a preceding AX read.
        // No permission prompt is issued here; the settings screen owns that action.
        if let hit = elementAt(point) {
            let remote = try ExternalAXElement(hit)
            _ = try await perform { cancellation in
                _ = try ancestry(remote.value, cancellation: cancellation)
                return true
            }
        } else if NSApplication.shared.windows.contains(where: {
            $0.isVisible && $0.frame.contains(TextLogic.quartzPoint(point, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0))
        }) {
            throw CaptureError.ownApplication
        }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noScreenPermission }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else { return nil }
        let display = CGDisplayBounds(displayID)
        let size = scope == .paragraph ? CGSize(width: 1120, height: 640) : CGSize(width: 880, height: 280)
        let crop = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height).intersection(display)
        guard !crop.isEmpty, !crop.isInfinite, !crop.isNull else { return nil }
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(in: crop)
        try Task.checkCancellation()
        return try await recognize(image: image, region: crop, at: point, scope: scope)
    }

    private typealias OCRLine = (text: String, bounds: CGRect, candidate: VNRecognizedText)

    private static func paragraphLines(around hitIndex: Int, in lines: [OCRLine]) -> [OCRLine] {
        let hit = lines[hitIndex].bounds
        let column = lines.indices.filter { index in
            let rect = lines[index].bounds
            return abs(rect.minX - hit.minX) <= max(10, hit.height, rect.height)
        }.sorted { lines[$0].bounds.midY < lines[$1].bounds.midY }
        guard let origin = column.firstIndex(of: hitIndex) else { return [lines[hitIndex]] }
        let columnWidth = column.map { lines[$0].bounds.width }.max() ?? hit.width
        func adjacent(_ earlier: OCRLine, _ later: OCRLine) -> Bool {
            let gap = later.bounds.minY - earlier.bounds.maxY
            let tallest = max(earlier.bounds.height, later.bounds.height)
            guard gap >= -2, gap <= max(8, tallest),
                  earlier.bounds.width >= later.bounds.width * 0.45 else { return false }
            let sentenceEndings = ".!?…"
            let earlierEndsSentence = earlier.text.last.map(sentenceEndings.contains) ?? false
            let similarHeight = min(earlier.bounds.height, later.bounds.height) >= tallest * 0.7
            // Vision measures visible glyphs. A wrapped ending such as "on."
            // can be much shorter than the preceding line at the same size.
            let shortEnding = !earlierEndsSentence && later.text.first?.isLowercase == true
                && later.bounds.height >= earlier.bounds.height * 0.5
                && later.bounds.height < earlier.bounds.height && later.bounds.width <= earlier.bounds.width * 0.45
                && (later.text.last.map(sentenceEndings.contains) ?? false)
            return (similarHeight || shortEnding) && (!earlierEndsSentence || earlier.bounds.width >= columnWidth * 0.65)
        }

        // Use the hovered row as the anchor and stop at the first break in
        // each direction so another column or a section below cannot join it.
        var start = origin
        while start > 0, adjacent(lines[column[start - 1]], lines[column[start]]) { start -= 1 }
        var end = origin
        while end + 1 < column.count, adjacent(lines[column[end]], lines[column[end + 1]]) { end += 1 }
        return column[start...end].map { lines[$0] }
    }

    static func recognize(image: CGImage, region crop: CGRect, at point: CGPoint, scope: HoverRecognitionScope) async throws -> CapturedText? {
        guard !crop.isEmpty, !crop.isInfinite, !crop.isNull, crop.contains(point) else { return nil }
        let job = OCRJob()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedText?, Error>) in
            ocrQueue.async {
                do {
                    if job.cancelled { throw CancellationError() }
                    let request = VNRecognizeTextRequest()
                    job.activate(request)
                    // Hover detection only needs English printed text. The accurate
                    // recognizer still initializes ANE models even with CPU assigned;
                    // the fast recognizer avoids that blocking initialization path.
                    if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
                        request.setComputeDevice(cpu, for: .main)
                    }
                    request.recognitionLanguages = ["en-US"]
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    if job.cancelled { throw CancellationError() }
                    let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.35 else { return nil }
                        let b = observation.boundingBox
                        let box = CGRect(x: crop.minX + b.minX * crop.width,
                                         y: crop.minY + (1 - b.maxY) * crop.height,
                                         width: b.width * crop.width, height: b.height * crop.height)
                        return (candidate.string, box, candidate)
                    }
                    // Hit-test the actual text line. Blank space must not pick the nearest paragraph.
                    guard let hitIndex = lines.indices.filter({ index in
                        let bounds = lines[index].bounds
                        return bounds.insetBy(dx: -max(4, bounds.height), dy: -4).contains(point)
                    }).min(by: { abs(lines[$0].bounds.midY - point.y) < abs(lines[$1].bounds.midY - point.y) }) else {
                        continuation.resume(returning: nil); return
                    }
                    var hit = lines[hitIndex]
                    var isPartialParagraph = false
                    if scope == .paragraph, hit.bounds.insetBy(dx: -4, dy: -4).contains(point) {
                        let paragraph = paragraphLines(around: hitIndex, in: lines)
                        let text = paragraph.map(\.text).joined(separator: " ")
                        isPartialParagraph = text.count > TextLogic.maximumHoverLength || paragraph.contains { row in
                            // Vision can omit a clipped glyph and leave a character-width gap at the edge.
                            let horizontalMargin = max(1, row.bounds.height * 0.65)
                            let verticalMargin = max(1, row.bounds.height / 4)
                            return !crop.insetBy(dx: horizontalMargin, dy: verticalMargin).contains(row.bounds)
                        }
                        if paragraph.count > 1, text.count <= TextLogic.maximumHoverLength {
                            if job.cancelled { throw CancellationError() }
                            continuation.resume(returning: CapturedText(text: text, bounds: hit.bounds,
                                method: "本机 OCR · 段落", isPartialParagraph: isPartialParagraph))
                            return
                        }
                    }
                    var hitRegion = crop
                    // Nearby control icons can make the fast detector drop an initial
                    // letter. Re-read just this line, excluding surrounding UI icons.
                    let lineRegion = hit.1.insetBy(dx: -max(32, hit.1.height * 1.25), dy: -12).intersection(crop)
                    let scaleX = CGFloat(image.width) / crop.width
                    let scaleY = CGFloat(image.height) / crop.height
                    let pixels = CGRect(x: (lineRegion.minX - crop.minX) * scaleX,
                                        y: (lineRegion.minY - crop.minY) * scaleY,
                                        width: lineRegion.width * scaleX, height: lineRegion.height * scaleY).integral
                    if let lineImage = image.cropping(to: pixels) {
                        let refinement = VNRecognizeTextRequest()
                        refinement.recognitionLevel = .fast
                        refinement.recognitionLanguages = ["en-US"]
                        refinement.usesLanguageCorrection = true
                        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
                            refinement.setComputeDevice(cpu, for: .main)
                        }
                        job.activate(refinement)
                        if job.cancelled { throw CancellationError() }
                        try VNImageRequestHandler(cgImage: lineImage).perform([refinement])
                        if job.cancelled { throw CancellationError() }
                        let refinedRegion = CGRect(x: crop.minX + pixels.minX / scaleX, y: crop.minY + pixels.minY / scaleY,
                                                   width: CGFloat(lineImage.width) / scaleX, height: CGFloat(lineImage.height) / scaleY)
                        let refined: [(String, CGRect, VNRecognizedText)] = (refinement.results ?? []).compactMap { observation in
                            guard let text = observation.topCandidates(1).first, text.confidence >= 0.35 else { return nil }
                            let b = observation.boundingBox
                            return (text.string, CGRect(x: refinedRegion.minX + b.minX * refinedRegion.width,
                                                        y: refinedRegion.minY + (1 - b.maxY) * refinedRegion.height,
                                                        width: b.width * refinedRegion.width, height: b.height * refinedRegion.height), text)
                        }
                        if let matching = refined.filter({ $0.1.insetBy(dx: -4, dy: -4).contains(point) })
                            .min(by: { abs($0.1.midY - point.y) < abs($1.1.midY - point.y) }) {
                            hit = matching
                            hitRegion = refinedRegion
                        }
                    }
                    guard hit.0.count <= TextLogic.maximumHoverLength, hit.1.insetBy(dx: -4, dy: -4).contains(point) else {
                        continuation.resume(returning: nil); return
                    }
                    if scope == .word {
                        let tokenizer = NLTokenizer(unit: .word)
                        tokenizer.string = hit.0
                        var found: CapturedText?
                        tokenizer.enumerateTokens(in: hit.0.startIndex..<hit.0.endIndex) { range, _ in
                            if job.cancelled { return false }
                            if let b = try? hit.2.boundingBox(for: range)?.boundingBox {
                                let box = CGRect(x: hitRegion.minX + b.minX * hitRegion.width, y: hitRegion.minY + (1-b.maxY) * hitRegion.height,
                                                 width: b.width * hitRegion.width, height: b.height * hitRegion.height)
                                if box.insetBy(dx: -3, dy: -3).contains(point) { found = CapturedText(text: String(hit.0[range]), bounds: box, method: "本机 OCR"); return false }
                            }
                            return true
                        }
                        if job.cancelled { throw CancellationError() }
                        continuation.resume(returning: found); return
                    }
                    if job.cancelled { throw CancellationError() }
                    continuation.resume(returning: CapturedText(text: hit.0, bounds: hit.1,
                        method: "本机 OCR · 当前行", isPartialParagraph: isPartialParagraph))
                } catch { continuation.resume(throwing: error) }
            }
            }
        } onCancel: {
            job.cancel()
        }
    }
}
