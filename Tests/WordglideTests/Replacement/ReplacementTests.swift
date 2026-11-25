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

    @MainActor func testUnreadableClipboardRejectsReplacementWithoutModifyingIt() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("original", forType: .string))
        let count = board.changeCount

        XCTAssertThrowsError(try TemporaryPasteboard(text: "translation", board: board, readItems: { _ in nil })) { error in
            guard case ReplacementError.clipboard = error else {
                return XCTFail("A failed clipboard snapshot must prevent replacement")
            }
        }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: board.name))

        let retry = try TemporaryPasteboard(text: "translation", board: board)
        retry.restore()
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    @MainActor func testEmptyClipboardCanBeUsedAndRestoredToEmpty() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertEqual(board.pasteboardItems?.count, 0)

        let lease = try TemporaryPasteboard(text: "translation", board: board)
        XCTAssertEqual(board.string(forType: .string), "translation")
        lease.restore()
        XCTAssertEqual(board.pasteboardItems?.count, 0)
        XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: board.name))
    }

    @MainActor func testClipboardLeaseRejectsOverlapUntilRestoration() throws {
        let name = NSPasteboard.Name("app.wordglide.tests.\(UUID().uuidString)")
        let board = NSPasteboard(name: name)
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("original", forType: .string))
        XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: name))

        let first = try TemporaryPasteboard(text: "first translation", board: board)
        defer { first.restore() }
        XCTAssertTrue(TemporaryPasteboard.hasActiveLease(for: name))
        let count = board.changeCount
        let sameBoard = NSPasteboard(name: name)
        XCTAssertThrowsError(try TemporaryPasteboard(text: "second translation", board: sameBoard)) { error in
            guard case ReplacementError.inProgress = error else {
                return XCTFail("A second lease must wait for restoration")
            }
        }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "first translation")
        XCTAssertTrue(first.isCurrent)

        first.restore()
        XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: name))
        XCTAssertEqual(board.string(forType: .string), "original")

        let second = try TemporaryPasteboard(text: "second translation", board: board)
        defer { second.restore() }
        first.restore()
        XCTAssertTrue(TemporaryPasteboard.hasActiveLease(for: name))
        XCTAssertTrue(second.isCurrent)
        second.restore()
        XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: name))
        XCTAssertEqual(board.string(forType: .string), "original")
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
            XCTAssertFalse(TemporaryPasteboard.hasActiveLease(for: board.name))
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
