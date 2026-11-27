import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Wordglide

final class TypingCaptureTests: XCTestCase {
    @MainActor func testTypingKeysAndInputMethodConfirmation() {
        XCTAssertTrue(HoverMonitor.isTypingKey(UInt16(kVK_ANSI_N), modifiers: [], hasTypingSession: false))
        XCTAssertTrue(HoverMonitor.isTypingKey(UInt16(kVK_Space), modifiers: .shift, hasTypingSession: true))
        XCTAssertTrue(HoverMonitor.isTypingKey(UInt16(kVK_Return), modifiers: [], hasTypingSession: true))
        XCTAssertFalse(HoverMonitor.isTypingKey(UInt16(kVK_Return), modifiers: [], hasTypingSession: false))
        XCTAssertFalse(HoverMonitor.isTypingKey(UInt16(kVK_ANSI_V), modifiers: .command, hasTypingSession: true))
        XCTAssertFalse(HoverMonitor.isTypingKey(UInt16(kVK_Return), modifiers: .control, hasTypingSession: true))
        XCTAssertFalse(HoverMonitor.isTypingKey(UInt16(kVK_Tab), modifiers: [], hasTypingSession: true))
        XCTAssertFalse(HoverMonitor.isTypingKey(UInt16(kVK_LeftArrow), modifiers: [], hasTypingSession: true))
    }

    func testOnlyReadableChineseDraftsBecomeTranslationSources() {
        XCTAssertEqual(TextCapture.chineseTypingSource("  你好\n"), "你好")
        XCTAssertEqual(TextCapture.chineseTypingSource("請稍等"), "請稍等")
        XCTAssertNil(TextCapture.chineseTypingSource("ni hao"))
        XCTAssertNil(TextCapture.chineseTypingSource(" \n"))
        XCTAssertNil(TextCapture.chineseTypingSource("你好\u{FFFC}"))
        XCTAssertNil(TextCapture.chineseTypingSource(String(repeating: "你", count: TextLogic.maximumInputLength + 1)))
    }

    @MainActor func testPreviewWaitsForCompositionAndUsesTheConfirmedCaret() async throws {
        let caret = CGRect(x: 60, y: 90, width: 0, height: 17)
        var reads = 0
        let result = try await HoverMonitor.stableTypedText(delay: .zero, confirmationDelay: .zero) {
            reads += 1
            if reads == 1 { throw ReplacementError.composing }
            return CapturedText(text: "你好", bounds: reads == 2 ? .null : caret, method: TextCapture.typingMethod)
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(result?.text, "你好")
        XCTAssertEqual(result?.bounds, caret)
    }

    @MainActor func testChangedDraftOrFocusCannotPublishTheOldPreview() async throws {
        var reads = 0
        let changedText = try await HoverMonitor.stableTypedText(delay: .zero, confirmationDelay: .zero) {
            reads += 1
            return CapturedText(text: reads == 1 ? "你好" : "你好世界", bounds: .zero, method: TextCapture.typingMethod)
        }
        XCTAssertNil(changedText)
        do {
            _ = try await HoverMonitor.stableTypedText(delay: .zero, confirmationDelay: .zero) {
                throw ReplacementError.changed
            }
            XCTFail("Reading a different editor must stop the preview")
        } catch ReplacementError.changed { }
    }

    @MainActor func testCancelledDebounceDoesNotReadTheEditor() async {
        let pending = Task { @MainActor in
            try await HoverMonitor.stableTypedText {
                XCTFail("The cancelled request must not read the editor")
                return nil
            }
        }
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
