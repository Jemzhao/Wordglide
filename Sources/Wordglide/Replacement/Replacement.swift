import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum ReplacementError: LocalizedError {
    case changed, unavailable, inProgress, alreadyAttempted, composing, writeUnsupported
    case noFocusedEditor, unsupportedEditor, editabilityUnconfirmed, unreadableValue, unreadableSelection
    case selectionNotWritable, emptyInput, multipleSelections, embeddedObject

    var permitsEditableAncestorResolution: Bool {
        switch self {
        case .unsupportedEditor, .editabilityUnconfirmed: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .changed:
            return "输入框、文字或选区已变化，请重新触发翻译。"
        case .unavailable:
            return "当前输入框未提供可靠的编辑信息，请复制原文后翻译。"
        case .noFocusedEditor:
            return "没有读取到正在编辑的输入框，请先点击输入框再试。"
        case .unsupportedEditor:
            return "当前焦点未被应用标记为文本编辑区域，暂不能直接替换。"
        case .editabilityUnconfirmed:
            return "此输入框未提供可验证的编辑能力，暂不能直接替换。"
        case .unreadableValue:
            return "此输入框未提供完整原文，暂不能直接替换。"
        case .unreadableSelection:
            return "此输入框未提供可靠的光标或选区位置，暂不能直接替换。"
        case .selectionNotWritable:
            return "此输入框不支持设置选区，请先选中文字再试。"
        case .emptyInput:
            return "输入框中没有可翻译的文字。"
        case .multipleSelections:
            return "当前有多个选区或光标，请只保留一个选区后再替换。"
        case .embeddedObject:
            return "待替换内容包含图片或附件，请缩小选区或复制译文。"
        case .writeUnsupported:
            return "此输入框不支持直接写入选区。可以翻译选中文字后复制译文。"
        case .inProgress:
            return "替换正在进行，请稍候。"
        case .alreadyAttempted:
            return "此选区已提交过替换。请检查目标应用。如需再替换，请重新选中文字。"
        case .composing:
            return "输入法仍在组词，请先确认文字，再触发翻译替换。"
        }
    }
}

struct DirectReplacementCapture: @unchecked Sendable {
    let target: ReplacementTarget
    let text: String
    /// Quartz coordinates. A zero rect means the application supplied no geometry.
    let bounds: CGRect
    let replacesWholeField: Bool
}

/// A read-only plan. In the whole-field case `edit` describes the eventual
/// replacement, while `originalRange` remains the user's caret during translation.
struct DirectReplacementPlan: Sendable {
    let edit: SelectionEdit
    let originalRange: NSRange
    let replacesWholeField: Bool

    init(value: String, selected: String?, range: NSRange, selectionWritable: Bool) throws {
        let length = value.utf16.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location,
              Range(range, in: value) != nil else { throw ReplacementError.unreadableSelection }
        let start = value.utf16.index(value.utf16.startIndex, offsetBy: range.location)
        let end = value.utf16.index(start, offsetBy: range.length)
        guard String.Index(start, within: value) != nil, String.Index(end, within: value) != nil else {
            throw ReplacementError.unreadableSelection
        }
        originalRange = range
        if range.length > 0 {
            guard let selected, !TextLogic.clean(selected).isEmpty,
                  value.utf16.count <= 1_000_000 else { throw ReplacementError.unreadableSelection }
            guard selected.utf16.count <= TextLogic.maximumInputLength else { throw CaptureError.inputTooLong }
            let selection = SelectionEdit(value: value, selected: selected, range: range)
            guard selection.replacing(with: selected) != nil else { throw ReplacementError.changed }
            edit = selection
            replacesWholeField = false
        } else {
            guard selected == nil || selected == "" else { throw ReplacementError.changed }
            guard !TextLogic.clean(value).isEmpty else { throw ReplacementError.emptyInput }
            guard selectionWritable else { throw ReplacementError.selectionNotWritable }
            guard length <= TextLogic.maximumInputLength else { throw CaptureError.inputTooLong }
            edit = SelectionEdit(value: value, selected: value, range: NSRange(location: 0, length: length))
            replacesWholeField = true
        }
        try ReplacementContentPolicy.requireTextOnly(edit.selected)
    }
}

