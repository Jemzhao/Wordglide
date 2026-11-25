import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

final class SelectionCaptureTests: XCTestCase {
    @MainActor func testSelectAllRequiresTheUnmodifiedCommandShortcut() throws {
        for (text, modifiers, matches) in [
            ("a", NSEvent.ModifierFlags.command, true),
            ("A", [.command, .capsLock], true),
            ("a", [.command, .option], false),
            ("A", [.command, .shift], false),
            ("a", [], false),
            ("b", [.command], false)
        ] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0
            ))
            XCTAssertEqual(HoverMonitor.isSelectAll(event), matches)
        }
    }

    func testReadsSelectedUTF16RangeWhenEditorOmitsSelectedText() throws {
        let text = "你好👋乔布斯"
        var range = CFRange(location: 2, length: text.utf16.count)
        let selectedRange = try XCTUnwrap(AXValueCreate(.cfRange, &range))

        let selection = TextCapture.readSelection(attribute: { name in
            name == kAXSelectedTextRangeAttribute ? selectedRange : nil
        }, parameterized: { name, value in
            guard name as String == kAXStringForRangeParameterizedAttribute else { return nil }
            XCTAssertTrue(CFEqual(value, selectedRange))
            return text as CFString
        }, permitsTextMarkers: { false })

        XCTAssertEqual(selection?.raw, text)
    }

    func testReadsOnlyNoncollapsedMarkerRangesInEligibleEditors() throws {
        let start = try marker(1)
        let end = try marker(2)
        let selected = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, end))
        let caret = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, marker(1)))

        XCTAssertEqual(readMarkerSelection(selected, allowed: true)?.raw, "你好晚上乔布斯")
        XCTAssertNil(readMarkerSelection(caret, allowed: true))
        XCTAssertNil(readMarkerSelection(selected, allowed: false))
    }

    func testRangeQueryMustReturnOnlyTheRequestedText() throws {
        var range = CFRange(location: 2, length: 2)
        let selectedRange = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        let selection = TextCapture.readSelection(attribute: { name in
            name == kAXSelectedTextRangeAttribute ? selectedRange : nil
        }, parameterized: { name, _ in
            name as String == kAXStringForRangeParameterizedAttribute ? "前缀你好后缀" as CFString : nil
        }, permitsTextMarkers: { false })

        XCTAssertNil(selection)
    }

    func testDocumentSelectionReturnsAllParagraphsOnlyAfterValidatingBothMarkers() throws {
        let start = try marker(1)
        let end = try marker(2)
        let range = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, end))
        let document = "Hello,\n\nThis is the first paragraph.\n\nHere is another.\n\nBest regards."
        let readAttribute: (String) -> CFTypeRef? = { name in
            name == kAXSelectedTextMarkerRangeAttribute as String ? range : nil
        }
        let selection = TextCapture.readMarkerSelection(attribute: readAttribute, parameterized: { name, value in
            guard name as String == kAXStringForTextMarkerRangeParameterizedAttribute as String else { return nil }
            XCTAssertTrue(CFEqual(value, range))
            return document as CFString
        }) { first, last in
            CFEqual(first, start) && CFEqual(last, end)
        }
        XCTAssertEqual(selection?.raw, document)

        XCTAssertNil(TextCapture.readMarkerSelection(attribute: readAttribute, parameterized: { _, _ in
            XCTFail("Unvalidated document markers must not be read")
            return nil
        }) { _, _ in false })
    }

    private func readMarkerSelection(_ range: AXTextMarkerRange, allowed: Bool) -> TextCapture.AXSelection? {
        TextCapture.readSelection(attribute: { name in
            name == kAXSelectedTextMarkerRangeAttribute as String ? range : nil
        }, parameterized: { name, value in
            guard name as String == kAXStringForTextMarkerRangeParameterizedAttribute as String else { return nil }
            XCTAssertTrue(CFEqual(value, range))
            return "你好晚上乔布斯" as CFString
        }, permitsTextMarkers: { allowed })
    }

    private func marker(_ value: UInt8) throws -> AXTextMarker {
        var byte = value
        return try XCTUnwrap(AXTextMarkerCreate(nil, &byte, 1))
    }
}
