// Adapted from Hover Translate. Copyright (c) 2026 Kianzzz.
// Distributed under the MIT License; see THIRD_PARTY_NOTICES.md.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Security
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
    case protectedText, unverifiedTarget, nothingSelected, selectionNotReady
    case noScreenPermission, noAccessibilityPermission, ownApplication, inputTooLong
    var errorDescription: String? {
        switch self {
        case .protectedText: return "此处是受保护的输入区域，已跳过识别。"
        case .unverifiedTarget: return "无法确认当前区域的辅助功能状态，已跳过操作。"
        case .nothingSelected, .selectionNotReady:
            return "当前应用没有提供可读取的选中文字。可以先复制，再用菜单中的“翻译剪贴板”。"
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
        return !hitTextRange
    }
}

struct HoveredWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let allowsSharing: Bool
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

    static func attributeResult(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        return (error, result)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let (error, result) = attributeResult(element, name)
        return error == .success ? result : nil
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

    // Optional attributes may legitimately be absent. A timeout, unknown role
    // or malformed value cannot establish that a target is safe.
    static func verifiedUnprotectedRole(attribute read: (String) -> (AXError, CFTypeRef?)) throws -> String {
        func value<T>(_ name: String, as type: T.Type) throws -> T? {
            let (status, raw) = read(name)
            switch status {
            case .noValue, .attributeUnsupported: return nil
            case .success:
                guard let raw, (type != Bool.self || CFGetTypeID(raw) == CFBooleanGetTypeID()),
                      let typed = raw as? T else { throw CaptureError.unverifiedTarget }
                return typed
            default: throw CaptureError.unverifiedTarget
            }
        }
        guard let role = try value(kAXRoleAttribute, as: String.self),
              !role.isEmpty, role != "AXUnknown" else { throw CaptureError.unverifiedTarget }
        if role == "AXSecureTextField" { throw CaptureError.protectedText }
        if try value(kAXSubroleAttribute, as: String.self) == "AXSecureTextField" { throw CaptureError.protectedText }
        if try value("AXProtectedContent", as: Bool.self) == true { throw CaptureError.protectedText }
        return role
    }

    /// Only external AX proxies belong on the capture queue. Bound the walk so a
    /// broken accessibility tree cannot recurse forever or enter our own UI.
    private static func ancestry(_ element: AXUIElement, cancellation: CaptureCancellation) throws -> [AXUIElement] {
        try requireExternalElement(element)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else { throw CaptureError.unverifiedTarget }
        var result: [AXUIElement] = []
        var current = element
        for _ in 0..<24 {
            try cancellation.check()
            var pid: pid_t = 0
            guard AXUIElementGetPid(current, &pid) == .success, pid == owner else { throw CaptureError.unverifiedTarget }
            AXUIElementSetMessagingTimeout(current, 0.2)
            let role = try verifiedUnprotectedRole { attributeResult(current, $0) }
            result.append(current)
            if role == "AXWindow" || role == "AXApplication" { return result }
            guard let ref = attribute(current, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                throw CaptureError.unverifiedTarget
            }
            let parent = ref as! AXUIElement
            guard !result.contains(where: { CFEqual($0, parent) }) else { throw CaptureError.unverifiedTarget }
            current = parent
        }
        throw CaptureError.unverifiedTarget
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
            let app = applicationForCapture(pid)
            guard let focused = try selectionFocus(in: app) else {
                // Read-only document views can accept selection commands even
                // when their application exposes no focused AX element.
                let selection = try readSelectionInFocusedWindow(app, pid: pid, cancellation: cancellation)
                return try selectedCapture(selection, fallbackPoint: fallbackPoint, replacement: nil)
            }
            var owner: pid_t = 0
            guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { throw CaptureError.nothingSelected }
            let focusPath = try ancestry(focused, cancellation: cancellation)
            let editor = editorForSelection(in: focusPath, pid: pid)
            let webArea = focusPath.first { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }
            let focusedIsEditor = editor.map { CFEqual($0, focused) } ?? false
            var selection = try selectedText(on: focused, pid: pid, webArea: webArea, cancellation: cancellation)
            var source: AXUIElement? = focused
            if selection == nil {
                if let editor {
                    source = editor
                    if !focusedIsEditor {
                        selection = try selectedText(on: editor, pid: pid, webArea: webArea, cancellation: cancellation)
                    }
                    if selection == nil, let webArea {
                        selection = try readWebSelection(in: webArea, pid: pid, editor: editor, cancellation: cancellation)
                    }
                } else if let webArea = nearestWebArea(in: focusPath, pid: pid) {
                    source = nil
                    selection = try readWebSelection(in: webArea, pid: pid, cancellation: cancellation)
                }
            }
            guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
            guard let selection else { throw CaptureError.nothingSelected }
            let raw = try selection.translationInput()
            var replacement: ReplacementTarget?
            if let source {
                replacement = ReplacementTarget.capture(element: source, pid: pid, selected: raw)
                if replacement == nil, let writable = try? ReplacementTarget.focusedEditor(app, pid: pid, matchingFocus: focused),
                   !CFEqual(writable, source) {
                    replacement = ReplacementTarget.capture(element: writable, pid: pid, selected: raw)
                }
            }
            guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
            guard let currentFocus = try selectionFocus(in: app), CFEqual(currentFocus, focused) else {
                throw CaptureError.nothingSelected
            }
            return try selectedCapture(selection, fallbackPoint: fallbackPoint, replacement: replacement)
        }
    }

    private static func applicationForCapture(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Chromium publishes its native accessibility tree on a role request.
        _ = attribute(app, kAXRoleAttribute)
        return app
    }

    static func prepareAccessibility(pid: pid_t) async throws {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { throw CaptureError.ownApplication }
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        try await perform { cancellation in
            try cancellation.check()
            _ = applicationForCapture(pid)
        }
    }

    private static func selectionFocus(in app: AXUIElement) throws -> AXUIElement? {
        var reference: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &reference) {
        case .noValue, .attributeUnsupported:
            return nil
        case .success:
            guard let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else {
                throw CaptureError.nothingSelected
            }
            return (reference as! AXUIElement)
        default:
            throw CaptureError.nothingSelected
        }
    }

    private static func selectedCapture(
        _ selection: AXSelection, fallbackPoint: CGPoint, replacement: ReplacementTarget?
    ) throws -> SelectedCapture {
        let raw = try selection.translationInput()
        return SelectedCapture(
            text: CapturedText(text: TextLogic.clean(raw),
                               bounds: selection.bounds ?? ScreenGeometry.pointerAnchor(fallbackPoint),
                               method: "选中文字"),
            replacement: replacement)
    }

    struct AXSelection {
        let raw: String
        let bounds: CGRect?

        func translationInput() throws -> String {
            guard !TextLogic.clean(raw).isEmpty else { throw CaptureError.nothingSelected }
            guard raw.count <= TextLogic.maximumInputLength else { throw CaptureError.inputTooLong }
            return raw
        }
    }

    private static let textEditorRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    private static let editorBoundaries: Set<String> = ["AXWebArea", "AXWindow", "AXApplication"]

    private static func editorForSelection(in focusPath: [AXUIElement], pid: pid_t) -> AXUIElement? {
        guard let focus = focusPath.first else { return nil }
        let advertisedRoot = ReplacementTarget.advertisedEditableAncestor(focus, pid: pid)
        for node in focusPath {
            guard let role = attribute(node, kAXRoleAttribute) as? String, !editorBoundaries.contains(role) else { return nil }
            if textEditorRoles.contains(role) { return node }
            // An editor can expose readable text markers without any AX setters.
            if role == kAXGroupRole, advertisedRoot.map({ CFEqual($0, node) }) == true
                || attribute(node, "AXEditable") as? Bool == true {
                return node
            }
        }
        return nil
    }

    private static func selectedText(
        on element: AXUIElement, pid: pid_t, webArea: AXUIElement?, cancellation: CaptureCancellation
    ) throws -> AXSelection? {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        return try readSelection(
            attribute: { attribute(element, $0) },
            parameterized: { parameterized(element, $0, $1) },
            permitsTextMarkers: { role == kAXGroupRole || textEditorRoles.contains(role) },
            hasAuthoritativeCaret: {
                guard role == kAXGroupRole else { return true }
                var names: CFArray?
                guard AXUIElementCopyAttributeNames(element, &names) == .success,
                      let names = names as? [String] else { return true }
                return names.contains(kAXSelectedTextRangeAttribute)
            },
            validateMarkerEndpoints: { start, end in
                for marker in CFEqual(start, end) ? [start] : [start, end] {
                    try cancellation.check()
                    let endpoint = markerElement(marker, in: element) ?? webArea.flatMap { markerElement(marker, in: $0) }
                    guard let endpoint,
                          try markerBelongs(to: element, endpoint: endpoint, pid: pid, cancellation: cancellation) else {
                        return false
                    }
                }
                return true
            }
        )
    }

    static func readSelection(
        attribute: (String) -> CFTypeRef?,
        parameterized: (CFString, CFTypeRef) -> CFTypeRef?,
        permitsTextMarkers: () -> Bool,
        hasAuthoritativeCaret: () -> Bool = { true },
        validateMarkerEndpoints: (AXTextMarker, AXTextMarker) throws -> Bool
    ) throws -> AXSelection? {
        func selectedText() -> String? {
            (attribute(kAXSelectedTextAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func markerSelection() throws -> AXSelection? {
            guard permitsTextMarkers() else { return nil }
            return try readMarkerSelection(attribute: attribute, parameterized: parameterized,
                                           stopsAtCaret: true, validateEndpoints: validateMarkerEndpoints)
        }
        let numericRange: (AXValue, Int)?
        do {
            numericRange = try noncollapsedSelectionRange(attribute(kAXSelectedTextRangeAttribute))
        } catch CaptureError.nothingSelected {
            // Some custom groups answer an unsupported numeric query with a
            // zero range. Accept only positive markers owned by this editor.
            guard !hasAuthoritativeCaret(), let selected = try markerSelection() else {
                throw CaptureError.nothingSelected
            }
            return selected
        }
        if let (reference, length) = numericRange {
            // Some controls only expose the selected text through a range query.
            let rangedText = selectedText().flatMap { $0.utf16.count == length ? $0 : nil }
                ?? (parameterized(kAXStringForRangeParameterizedAttribute as CFString, reference) as? String)
                .flatMap { $0.utf16.count == length ? $0 : nil }
            if let rangedText {
                let bounds = textBounds(parameterized(kAXBoundsForRangeParameterizedAttribute as CFString, reference))
                return AXSelection(raw: rangedText, bounds: bounds.flatMap { $0.width > 0 ? $0 : nil })
            }
        } else if let raw = selectedText() {
            return AXSelection(raw: raw, bounds: nil)
        }
        return try markerSelection()
    }

    private static func noncollapsedSelectionRange(_ reference: CFTypeRef?) throws -> (AXValue, Int)? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        let value = reference as! AXValue
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        // Nil lets the caller try a document selection. An explicit caret ends the read.
        guard range.length > 0 else { throw CaptureError.nothingSelected }
        return (value, range.length)
    }

    static func readMarkerSelection(
        attribute: (String) -> CFTypeRef?,
        parameterized: (CFString, CFTypeRef) -> CFTypeRef?,
        stopsAtCaret: Bool = false,
        validateEndpoints: (AXTextMarker, AXTextMarker) throws -> Bool
    ) throws -> AXSelection? {
        guard let reference = attribute(kAXSelectedTextMarkerRangeAttribute as String),
              CFGetTypeID(reference) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = reference as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(range)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        if CFEqual(start, end) {
            if stopsAtCaret, try validateEndpoints(start, end) { throw CaptureError.nothingSelected }
            return nil
        }
        guard try validateEndpoints(start, end),
              let raw = parameterized(kAXStringForTextMarkerRangeParameterizedAttribute as CFString, range) as? String,
              !raw.isEmpty else { return nil }
        let bounds = textBounds(parameterized(kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString, range))
        return AXSelection(raw: raw, bounds: bounds.flatMap { $0.width > 0 ? $0 : nil })
    }

    private static func markerElement(_ marker: AXTextMarker, in element: AXUIElement) -> AXUIElement? {
        guard let reference = parameterized(element, kAXUIElementForTextMarkerParameterizedAttribute as CFString, marker),
              CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        return (reference as! AXUIElement)
    }

    private static func markerBelongs(
        to editor: AXUIElement, endpoint: AXUIElement, pid: pid_t, cancellation: CaptureCancellation
    ) throws -> Bool {
        var node = endpoint
        // WebKit can report a document-wide range on a field. Each marker
        // must resolve to the field or a descendant without crossing another
        // editor, document or process. Inspect no attributes of foreign nodes.
        for _ in 0..<8 {
            try cancellation.check()
            var owner: pid_t = 0
            guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { return false }
            AXUIElementSetMessagingTimeout(node, 0.2)
            let role: String
            do { role = try verifiedUnprotectedRole { attributeResult(node, $0) } }
            catch CaptureError.unverifiedTarget { return false }
            if CFEqual(node, editor) { return true }
            guard !textEditorRoles.contains(role), !editorBoundaries.contains(role) else {
                return false
            }
            // A custom editor may be an AXGroup. An advertised editable
            // ancestor, when present, must also agree with the intended editor.
            let (result, editableAncestor) = attributeResult(node, kAXEditableAncestorAttribute as String)
            switch result {
            case .noValue, .attributeUnsupported: break
            case .success:
                guard let editableAncestor, CFGetTypeID(editableAncestor) == AXUIElementGetTypeID(),
                      CFEqual(editableAncestor, editor) else { return false }
            default: return false
            }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return false
            }
            node = parent as! AXUIElement
        }
        return false
    }

    private static func nearestWebArea(in path: [AXUIElement], pid: pid_t) -> AXUIElement? {
        for element in path {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return element }
            // A caret in a text control must not resolve to a stale page selection.
            if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return nil }
        }
        return nil
    }

    private static func readWebSelection(
        in webArea: AXUIElement, pid: pid_t, editor: AXUIElement? = nil, cancellation: CaptureCancellation
    ) throws -> AXSelection? {
        // WebKit can expose the document's selection even on leaf elements.
        // Resolve both markers within the focused document before reading text.
        try readMarkerSelection(attribute: { attribute(webArea, $0) },
                                parameterized: { parameterized(webArea, $0, $1) }) { start, end in
            for marker in [start, end] {
                try cancellation.check()
                guard let endpoint = markerElement(marker, in: webArea) else { return false }
                if let editor {
                    guard try markerBelongs(to: editor, endpoint: endpoint, pid: pid, cancellation: cancellation) else {
                        return false
                    }
                    continue
                }
                let path = try ancestry(endpoint, cancellation: cancellation)
                guard let endpointArea = nearestWebArea(in: path, pid: pid), CFEqual(endpointArea, webArea) else { return false }
            }
            return true
        }
    }

    private static func readSelectionInFocusedWindow(
        _ app: AXUIElement, pid: pid_t, cancellation: CaptureCancellation
    ) throws -> AXSelection {
        guard let reference = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            throw CaptureError.nothingSelected
        }
        let window = reference as! AXUIElement
        guard let area = try onlyWebArea(in: window, pid: pid, cancellation: cancellation) else {
            throw CaptureError.selectionNotReady
        }
        // Inspecting WebKit may initialize focus. A caret reported by that
        // newly focused element also takes precedence over document markers.
        func verifyFocus() throws {
            guard let focused = try selectionFocus(in: app) else { return }
            let path = try ancestry(focused, cancellation: cancellation)
            guard let focusedArea = nearestWebArea(in: path, pid: pid), CFEqual(focusedArea, area) else {
                throw CaptureError.nothingSelected
            }
            _ = try noncollapsedSelectionRange(attribute(focused, kAXSelectedTextRangeAttribute))
        }
        try verifyFocus()
        guard let selection = try readWebSelection(in: area, pid: pid, cancellation: cancellation) else {
            if try selectionFocus(in: app) == nil { throw CaptureError.selectionNotReady }
            throw CaptureError.nothingSelected
        }
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard let currentWindow = attribute(app, kAXFocusedWindowAttribute), CFEqual(currentWindow, window) else {
            throw CaptureError.nothingSelected
        }
        try verifyFocus()
        return selection
    }

    private static func onlyWebArea(
        in window: AXUIElement, pid: pid_t, cancellation: CaptureCancellation
    ) throws -> AXUIElement? {
        var remaining = 48
        var area: AXUIElement?
        // Search only structural containers in the focused window, stopping
        // before document contents. Do not guess between multiple documents.
        let containers = ["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea"]
        func visit(_ element: AXUIElement, depth: Int) throws -> Bool {
            try cancellation.check()
            guard remaining > 0 else { return false }
            remaining -= 1
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return false }
            AXUIElementSetMessagingTimeout(element, 0.2)
            let role: String
            do { role = try verifiedUnprotectedRole { attributeResult(element, $0) } }
            catch CaptureError.protectedText { return true }
            catch CaptureError.unverifiedTarget { return false }
            guard role == "AXWebArea" || containers.contains(role) else { return true }
            if role == "AXWebArea" {
                guard attribute(element, "AXHidden") as? Bool != true else { return true }
                guard area == nil else { return false }
                area = element
                return true
            }
            var reference: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &reference)
            if result == .noValue || result == .attributeUnsupported { return true }
            guard result == .success, let children = reference as? [AXUIElement] else { return false }
            guard children.isEmpty || depth < 8 else { return false }
            for child in children {
                guard try visit(child, depth: depth + 1) else { return false }
            }
            return true
        }
        return try visit(window, depth: 0) ? area : nil
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

    private static func textRange(_ reference: CFTypeRef?, allowsCaret: Bool = false) -> NSRange? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(reference as! AXValue, .cfRange, &range),
              range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.length > 0 || (allowsCaret && range.location > 0),
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func textHit(_ element: AXUIElement, at point: CGPoint) -> (offset: Int, bounds: CGRect)? {
        var position = point
        guard let pointValue = AXValueCreate(.cgPoint, &position),
              let reference = parameterized(element, kAXRangeForPositionParameterizedAttribute as CFString, pointValue),
              let range = textRange(reference, allowsCaret: true),
              let rect = textBounds(parameterized(element, kAXBoundsForRangeParameterizedAttribute as CFString, reference)),
              rect.insetBy(dx: -6, dy: -5).contains(point) else { return nil }
        return (range.location, rect)
    }

    static func hitInTextBounds(_ value: String, visibleRange: NSRange?, at point: CGPoint, in field: CGRect,
                                boundsForRange: (NSRange) throws -> CGRect?) rethrows -> (offset: Int, bounds: CGRect)? {
        let text = value as NSString
        let range = visibleRange ?? NSRange(location: 0, length: text.length)
        guard field.contains(point), range.location >= 0, range.location < text.length, range.length > 0,
              range.length <= text.length - range.location, range.length <= TextLogic.maximumInputLength,
              Range(range, in: value) != nil else { return nil }
        var pending = [range]
        // Chromium can return a dummy 0:0 position even with real character
        // bounds. Search only bounded ranges whose screen rectangle hits.
        for _ in 0..<32 {
            guard let next = pending.popLast() else { break }
            guard let bounds = try boundsForRange(next), bounds.intersection(field).contains(point) else { continue }
            let end = NSMaxRange(next)
            let midpoint = next.location + next.length / 2
            let character = text.rangeOfComposedCharacterSequence(at: midpoint)
            let cut = character.location > next.location ? character.location : NSMaxRange(character)
            guard cut < end else { return (next.location, bounds.intersection(field)) }
            pending.append(NSRange(location: cut, length: end - cut))
            pending.append(NSRange(location: next.location, length: cut - next.location))
        }
        return nil
    }

    private static func textControlHover(_ element: AXUIElement, role: String, at point: CGPoint, scope: HoverRecognitionScope,
                                         cancellation: CaptureCancellation) throws -> AccessibleHoverCapture? {
        guard let field = bounds(element), field.contains(point) else { return nil }
        let (valueStatus, rawValue) = attributeResult(element, kAXValueAttribute)
        let raw = rawValue as? String ?? ""
        if !TextLogic.clean(raw).isEmpty {
            guard raw.utf16.count <= 250_000 else { return nil }
            var hasRangeGeometry = false
            let visible = textRange(attribute(element, kAXVisibleCharacterRangeAttribute))
            let hit: (offset: Int, bounds: CGRect)?
            if let direct = textHit(element, at: point), direct.offset < raw.utf16.count {
                hasRangeGeometry = true
                hit = direct
            } else {
                hit = try hitInTextBounds(raw, visibleRange: visible, at: point, in: field) { range in
                    try cancellation.check()
                    var rawRange = CFRange(location: range.location, length: range.length)
                    guard let packed = AXValueCreate(.cfRange, &rawRange) else { return nil }
                    let rect = textBounds(parameterized(element, kAXBoundsForRangeParameterizedAttribute as CFString, packed))
                    hasRangeGeometry = hasRangeGeometry || rect.map { $0.width > 0 } == true
                    return rect
                }
            }
            if let hit, let text = TextLogic.segment(raw, utf16Offset: hit.offset, scope: scope) {
                return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: hit.bounds, method: "系统取词"),
                                              hitTextRange: true)
            }
            // A one-line value can still be translated as a control when the
            // provider offers no glyph geometry. Do not guess among paragraphs.
            let text = TextLogic.clean(raw)
            let singleLineControl = role == kAXTextFieldRole || role == kAXComboBoxRole
            let wholeValueVisible = visible == NSRange(location: 0, length: raw.utf16.count)
            guard !hasRangeGeometry, field.height <= 130, raw.count <= 500,
                  wholeValueVisible || (visible == nil && singleLineControl),
                  !raw.contains(where: \.isNewline),
                  scope != .word || text.split(whereSeparator: \.isWhitespace).count == 1 else { return nil }
            return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: field, method: "系统取词 · 控件"),
                                          hitTextRange: false)
        }
        guard rawValue is String || valueStatus == .noValue || valueStatus == .attributeUnsupported,
              let placeholder = attribute(element, kAXPlaceholderValueAttribute) as? String else { return nil }
        let text = TextLogic.clean(placeholder)
        guard !text.isEmpty, text.count <= 500, !text.contains(where: \.isNewline),
              scope != .word || text.split(whereSeparator: \.isWhitespace).count == 1 else { return nil }
        return AccessibleHoverCapture(capture: CapturedText(text: text, bounds: field, method: "系统取词 · 输入提示"),
                                      hitTextRange: false)
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
    static func accessible(at point: CGPoint, scope: HoverRecognitionScope,
                           window: HoveredWindow? = nil) async throws -> AccessibleHoverCapture? {
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        if let window, window.pid > 0, window.pid != ProcessInfo.processInfo.processIdentifier {
            try await prepareAccessibility(pid: window.pid)
            try Task.checkCancellation()
            guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
            guard hoveredWindow(at: point) == window else { return nil }
        }
        guard let hit = elementAt(point) else { return nil }
        let remote = try ExternalAXElement(hit)
        try Task.checkCancellation()
        return try await perform { cancellation in
                let elements = try ancestry(remote.value, cancellation: cancellation)
                for element in elements {
                    try cancellation.check()
                    guard let role = attribute(element, kAXRoleAttribute) as? String, !editorBoundaries.contains(role) else { break }
                    if textEditorRoles.contains(role) {
                        return try textControlHover(element, role: role, at: point, scope: scope, cancellation: cancellation)
                    }
                }
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

    private static func windowAtPoint(_ point: CGPoint) -> (window: HoveredWindow, occluders: [CGRect])? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windowAtPoint(point, windows: windows, isWindowServer: isSystemWindowServer)
    }

    private static func isSystemWindowServer(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.WindowServer\"" as CFString,
                                             [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func windowAtPoint(_ point: CGPoint, windows: [[String: Any]],
                              isWindowServer: (pid_t) -> Bool) -> (window: HoveredWindow, occluders: [CGRect])? {
        var occluders: [CGRect] = []
        let cursorLayer = CGWindowLevelForKey(.cursorWindow)
        var cursorOwner: pid_t?
        // The list is front to back. All preceding visible bounds can obscure
        // the target even if they don't cover the exact point under the pointer.
        for entry in windows {
            // Window Server may list the pointer as an opaque window. The
            // screenshot excludes it, so it is neither a source nor an occluder.
            if entry[kCGWindowLayer as String] as? CGWindowLevel == cursorLayer,
               let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner > 0,
               owner == cursorOwner || isWindowServer(owner) {
                cursorOwner = owner
                continue
            }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  !frame.isNull, !frame.isInfinite else { return nil }
            guard !frame.isEmpty else { continue }
            if frame.contains(point) {
                guard let id = entry[kCGWindowNumber as String] as? CGWindowID, id != kCGNullWindowID,
                      let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid > 0 else { return nil }
                let sharing = entry[kCGWindowSharingState as String] as? UInt32
                let allowsSharing = sharing == CGWindowSharingType.readOnly.rawValue
                    || sharing == CGWindowSharingType.readWrite.rawValue
                return (HoveredWindow(id: id, pid: pid, bounds: frame, allowsSharing: allowsSharing), occluders)
            }
            occluders.append(frame)
        }
        return nil
    }

    static func hoveredWindow(at point: CGPoint) -> HoveredWindow? { windowAtPoint(point)?.window }

    static func ocrCrop(at point: CGPoint, scope: HoverRecognitionScope, window: CGRect,
                        display: CGRect, occluders: [CGRect]) -> CGRect? {
        let size = scope == .paragraph ? CGSize(width: 1120, height: 640) : CGSize(width: 880, height: 280)
        let requested = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                               width: size.width, height: size.height)
        var crop = requested.intersection(window).intersection(display)
        guard crop.contains(point) else { return nil }
        for bounds in occluders {
            let covered = crop.intersection(bounds)
            if covered.isEmpty { continue }
            // The single-window filter removes overlays. Crop away the parts
            // those overlays conceal so the screenshot cannot see behind them.
            let remaining = [
                CGRect(x: crop.minX, y: crop.minY, width: covered.minX - crop.minX, height: crop.height),
                CGRect(x: covered.maxX, y: crop.minY, width: crop.maxX - covered.maxX, height: crop.height),
                CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: covered.minY - crop.minY),
                CGRect(x: crop.minX, y: covered.maxY, width: crop.width, height: crop.maxY - covered.maxY),
            ]
            guard let visible = remaining.filter({ $0.contains(point) }).max(by: {
                $0.width * $0.height < $1.width * $1.height
            }) else { return nil }
            crop = visible
        }
        return crop
    }

    private static func windowBoundsMatch(_ first: CGRect, _ second: CGRect) -> Bool {
        // AX frames can be fractional while the window server rounds to points.
        abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.maxX - second.maxX) <= 1 && abs(first.maxY - second.maxY) <= 1
    }

    private static func verifiedOCRPath(from element: AXUIElement, window: HoveredWindow,
                                        cancellation: CaptureCancellation) throws -> Bool {
        var current = element
        for _ in 0..<24 {
            try cancellation.check()
            var pid: pid_t = 0
            guard AXUIElementGetPid(current, &pid) == .success, pid == window.pid else { return false }
            AXUIElementSetMessagingTimeout(current, 0.2)
            let role = try verifiedUnprotectedRole { attributeResult(current, $0) }
            if role == "AXWindow" {
                guard let frame = bounds(current) else { return false }
                return windowBoundsMatch(frame, window.bounds)
            }
            guard role != "AXApplication",
                  let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(parent, current) else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    @MainActor
    private static func verifiedOCRHit(at point: CGPoint, window: HoveredWindow,
                                       previous: ExternalAXElement? = nil) async throws -> ExternalAXElement? {
        func isCurrent() -> Bool {
            let pointer = TextLogic.quartzPoint(NSEvent.mouseLocation, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
            return hypot(pointer.x - point.x, pointer.y - point.y) <= 3 && hoveredWindow(at: point) == window
        }
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard AXIsProcessTrusted() else { throw CaptureError.noAccessibilityPermission }
        guard window.allowsSharing, isCurrent(), let hit = elementAt(point),
              previous.map({ CFEqual($0.value, hit) }) ?? true else { return nil }
        let remote = try ExternalAXElement(hit)
        do {
            guard try await perform({ cancellation in
                try verifiedOCRPath(from: remote.value, window: window, cancellation: cancellation)
            }) else { return nil }
        } catch CaptureError.unverifiedTarget {
            return nil
        }
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard isCurrent() else { return nil }
        return remote
    }

    @MainActor
    static func ocr(at point: CGPoint, scope: HoverRecognitionScope, window: HoveredWindow) async throws -> CapturedText? {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noScreenPermission }
        guard let hit = try await verifiedOCRHit(at: point, window: window) else { return nil }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first(where: { $0.displayID == displayID }),
              let source = shareable.windows.first(where: { $0.windowID == window.id }),
              source.owningApplication?.processID == window.pid, windowBoundsMatch(source.frame, window.bounds),
              try await verifiedOCRHit(at: point, window: window, previous: hit) != nil,
              let stack = windowAtPoint(point), stack.window == window,
              let crop = ocrCrop(at: point, scope: scope, window: window.bounds, display: displayBounds,
                                 occluders: stack.occluders) else { return nil }
        let filter = SCContentFilter(display: display, including: [source])
        filter.includeMenuBar = false
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { return nil }
        let config = SCScreenshotConfiguration()
        config.sourceRect = crop.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        config.width = max(1, Int((crop.width * scale).rounded()))
        config.height = max(1, Int((crop.height * scale).rounded()))
        config.showsCursor = false
        config.includeChildWindows = false
        config.ignoreShadows = true
        config.ignoreClipping = false
        try Task.checkCancellation()
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noScreenPermission }
        guard CGDisplayBounds(displayID) == displayBounds else { return nil }
        func cropIsVisible() -> Bool {
            guard CGDisplayBounds(displayID) == displayBounds,
                  let stack = windowAtPoint(point), stack.window == window else { return false }
            return !stack.occluders.contains(where: { !$0.intersection(crop).isEmpty })
        }
        let screenshot = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = screenshot.sdrImage, image.width == config.width, image.height == config.height,
              try await verifiedOCRHit(at: point, window: window, previous: hit) != nil,
              cropIsVisible() else { return nil }
        guard let text = try await recognize(image: image, region: crop, at: point, scope: scope),
              try await verifiedOCRHit(at: point, window: window, previous: hit) != nil,
              cropIsVisible() else { return nil }
        return text
    }

    private struct OCRLine {
        let bounds: CGRect
        let candidate: VNRecognizedText

        var text: String { candidate.string }
        var isEnglish: Bool { candidate.confidence >= 0.35 && TextLogic.hasEnglishOCR(text) }
    }

    private static func recognizeLines(in image: CGImage, region: CGRect, job: OCRJob) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        // The accurate recognizer can stall on model initialization, even on the CPU.
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: .main)
        }
        job.activate(request)
        if job.cancelled { throw CancellationError() }
        try VNImageRequestHandler(cgImage: image).perform([request])
        if job.cancelled { throw CancellationError() }
        return (request.results ?? []).compactMap { observation in
            // Keep weak and corrupt rows in the hit test. Removing them here
            // could let a nearby English line take their place under the pointer.
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let box = observation.boundingBox
            let bounds = CGRect(x: region.minX + box.minX * region.width,
                                y: region.minY + (1 - box.maxY) * region.height,
                                width: box.width * region.width, height: box.height * region.height)
            return OCRLine(bounds: bounds, candidate: candidate)
        }
    }

    private static func paragraphLines(around hitIndex: Int, in lines: [OCRLine]) -> (rows: [OCRLine], interrupted: Bool) {
        let hit = lines[hitIndex].bounds
        let column = lines.indices.filter { index in
            let rect = lines[index].bounds
            return abs(rect.minX - hit.minX) <= max(10, hit.height, rect.height)
        }.sorted { lines[$0].bounds.midY < lines[$1].bounds.midY }
        guard let origin = column.firstIndex(of: hitIndex) else { return ([lines[hitIndex]], false) }
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
        var end = origin
        var interrupted = false
        while start > 0, adjacent(lines[column[start - 1]], lines[column[start]]) {
            guard lines[column[start - 1]].isEnglish else { interrupted = true; break }
            start -= 1
        }
        while end + 1 < column.count, adjacent(lines[column[end]], lines[column[end + 1]]) {
            guard lines[column[end + 1]].isEnglish else { interrupted = true; break }
            end += 1
        }
        return (column[start...end].map { lines[$0] }, interrupted)
    }

    static func recognize(image: CGImage, region crop: CGRect, at point: CGPoint, scope: HoverRecognitionScope) async throws -> CapturedText? {
        guard !crop.isEmpty, !crop.isInfinite, !crop.isNull, crop.contains(point) else { return nil }
        let job = OCRJob()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedText?, Error>) in
            ocrQueue.async {
                do {
                    let lines = try recognizeLines(in: image, region: crop, job: job)
                    // Hit-test the actual text line. Blank space must not pick the nearest paragraph.
                    guard let hitIndex = lines.indices.filter({ index in
                        let bounds = lines[index].bounds
                        return bounds.insetBy(dx: -max(4, bounds.height), dy: -4).contains(point)
                    }).min(by: { abs(lines[$0].bounds.midY - point.y) < abs(lines[$1].bounds.midY - point.y) }),
                          lines[hitIndex].isEnglish else {
                        continuation.resume(returning: nil); return
                    }
                    var hit = lines[hitIndex]
                    var isPartialParagraph = false
                    if scope == .paragraph, hit.bounds.insetBy(dx: -4, dy: -4).contains(point) {
                        let (paragraph, interrupted) = paragraphLines(around: hitIndex, in: lines)
                        let text = paragraph.map(\.text).joined(separator: " ")
                        isPartialParagraph = interrupted || text.count > TextLogic.maximumHoverLength || paragraph.contains { row in
                            // Vision can omit a clipped glyph and leave a character-width gap at the edge.
                            let horizontalMargin = max(1, row.bounds.height * 0.65)
                            let verticalMargin = max(1, row.bounds.height / 4)
                            return !crop.insetBy(dx: horizontalMargin, dy: verticalMargin).contains(row.bounds)
                        }
                        if paragraph.count > 1, text.count <= TextLogic.maximumHoverLength, TextLogic.hasEnglishOCR(text) {
                            if job.cancelled { throw CancellationError() }
                            continuation.resume(returning: CapturedText(text: text, bounds: hit.bounds,
                                method: "本机 OCR · 段落", isPartialParagraph: isPartialParagraph))
                            return
                        }
                        isPartialParagraph = isPartialParagraph || paragraph.count > 1
                    }
                    var hitRegion = crop
                    // Nearby control icons can make the fast detector drop an initial
                    // letter. Re-read just this line, excluding surrounding UI icons.
                    let lineRegion = hit.bounds.insetBy(dx: -max(32, hit.bounds.height * 1.25), dy: -12).intersection(crop)
                    let scaleX = CGFloat(image.width) / crop.width
                    let scaleY = CGFloat(image.height) / crop.height
                    let pixels = CGRect(x: (lineRegion.minX - crop.minX) * scaleX,
                                        y: (lineRegion.minY - crop.minY) * scaleY,
                                        width: lineRegion.width * scaleX, height: lineRegion.height * scaleY).integral
                    if let lineImage = image.cropping(to: pixels) {
                        let refinedRegion = CGRect(x: crop.minX + pixels.minX / scaleX, y: crop.minY + pixels.minY / scaleY,
                                                   width: CGFloat(lineImage.width) / scaleX, height: CGFloat(lineImage.height) / scaleY)
                        let refined = try recognizeLines(in: lineImage, region: refinedRegion, job: job)
                        if let matching = refined.filter({ $0.bounds.insetBy(dx: -4, dy: -4).contains(point) })
                            .min(by: { abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y) }),
                           matching.isEnglish {
                            hit = matching
                            hitRegion = refinedRegion
                        }
                    }
                    let line = hit.text
                    guard line.count <= TextLogic.maximumHoverLength, hit.bounds.insetBy(dx: -4, dy: -4).contains(point) else {
                        continuation.resume(returning: nil); return
                    }
                    if scope == .word {
                        let tokenizer = NLTokenizer(unit: .word)
                        tokenizer.string = line
                        var found: CapturedText?
                        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                            if job.cancelled { return false }
                            if let b = try? hit.candidate.boundingBox(for: range)?.boundingBox {
                                let box = CGRect(x: hitRegion.minX + b.minX * hitRegion.width, y: hitRegion.minY + (1-b.maxY) * hitRegion.height,
                                                 width: b.width * hitRegion.width, height: b.height * hitRegion.height)
                                if box.insetBy(dx: -3, dy: -3).contains(point) {
                                    let word = String(line[range])
                                    if TextLogic.hasEnglishOCR(word) {
                                        found = CapturedText(text: word, bounds: box, method: "本机 OCR")
                                    }
                                    return false
                                }
                            }
                            return true
                        }
                        if job.cancelled { throw CancellationError() }
                        continuation.resume(returning: found); return
                    }
                    if job.cancelled { throw CancellationError() }
                    continuation.resume(returning: CapturedText(text: line, bounds: hit.bounds,
                        method: "本机 OCR · 当前行", isPartialParagraph: isPartialParagraph))
                } catch { continuation.resume(throwing: error) }
            }
            }
        } onCancel: {
            job.cancel()
        }
    }
}
