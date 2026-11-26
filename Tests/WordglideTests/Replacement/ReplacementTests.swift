import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

final class ReplacementTests: XCTestCase {
    func testAttemptIsSharedAndNeverRetriesAfterWrite() throws {
        let attempt = ReplacementAttempt()
        try attempt.begin()
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.inProgress = error else {
                return XCTFail("A pending validation must reject another submission")
            }
        }
        attempt.abandonBeforeWrite()
        try attempt.begin()
        attempt.markSent()
        attempt.abandonBeforeWrite()
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.alreadyAttempted = error else {
                return XCTFail("An uncertain write must never be sent twice")
            }
        }
    }

    func testTargetCopiesShareOneAttempt() throws {
        let target = ReplacementTarget(element: AXUIElementCreateApplication(1), pid: 1,
            edit: SelectionEdit(value: "hello world", selected: "world", range: NSRange(location: 6, length: 5)))
        let copy = target
        try target.attempt.begin()
        XCTAssertThrowsError(try copy.attempt.begin())
        target.attempt.markSent()
        XCTAssertThrowsError(try copy.attempt.begin())
    }

    func testCaptureRejectsOwnProcessWithoutReadingAXTree() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNil(ReplacementTarget.capture(element: AXUIElementCreateApplication(ownPID), pid: ownPID, selected: "secret"))
    }

    @MainActor func testRejectedWriteDoesNotTouchSystemClipboard() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = ReplacementTarget(element: AXUIElementCreateApplication(pid), pid: pid,
            edit: SelectionEdit(value: "hello", selected: "hello", range: NSRange(location: 0, length: 5)))
        let clipboardRevision = NSPasteboard.general.changeCount
        do {
            _ = try await TextReplacement.perform(target, text: "你好", stillCurrent: { true }, releasePanelFocus: {})
            XCTFail("A self-target must not be writable")
        } catch ReplacementError.unavailable {}
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardRevision)
    }
}
