import AppKit
import Combine

enum DirectReplacementOutcome: Equatable {
    case success
    case uncertain
    case failure(String)
    case cancelled(String)

    var message: String {
        switch self {
        case .success:
            return "已替换为译文 · 可在原输入框按 ⌘Z 撤销"
        case .uncertain:
            return "已发送一次粘贴，但无法确认结果。请检查原输入框；未重复替换。"
        case .failure(let message), .cancelled(let message):
            return message
        }
    }
}

/// Coordinates an explicitly requested replacement without activating a panel.
/// AX capture and paste remain in Replacement.swift; no text is submitted until
/// the original application, focused control, value and selection are rechecked.
@MainActor
final class DirectReplacementCoordinator: ObservableObject {
    struct Dependencies {
        var capture: (pid_t) async throws -> DirectReplacementCapture
        var translate: (String, String) async throws -> String
        var validate: (DirectReplacementCapture) async throws -> Void
        var perform: (DirectReplacementCapture, String, @escaping () -> Bool) async throws -> Bool
        var isFrontmost: (pid_t) -> Bool
        var pause: () async throws -> Void
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isCommitting = false
    @Published private(set) var status = ""
    var statusChanged: ((String) -> Void)?
    var captured: ((CGRect, Bool) -> Void)?
    var finished: ((DirectReplacementOutcome) -> Void)?
    var recoveryAvailable: ((ReplacementRecovery) -> Void)?

    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var requestID: UUID?
    private var submissionValid = false
    private var activeAttempt: ReplacementAttempt?

