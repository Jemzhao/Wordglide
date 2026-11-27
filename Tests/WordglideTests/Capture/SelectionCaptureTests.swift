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

        let selection = try TextCapture.readSelection(attribute: { name in
            name == kAXSelectedTextRangeAttribute ? selectedRange : nil
        }, parameterized: { name, value in
            guard name as String == kAXStringForRangeParameterizedAttribute else { return nil }
            XCTAssertTrue(CFEqual(value, selectedRange))
            return text as CFString
        }, permitsTextMarkers: { false }) { _, _ in false }

        XCTAssertEqual(selection?.raw, text)
    }

    func testReadsOnlyOwnedNoncollapsedMarkerRangesInEligibleEditors() throws {
        let start = try marker(1)
        let end = try marker(2)
        let selected = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, end))
        let caret = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, marker(1)))
        let crossesBoundary = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, marker(3)))
        let belongsToEditor: (AXTextMarker, AXTextMarker) -> Bool = { first, last in
            CFEqual(first, start) && CFEqual(last, end)
        }

        XCTAssertEqual(try readMarkerSelection(selected, allowed: true, validate: belongsToEditor)?.raw, "你好晚上乔布斯")
        XCTAssertThrowsError(try readMarkerSelection(caret, allowed: true) { first, last in
            CFEqual(first, start) && CFEqual(last, start)
        }) { error in
            guard case CaptureError.nothingSelected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(try readMarkerSelection(caret, allowed: true, validate: belongsToEditor))
        XCTAssertNil(try readMarkerSelection(selected, allowed: false, validate: belongsToEditor))
        XCTAssertNil(try readMarkerSelection(crossesBoundary, allowed: true, validate: belongsToEditor))
    }

    func testFocusedCaretStopsEditorAndDocumentFallbacks() throws {
        var range = CFRange(location: 6, length: 0)
        let caret = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        func staleDocumentSelection() -> TextCapture.AXSelection? {
            XCTFail("An explicit caret must not fall back to the document's old selection")
            return TextCapture.AXSelection(raw: "Old document selection", bounds: nil)
        }
        XCTAssertThrowsError(try TextCapture.readSelection(attribute: { name in
            if name == kAXSelectedTextRangeAttribute { return caret }
            XCTFail("An explicit caret must not request another attribute")
            if name == kAXSelectedTextAttribute { return "Stale selection" as CFString }
            return nil
        }, parameterized: { _, _ in
            XCTFail("An explicit caret must not request selected text")
            return nil
        }, permitsTextMarkers: { true }) { _, _ in
            XCTFail("An explicit caret must not resolve markers")
            return true
        } ?? staleDocumentSelection()) { error in
            guard case CaptureError.nothingSelected = error else {
                return XCTFail("Unexpected selection error: \(error)")
            }
        }
    }

    func testUnadvertisedNumericCaretOnlyAcceptsOwnedPositiveMarkers() throws {
        var placeholder = CFRange(location: 0, length: 0)
        let numeric = try XCTUnwrap(AXValueCreate(.cfRange, &placeholder))
        let start = try marker(1)
        let end = try marker(2)
        let markers = try XCTUnwrap(AXTextMarkerRangeCreate(nil, start, end))
        let attributes: (String) -> CFTypeRef? = { name in
            if name == kAXSelectedTextRangeAttribute { return numeric }
            if name == kAXSelectedTextMarkerRangeAttribute as String { return markers }
            XCTFail("A placeholder caret must use verified markers only")
            return nil
        }
        let selection = try TextCapture.readSelection(attribute: attributes, parameterized: { name, range in
            guard name as String == kAXStringForTextMarkerRangeParameterizedAttribute as String else { return nil }
            XCTAssertTrue(CFEqual(range, markers))
            return "实际选中的文字" as CFString
        }, permitsTextMarkers: { true }, hasAuthoritativeCaret: { false }) { first, last in
            CFEqual(first, start) && CFEqual(last, end)
        }
        XCTAssertEqual(selection?.raw, "实际选中的文字")

        XCTAssertThrowsError(try TextCapture.readSelection(attribute: attributes, parameterized: { _, _ in
            XCTFail("Do not read text from another editor")
            return nil
        }, permitsTextMarkers: { true }, hasAuthoritativeCaret: { false }, validateMarkerEndpoints: { _, _ in false })) { error in
            guard case CaptureError.nothingSelected = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRangeQueryMustReturnOnlyTheRequestedText() throws {
        var range = CFRange(location: 2, length: 2)
        let selectedRange = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        let selection = try TextCapture.readSelection(attribute: { name in
            if name == kAXSelectedTextRangeAttribute { return selectedRange }
            return name == kAXSelectedTextAttribute ? "前缀你好后缀" as CFString : nil
        }, parameterized: { name, _ in
            name as String == kAXStringForRangeParameterizedAttribute ? "前缀你好后缀" as CFString : nil
        }, permitsTextMarkers: { false }) { _, _ in false }

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
        let localSelection = try TextCapture.readSelection(attribute: { _ in nil }, parameterized: { _, _ in nil },
                                                           permitsTextMarkers: { false }, validateMarkerEndpoints: { _, _ in false })
        let selection = try localSelection ?? TextCapture.readMarkerSelection(attribute: readAttribute, parameterized: { name, value in
            guard name as String == kAXStringForTextMarkerRangeParameterizedAttribute as String else { return nil }
            XCTAssertTrue(CFEqual(value, range))
            return document as CFString
        }) { first, last in
            CFEqual(first, start) && CFEqual(last, end)
        }
        XCTAssertEqual(selection?.raw, document)

        XCTAssertNil(try TextCapture.readMarkerSelection(attribute: readAttribute, parameterized: { _, _ in
            XCTFail("Unvalidated document markers must not be read")
            return nil
        }) { _, _ in false })
    }

    private func readMarkerSelection(
        _ range: AXTextMarkerRange,
        allowed: Bool,
        validate: (AXTextMarker, AXTextMarker) -> Bool
    ) throws -> TextCapture.AXSelection? {
        try TextCapture.readSelection(attribute: { name in
            name == kAXSelectedTextMarkerRangeAttribute as String ? range : nil
        }, parameterized: { name, value in
            guard name as String == kAXStringForTextMarkerRangeParameterizedAttribute as String else { return nil }
            XCTAssertTrue(CFEqual(value, range))
            return "你好晚上乔布斯" as CFString
        }, permitsTextMarkers: { allowed }, validateMarkerEndpoints: validate)
    }

    private func marker(_ value: UInt8) throws -> AXTextMarker {
        var byte = value
        return try XCTUnwrap(AXTextMarkerCreate(nil, &byte, 1))
    }
}