/// Typed evidence only: an absent or unsupported AX attribute is not a universal
/// guarantee that an editor has finished composing. A non-null standard marker
/// range explicitly denotes provisional input, including a zero-length marker.
enum ReplacementCompositionEvidence {
    static func isActive(standardRange: CFTypeRef? = nil, legacyFlag: Bool? = nil,
                         legacyText: CFTypeRef? = nil, legacyRange: CFTypeRef? = nil) -> Bool {
        if let standardRange, CFGetTypeID(standardRange) == AXTextMarkerRangeGetTypeID() { return true }
        if legacyFlag == true { return true }
        if let text = legacyText as? String, !text.isEmpty { return true }
        if let text = legacyText as? NSAttributedString, text.length > 0 { return true }
        guard let legacyRange, CFGetTypeID(legacyRange) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        return AXValueGetValue(legacyRange as! AXValue, .cfRange, &range)
            && range.location >= 0 && range.location != NSNotFound && range.length > 0
    }
}

/// Shared by all copies of a target, including two buttons awaiting AX replies.
/// Once a write has been sent, even an unconfirmed result consumes the target.
final class ReplacementAttempt: @unchecked Sendable {
    private enum State { case ready, checking, sent }
    private let lock = NSLock()
    private var state = State.ready
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    /// Invalidation is permanent and shared by both the main-actor request and
    /// the AX preparation queue. It does not undo or retry a write already sent.
    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        if state == .sent { throw ReplacementError.alreadyAttempted }
        guard valid else { throw ReplacementError.changed }
        switch state {
        case .ready: state = .checking
        case .checking: throw ReplacementError.inProgress
        case .sent: throw ReplacementError.alreadyAttempted
        }
    }

    func abandonBeforeWrite() {
        lock.lock()
        defer { lock.unlock() }
        if state == .checking { state = .ready }
    }

    /// Atomically consumes a still-valid pending request at the write boundary.
    @discardableResult
    func markSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid, state == .checking else { return false }
        state = .sent
        return true
    }
}

