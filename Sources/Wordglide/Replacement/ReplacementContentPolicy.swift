import Foundation
import ApplicationServices

/// Local checks only. These helpers never inspect another application or use a
/// pasteboard, so malformed AX replies and selection plans can be tested safely.
enum ReplacementContentPolicy {
    static func requireTextOnly(_ selected: String) throws {
        guard !selected.unicodeScalars.contains(where: { $0.value == 0xFFFC }) else {
            throw ReplacementError.embeddedObject
        }
    }

    static func requireSingleSelection(_ primary: NSRange, reported: [NSRange]?) throws {
        guard valid(primary) else { throw ReplacementError.unreadableSelection }
        guard let reported else { return }
        guard reported.count <= 1 else { throw ReplacementError.multipleSelections }
        guard let only = reported.first, valid(only), only == primary else {
            throw ReplacementError.unreadableSelection
        }
    }

    static func reportedRanges(from reference: CFTypeRef) throws -> [NSRange] {
        guard CFGetTypeID(reference) == CFArrayGetTypeID(), let values = reference as? [Any] else {
            throw ReplacementError.unreadableSelection
        }
        return try values.map { item in
            let reference = item as CFTypeRef
            guard CFGetTypeID(reference) == AXValueGetTypeID() else {
                throw ReplacementError.unreadableSelection
            }
            var range = CFRange()
            guard AXValueGetValue(reference as! AXValue, .cfRange, &range) else {
                throw ReplacementError.unreadableSelection
            }
            let result = NSRange(location: range.location, length: range.length)
            guard valid(result) else { throw ReplacementError.unreadableSelection }
            return result
        }
    }

    private static func valid(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.length <= Int.max - range.location
    }
}
