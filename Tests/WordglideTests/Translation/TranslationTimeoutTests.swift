import XCTest
import Translation
@testable import Wordglide

// A deliberately cancellation-ignoring operation. Tests choose when it returns,
// so timeout and cancellation behavior never depends on an installed language.
private final class ManualTranslationResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var startedStorage = false
    private var returnedStorage = false

    var started: Bool { lock.withLock { startedStorage } }
    var returned: Bool { lock.withLock { returnedStorage } }

    func wait() async throws -> Value {
        defer { lock.withLock { returnedStorage = true } }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            startedStorage = true
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class ManualTranslationDeadline: @unchecked Sendable {
    let tick = ManualTranslationResult<Void>()

    func sleep(_ nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await tick.wait()
        } onCancel: {
            self.tick.finish(.failure(CancellationError()))
        }
    }

    func expire() { tick.finish(.success(())) }
}

private final class ControlledTranslationSession: @unchecked Sendable {
    let output = ManualTranslationResult<String>()
    private let lock = NSLock()
    private var cancelCountStorage = 0
    var cancelCount: Int { lock.withLock { cancelCountStorage } }
    func cancel() { lock.withLock { cancelCountStorage += 1 } }
}

@MainActor
private final class ControlledTranslationRuntime {
    var availabilityOutput: ManualTranslationResult<LanguageAvailability.Status>?
    var immediateStatus: LanguageAvailability.Status = .installed
    private(set) var availabilityCount = 0
    private(set) var availabilityReturned = 0
    private(set) var sessions: [ControlledTranslationSession] = []

    var runtime: LocalTranslationRuntime {
        LocalTranslationRuntime(availability: { [self] _, _ in
            availabilityCount += 1
            defer { availabilityReturned += 1 }
            if let availabilityOutput { return (try? await availabilityOutput.wait()) ?? .unsupported }
            return immediateStatus
        }, session: { [self] _, _ in
            let session = ControlledTranslationSession()
            sessions.append(session)
            return LocalTranslationSession(translate: { text in try await session.output.wait() },
                                           cancel: { session.cancel() })
        })
    }
}

