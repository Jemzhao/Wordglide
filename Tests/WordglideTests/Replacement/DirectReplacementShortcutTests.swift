import AppKit
import Carbon
import XCTest
@testable import Wordglide

final class DirectReplacementShortcutTests: XCTestCase {
    func testDirectShortcutMatchesOnlyItsConfiguredModifiers() throws {
        let shortcut = DirectReplacementShortcut.controlReturn
        XCTAssertTrue(shortcut.matches(event: try event(keyCode: UInt16(kVK_Return), flags: [.control])))
        XCTAssertTrue(shortcut.matches(event: try event(keyCode: UInt16(kVK_Return), flags: [.control, .capsLock])))
        XCTAssertFalse(shortcut.matches(event: try event(keyCode: UInt16(kVK_Return), flags: [.control, .shift])))
        XCTAssertFalse(shortcut.matches(event: try event(keyCode: UInt16(kVK_Return), flags: [.control, .option])))
        XCTAssertFalse(shortcut.matches(event: try event(keyCode: UInt16(kVK_Return), flags: [])))
    }

    func testEveryShortcutPreservesCommandX() throws {
        let cutEvent = try event(keyCode: UInt16(kVK_ANSI_X), flags: [.command])
        for shortcut in DirectReplacementShortcut.allCases {
            XCTAssertFalse(shortcut.matches(event: cutEvent))
            XCTAssertFalse(shortcut.eventModifiers.contains(.command))
        }
    }

    func testCarbonAndNSEventShortcutDefinitionsAgree() {
        for shortcut in DirectReplacementShortcut.allCases {
            XCTAssertEqual(shortcut.modifiers & UInt32(controlKey) != 0, shortcut.eventModifiers.contains(.control))
            XCTAssertEqual(shortcut.modifiers & UInt32(optionKey) != 0, shortcut.eventModifiers.contains(.option))
            XCTAssertEqual(shortcut.modifiers & UInt32(cmdKey), 0)
        }
        XCTAssertEqual(DirectReplacementShortcut.controlOptionR.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(DirectReplacementShortcut.controlReturn.keyCode, UInt32(kVK_Return))
        XCTAssertEqual(DirectReplacementShortcut.controlOptionReturn.keyCode, UInt32(kVK_Return))
    }

    private func event(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode
        ))
    }
}
