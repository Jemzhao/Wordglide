// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import Foundation
import Translation

enum TranslationRuntime {
    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }
    static func session(source: Locale.Language, target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) { return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency) }
        return TranslationSession(installedSource: source, target: target)
    }
    static func configuration(source sourceID: String = "en", target targetID: String = "zh-Hans") -> TranslationSession.Configuration {
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        if #available(macOS 26.4, *) { return TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency) }
        return TranslationSession.Configuration(source: source, target: target)
    }
}

enum TranslationIssue: LocalizedError {
    case languagePack, tooLong, unsupported, timedOut
    var errorDescription: String? {
        switch self {
        case .languagePack: return "中英文语言包尚未准备好。打开设置，点击“准备语言包”后即可使用本机翻译。"
        case .tooLong: return "这段文字超过 8,000 字，请缩小选区后重试。"
        case .unsupported: return "本机翻译引擎暂不支持这一语言组合。"
        case .timedOut: return "翻译等待超过 30 秒，请重试。"
        }
    }
}

@MainActor
protocol TranslationService {
    func translate(_ text: String, target: String) async throws -> String
}

// A session is created only after availability succeeds. Keeping these operations
// injectable lets deadline tests run without installed languages or live UI.
struct LocalTranslationSession {
    let translate: @MainActor (String) async throws -> String
    let cancel: @Sendable () -> Void
}

@MainActor
struct LocalTranslationRuntime {
    let availability: (String, String) async -> LanguageAvailability.Status
    let session: (String, String) -> LocalTranslationSession

    static var system: Self {
        Self(availability: { source, target in
            await TranslationRuntime.availability().status(
                from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        }, session: { source, target in
            let session = TranslationRuntime.session(source: Locale.Language(identifier: source),
                                                     target: Locale.Language(identifier: target))
            return LocalTranslationSession(translate: { text in
                try await session.translate(text).targetText
            }, cancel: { session.cancel() })
        })
    }
}

// Unlike a task group, this gate does not wait for a system request that ignores
// cancellation. Exactly one result resumes the caller; late replies are discarded.
private final class TranslationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelSession: (@Sendable () -> Void)?

    func register(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let ended = result != nil
        if !ended { self.worker = worker; self.timer = timer }
        lock.unlock()
        if ended { worker.cancel(); timer.cancel() }
    }

    func registerSessionCancellation(_ cancellation: @escaping @Sendable () -> Void) throws {
        lock.lock()
        let ended = result != nil
        if !ended { cancelSession = cancellation }
        lock.unlock()
        if ended {
            cancellation()
            throw CancellationError()
        }
    }

    func checkActive() throws {
        try Task.checkCancellation()
        lock.lock()
        let ended = result != nil
        lock.unlock()
        if ended { throw CancellationError() }
    }

    func finish(_ result: Result<String, Error>, abort: Bool = false) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let worker = self.worker
        let timer = self.timer
        let cancellation = cancelSession
        self.continuation = nil
        self.worker = nil
        self.timer = nil
        cancelSession = nil
        lock.unlock()
        // Cancel the actual system session as well as our waiting task.
        if abort { worker?.cancel(); cancellation?() }
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

@MainActor
final class LocalTranslator: TranslationService {
    private let runtime: LocalTranslationRuntime
    private let timeoutNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var cache: [String: String] = [:]
    private var keys: [String] = []
    private var cacheCharacters = 0

    init(timeoutNanoseconds: UInt64 = 30_000_000_000,
         runtime: LocalTranslationRuntime? = nil,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.runtime = runtime ?? .system
        self.sleep = sleep
    }

    func translate(_ text: String, target: String) async throws -> String {
        try Task.checkCancellation()
        guard text.count <= TextLogic.maximumInputLength else { throw TranslationIssue.tooLong }
        guard ["en", "zh-Hans"].contains(target) else { throw TranslationIssue.unsupported }
        let source = TextLogic.language(of: text)
        if source == target { return text }
        let key = source + "|" + target + "|" + text
        if let cached = cache[key] { return cached }
        let response = try await translateWithDeadline(text, source: source, target: target)
        try Task.checkCancellation()
        while !keys.isEmpty && (keys.count >= 100 || cacheCharacters + key.count + response.count > 160_000) {
            let oldest = keys.removeFirst()
            cacheCharacters -= oldest.count + (cache.removeValue(forKey: oldest)?.count ?? 0)
        }
        cache[key] = response
        keys.append(key)
        cacheCharacters += key.count + response.count
        return response
    }

    private func translateWithDeadline(_ text: String, source: String, target: String) async throws -> String {
        let gate = TranslationRequestGate()
        let runtime = self.runtime
        let timeoutNanoseconds = self.timeoutNanoseconds
        let sleep = self.sleep
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.register(continuation) else { return }
                let worker = Task { @MainActor in
                    do {
                        try gate.checkActive()
                        let status = await runtime.availability(source, target)
                        try gate.checkActive()
                        guard status != .unsupported else { throw TranslationIssue.unsupported }
                        guard status == .installed else { throw TranslationIssue.languagePack }
                        let session = runtime.session(source, target)
                        try gate.registerSessionCancellation(session.cancel)
                        try gate.checkActive()
                        let result = try await session.translate(text)
                        try gate.checkActive()
                        gate.finish(.success(result))
                    } catch { gate.finish(.failure(error)) }
                }
                let timer = Task.detached {
                    do {
                        try await sleep(timeoutNanoseconds)
                        try Task.checkCancellation()
                        gate.finish(.failure(TranslationIssue.timedOut), abort: true)
                    } catch {
                        if !(error is CancellationError) { gate.finish(.failure(error), abort: true) }
                    }
                }
                gate.install(worker: worker, timer: timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()), abort: true)
        }
    }
}
