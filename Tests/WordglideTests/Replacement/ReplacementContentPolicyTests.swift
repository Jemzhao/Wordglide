import Foundation
import ApplicationServices
import XCTest
@testable import Wordglide

final class ReplacementContentPolicyTests: XCTestCase {
    func testMissingPluralSelectionAndOneMatchingRangeRemainSupported() {
        for range in [NSRange(location: 3, length: 0), NSRange(location: 3, length: 4)] {
            XCTAssertNoThrow(try ReplacementContentPolicy.requireSingleSelection(range, reported: nil))
            XCTAssertNoThrow(try ReplacementContentPolicy.requireSingleSelection(range, reported: [range]))
        }
    }

    func testMultipleCaretsOrSelectionsAreRejected() {
        XCTAssertFalse(ReplacementError.multipleSelections.permitsEditableAncestorResolution)
        let first = NSRange(location: 1, length: 0)
        for ranges in [[first, NSRange(location: 4, length: 0)],
                       [first, NSRange(location: 4, length: 2)]] {
            XCTAssertThrowsError(try ReplacementContentPolicy.requireSingleSelection(first, reported: ranges)) { error in
                guard case ReplacementError.multipleSelections = error else {
                    return XCTFail("Expected an explicit multiple-selection refusal")
                }
            }
        }
    }

    func testEmptyInconsistentOrMalformedPluralRangesAreRejected() {
        let primary = NSRange(location: 1, length: 2)
        let malformed = [NSRange(location: NSNotFound, length: 0),
                         NSRange(location: -1, length: 0),
                         NSRange(location: 1, length: -1),
                         NSRange(location: Int.max - 1, length: 2)]
        for ranges in [[], [NSRange(location: 2, length: 2)]] + malformed.map({ [$0] }) {
            XCTAssertThrowsError(try ReplacementContentPolicy.requireSingleSelection(primary, reported: ranges)) { error in
                guard case ReplacementError.unreadableSelection = error else {
                    return XCTFail("Expected an unreadable or contradictory selection")
                }
            }
        }
        for range in malformed {
            XCTAssertThrowsError(try ReplacementContentPolicy.requireSingleSelection(range, reported: nil))
        }
    }

    func testAXRangeArraysDecodeWithoutReadingAnyApplication() throws {
        var range = CFRange(location: 2, length: 3)
        let value = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        let decoded = try ReplacementContentPolicy.reportedRanges(from: [value] as CFArray)
        XCTAssertEqual(decoded, [NSRange(location: 2, length: 3)])
        XCTAssertNoThrow(try ReplacementContentPolicy.requireSingleSelection(decoded[0], reported: decoded))
    }

    func testMalformedAXRangeContainersAndValuesAreRejected() throws {
        var point = CGPoint(x: 1, y: 2)
        let wrongKind = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        var negative = CFRange(location: -1, length: 1)
        let negativeRange = try XCTUnwrap(AXValueCreate(.cfRange, &negative))
        let references: [CFTypeRef] = ["not an array" as CFString,
                                      ["not an AXValue"] as CFArray,
                                      [wrongKind] as CFArray,
                                      [negativeRange] as CFArray]
        for reference in references {
            XCTAssertThrowsError(try ReplacementContentPolicy.reportedRanges(from: reference))
        }
    }

    func testWholeFieldOrSelectedEmbeddedObjectsAreRejected() {
        XCTAssertFalse(ReplacementError.embeddedObject.permitsEditableAncestorResolution)
        let value = "文字\u{FFFC}附件"
        XCTAssertThrowsError(try DirectReplacementPlan(value: value, selected: "",
            range: NSRange(location: 0, length: 0), selectionWritable: true)) { error in
            guard case ReplacementError.embeddedObject = error else { return XCTFail("Expected attachment refusal") }
        }
        XCTAssertThrowsError(try DirectReplacementPlan(value: value, selected: "\u{FFFC}",
            range: NSRange(location: 2, length: 1), selectionWritable: true)) { error in
            guard case ReplacementError.embeddedObject = error else { return XCTFail("Expected selected attachment refusal") }
        }
    }

    func testPartialPlainTextRemainsSupportedBesideAnAttachment() throws {
        let value = "前缀\u{FFFC} 中文 后缀"
        let plan = try DirectReplacementPlan(value: value, selected: "中文",
            range: (value as NSString).range(of: "中文"), selectionWritable: false)
        XCTAssertFalse(plan.replacesWholeField)
        XCTAssertEqual(plan.edit.selected, "中文")
        XCTAssertEqual(plan.edit.replacing(with: "Chinese"), "前缀\u{FFFC} Chinese 后缀")
    }
}
