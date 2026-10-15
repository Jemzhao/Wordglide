import XCTest
import AppKit
import ApplicationServices
@testable import Wordglide

@MainActor
private final class RecordingTranslator: TranslationService {
    struct Request: Equatable {
        let text: String
        let target: String
    }

    var suspends = false
    private(set) var requests: [Request] = []
    private(set) var returnedRequests = Set<Int>()
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    func translate(_ text: String, target: String) async throws -> String {
        let index = requests.count
        requests.append(Request(text: text, target: target))
        let output: String
        if suspends {
            // Deliberately ignore cancellation. A completed older service
            // request must never overwrite the model's current language/result.
            output = try await withCheckedThrowingContinuation { pending[index] = $0 }
        } else {
            output = text + " → " + target
        }
        returnedRequests.insert(index)
        return output
    }

    func complete(_ index: Int, with output: String) {
        pending.removeValue(forKey: index)?.resume(returning: output)
    }
}

final class ModelTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for model state", file: file, line: line)
    }

    @MainActor func testTextAndGeometryChecks() {
        XCTAssertEqual(TextLogic.coreCheckFailures(), [])
    }

    @MainActor func testRejectedPresentationDoesNotStartHiddenTranslation() async {
        let translator = RecordingTranslator()
        let model = AppModel(checkPermissions: false, translator: translator)
        model.showCard = { _ in model.dismiss(force: true) }
        model.present(CapturedText(text: "你好", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(translator.requests.isEmpty)
        model.showCard = nil
    }

    @MainActor func testPresentationImmediatelyTranslatesChineseAndEnglishForBothTriggers() async {
        let scenarios: [(text: String, target: String, selection: Bool)] = [
            ("你好，世界。", "en", true),
            ("Hello, world.", "zh-Hans", true),
            ("你好，世界。", "en", false),
            ("Hello, world.", "zh-Hans", false)
        ]
        for scenario in scenarios {
            let translator = RecordingTranslator()
            let model = AppModel(checkPermissions: false, translator: translator)
            model.present(CapturedText(text: scenario.text, bounds: .zero, method: "test"),
                          cocoaAnchor: .zero, selection: scenario.selection)

            XCTAssertTrue(model.phase == .loading)
            XCTAssertEqual(model.target, scenario.target)
            XCTAssertEqual(model.result, "")
            XCTAssertEqual(model.selectionVisible, scenario.selection)
            await eventually { model.phase == .result }
            XCTAssertEqual(translator.requests, [.init(text: scenario.text, target: scenario.target)])
            XCTAssertEqual(model.result, scenario.text + " → " + scenario.target)
            model.dismiss(force: true)
        }
    }

    @MainActor func testSupersededTranslationCannotPublish() async {
        let translator = RecordingTranslator()
        translator.suspends = true
        let model = AppModel(checkPermissions: false, translator: translator)
        model.present(CapturedText(text: "old", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: false)
        await eventually { translator.requests.count == 1 }
        model.present(CapturedText(text: "new", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: false)
        await eventually { translator.requests.count == 2 }
        translator.complete(1, with: "new translated")
        await eventually { model.result == "new translated" }
        translator.complete(0, with: "old translated")
        await eventually { translator.returnedRequests.contains(0) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(translator.requests.map(\.target), ["zh-Hans", "zh-Hans"])
        XCTAssertEqual(model.result, "new translated")
        XCTAssertEqual(model.source, "new")
        model.dismiss(force: true)
    }

    @MainActor func testOlderTranslationReturningCannotClearNewTranslationBusyState() async {
        let translator = RecordingTranslator()
        translator.suspends = true
        let model = AppModel(checkPermissions: false, translator: translator)
        defer {
            translator.complete(0, with: "cleanup")
            translator.complete(1, with: "cleanup")
            model.dismiss(force: true)
        }
        model.present(CapturedText(text: "old", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: false)
        XCTAssertTrue(model.isTranslationInFlight)
        await eventually { translator.requests.count == 1 }
        model.present(CapturedText(text: "new", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: false)
        await eventually { translator.requests.count == 2 }

        // The superseded service ignores cancellation and returns while the
        // current request is still pending. It must not make updating look idle.
        translator.complete(0, with: "old translated")
        await eventually { translator.returnedRequests.contains(0) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.isTranslationInFlight)
        XCTAssertTrue(model.phase == .loading)
        XCTAssertEqual(model.source, "new")
        XCTAssertEqual(model.result, "")

        translator.complete(1, with: "new translated")
        await eventually { model.result == "new translated" && !model.isTranslationInFlight }
    }

    @MainActor func testCancelledTranslationReturningCannotClearRetryBusyState() async {
        let translator = RecordingTranslator()
        translator.suspends = true
        let model = AppModel(checkPermissions: false, translator: translator)
        defer {
            translator.complete(0, with: "cleanup")
            translator.complete(1, with: "cleanup")
            model.dismiss(force: true)
        }
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
        await eventually { translator.requests.count == 1 }
        XCTAssertTrue(model.isTranslationInFlight)

        model.cancelTranslation()
        XCTAssertFalse(model.isTranslationInFlight)
        XCTAssertTrue(model.canRetryTranslation)
        model.retryTranslation()
        XCTAssertTrue(model.isTranslationInFlight)
        await eventually { translator.requests.count == 2 }

        translator.complete(0, with: "cancelled output")
        await eventually { translator.returnedRequests.contains(0) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.isTranslationInFlight)
        XCTAssertTrue(model.phase == .loading)
        XCTAssertEqual(model.result, "")

        translator.complete(1, with: "retry output")
        await eventually { model.result == "retry output" && !model.isTranslationInFlight }
    }

    @MainActor func testManualLanguageChoiceOverridesPendingAutomaticTranslation() async {
        let translator = RecordingTranslator()
        translator.suspends = true
        let model = AppModel(checkPermissions: false, translator: translator)
        let text = "请帮我翻译这段文字。"
        model.present(CapturedText(text: text, bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
        await eventually { translator.requests.count == 1 }
        XCTAssertEqual(translator.requests.first, RecordingTranslator.Request(text: text, target: "en"))

        model.translate(to: "zh-Hans")
        XCTAssertTrue(model.phase == .loading)
        XCTAssertEqual(model.target, "zh-Hans")
        await eventually { translator.requests.count == 2 }
        XCTAssertEqual(translator.requests.dropFirst().first, RecordingTranslator.Request(text: text, target: "zh-Hans"))
        translator.complete(1, with: "手动选择的结果")
        await eventually { model.result == "手动选择的结果" }
        translator.complete(0, with: "An outdated automatic translation")
        await eventually { translator.returnedRequests.contains(0) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(model.phase == .result)
        XCTAssertEqual(model.target, "zh-Hans")
        XCTAssertEqual(model.result, "手动选择的结果")
        model.dismiss(force: true)
    }

    @MainActor func testChoosingOriginalCancelsPendingAutomaticTranslation() async {
        let translator = RecordingTranslator()
        translator.suspends = true
        let model = AppModel(checkPermissions: false, translator: translator)
        let text = "你好，世界。"
        model.present(CapturedText(text: text, bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true)
        await eventually { translator.requests.count == 1 }

        model.translate(to: "original")
        XCTAssertTrue(model.phase == .result)
        XCTAssertEqual(model.target, "original")
        XCTAssertEqual(model.result, text)
        translator.complete(0, with: "Hello, world.")
        await eventually { translator.returnedRequests.contains(0) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(translator.requests, [.init(text: text, target: "en")])
        XCTAssertEqual(model.target, "original")
        XCTAssertEqual(model.result, text)
        model.dismiss(force: true)
    }

    @MainActor func testOneClickReplacementRejectsOwnProcessWithoutTouchingClipboard() async {
        let model = AppModel(checkPermissions: false, translator: RecordingTranslator())
        let original = "Hello"
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let target = ReplacementTarget(element: AXUIElementCreateApplication(ownPID), pid: ownPID,
            edit: SelectionEdit(value: original, selected: original, range: NSRange(location: 0, length: 5)))
        model.present(CapturedText(text: original, bounds: .zero, method: "test"), cocoaAnchor: .zero, selection: true, replacement: target)
        // Cancel automatic translation before seeding a result for the guarded
        // replacement. This test never needs a language pack or remote AX app.
        model.translate(to: "original")
        model.target = "zh-Hans"; model.result = "你好"; model.phase = .result
        let count = NSPasteboard.general.changeCount
        model.replaceSelection()
        XCTAssertTrue(model.isReplacing)
        await eventually { !model.isReplacing }
        XCTAssertFalse(model.isReplacing)
        XCTAssertFalse(model.canReplaceSelection)
        XCTAssertFalse(model.replacementMessage.isEmpty)
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
        model.dismiss(force: true)
    }

    @MainActor func testDismissedManualPasteRemainsBusyUntilConfirmationFinishes() async throws {
        let model = AppModel(checkPermissions: false, translator: RecordingTranslator())
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
            edit: SelectionEdit(value: "Hello", selected: "Hello", range: NSRange(location: 0, length: 5)))
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
                      selection: true, replacement: target)
        model.translate(to: "original")
        model.target = "zh-Hans"
        model.result = "你好"
        model.phase = .result

        var confirmation: CheckedContinuation<Bool, Never>?
        var pastes = 0
        defer {
            confirmation?.resume(returning: true)
            model.dismiss(force: true)
        }
        model.replacementPerformer = { destination, _, current, _ in
            try destination.attempt.begin()
            guard current(), destination.attempt.markSent() else { throw ReplacementError.changed }
            pastes += 1
            // No AX mutation or clipboard access: model a paste already sent
            // whose confirmation and clipboard restoration are still running.
            return await withCheckedContinuation { confirmation = $0 }
        }
        let clipboardCount = NSPasteboard.general.changeCount
        XCTAssertFalse(model.isReplacementInFlight)
        model.replaceSelection()
        XCTAssertTrue(model.isReplacementInFlight)
        await eventually { confirmation != nil }
        XCTAssertEqual(pastes, 1)

        model.dismiss(force: true)
        XCTAssertFalse(model.isReplacing)
        XCTAssertFalse(model.selectionVisible)
        XCTAssertTrue(model.isReplacementInFlight)
        XCTAssertFalse(target.attempt.isValid)

        let pending = try XCTUnwrap(confirmation)
        confirmation = nil
        pending.resume(returning: true)
        await eventually { !model.isReplacementInFlight }
        XCTAssertEqual(pastes, 1)
        XCTAssertTrue(model.status.contains("上一次替换已确认完成"))
        XCTAssertFalse(model.isReplacing)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
    }

    @MainActor func testInputLimitWithoutLanguagePack() async {
        do {
            _ = try await LocalTranslator().translate(String(repeating: "x", count: 8001), target: "zh-Hans")
            XCTFail("Expected input limit")
        } catch TranslationIssue.tooLong { }
        catch { XCTFail("Unexpected \(error)") }
    }
    @MainActor func testPausedMonitorStopsFrequentWork() async {
        let model = AppModel(checkPermissions: false)
        model.hoverEnabled = true
        model.applyPermissions(accessibility: true, screen: false)
        let monitor = HoverMonitor(model: model)
        monitor.start()
        XCTAssertFalse(monitor.isPointerPolling)
        XCTAssertFalse(monitor.hasGlobalEventMonitor)
        XCTAssertTrue(monitor.isPermissionPolling)
        model.enabled = true
        try? await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertTrue(monitor.isPointerPolling)
        model.enabled = false
        try? await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertFalse(monitor.isPointerPolling)
        XCTAssertFalse(monitor.hasGlobalEventMonitor)
        monitor.stop()
        XCTAssertFalse(monitor.isPermissionPolling)
    }

    @MainActor func testLanguageMenuKeepsHoverCardReachable() async {
        let model = AppModel(checkPermissions: false, translator: RecordingTranslator())
        model.closeDelay = 0
        let monitor = HoverMonitor(model: model)
        let badge = CGRect(x: 100, y: 100, width: 30, height: 30)
        let frame = CGRect(x: 100, y: 200, width: 360, height: 200)
        var visible = false
        monitor.showBadge = { _, _ in badge }
        monitor.visibleCardFrame = { visible ? frame : nil }
        model.showCard = { _ in visible = true }
        model.hideCard = { visible = false }
        model.clearHover = { [weak monitor] in monitor?.clearCandidate() }
        monitor.start()
        monitor.stage(CapturedText(text: "Hello", bounds: .zero, method: "test"), sourceRect: badge,
                      pointer: CGPoint(x: 110, y: 150), demo: true)
        XCTAssertTrue(monitor.retainCandidate(at: CGPoint(x: 115, y: 115)))
        let menu = NSMenu(title: "Languages")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertTrue(monitor.isMenuTracking)
        XCTAssertTrue(monitor.retainCandidate(at: CGPoint(x: 800, y: 600)))
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertFalse(monitor.isPointerPolling)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertFalse(monitor.isMenuTracking)
        XCTAssertTrue(monitor.retainCandidate(at: CGPoint(x: 800, y: 600)))
        XCTAssertFalse(monitor.retainCandidate(at: CGPoint(x: 800, y: 600), now: Date().addingTimeInterval(0.5)))
        monitor.stop()
        model.dismiss(force: true)
    }

}