final class TranslationTimeoutTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled request", file: file, line: line)
    }

    private func assertTimedOut(_ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result, case TranslationIssue.timedOut = error else {
            XCTFail("Expected timeout, got \(result)", file: file, line: line)
            return
        }
    }

    private func assertCancelled(_ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result, error is CancellationError else {
            XCTFail("Expected cancellation, got \(result)", file: file, line: line)
            return
        }
    }

    @MainActor func testDeadlineIncludesAvailabilityAndIgnoresItsLateCompletion() async {
        let runtime = ControlledTranslationRuntime()
        let availability = ManualTranslationResult<LanguageAvailability.Status>()
        runtime.availabilityOutput = availability
        let clock = ManualTranslationDeadline()
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
        let request = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { availability.started && clock.tick.started }
        clock.expire()
        assertTimedOut(await request.result)
        XCTAssertEqual(runtime.sessions.count, 0)
        availability.finish(.success(.installed))
        await eventually { runtime.availabilityReturned == 1 }
        XCTAssertEqual(runtime.sessions.count, 0)
    }

    @MainActor func testOneDeadlineCoversAvailabilityAndTranslationTogether() async {
        let runtime = ControlledTranslationRuntime()
        let availability = ManualTranslationResult<LanguageAvailability.Status>()
        runtime.availabilityOutput = availability
        let clock = ManualTranslationDeadline()
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
        let request = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { availability.started && clock.tick.started }
        availability.finish(.success(.installed))
        await eventually { runtime.sessions.count == 1 }
        // Expiring the timer started before availability must also stop the
        // later translation; the second stage must not get a fresh 30 seconds.
        clock.expire()
        assertTimedOut(await request.result)
        XCTAssertEqual(runtime.sessions[0].cancelCount, 1)
        runtime.sessions[0].output.finish(.success("late"))
        await eventually { runtime.sessions[0].output.returned }
    }

    @MainActor func testEngineFailureKeepsOriginalErrorAndAllowsRetry() async throws {
        enum EngineFailure: Error { case unavailable }
        let runtime = ControlledTranslationRuntime()
        let clock = ManualTranslationDeadline()
        let retryClock = ManualTranslationDeadline()
        let clocks = TranslationClockSequence([clock, retryClock])
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clocks.sleep($0) })
        let first = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 1 && clock.tick.started }
        runtime.sessions[0].output.finish(.failure(EngineFailure.unavailable))
        guard case .failure(let error) = await first.result, case EngineFailure.unavailable = error else {
            XCTFail("Original engine error was lost")
            return
        }
        await eventually { clock.tick.returned }
        let retry = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 2 }
        runtime.sessions[1].output.finish(.success("恢复结果"))
        let retryValue = try await retry.value
        XCTAssertEqual(retryValue, "恢复结果")
    }

    @MainActor func testLateTimedOutReplyDoesNotPopulateSameTranslatorCache() async throws {
        let runtime = ControlledTranslationRuntime()
        let firstClock = ManualTranslationDeadline()
        let nextClock = ManualTranslationDeadline()
        let clockSequence = TranslationClockSequence([firstClock, nextClock])
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clockSequence.sleep($0) })
        let first = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 1 && firstClock.tick.started }
        firstClock.expire()
        assertTimedOut(await first.result)
        XCTAssertEqual(runtime.sessions[0].cancelCount, 1)
        runtime.sessions[0].output.finish(.success("旧结果"))
        await eventually { runtime.sessions[0].output.returned }
        let retry = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 2 && nextClock.tick.started }
        runtime.sessions[1].output.finish(.success("新结果"))
        let retryValue = try await retry.value
        XCTAssertEqual(retryValue, "新结果")
        let cachedValue = try await translator.translate("hello", target: "zh-Hans")
        XCTAssertEqual(cachedValue, "新结果")
        XCTAssertEqual(runtime.sessions.count, 2)
    }

    @MainActor func testCancellationWhileCheckingAvailabilityReturnsWithoutWaiting() async {
        let runtime = ControlledTranslationRuntime()
        let availability = ManualTranslationResult<LanguageAvailability.Status>()
        runtime.availabilityOutput = availability
        let clock = ManualTranslationDeadline()
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
        let request = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { availability.started && clock.tick.started }
        request.cancel()
        assertCancelled(await request.result)
        availability.finish(.success(.installed))
        await eventually { runtime.availabilityReturned == 1 && clock.tick.returned }
        XCTAssertTrue(runtime.sessions.isEmpty)
    }

    @MainActor func testCancellationDuringSessionCancelsOnceAndDiscardsLateResult() async throws {
        let runtime = ControlledTranslationRuntime()
        let clock = ManualTranslationDeadline()
        let retryClock = ManualTranslationDeadline()
        let clocks = TranslationClockSequence([clock, retryClock])
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clocks.sleep($0) })
        let request = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 1 && clock.tick.started }
        request.cancel()
        assertCancelled(await request.result)
        XCTAssertEqual(runtime.sessions[0].cancelCount, 1)
        runtime.sessions[0].output.finish(.success("旧结果"))
        await eventually { runtime.sessions[0].output.returned }
        let retry = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 2 }
        runtime.sessions[1].output.finish(.success("新结果"))
        let retryValue = try await retry.value
        XCTAssertEqual(retryValue, "新结果")
    }

    @MainActor func testSuccessCancelsDeadlineWithoutCancellingSessionAndCachesResult() async throws {
        let runtime = ControlledTranslationRuntime()
        let clock = ManualTranslationDeadline()
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
        let request = Task { try await translator.translate("hello", target: "zh-Hans") }
        await eventually { runtime.sessions.count == 1 && clock.tick.started }
        runtime.sessions[0].output.finish(.success("你好"))
        let requestValue = try await request.value
        XCTAssertEqual(requestValue, "你好")
        await eventually { clock.tick.returned }
        clock.expire() // A late deadline cannot change a completed success.
        XCTAssertEqual(runtime.sessions[0].cancelCount, 0)
        let cachedValue = try await translator.translate("hello", target: "zh-Hans")
        XCTAssertEqual(cachedValue, "你好")
        XCTAssertEqual(runtime.availabilityCount, 1)
    }

    @MainActor func testUnavailableLanguageKeepsOriginalErrorAndCleansDeadline() async {
        for status in [LanguageAvailability.Status.unsupported, .supported] {
            let runtime = ControlledTranslationRuntime()
            runtime.immediateStatus = status
            let clock = ManualTranslationDeadline()
            let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
            let request = Task { try await translator.translate("hello", target: "zh-Hans") }
            guard case .failure(let error) = await request.result else {
                XCTFail("Expected unavailable language error")
                continue
            }
            if status == .unsupported {
                guard case TranslationIssue.unsupported = error else { XCTFail("\(error)"); continue }
            } else {
                guard case TranslationIssue.languagePack = error else { XCTFail("\(error)"); continue }
            }
            await eventually { clock.tick.returned }
            XCTAssertTrue(runtime.sessions.isEmpty)
        }
    }

    @MainActor func testAlreadyCancelledCallNeverStartsRuntimeOrDeadline() async {
        let runtime = ControlledTranslationRuntime()
        let clock = ManualTranslationDeadline()
        let translator = LocalTranslator(runtime: runtime.runtime, sleep: { try await clock.sleep($0) })
        let start = ManualTranslationResult<Void>()
        let request = Task {
            _ = try await start.wait()
            return try await translator.translate("hello", target: "zh-Hans")
        }
        await eventually { start.started }
        request.cancel()
        start.finish(.success(()))
        assertCancelled(await request.result)
        XCTAssertEqual(runtime.availabilityCount, 0)
        XCTAssertFalse(clock.tick.started)
    }

    func testTimeoutMessageExplainsRetry() {
        let message = TranslationIssue.timedOut.localizedDescription
        XCTAssertTrue(message.contains("30 秒"))
        XCTAssertTrue(message.contains("重试"))
    }
}

private final class TranslationClockSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var clocks: [ManualTranslationDeadline]
    init(_ clocks: [ManualTranslationDeadline]) { self.clocks = clocks }
    func sleep(_ nanoseconds: UInt64) async throws {
        let clock = lock.withLock { clocks.removeFirst() }
        try await clock.sleep(nanoseconds)
    }
}
