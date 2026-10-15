import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

final class ReplacementTests: XCTestCase {
    func testAttemptIsSharedAndNeverRetriesAfterPaste() throws {
        let attempt = ReplacementAttempt()
        try attempt.begin()
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.inProgress = error else {
                return XCTFail("A pending validation must reject another submission")
            }
        }
        attempt.abandonBeforePaste()
        try attempt.begin()
        attempt.markSent()
        attempt.abandonBeforePaste()
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.alreadyAttempted = error else {
                return XCTFail("An uncertain paste must never be sent twice")
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

    func testClipboardRestoresAllOriginalFormats() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let rich = NSPasteboardItem()
            let richData = Data("{\\rtf1 original}".utf8)
            let customType = NSPasteboard.PasteboardType("app.wordglide.tests.custom")
            XCTAssertTrue(rich.setString("original", forType: .string))
            XCTAssertTrue(rich.setData(richData, forType: .rtf))
            XCTAssertTrue(rich.setData(Data([0, 1, 2, 255]), forType: customType))
            XCTAssertTrue(board.writeObjects([rich]))

            let lease = try TemporaryPasteboard(text: "译文", board: board)
            XCTAssertEqual(board.string(forType: .string), "译文")
            XCTAssertTrue(lease.isCurrent)
            lease.restore()
            XCTAssertEqual(board.string(forType: .string), "original")
            XCTAssertEqual(board.data(forType: .rtf), richData)
            XCTAssertEqual(board.data(forType: customType), Data([0, 1, 2, 255]))
            XCTAssertFalse(lease.isCurrent)
        }
    }

    func testNewUserCopyWinsOverRestore() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            XCTAssertTrue(board.setString("original", forType: .string))
            let lease = try TemporaryPasteboard(text: "translation", board: board)
            board.clearContents()
            XCTAssertTrue(board.setString("new user copy", forType: .string))
            XCTAssertFalse(lease.isCurrent)
            let count = board.changeCount
            lease.restore()
            XCTAssertEqual(board.string(forType: .string), "new user copy")
            XCTAssertEqual(board.changeCount, count)
        }
    }

    func testRestoreIsIdempotentAfterLaterCopy() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            XCTAssertTrue(board.setString("original", forType: .string))
            let lease = try TemporaryPasteboard(text: "translation", board: board)
            lease.restore()
            board.clearContents()
            XCTAssertTrue(board.setString("later copy", forType: .string))
            let count = board.changeCount
            lease.restore()
            XCTAssertEqual(board.string(forType: .string), "later copy")
            XCTAssertEqual(board.changeCount, count)
        }
    }
}
