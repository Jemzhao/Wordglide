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

    @MainActor
    static func accessible(at point: CGPoint, word: Bool) async throws -> CapturedText? {
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard let hit = elementAt(point) else { return nil }
        let remote = try ExternalAXElement(hit)
        try Task.checkCancellation()
        return try await perform { cancellation in
                let elements = try ancestry(remote.value, cancellation: cancellation)
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
                    var pointCopy = point
                    if let pointValue = AXValueCreate(.cgPoint, &pointCopy) {
                        var rangeRef: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString, pointValue, &rangeRef) == .success,
                           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
                            var range = CFRange()
                            var boxRef: CFTypeRef?
                            var charBounds = CGRect.zero
                            let hasBounds = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boxRef) == .success
                            if let boxRef, CFGetTypeID(boxRef) == AXValueGetTypeID() { _ = AXValueGetValue(boxRef as! AXValue, .cgRect, &charBounds) }
                            if hasBounds, charBounds.height > 0, charBounds.insetBy(dx: -6, dy: -5).contains(point),
                               AXValueGetValue(rangeRef as! AXValue, .cfRange, &range),
                               let result = TextLogic.segment(raw, utf16Offset: range.location, word: word) {
                                return CapturedText(text: result, bounds: charBounds, method: "系统取词")
                            }
                        }
                    }
                    // UI controls, system menus and labels often expose a title or description,
                    // not a text value. Large document containers still go through local OCR.
                    let compact = rect.height <= 130 && text.count <= 500 && text.components(separatedBy: .newlines).count <= 4
                    if compact && compactRoles.contains(role) {
                        if !word || text.split(whereSeparator: { $0.isWhitespace }).count == 1 {
                            return CapturedText(text: text, bounds: rect, method: "系统取词 · 控件 / 菜单")
                        }
                    }
                }
                return nil
        }
    }

    @MainActor
    static func ocr(at point: CGPoint, word: Bool) async throws -> CapturedText? {
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
        let crop = CGRect(x: point.x - 440, y: point.y - 140, width: 880, height: 280).intersection(display)
        guard !crop.isEmpty, !crop.isInfinite, !crop.isNull else { return nil }
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(in: crop)
        try Task.checkCancellation()
        return try await recognize(image: image, region: crop, at: point, word: word)
    }

    static func recognize(image: CGImage, region crop: CGRect, at point: CGPoint, word: Bool) async throws -> CapturedText? {
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
                    let lines: [(String, CGRect, VNRecognizedText)] = (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.35 else { return nil }
                        let b = observation.boundingBox
                        let box = CGRect(x: crop.minX + b.minX * crop.width,
                                         y: crop.minY + (1 - b.maxY) * crop.height,
                                         width: b.width * crop.width, height: b.height * crop.height)
                        return (candidate.string, box, candidate)
                    }
                    // Hit-test the actual text line. Blank space must not pick the nearest paragraph.
                    guard var hit = lines.filter({ $0.1.insetBy(dx: -max(4, $0.1.height), dy: -4).contains(point) })
                        .min(by: { abs($0.1.midY - point.y) < abs($1.1.midY - point.y) }) else {
                        continuation.resume(returning: nil); return
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
                    if word {
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
                    continuation.resume(returning: CapturedText(text: hit.0, bounds: hit.1, method: "本机 OCR · 当前行"))
                } catch { continuation.resume(throwing: error) }
            }
            }
        } onCancel: {
            job.cancel()
        }
    }
}
