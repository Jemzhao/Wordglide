import AppKit
import ApplicationServices
import XCTest
@testable import Wordglide

final class ReplacementCompositionTests: XCTestCase {
    private func markerRange(collapsed: Bool = false) -> CFTypeRef {
        let startBytes: [UInt8] = [1, 2, 3, 4]
        let endBytes: [UInt8] = [1, 2, 3, 5]
        let start = startBytes.withUnsafeBufferPointer {
            AXTextMarkerCreate(nil, $0.baseAddress!, $0.count)
        }
        let end = collapsed ? start : endBytes.withUnsafeBufferPointer {
            AXTextMarkerCreate(nil, $0.baseAddress!, $0.count)
        }
        return AXTextMarkerRangeCreate(nil, start, end)
    }

    private func range(_ location: Int, _ length: Int) -> AXValue {
        var value = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &value)!
    }

    func testStandardMarkerRangeDenotesActiveComposition() {
        let marker = markerRange()
        XCTAssertEqual(CFGetTypeID(marker), AXTextMarkerRangeGetTypeID())
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(standardRange: marker))
    }

    func testNonNullCollapsedStandardMarkerStillDenotesProvisionalInput() {
        // The AX contract uses NULL, rather than marker length, for inactivity.
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(standardRange: markerRange(collapsed: true)))
    }

    func testMissingOrWronglyTypedStandardEvidenceDoesNotClaimComposition() {
        XCTAssertFalse(ReplacementCompositionEvidence.isActive())
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(standardRange: NSNumber(value: true)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(standardRange: range(0, 3)))
    }

    func testLegacyFlagAndBothTextRepresentationsRemainSupported() {
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(legacyFlag: true))
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(legacyText: "nihao" as NSString))
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(legacyText: NSAttributedString(string: "你好")))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyFlag: false, legacyText: "" as NSString))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyText: NSAttributedString(string: "")))
    }

    func testLegacyRangeRequiresRealNonemptyValidRange() {
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(legacyRange: range(0, 2)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyRange: range(0, 0)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyRange: range(-1, 2)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyRange: range(NSNotFound, 2)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyRange: range(0, -1)))
        XCTAssertFalse(ReplacementCompositionEvidence.isActive(legacyRange: markerRange()))
    }

    func testPositiveLegacyEvidenceSurvivesUnsupportedStandardValue() {
        XCTAssertTrue(ReplacementCompositionEvidence.isActive(standardRange: "unsupported" as NSString,
            legacyFlag: true))
    }
}
