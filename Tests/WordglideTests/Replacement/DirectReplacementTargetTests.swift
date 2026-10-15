import Foundation
import XCTest
@testable import Wordglide

final class DirectReplacementTargetTests: XCTestCase {
    func testOnlyEligibilityErrorsMayResolveAnEditableAncestor() {
        XCTAssertTrue(ReplacementError.unsupportedEditor.permitsEditableAncestorResolution)
        XCTAssertTrue(ReplacementError.editabilityUnconfirmed.permitsEditableAncestorResolution)
        for error in [ReplacementError.changed, .unavailable, .clipboard, .inProgress, .alreadyAttempted,
                      .composing, .noFocusedEditor, .unreadableValue, .unreadableSelection,
                      .selectionNotWritable, .emptyInput] {
            XCTAssertFalse(error.permitsEditableAncestorResolution)
        }
    }

    func testWholeFieldPlanKeepsCaretSeparateFromReplacementRange() throws {
        let value = "你好😀 world"
        let caret = NSRange(location: 4, length: 0)
        let plan = try DirectReplacementPlan(value: value, selected: "", range: caret, selectionWritable: true)
        XCTAssertTrue(plan.replacesWholeField)
        XCTAssertEqual(plan.originalRange, caret)
        XCTAssertEqual(plan.edit.range, NSRange(location: 0, length: value.utf16.count))
        XCTAssertEqual(plan.edit.selected, value)
        XCTAssertEqual(plan.edit.replacing(with: "Hello world"), "Hello world")
    }

    func testWholeFieldAllowsEndCaretWithoutSelectedTextAttribute() throws {
        let plan = try DirectReplacementPlan(value: "你好", selected: nil,
            range: NSRange(location: 2, length: 0), selectionWritable: true)
        XCTAssertTrue(plan.replacesWholeField)
        XCTAssertEqual(plan.originalRange, NSRange(location: 2, length: 0))
    }

    func testWholeFieldRequiresWritableSelectionAndConsistentEmptySelection() {
        XCTAssertThrowsError(try DirectReplacementPlan(value: "你好", selected: "",
            range: NSRange(location: 2, length: 0), selectionWritable: false))
        XCTAssertThrowsError(try DirectReplacementPlan(value: "你好", selected: "你",
            range: NSRange(location: 2, length: 0), selectionWritable: true))
        XCTAssertThrowsError(try DirectReplacementPlan(value: " \n ", selected: "",
            range: NSRange(location: 0, length: 0), selectionWritable: true))
    }

    func testRejectsInvalidCaretAndSplitSurrogateBoundary() {
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0),
                      NSRange(location: 4, length: 0), NSRange(location: 1, length: 0)] {
            XCTAssertThrowsError(try DirectReplacementPlan(value: "😀a", selected: "",
                range: range, selectionWritable: true))
        }
    }

    func testStrictSelectionUsesSelectedTextAndLeavesWholeFieldUntouched() throws {
        let plan = try DirectReplacementPlan(value: "before 中文 after", selected: "中文",
            range: NSRange(location: 7, length: 2), selectionWritable: false)
        XCTAssertFalse(plan.replacesWholeField)
        XCTAssertEqual(plan.edit.replacing(with: "Chinese"), "before Chinese after")
        XCTAssertThrowsError(try DirectReplacementPlan(value: "before 中文 after", selected: "wrong",
            range: NSRange(location: 7, length: 2), selectionWritable: true))
    }

    func testWholeFieldLimitUsesUTF16AndAcceptsBoundary() throws {
        let boundary = String(repeating: "你", count: TextLogic.maximumInputLength)
        XCTAssertNoThrow(try DirectReplacementPlan(value: boundary, selected: "",
            range: NSRange(location: boundary.utf16.count, length: 0), selectionWritable: true))
        let tooLong = String(repeating: "😀", count: TextLogic.maximumInputLength / 2 + 1)
        XCTAssertThrowsError(try DirectReplacementPlan(value: tooLong, selected: "",
            range: NSRange(location: 0, length: 0), selectionWritable: true)) { error in
            guard case CaptureError.inputTooLong = error else { return XCTFail("Expected length limit") }
        }
    }

    func testSelectionCanComeFromLargeFieldButSelectedTextRemainsBounded() throws {
        let value = "你" + String(repeating: "a", count: 9_000)
        let plan = try DirectReplacementPlan(value: value, selected: "你",
            range: NSRange(location: 0, length: 1), selectionWritable: false)
        XCTAssertEqual(plan.edit.selected, "你")
        XCTAssertFalse(plan.replacesWholeField)
        let oversized = String(repeating: "a", count: TextLogic.maximumInputLength + 1)
        XCTAssertThrowsError(try DirectReplacementPlan(value: oversized, selected: oversized,
            range: NSRange(location: 0, length: oversized.utf16.count), selectionWritable: true))
    }

    func testDirectCaptureRejectsOwnProcessBeforeCheckingPermissions() async {
        do {
            _ = try await ReplacementTarget.captureForDirectReplacement(pid: ProcessInfo.processInfo.processIdentifier)
            XCTFail("A direct target must never point into Wordglide")
        } catch {
            guard case CaptureError.ownApplication = error else { return XCTFail("Expected own-app filter") }
        }
    }
}
