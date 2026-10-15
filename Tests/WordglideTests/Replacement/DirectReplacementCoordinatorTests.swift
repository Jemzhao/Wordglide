import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

@MainActor
private final class DirectReply<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    // Intentionally does not react to cancellation: the coordinator must also
    // reject late results from an underlying service that finishes anyway.
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ value: Value) {
        let current = continuation
        continuation = nil
        current?.resume(returning: value)
    }
}

@MainActor
private final class DirectReplacementFixture {
    var source = "你好"
    var wholeField = false
    var frontmost = true
    var valid = true
    var captureError: Error?
    var captureCount = 0
    var lastTarget: ReplacementTarget?
    var validationError: Error?
    var translations: [(String, String)] = []
    var pasted: [String] = []
    var translate: (String, String) async throws -> String = { _, _ in "Hello" }
    var perform: (String, @escaping () -> Bool) async throws -> Bool = { _, current in current() }

    func coordinator() -> DirectReplacementCoordinator {
        DirectReplacementCoordinator(dependencies: .init(
            capture: { [self] pid in
                captureCount += 1
                if let captureError { throw captureError }
                let target = ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
                    edit: SelectionEdit(value: source, selected: source,
                                        range: NSRange(location: 0, length: source.utf16.count)))
                lastTarget = target
                return DirectReplacementCapture(target: target, text: source,
                    bounds: CGRect(x: 10, y: 20, width: 100, height: 30), replacesWholeField: wholeField)
            },
            translate: { [self] text, target in
                translations.append((text, target))
                return try await translate(text, target)
            },
            validate: { [self] _ in
                if let validationError { throw validationError }
                if !valid { throw ReplacementError.changed }
            },
            perform: { [self] _, output, current in
                pasted.append(output)
                return try await perform(output, current)
            },
            isFrontmost: { [self] _ in frontmost },
            pause: {
                await Task.yield()
                try Task.checkCancellation()
            }
        ))
    }
}

final class DirectReplacementCoordinatorTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for coordinator state", file: file, line: line)
    }

    @MainActor func testAutomaticDirectionAndFixedTargets() throws {
        XCTAssertEqual(try DirectReplacementCoordinator.targetLanguage(for: "你好世界", preference: "auto"), "en")
        XCTAssertEqual(try DirectReplacementCoordinator.targetLanguage(for: "Hello world", preference: "auto"), "zh-Hans")
        XCTAssertEqual(try DirectReplacementCoordinator.targetLanguage(for: "你好", preference: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(try DirectReplacementCoordinator.targetLanguage(for: "Hello", preference: "en"), "en")
        XCTAssertThrowsError(try DirectReplacementCoordinator.targetLanguage(for: "Hello", preference: "unsupported"))
    }

    @MainActor func testSelectionTranslatesAndPastesOnceWithoutPreview() async {
        let fixture = DirectReplacementFixture()
        let coordinator = fixture.coordinator()
        var outcomes: [DirectReplacementOutcome] = []
        var anchor: CGRect?
        var wholeField = true
        coordinator.captured = { anchor = $0; wholeField = $1 }
        coordinator.finished = { outcomes.append($0) }
        fixture.perform = { _, current in
            XCTAssertTrue(coordinator.isCommitting)
            XCTAssertTrue(current())
            return true
        }

        XCTAssertTrue(coordinator.start(pid: 42))
        await eventually { !coordinator.isRunning }

        XCTAssertEqual(fixture.translations.first?.0, "你好")
        XCTAssertEqual(fixture.translations.first?.1, "en")
        XCTAssertEqual(fixture.pasted, ["Hello"])
        XCTAssertEqual(anchor, CGRect(x: 10, y: 20, width: 100, height: 30))
        XCTAssertFalse(wholeField)
        XCTAssertEqual(outcomes, [.success])
        XCTAssertTrue(coordinator.status.contains("⌘Z"))
        XCTAssertFalse(coordinator.isCommitting)
    }

    @MainActor func testWholeFieldPreservesExactSourceAndUsesFixedTarget() async {
        let fixture = DirectReplacementFixture()
        fixture.source = "  Hello world\n"
        fixture.wholeField = true
        fixture.translate = { _, _ in "  你好世界\n" }
        let coordinator = fixture.coordinator()
        var capturedWholeField = false
        coordinator.captured = { _, whole in capturedWholeField = whole }

        coordinator.start(pid: 42, targetLanguage: "zh-Hans")
        await eventually { !coordinator.isRunning }

        XCTAssertTrue(capturedWholeField)
        XCTAssertEqual(fixture.translations.first?.0, "  Hello world\n")
        XCTAssertEqual(fixture.translations.first?.1, "zh-Hans")
        XCTAssertEqual(fixture.pasted, ["  你好世界\n"])
    }

    @MainActor func testRepeatedShortcutDoesNotStartSecondTransaction() async {
        let fixture = DirectReplacementFixture()
        let reply = DirectReply<String>()
        fixture.translate = { _, _ in try await reply.wait() }
        let coordinator = fixture.coordinator()

        XCTAssertTrue(coordinator.start(pid: 42))
        await eventually { fixture.translations.count == 1 }
        XCTAssertFalse(coordinator.start(pid: 42))
        XCTAssertEqual(fixture.captureCount, 1)
        reply.resolve("Hello")
        await eventually { !coordinator.isRunning }
        XCTAssertEqual(fixture.pasted, ["Hello"])
    }

    @MainActor func testCancelledLateTranslationCannotPasteOrOverwriteNextResult() async {
        let fixture = DirectReplacementFixture()
        let reply = DirectReply<String>()
        fixture.translate = { text, _ in text == "你好" ? try await reply.wait() : "Second" }
        let coordinator = fixture.coordinator()
        var outcomes: [DirectReplacementOutcome] = []
        coordinator.finished = { outcomes.append($0) }

        coordinator.start(pid: 42)
        await eventually { fixture.translations.count == 1 }
        coordinator.cancel()
        XCTAssertFalse(coordinator.isRunning)
        fixture.source = "第二个"
        coordinator.start(pid: 42)
        await eventually { outcomes.count == 2 }
        reply.resolve("Stale")
        for _ in 0..<30 { await Task.yield() }

        XCTAssertEqual(fixture.pasted, ["Second"])
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.last, .success)
        XCTAssertEqual(coordinator.status, DirectReplacementOutcome.success.message)
    }

    @MainActor func testChangedOriginalCancelsWhileTranslationIsPending() async {
        let fixture = DirectReplacementFixture()
        let reply = DirectReply<String>()
        fixture.translate = { _, _ in try await reply.wait() }
        let coordinator = fixture.coordinator()

        coordinator.start(pid: 42)
        await eventually { fixture.translations.count == 1 }
        fixture.valid = false
        await eventually { !coordinator.isRunning }
        reply.resolve("Stale")
        for _ in 0..<30 { await Task.yield() }

        XCTAssertEqual(fixture.pasted, [])
        XCTAssertTrue(coordinator.status.contains("光标已变化"))
    }

    @MainActor func testCompositionBeginningDuringTranslationInvalidatesSharedSubmissionGate() async {
        let fixture = DirectReplacementFixture()
        let reply = DirectReply<String>()
        fixture.translate = { _, _ in try await reply.wait() }
        let coordinator = fixture.coordinator()
        coordinator.start(pid: 42)
        await eventually { fixture.translations.count == 1 }
        fixture.validationError = ReplacementError.composing
        await eventually { !coordinator.isRunning }
        XCTAssertFalse(fixture.lastTarget?.attempt.isValid ?? true)
        reply.resolve("Late translation")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(fixture.pasted, [])
        XCTAssertTrue(coordinator.status.contains("组词"))
    }

    @MainActor func testFinalValidationRejectsChangeAsTranslationFinishes() async {
        let fixture = DirectReplacementFixture()
        fixture.translate = { [fixture] _, _ in
            fixture.valid = false
            return "Stale"
        }
        let coordinator = fixture.coordinator()

        coordinator.start(pid: 42)
        await eventually { !coordinator.isRunning }
        XCTAssertEqual(fixture.pasted, [])
        XCTAssertTrue(coordinator.status.contains("已取消"))
    }

    @MainActor func testMissingLanguagePackReportsSettingsWithoutPaste() async {
        let fixture = DirectReplacementFixture()
        fixture.translate = { _, _ in throw TranslationIssue.languagePack }
        let coordinator = fixture.coordinator()

        coordinator.start(pid: 42)
        await eventually { !coordinator.isRunning }
        XCTAssertEqual(fixture.pasted, [])
        XCTAssertTrue(coordinator.status.contains("打开设置"))
        XCTAssertTrue(coordinator.status.contains("语言包"))
    }

    @MainActor func testCancellationAfterCommitStillReportsUncertainPasteOnce() async {
        let fixture = DirectReplacementFixture()
        let confirmation = DirectReply<Bool>()
        var pasteIsCurrent: (() -> Bool)?
        fixture.perform = { _, current in
            pasteIsCurrent = current
            return try await confirmation.wait()
        }
        let coordinator = fixture.coordinator()
        var outcomes: [DirectReplacementOutcome] = []
        coordinator.finished = { outcomes.append($0) }

        coordinator.start(pid: 42)
        await eventually { fixture.pasted.count == 1 }
        coordinator.cancel()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(fixture.lastTarget?.attempt.isValid ?? true)
        XCTAssertFalse(pasteIsCurrent?() ?? true)
        XCTAssertFalse(coordinator.start(pid: 42))
        confirmation.resolve(false)
        await eventually { !coordinator.isRunning }

        XCTAssertEqual(fixture.pasted, ["Hello"])
        XCTAssertEqual(outcomes, [.uncertain])
        XCTAssertTrue(coordinator.status.contains("未重复替换"))
    }

    @MainActor func testUnconfirmedEditableCaptureDoesNotTranslateOrPaste() async {
        let fixture = DirectReplacementFixture()
        fixture.captureError = ReplacementError.unavailable
        let coordinator = fixture.coordinator()

        coordinator.start(pid: 42)
        await eventually { !coordinator.isRunning }
        XCTAssertEqual(fixture.translations.count, 0)
        XCTAssertEqual(fixture.pasted, [])
        XCTAssertEqual(coordinator.status, ReplacementError.unavailable.localizedDescription)
    }
}
