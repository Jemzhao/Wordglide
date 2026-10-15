import AppKit
import Carbon

enum DirectReplacementShortcut: String, CaseIterable, Identifiable {
    case controlReturn
    case controlOptionR
    case controlOptionReturn

    var id: String { rawValue }

    var symbols: String {
        switch self {
        case .controlReturn: return "⌃↩"
        case .controlOptionR: return "⌃⌥R"
        case .controlOptionReturn: return "⌃⌥↩"
        }
    }

    var displayName: String {
        switch self {
        case .controlReturn: return "⌃↩  Control + Return"
        case .controlOptionR: return "⌃⌥R  Control + Option + R"
        case .controlOptionReturn: return "⌃⌥↩  Control + Option + Return"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlReturn, .controlOptionReturn: return UInt32(kVK_Return)
        case .controlOptionR: return UInt32(kVK_ANSI_R)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlReturn: return UInt32(controlKey)
        case .controlOptionR, .controlOptionReturn: return UInt32(controlKey | optionKey)
        }
    }

    var eventModifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlReturn: return [.control]
        case .controlOptionR, .controlOptionReturn: return [.control, .option]
        }
    }

    func matches(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return event.keyCode == UInt16(keyCode) && modifiers == eventModifiers
    }
}