/// An immutable remote AX proxy. Every validation runs off the UI thread and
/// verifies the process again before asking the remote application for data.
struct ReplacementTarget: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let edit: SelectionEdit
    let attempt: ReplacementAttempt

    private let queue: DispatchQueue
    private let originalCaret: NSRange?

    init(element: AXUIElement, pid: pid_t, edit: SelectionEdit) {
        self.element = element
        self.pid = pid
        self.edit = edit
        self.attempt = ReplacementAttempt()
        self.queue = DispatchQueue(label: "app.wordglide.replacement", qos: .userInitiated)
        self.originalCaret = nil
    }

    private init(element: AXUIElement, pid: pid_t, plan: DirectReplacementPlan) {
        self.element = element
        self.pid = pid
        self.edit = plan.edit
        self.attempt = ReplacementAttempt()
        self.queue = DispatchQueue(label: "app.wordglide.replacement", qos: .userInitiated)
        self.originalCaret = plan.replacesWholeField ? plan.originalRange : nil
    }

    private static func owns(_ element: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return pid > 0 && pid != ProcessInfo.processInfo.processIdentifier
            && AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private static func requireSafeAncestry(_ element: AXUIElement, pid: pid_t, checkComposition: Bool = true) throws {
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        // Secure descendants must remain excluded even when an app puts the
        // protected flag on a containing view rather than on the text field.
        var current = element
        var seen: [AXUIElement] = []
        for _ in 0..<16 {
            guard owns(current, pid: pid) else { throw ReplacementError.unavailable }
            let role = try TextCapture.verifiedUnprotectedRole { TextCapture.attributeResult(current, $0) }
            if checkComposition, hasReadableComposition(current) { throw ReplacementError.composing }
            if role == "AXWindow" || role == "AXApplication" { return }
            seen.append(current)
            let (status, reference) = TextCapture.attributeResult(current, kAXParentAttribute)
            guard status == .success, let parent = reference,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { throw CaptureError.unverifiedTarget }
            current = parent as! AXUIElement
            guard !seen.contains(where: { CFEqual($0, current) }) else { throw CaptureError.unverifiedTarget }
            AXUIElementSetMessagingTimeout(current, 0.15)
        }
        throw CaptureError.unverifiedTarget
    }

    /// An editable ancestor must be advertised, not just answer a direct query:
    /// browser implementations can answer the query even for a read-only child.
    static func advertisedEditableAncestor(_ element: AXUIElement, pid: pid_t) -> AXUIElement? {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attributes = names as? [String], attributes.contains("AXEditableAncestor"),
              let ref = TextCapture.attribute(element, "AXEditableAncestor"),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let ancestor = ref as! AXUIElement
        guard owns(ancestor, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(ancestor, 0.15)
        return ancestor
    }

    private static func attributeIsWritable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func requireEditable(_ element: AXUIElement, pid: pid_t) throws {
        try requireSafeAncestry(element, pid: pid)
        let role = TextCapture.attribute(element, kAXRoleAttribute) as? String ?? ""
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup"].contains(role) else {
            throw ReplacementError.unsupportedEditor
        }
        let enabled = TextCapture.attribute(element, kAXEnabledAttribute) as? Bool
        let readOnly = TextCapture.attribute(element, "AXReadOnly") as? Bool == true
            || TextCapture.attribute(element, "AXARIAReadOnly") as? Bool == true
        let explicitEditable = TextCapture.attribute(element, "AXEditable") as? Bool
        let valueWritable = attributeIsWritable(element, kAXValueAttribute)
        let selectedTextWritable = attributeIsWritable(element, kAXSelectedTextAttribute)
        if ReplacementEditability.allows(role: role, enabled: enabled, readOnly: readOnly,
            explicitEditable: explicitEditable, valueWritable: valueWritable, selectedTextWritable: selectedTextWritable,
            selectionWritable: false, advertisedEditableRoot: false) { return }

        // contenteditable may be AXGroup and expose selection editing without
        // AXValue setters. Never infer editability from selection alone.
        let root = advertisedEditableAncestor(element, pid: pid)
        guard ReplacementEditability.allows(role: role, enabled: enabled, readOnly: readOnly,
            explicitEditable: explicitEditable, valueWritable: valueWritable, selectedTextWritable: selectedTextWritable,
            selectionWritable: selectionIsWritable(element), advertisedEditableRoot: root.map { CFEqual($0, element) } ?? false)
        else { throw ReplacementError.editabilityUnconfirmed }
    }

    private static func editable(_ element: AXUIElement, pid: pid_t) -> Bool {
        (try? requireEditable(element, pid: pid)) != nil
    }

    private static func hasExplicitEditingDenial(_ element: AXUIElement) -> Bool {
        TextCapture.attribute(element, "AXReadOnly") as? Bool == true
            || TextCapture.attribute(element, "AXARIAReadOnly") as? Bool == true
            || TextCapture.attribute(element, "AXEditable") as? Bool == false
            || TextCapture.attribute(element, kAXEnabledAttribute) as? Bool == false
    }

    static func focusedEditor(_ app: AXUIElement, pid: pid_t, matchingFocus: AXUIElement? = nil) throws -> AXUIElement {
        guard let ref = TextCapture.attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { throw ReplacementError.noFocusedEditor }
        let focused = ref as! AXUIElement
        guard owns(focused, pid: pid) else { throw ReplacementError.unavailable }
        if let matchingFocus, !CFEqual(focused, matchingFocus) { throw ReplacementError.changed }
        AXUIElementSetMessagingTimeout(focused, 0.15)
        try requireSafeAncestry(focused, pid: pid)
        do {
            try requireEditable(focused, pid: pid)
            return focused
        } catch {
            // Follow only the nearest, explicitly advertised editing root. Do
            // not search siblings or promote a read-only island to its parent.
            guard let reason = error as? ReplacementError, reason.permitsEditableAncestorResolution,
                  !hasExplicitEditingDenial(focused),
                  let ancestor = advertisedEditableAncestor(focused, pid: pid),
                  !CFEqual(ancestor, focused) else { throw error }
            var current = focused
            for _ in 0..<6 {
                guard let ref = TextCapture.attribute(current, kAXParentAttribute),
                      CFGetTypeID(ref) == AXUIElementGetTypeID() else { break }
                current = ref as! AXUIElement
                guard owns(current, pid: pid) else { break }
                AXUIElementSetMessagingTimeout(current, 0.15)
                try requireSafeAncestry(current, pid: pid)
                guard !hasExplicitEditingDenial(current) else { throw ReplacementError.editabilityUnconfirmed }
                if CFEqual(current, ancestor) {
                    guard let root = advertisedEditableAncestor(ancestor, pid: pid), CFEqual(root, ancestor) else { throw error }
                    try requireEditable(ancestor, pid: pid)
                    // Recheck the leaf too: a protected/IME state may have
                    // changed while its containing editor was being resolved.
                    try requireSafeAncestry(focused, pid: pid)
                    guard !hasExplicitEditingDenial(focused),
                          let currentFocus = TextCapture.attribute(app, kAXFocusedUIElementAttribute),
                          CFGetTypeID(currentFocus) == AXUIElementGetTypeID(), CFEqual(currentFocus, focused) else {
                        throw ReplacementError.changed
                    }
                    return ancestor
                }
                let role = TextCapture.attribute(current, kAXRoleAttribute) as? String
                if role == "AXWindow" || role == "AXApplication" || role == "AXWebArea" { break }
            }
            throw error
        }
    }

    private static func selectedRange(_ element: AXUIElement, allowCaret: Bool = false) -> NSRange? {
        guard let reference = TextCapture.attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(reference as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= (allowCaret ? 0 : 1) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// A single AXSelectedTextRange does not prove there is only one selection:
    /// editors may also expose multiple ranges, and writing can affect all of
    /// them. Absence keeps the existing single-range capability. Successful
    /// but malformed or contradictory replies cannot establish a safe target.
    private static func requireSingleSelection(_ element: AXUIElement, range: NSRange) throws {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangesAttribute as CFString, &reference)
        switch result {
        case .attributeUnsupported, .noValue:
            try ReplacementContentPolicy.requireSingleSelection(range, reported: nil)
        case .success:
            guard let reference else { throw ReplacementError.unreadableSelection }
            let ranges = try ReplacementContentPolicy.reportedRanges(from: reference)
            try ReplacementContentPolicy.requireSingleSelection(range, reported: ranges)
        default:
            throw ReplacementError.unreadableSelection
        }
    }

    /// AX does not expose a universal IME-composition query. Reject affirmative
    /// information when a control supplies it; absence is not proof that every
    /// editor has finished composing. The complete value and caret are also
    /// revalidated immediately before writing.
    private static func hasReadableComposition(_ element: AXUIElement) -> Bool {
        let standard = TextCapture.attribute(element, kAXTextInputMarkedTextMarkerRangeAttribute as String)
        if ReplacementCompositionEvidence.isActive(standardRange: standard) { return true }
        return ReplacementCompositionEvidence.isActive(
            legacyFlag: TextCapture.attribute(element, "AXHasMarkedText") as? Bool,
            legacyText: TextCapture.attribute(element, "AXMarkedText"),
            legacyRange: TextCapture.attribute(element, "AXMarkedTextRange"))
    }

    private static func selectionIsWritable(_ element: AXUIElement) -> Bool {
        attributeIsWritable(element, kAXSelectedTextRangeAttribute)
    }

    private static func selectionValue(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }

    private static func rangeBounds(_ element: AXUIElement, range: NSRange) -> CGRect? {
        guard let value = selectionValue(range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        value, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.width >= 0, !rect.isInfinite, !rect.isNull else { return nil }
        return rect
    }

    static func captureForDirectReplacement(pid: pid_t) async throws -> DirectReplacementCapture {
        try Task.checkCancellation()
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { throw CaptureError.ownApplication }
        guard AXIsProcessTrusted() else { throw CaptureError.noAccessibilityPermission }
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        let capture = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DirectReplacementCapture, Error>) in
            TextCapture.queue.async {
                do {
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, 0.15)
                    let element = try focusedEditor(app, pid: pid)
                    guard attributeIsWritable(element, kAXSelectedTextAttribute) else {
                        throw ReplacementError.writeUnsupported
                    }
                    guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
                    guard !hasReadableComposition(element) else { throw ReplacementError.composing }
                    guard let range = selectedRange(element, allowCaret: true) else { throw ReplacementError.unreadableSelection }
                    try requireSingleSelection(element, range: range)
                    guard let value = TextCapture.attribute(element, kAXValueAttribute) as? String else { throw ReplacementError.unreadableValue }
                    let selected = TextCapture.attribute(element, kAXSelectedTextAttribute) as? String
                    let plan = try DirectReplacementPlan(value: value, selected: selected, range: range,
                                                         selectionWritable: selectionIsWritable(element))
                    // Keep the established strict selection-capture contract.
                    let target: ReplacementTarget
                    if plan.replacesWholeField {
                        target = ReplacementTarget(element: element, pid: pid, plan: plan)
                    } else {
                        guard let selected, let strict = Self.capture(element: element, pid: pid, selected: selected),
                              strict.edit.value == value, strict.edit.range == range else {
                            throw ReplacementError.changed
                        }
                        target = strict
                    }
                    let bounds = rangeBounds(element, range: range) ?? TextCapture.bounds(element) ?? .zero
                    try target.validateOnQueue(prepared: false)
                    continuation.resume(returning: DirectReplacementCapture(target: target, text: plan.edit.selected,
                        bounds: bounds, replacesWholeField: plan.replacesWholeField))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return capture
    }

    static func capture(element: AXUIElement, pid: pid_t, selected: String) -> ReplacementTarget? {
        guard owns(element, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard editable(element, pid: pid), attributeIsWritable(element, kAXSelectedTextAttribute),
              let range = selectedRange(element),
              let value = TextCapture.attribute(element, kAXValueAttribute) as? String,
              value.utf16.count <= 1_000_000,
              TextCapture.attribute(element, kAXSelectedTextAttribute) as? String == selected else { return nil }
        guard (try? requireSingleSelection(element, range: range)) != nil,
              (try? ReplacementContentPolicy.requireTextOnly(selected)) != nil else { return nil }
        let edit = SelectionEdit(value: value, selected: selected, range: range)
        guard edit.replacing(with: selected) != nil else { return nil }
        return ReplacementTarget(element: element, pid: pid, edit: edit)
    }

    private func validateOnQueue(prepared: Bool) throws {
        guard Self.owns(element, pid: pid) else { throw ReplacementError.unavailable }
        try ReplacementContentPolicy.requireTextOnly(edit.selected)
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
        guard !Self.hasReadableComposition(element) else { throw ReplacementError.composing }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let focused = try Self.focusedEditor(app, pid: pid)
        guard CFEqual(focused, element),
              TextCapture.attribute(app, kAXFrontmostAttribute) as? Bool == true else { throw ReplacementError.changed }
        guard Self.attributeIsWritable(element, kAXSelectedTextAttribute) else {
            throw ReplacementError.writeUnsupported
        }
        guard originalCaret == nil || Self.selectionIsWritable(element) else {
            throw ReplacementError.selectionNotWritable
        }
        guard TextCapture.attribute(element, kAXValueAttribute) as? String == edit.value else {
            throw ReplacementError.changed
        }
        let expectedCaret = prepared ? nil : originalCaret
        let range = expectedCaret ?? edit.range
        guard let currentRange = Self.selectedRange(element, allowCaret: expectedCaret != nil) else {
            throw ReplacementError.unreadableSelection
        }
        try Self.requireSingleSelection(element, range: currentRange)
        let selected = TextCapture.attribute(element, kAXSelectedTextAttribute) as? String
        let expectedSelected = expectedCaret != nil ? "" : edit.selected
        guard currentRange == range,
              selected == expectedSelected || (expectedCaret != nil && selected == nil) else { throw ReplacementError.changed }
    }

    func validate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try validateOnQueue(prepared: false); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Keep the final checks and the addressed AX write on one queue. AX does
    /// not expose a compare-and-set selection API, so always verify the result.
    fileprivate func writeSelectedText(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var attemptedSelection = false
                do {
                    guard attempt.isValid else { throw ReplacementError.changed }
                    try validateOnQueue(prepared: false)
                    if originalCaret != nil {
                        guard let all = Self.selectionValue(edit.range) else { throw ReplacementError.unavailable }
                        guard attempt.isValid else { throw ReplacementError.changed }
                        // Mark before the remote call: an AX timeout can still
                        // have changed the selection in the receiving process.
                        attemptedSelection = true
                        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, all) == .success else {
                            throw ReplacementError.unavailable
                        }
                        try validateOnQueue(prepared: true)
                    }
                    guard !IsSecureEventInputEnabled() else { throw CaptureError.protectedText }
                    guard attempt.markSent() else { throw ReplacementError.changed }
                    // Even an AX error may arrive after the editor applied the
                    // change. The caller confirms the value without retrying.
                    _ = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                    continuation.resume()
                } catch {
                    if attemptedSelection, let originalCaret, let caret = Self.selectionValue(originalCaret),
                       (try? validateOnQueue(prepared: true)) != nil {
                        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caret)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func currentValue() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                // The editor might have switched to a protected state after
                // accepting the write. Leave the result unconfirmed in that case.
                guard (try? Self.requireSafeAncestry(element, pid: pid, checkComposition: false)) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                // A bounded AX message keeps an unresponsive editor from
                // extending the result-check deadline indefinitely.
                AXUIElementSetMessagingTimeout(element, 0.12)
                continuation.resume(returning: TextCapture.attribute(element, kAXValueAttribute) as? String)
            }
        }
    }
}

@MainActor
enum TextReplacement {
    /// A false result means the write was requested but its final value could
    /// not be confirmed. The same target must never be submitted again.
    static func perform(_ target: ReplacementTarget, text: String,
                        stillCurrent: () -> Bool, releasePanelFocus: () -> Void) async throws -> Bool {
        try target.attempt.begin()
        defer { target.attempt.abandonBeforeWrite() }

        guard !text.isEmpty, text.utf16.count <= 32_000,
              let expected = target.edit.replacing(with: text), expected != target.edit.value else {
            throw ReplacementError.unavailable
        }

        try Task.checkCancellation()
        guard stillCurrent(), target.attempt.isValid else { throw ReplacementError.changed }
        releasePanelFocus()
        guard stillCurrent(), target.attempt.isValid else { throw ReplacementError.changed }
        try await target.writeSelectedText(text)

        // Confirmation is independent of an editor or card dismissing the
        // request. An unconfirmed write is never replayed.
        let confirmation = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(1_600))
            while clock.now < deadline {
                if await target.currentValue() == expected { return true }
                guard clock.now < deadline else { break }
                try? await Task.sleep(for: .milliseconds(70))
            }
            return false
        }
        return await confirmation.value
    }
}
