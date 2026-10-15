import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

private final class CommitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class ReplacementAttemptValidityTests: XCTestCase {
    func testInvalidationBeforeBeginRejectsTheTarget() {
        let attempt = ReplacementAttempt()
        XCTAssertTrue(attempt.isValid)
        attempt.invalidate()
        XCTAssertFalse(attempt.isValid)
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.changed = error else { return XCTFail("Expected invalid target rejection") }
        }
        XCTAssertFalse(attempt.markSent())
    }

    func testAbandoningAnInvalidatedPreparationCannotRearmIt() throws {
        let attempt = ReplacementAttempt()
        try attempt.begin()
        attempt.invalidate()
        attempt.abandonBeforePaste()
        XCTAssertFalse(attempt.isValid)
        XCTAssertFalse(attempt.markSent())
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.changed = error else { return XCTFail("Invalidation must remain permanent") }
        }
    }

    func testInvalidatedPendingPreparationCannotCommit() throws {
        let attempt = ReplacementAttempt()
        try attempt.begin()
        attempt.invalidate()
        XCTAssertFalse(attempt.markSent())
        XCTAssertFalse(attempt.markSent())
    }

    func testInvalidatingAlreadySentPasteDoesNotEnableRetry() throws {
        let attempt = ReplacementAttempt()
        try attempt.begin()
        XCTAssertTrue(attempt.markSent())
        attempt.invalidate()
        attempt.abandonBeforePaste()
        XCTAssertFalse(attempt.isValid)
        XCTAssertFalse(attempt.markSent())
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.alreadyAttempted = error else {
                return XCTFail("A paste sent before invalidation must remain consumed")
            }
        }
    }

    func testCopiedTargetsShareInvalidationAcrossQueues() throws {
        let target = ReplacementTarget(element: AXUIElementCreateApplication(1), pid: 1,
            edit: SelectionEdit(value: "你好", selected: "你好", range: NSRange(location: 0, length: 2)))
        let copy = target
        try target.attempt.begin()
        DispatchQueue.global().sync { copy.attempt.invalidate() }
        XCTAssertFalse(target.attempt.isValid)
        XCTAssertFalse(target.attempt.markSent())
    }

    func testConcurrentCommitChecksCanConsumeOnlyOnce() throws {
        let attempt = ReplacementAttempt()
        let commits = CommitCount()
        try attempt.begin()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if attempt.markSent() { commits.increment() }
        }
        XCTAssertEqual(commits.count, 1)
        XCTAssertThrowsError(try attempt.begin()) { error in
            guard case ReplacementError.alreadyAttempted = error else { return XCTFail("Expected consumed target") }
        }
    }
}
