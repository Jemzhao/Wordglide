import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

@MainActor
private final class RecoveryReply<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private(set) var returned = false

    // Cancellation is deliberately ignored to exercise the caller's request
    // identity checks, including an older engine that returns after a retry.
    func wait() async throws -> Value {
        let value = try await withCheckedThrowingContinuation { continuation = $0 }
        returned = true
        return value
    }

    func resolve(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func reject(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class RecoveryTranslator: TranslationService {
    struct Request: Equatable {
        let source: String
        let target: String
    }

    private(set) var requests: [Request] = []
    var operation: (String, String) async throws -> String = { _, _ in "Translated" }

    func translate(_ text: String, target: String) async throws -> String {
        requests.append(Request(source: text, target: target))
        return try await operation(text, target)
    }
}

@MainActor
private final class RecoveryCoordinatorFixture {
    var source = "请确认时间。"
    var validationError: Error?
    var translate: (String, String) async throws -> String = { _, _ in "Please confirm the time." }
    var perform: (String) async throws -> Bool = { _ in true }
    private(set) var pasted: [String] = []
    private(set) var translations = 0

    func coordinator() -> DirectReplacementCoordinator {
        DirectReplacementCoordinator(dependencies: .init(
            capture: { [self] pid in
                // An immutable AX handle is constructed but never read. All
                // capture, validation and paste effects are isolated fakes.
                let target = ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
                    edit: SelectionEdit(value: source, selected: source,
                        range: NSRange(location: 0, length: source.utf16.count)))
                return DirectReplacementCapture(target: target, text: source,
                    bounds: .zero, replacesWholeField: false)
            },
            translate: { [self] source, target in
                translations += 1
                return try await translate(source, target)
            },
            validate: { [self] _ in
                if let validationError { throw validationError }
            },
            perform: { [self] _, output, _ in
                pasted.append(output)
                return try await perform(output)
            },
            isFrontmost: { _ in true },
            pause: { try await Task.sleep(for: .milliseconds(5)) }
        ))
    }
}

final class RecoveryTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for recovery state", file: file, line: line)
    }

    @MainActor
    private func recovery(_ output: String? = "Hello", source: String = "你好", target: String = "en") -> ReplacementRecovery {
        ReplacementRecovery(source: source, translation: output, targetLanguage: target, message: "Replacement failed")
    }

    @MainActor
    private func target(for source: String) -> ReplacementTarget {
        let pid = ProcessInfo.processInfo.processIdentifier
        return ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
            edit: SelectionEdit(value: source, selected: source, range: NSRange(location: 0, length: source.utf16.count)))
    }

    @MainActor func testRecoveryKeepsOnlyLatestAndCopiesExactTranslationToPrivatePasteboard() {
        let model = AppModel(checkPermissions: false, translator: RecoveryTranslator())
        let pasteboard = NSPasteboard.withUniqueName()
        model.recoveryPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        let first = recovery("Old")
        let latest = recovery("  Hello 😀\n")
        model.retainReplacementRecovery(first)
        model.retainReplacementRecovery(latest)

        XCTAssertEqual(model.replacementRecovery, latest)
        model.copyRecoveredTranslation()
        XCTAssertEqual(pasteboard.string(forType: .string), "  Hello 😀\n")
        let copiedCount = pasteboard.changeCount
        model.dismissReplacementRecovery()
        XCTAssertNil(model.replacementRecovery)
        XCTAssertEqual(pasteboard.changeCount, copiedCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "  Hello 😀\n")
    }

    @MainActor func testMissingTranslationNeverClearsClipboardWhenCopyIsInvoked() {
        let model = AppModel(checkPermissions: false, translator: RecoveryTranslator())
        let pasteboard = NSPasteboard.withUniqueName()
        model.recoveryPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("User clipboard", forType: .string)
        let initialCount = pasteboard.changeCount
        model.retainReplacementRecovery(recovery(nil))
        model.copyRecoveredTranslation()
        XCTAssertEqual(pasteboard.changeCount, initialCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "User clipboard")
    }

    @MainActor func testWhitespaceOutputIsNotOfferedAsRecoveredTranslation() {
        let empty = recovery(" \n\t ")
        XCTAssertNil(empty.translation)
        XCTAssertFalse(empty.hasTranslation)
        XCTAssertTrue(recovery(" Hello ").hasTranslation)
    }

    @MainActor func testShowingRecoveredOutputDoesNotTranslateOrRetainAnEditTarget() async {
        let translator = RecoveryTranslator()
        let model = AppModel(checkPermissions: false, translator: translator)
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
            selection: true, replacement: target(for: "Hello"))
        await eventually { model.phase == .result }
        XCTAssertTrue(model.hasReplacementTarget)
        var presentations = 0
        model.showCard = { _ in presentations += 1 }
        model.retainReplacementRecovery(recovery("Recovered", source: "Earlier", target: "zh-Hans"))

        model.showRecoveredTranslation()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(translator.requests.count, 1)
        XCTAssertEqual(model.source, "Earlier")
        XCTAssertEqual(model.target, "zh-Hans")
        XCTAssertEqual(model.result, "Recovered")
        XCTAssertTrue(model.phase == .result)
        XCTAssertFalse(model.hasReplacementTarget)
        XCTAssertFalse(model.canReplaceSelection)
        model.dismiss(force: true)
    }

    @MainActor func testRecoveredTimeoutRetriesSpecifiedLanguageWithoutPasteCapability() async {
        let translator = RecoveryTranslator()
        let model = AppModel(checkPermissions: false, translator: translator)
        // Deliberately choose the same target as the Chinese source so an
        // automatic direction calculation would produce the wrong request.
        model.retainReplacementRecovery(recovery(nil, source: "原文", target: "zh-Hans"))
        var pastes = 0
        model.replacementPerformer = { _, _, _, _ in pastes += 1; return true }
        model.retryRecoveredTranslation()
        await eventually { model.phase == .result }
        model.replaceSelection()

        XCTAssertEqual(translator.requests, [.init(source: "原文", target: "zh-Hans")])
        XCTAssertEqual(model.result, "Translated")
        XCTAssertFalse(model.hasReplacementTarget)
        XCTAssertFalse(model.canReplaceSelection)
        XCTAssertEqual(pastes, 0)
        model.dismiss(force: true)
    }

    @MainActor func testSuccessfulRecoveryRetryMakesNewTranslationAvailableToCopy() async {
        let translator = RecoveryTranslator()
        translator.operation = { _, _ in "  New translation 😀\n" }
        let model = AppModel(checkPermissions: false, translator: translator)
        let pasteboard = NSPasteboard.withUniqueName()
        model.recoveryPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original clipboard", forType: .string)
        let initialCount = pasteboard.changeCount
        model.retainReplacementRecovery(recovery(nil))

        model.retryRecoveredTranslation()
        await eventually { model.phase == .result }

        XCTAssertEqual(model.replacementRecovery?.translation, "  New translation 😀\n")
        XCTAssertTrue(model.replacementRecovery?.hasTranslation ?? false)
        XCTAssertTrue(model.replacementRecovery?.message.contains("重新翻译已完成") ?? false)
        XCTAssertEqual(pasteboard.changeCount, initialCount)
        XCTAssertFalse(model.canReplaceSelection)
        model.copyRecoveredTranslation()
        XCTAssertEqual(pasteboard.string(forType: .string), "  New translation 😀\n")
        model.dismiss(force: true)
    }

    @MainActor func testSuccessfulRetryCannotReviveDismissedOrOverwriteUpdatedRecovery() async {
        for replaceRecovery in [false, true] {
            let reply = RecoveryReply<String>()
            let translator = RecoveryTranslator()
            translator.operation = { _, _ in try await reply.wait() }
            let model = AppModel(checkPermissions: false, translator: translator)
            model.retainReplacementRecovery(recovery(nil))
            model.retryRecoveredTranslation()
            await eventually { translator.requests.count == 1 }
            // Keep the same source and target in the newer entry. Identity,
            // rather than text equality, must protect the user's latest choice.
            let newer = replaceRecovery ? recovery("Newer saved output") : nil
            if let newer { model.retainReplacementRecovery(newer) }
            else { model.dismissReplacementRecovery() }

            reply.resolve("Retry output")
            await eventually { model.phase == .result }

            XCTAssertEqual(model.result, "Retry output")
            XCTAssertEqual(model.replacementRecovery, newer)
            XCTAssertFalse(model.canReplaceSelection)
            model.dismiss(force: true)
        }
    }

    @MainActor func testRetriedTimeoutCannotReviveDismissedOrOverwriteUpdatedRecovery() async {
        for replaceRecovery in [false, true] {
            let reply = RecoveryReply<String>()
            let translator = RecoveryTranslator()
            translator.operation = { _, _ in try await reply.wait() }
            let model = AppModel(checkPermissions: false, translator: translator)
            model.retainReplacementRecovery(recovery(nil))
            model.retryRecoveredTranslation()
            await eventually { translator.requests.count == 1 }
            let newer = replaceRecovery ? recovery("Newer saved output") : nil
            if let newer { model.retainReplacementRecovery(newer) }
            else { model.dismissReplacementRecovery() }

            reply.reject(TranslationIssue.timedOut)
            await eventually { model.phase == .failure }

            XCTAssertEqual(model.result, TranslationIssue.timedOut.localizedDescription)
            XCTAssertTrue(model.canRetryTranslation)
            XCTAssertEqual(model.replacementRecovery, newer)
            XCTAssertFalse(model.canReplaceSelection)
            model.dismiss(force: true)
        }
    }

    @MainActor func testCancelAndRetryIgnoreOlderEngineResultAndDropEditTarget() async {
        let first = RecoveryReply<String>()
        let second = RecoveryReply<String>()
        let translator = RecoveryTranslator()
        translator.operation = { _, _ in
            translator.requests.count == 1 ? try await first.wait() : try await second.wait()
        }
        let model = AppModel(checkPermissions: false, translator: translator)
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
            selection: true, replacement: target(for: "Hello"))
        await eventually { translator.requests.count == 1 }
        model.cancelTranslation()
        XCTAssertTrue(model.phase == .failure)
        XCTAssertTrue(model.canRetryTranslation)
        XCTAssertFalse(model.hasReplacementTarget)

        model.retryTranslation()
        await eventually { translator.requests.count == 2 }
        XCTAssertFalse(model.canRetryTranslation)
        second.resolve("新译文")
        await eventually { model.result == "新译文" }
        first.resolve("Stale output")
        await eventually { first.returned }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(translator.requests, [.init(source: "Hello", target: "zh-Hans"), .init(source: "Hello", target: "zh-Hans")])
        XCTAssertEqual(model.result, "新译文")
        XCTAssertTrue(model.phase == .result)
        XCTAssertFalse(model.hasReplacementTarget)
        model.dismiss(force: true)
    }

    @MainActor func testTimeoutCanRetryButMissingLanguagePackDoesNotOfferUselessRetry() async {
        for (error, expectedRetry) in [(TranslationIssue.timedOut, true), (.languagePack, false)] {
            let translator = RecoveryTranslator()
            translator.operation = { _, _ in throw error }
            let model = AppModel(checkPermissions: false, translator: translator)
            model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
            await eventually { model.phase == .failure }
            XCTAssertEqual(model.canRetryTranslation, expectedRetry)
            model.dismiss(force: true)
        }
    }

    @MainActor func testManualReplacementFailureRetainsCurrentSourceAndOutput() async {
        let translator = RecoveryTranslator()
        let model = AppModel(checkPermissions: false, translator: translator)
        model.replacementPerformer = { _, _, _, _ in throw ReplacementError.changed }
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
            selection: true, replacement: target(for: "Hello"))
        await eventually { model.phase == .result }
        model.replaceSelection()
        await eventually { model.replacementRecovery != nil }

        XCTAssertEqual(model.replacementRecovery?.source, "Hello")
        XCTAssertEqual(model.replacementRecovery?.translation, "Translated")
        XCTAssertEqual(model.replacementRecovery?.targetLanguage, "zh-Hans")
        XCTAssertFalse(model.replacementRecovery?.message.isEmpty ?? true)
        XCTAssertFalse(model.canReplaceSelection)
        model.dismiss(force: true)
    }

    @MainActor func testLateManualPasteConfirmationCannotOverwriteNewerRecovery() async {
        let reply = RecoveryReply<Bool>()
        let translator = RecoveryTranslator()
        let model = AppModel(checkPermissions: false, translator: translator)
        var waitingForConfirmation = false
        model.replacementPerformer = { _, _, _, _ in
            waitingForConfirmation = true
            return try await reply.wait()
        }
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
            selection: true, replacement: target(for: "Hello"))
        await eventually { model.phase == .result }
        model.replaceSelection()
        await eventually { waitingForConfirmation }
        model.dismiss(force: true)
        model.present(CapturedText(text: "Newest source", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
        await eventually { model.phase == .result }
        let newest = recovery("Newest output", source: "Newest source", target: "zh-Hans")
        model.retainReplacementRecovery(newest)

        reply.resolve(false)
        await eventually { reply.returned }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.replacementRecovery, newest)
        XCTAssertEqual(model.source, "Newest source")
        XCTAssertFalse(model.hasReplacementTarget)
        model.dismiss(force: true)
    }

    @MainActor func testDirectReplacementFailureRetainsTranslatedOutputOnce() async {
        let fixture = RecoveryCoordinatorFixture()
        fixture.perform = { _ in throw ReplacementError.changed }
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { !coordinator.isRunning }

        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.source, fixture.source)
        XCTAssertEqual(recoveries.first?.translation, "Please confirm the time.")
        XCTAssertEqual(recoveries.first?.targetLanguage, "en")
        XCTAssertFalse(recoveries.first?.message.isEmpty ?? true)
        XCTAssertEqual(fixture.pasted.count, 1)
    }

    @MainActor func testUncertainDirectPasteKeepsOutputWithoutRepeatingPaste() async {
        let fixture = RecoveryCoordinatorFixture()
        fixture.perform = { _ in false }
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { !coordinator.isRunning }

        XCTAssertEqual(fixture.pasted, ["Please confirm the time."])
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.translation, "Please confirm the time.")
        XCTAssertTrue(recoveries.first?.message.contains("无法确认") ?? false)
    }

    @MainActor func testFinalDirectValidationFailureKeepsReadyTranslationWithoutPasting() async {
        let fixture = RecoveryCoordinatorFixture()
        fixture.translate = { _, _ in
            fixture.validationError = ReplacementError.changed
            return "Ready but not pasted"
        }
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { !coordinator.isRunning }

        XCTAssertTrue(fixture.pasted.isEmpty)
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.translation, "Ready but not pasted")
        XCTAssertEqual(recoveries.first?.source, fixture.source)
    }

    @MainActor func testDirectTimeoutKeepsSourceForTranslationRetryWithoutPaste() async {
        let fixture = RecoveryCoordinatorFixture()
        fixture.translate = { _, _ in throw TranslationIssue.timedOut }
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier, targetLanguage: "zh-Hans")
        await eventually { !coordinator.isRunning }

        XCTAssertTrue(fixture.pasted.isEmpty)
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.source, fixture.source)
        XCTAssertEqual(recoveries.first?.targetLanguage, "zh-Hans")
        XCTAssertNil(recoveries.first?.translation)
        XCTAssertFalse(recoveries.first?.hasTranslation ?? true)
    }

    @MainActor func testSuccessfulDirectReplacementDoesNotCreateRecovery() async {
        let fixture = RecoveryCoordinatorFixture()
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { !coordinator.isRunning }

        XCTAssertEqual(fixture.pasted.count, 1)
        XCTAssertTrue(recoveries.isEmpty)
    }

    @MainActor func testCancelledLateOutputCannotPublishRecoveryOverNewerRequest() async {
        let fixture = RecoveryCoordinatorFixture()
        let first = RecoveryReply<String>()
        fixture.translate = { source, _ in
            source == "请确认时间。" ? try await first.wait() : "Newest output"
        }
        fixture.perform = { _ in false }
        let coordinator = fixture.coordinator()
        var recoveries: [ReplacementRecovery] = []
        coordinator.recoveryAvailable = { recoveries.append($0) }
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { fixture.translations == 1 }
        coordinator.cancel()
        XCTAssertTrue(recoveries.isEmpty)
        fixture.source = "最新请求"
        coordinator.start(pid: ProcessInfo.processInfo.processIdentifier)
        await eventually { !coordinator.isRunning }
        first.resolve("Outdated output")
        await eventually { first.returned }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(fixture.pasted, ["Newest output"])
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.source, "最新请求")
        XCTAssertEqual(recoveries.first?.translation, "Newest output")
    }
}
