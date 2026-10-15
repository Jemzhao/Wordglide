import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

@MainActor
private final class ReplacementCheckpoint {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class ReplacementBoundaryTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for replacement checkpoint", file: file, line: line)
    }

    @MainActor
    private func fixture() -> (AppModel, ReplacementTarget, HoverMonitor) {
        let model = AppModel(checkPermissions: false)
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
            edit: SelectionEdit(value: "Hello", selected: "Hello", range: NSRange(location: 0, length: 5)))
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: .zero,
            selection: true, replacement: target)
        model.translate(to: "original")
        model.target = "zh-Hans"
        model.result = "你好"
        model.phase = .result
        return (model, target, HoverMonitor(model: model))
    }

    @MainActor
    private func key(ownPaste: Bool = false) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        if ownPaste { cg.setIntegerValueField(.eventSourceUserData, value: TextReplacement.pasteEventMarker) }
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    @MainActor func testRealInputInvalidatesPendingManualPasteEvenWithUnchangedSnapshot() async throws {
        let (model, target, monitor) = fixture()
        let checkpoint = ReplacementCheckpoint()
        var checking = false
        var pastes = 0
        let clipboardCount = NSPasteboard.general.changeCount
        model.replacementPerformer = { destination, _, current, _ in
            try destination.attempt.begin()
            checking = true
            await checkpoint.wait()
            // The immutable text/range snapshot is deliberately unchanged.
            guard current(), destination.attempt.isValid else { throw ReplacementError.changed }
            pastes += 1
            return true
        }
        model.replaceSelection()
        await eventually { checking }
        monitor.handle(try key(), local: false)
        XCTAssertFalse(target.attempt.isValid)
        checkpoint.resume()
        await eventually { !model.isReplacing }
        XCTAssertEqual(pastes, 0)
        XCTAssertFalse(model.replacementMessage.isEmpty)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
        model.dismiss(force: true)
    }

    @MainActor func testOwnPasteDoesNotInvalidateAndRepeatedClickCannotDuplicateTransaction() async throws {
        let (model, target, monitor) = fixture()
        let checkpoint = ReplacementCheckpoint()
        var checking = false
        var pastes = 0
        model.replacementPerformer = { destination, _, current, _ in
            try destination.attempt.begin()
            checking = true
            await checkpoint.wait()
            guard current(), destination.attempt.markSent() else { throw ReplacementError.changed }
            pastes += 1
            return true
        }
        model.replaceSelection()
        await eventually { checking }
        monitor.handle(try key(ownPaste: true), local: false)
        XCTAssertTrue(target.attempt.isValid)
        model.replaceSelection()
        checkpoint.resume()
        await eventually { !model.isReplacing }
        XCTAssertEqual(pastes, 1)
        XCTAssertTrue(model.status.contains("已替换"))
    }

    @MainActor func testInputAfterPasteRetainsConfirmationAndNeverRepeatsPaste() async throws {
        let (model, target, monitor) = fixture()
        let checkpoint = ReplacementCheckpoint()
        var pastes = 0
        model.replacementPerformer = { destination, _, current, _ in
            try destination.attempt.begin()
            guard current(), destination.attempt.markSent() else { throw ReplacementError.changed }
            pastes += 1
            await checkpoint.wait()
            return false
        }
        model.replaceSelection()
        await eventually { pastes == 1 }
        monitor.handle(try key(), local: false)
        XCTAssertFalse(target.attempt.isValid)
        XCTAssertTrue(model.isReplacing)
        model.replaceSelection()
        checkpoint.resume()
        await eventually { !model.isReplacing }
        XCTAssertEqual(pastes, 1)
        XCTAssertTrue(model.replacementMessage.contains("无法确认"))
        model.dismiss(force: true)
    }
}