    convenience init(translator: any TranslationService) {
        self.init(dependencies: Dependencies(
            capture: { try await ReplacementTarget.captureForDirectReplacement(pid: $0) },
            translate: { try await translator.translate($0, target: $1) },
            validate: { try await $0.target.validate() },
            perform: { capture, output, stillCurrent in
                try await TextReplacement.perform(capture.target, text: output,
                    stillCurrent: stillCurrent, releasePanelFocus: {})
            },
            isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 },
            pause: { try await Task.sleep(for: .milliseconds(160)) }
        ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Returns false when a previous request is still running. A held key or a
    /// second shortcut must never start a second paste transaction.
    @discardableResult
    func start(pid: pid_t, targetLanguage: String = "auto") -> Bool {
        guard !isRunning else {
            updateStatus("快捷替换正在进行，请稍候。")
            return false
        }
        let id = UUID()
        activeAttempt = nil
        requestID = id
        submissionValid = true
        isRunning = true
        isCommitting = false
        updateStatus("正在读取输入框…")
        task = Task { [weak self] in
            await self?.run(pid: pid, targetLanguage: targetLanguage, id: id)
        }
        return true
    }

    /// Input, clicks and app changes invalidate a pending translation. Once a
    /// paste is underway, retain its confirmation task: cancellation cannot tell
    /// us whether an already posted event reached the editor.
    func cancel() {
        guard let id = requestID else { return }
        activeAttempt?.invalidate()
        submissionValid = false
        if isCommitting { return }
        task?.cancel()
        finish(.cancelled("已取消快捷替换，原文未改动。"), id: id)
    }

    private func run(pid: pid_t, targetLanguage: String, id: UUID) async {
        var recoverySource: String?
        var recoveryTarget = ""
        var recoveryOutput: String?
        func recovery(for message: String, includingUntranslated: Bool = false) -> ReplacementRecovery? {
            guard let recoverySource, recoveryOutput != nil || includingUntranslated else { return nil }
            return ReplacementRecovery(source: recoverySource, translation: recoveryOutput,
                targetLanguage: recoveryTarget, message: message)
        }
        do {
            try checkCurrent(pid: pid, id: id)
            let capture = try await dependencies.capture(pid)
            try checkCurrent(pid: pid, id: id)
            activeAttempt = capture.target.attempt
            guard !TextLogic.clean(capture.text).isEmpty else {
                finish(.failure("当前输入框没有可翻译的文字。"), id: id)
                return
            }
            guard capture.text.count <= TextLogic.maximumInputLength else { throw TranslationIssue.tooLong }
            let target = try Self.targetLanguage(for: capture.text, preference: targetLanguage)
            recoverySource = capture.text
            recoveryTarget = target
            try await validate(capture, pid: pid, id: id)
            captured?(capture.bounds, capture.replacesWholeField)
            try checkCurrent(pid: pid, id: id)
            updateStatus(capture.replacesWholeField ? "正在翻译整个输入框…" : "正在翻译选中文字…")
            watch(capture, pid: pid, id: id)

            let output = try await dependencies.translate(capture.text, target)
            if !TextLogic.clean(output).isEmpty, output != capture.text { recoveryOutput = output }
            try checkCurrent(pid: pid, id: id)
            watcher?.cancel()
            watcher = nil
            try await validate(capture, pid: pid, id: id)
            guard !TextLogic.clean(output).isEmpty else {
                finish(.failure("翻译结果为空，原文未改动。"), id: id)
                return
            }
            guard output != capture.text else {
                finish(.failure("译文与原文相同，无需替换。"), id: id)
                return
            }

            // Whole-field replacement selects its full range inside perform.
            // Stop the original-caret watcher before that deliberate change.
            isCommitting = true
            updateStatus("正在替换…")
            let verified = try await dependencies.perform(capture, output, { [weak self] in
                guard let self else { return false }
                return self.requestID == id && self.submissionValid && capture.target.attempt.isValid
            })
            // Do not discard a paste result after external cancellation. The
            // transaction was sent at most once and must always be accounted for.
            finish(verified ? .success : .uncertain, id: id,
                   recovery: verified ? nil : recovery(for: DirectReplacementOutcome.uncertain.message))
        } catch is CancellationError {
            guard requestID == id else { return }
            let message = "已取消快捷替换，原文未改动。"
            finish(.cancelled(message), id: id, recovery: recovery(for: message))
        } catch {
            guard requestID == id else { return }
            let message = Self.message(for: error)
            let timedOut: Bool
            if case TranslationIssue.timedOut = error { timedOut = true } else { timedOut = false }
            finish(.failure(message), id: id, recovery: recovery(for: message, includingUntranslated: timedOut))
        }
    }

    static func targetLanguage(for text: String, preference: String) throws -> String {
        switch preference {
        case "auto": return TextLogic.language(of: text) == "zh-Hans" ? "en" : "zh-Hans"
        case "en", "zh-Hans": return preference
        default: throw TranslationIssue.unsupported
        }
    }

    private func checkCurrent(pid: pid_t, id: UUID) throws {
        try Task.checkCancellation()
        guard requestID == id, submissionValid else { throw CancellationError() }
        guard dependencies.isFrontmost(pid) else { throw ReplacementError.changed }
    }

    private func validate(_ capture: DirectReplacementCapture, pid: pid_t, id: UUID) async throws {
        try checkCurrent(pid: pid, id: id)
        try await dependencies.validate(capture)
        try checkCurrent(pid: pid, id: id)
    }

    private func watch(_ capture: DirectReplacementCapture, pid: pid_t, id: UUID) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            guard let self else { return }
            do {
                while requestID == id && !isCommitting {
                    try await dependencies.pause()
                    try Task.checkCancellation()
                    guard requestID == id, !isCommitting else { return }
                    try await validate(capture, pid: pid, id: id)
                }
            } catch is CancellationError {
                // The main request owns normal completion and cancellation.
            } catch {
                guard requestID == id, !isCommitting else { return }
                submissionValid = false
                activeAttempt?.invalidate()
                task?.cancel()
                finish(.cancelled(Self.message(for: error)), id: id)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ReplacementError {
            switch error {
            case .changed:
                return "输入框、原文或光标已变化，已取消快捷替换。"
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func updateStatus(_ value: String) {
        status = value
        statusChanged?(value)
    }

    private func finish(_ outcome: DirectReplacementOutcome, id: UUID, recovery: ReplacementRecovery? = nil) {
        guard requestID == id else { return }
        activeAttempt?.invalidate()
        activeAttempt = nil
        watcher?.cancel()
        watcher = nil
        task = nil
        requestID = nil
        submissionValid = false
        isRunning = false
        isCommitting = false
        if let recovery {
            recoveryAvailable?(recovery)
            updateStatus(outcome.message + (recovery.hasTranslation
                ? " 打开 Wordglide 可查看或复制本次译文。"
                : " 打开 Wordglide 可重新翻译；不会自动替换。"))
        } else {
            updateStatus(outcome.message)
        }
        finished?(outcome)
    }
}
