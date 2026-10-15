import XCTest
@testable import Wordglide

final class ReplacementEditabilityTests: XCTestCase {
    func testSelectionWritabilityAloneDoesNotProveEditability() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup"] {
            XCTAssertFalse(allows(role: role, selectionWritable: true), role)
        }
        XCTAssertFalse(allows(role: "AXTextArea", readOnly: true, selectionWritable: true))
    }

    func testStandardTextRolesAcceptEachDirectEditabilityProof() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertTrue(allows(role: role, valueWritable: true), role)
            XCTAssertTrue(allows(role: role, selectedTextWritable: true), role)
            XCTAssertTrue(allows(role: role, explicitEditable: true), role)
        }
    }

    func testSelectedTextWritabilityDoesNotRequireSettingSelectionRange() {
        XCTAssertTrue(allows(role: "AXTextArea", selectedTextWritable: true, selectionWritable: false))
    }

    func testStandardTextRoleCannotUseEditableRootAndRangeAsOnlyProof() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup"] {
            XCTAssertFalse(allows(role: role, advertisedEditableRoot: true), role)
        }
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertFalse(allows(role: role, selectionWritable: true, advertisedEditableRoot: true), role)
        }
    }

    func testGroupRequiresEditableRootEvidence() {
        XCTAssertFalse(allows(role: "AXGroup", valueWritable: true))
        XCTAssertFalse(allows(role: "AXGroup", selectedTextWritable: true))
        XCTAssertFalse(allows(role: "AXGroup", explicitEditable: true, selectionWritable: true))
        XCTAssertTrue(allows(role: "AXGroup", selectionWritable: true, advertisedEditableRoot: true))
    }

    func testProhibitingFlagsOverrideEveryPositiveProof() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup"] {
            XCTAssertFalse(allows(role: role, enabled: false, explicitEditable: true,
                valueWritable: true, selectedTextWritable: true, selectionWritable: true, advertisedEditableRoot: true), role)
            XCTAssertFalse(allows(role: role, readOnly: true, explicitEditable: true,
                valueWritable: true, selectedTextWritable: true, selectionWritable: true, advertisedEditableRoot: true), role)
            XCTAssertFalse(allows(role: role, explicitEditable: false,
                valueWritable: true, selectedTextWritable: true, selectionWritable: true, advertisedEditableRoot: true), role)
        }
    }

    func testNonEditableRolesCannotBePromotedByPositiveFlags() {
        for role in ["AXStaticText", "AXDocument", "AXWebArea", "AXButton", "AXSecureTextField", "", "AXUnknown"] {
            XCTAssertFalse(allows(role: role, enabled: true, readOnly: false, explicitEditable: true,
                valueWritable: true, selectedTextWritable: true, selectionWritable: true, advertisedEditableRoot: true), role)
        }
    }

    private func allows(
        role: String,
        enabled: Bool? = nil,
        readOnly: Bool? = nil,
        explicitEditable: Bool? = nil,
        valueWritable: Bool = false,
        selectedTextWritable: Bool = false,
        selectionWritable: Bool = false,
        advertisedEditableRoot: Bool = false
    ) -> Bool {
        ReplacementEditability.allows(
            role: role, enabled: enabled, readOnly: readOnly, explicitEditable: explicitEditable,
            valueWritable: valueWritable, selectedTextWritable: selectedTextWritable,
            selectionWritable: selectionWritable, advertisedEditableRoot: advertisedEditableRoot
        )
    }
}
