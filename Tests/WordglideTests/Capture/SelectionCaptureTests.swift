import ApplicationServices
import XCTest
@testable import Wordglide

final class SelectionCaptureTests: XCTestCase {
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
