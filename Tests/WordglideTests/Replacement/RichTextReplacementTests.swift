import AppKit
import XCTest

/// An AppKit text consumer with its own undo stack. It has no window, never
/// becomes first responder, and does not send keystrokes to any application.
@MainActor
private final class IsolatedRichTextView: NSTextView {
    let isolatedUndoManager = UndoManager()
    override var undoManager: UndoManager? { isolatedUndoManager }
}

final class RichTextReplacementTests: XCTestCase {
    @MainActor
    private func makeView(_ content: NSAttributedString) -> IsolatedRichTextView {
        _ = NSApplication.shared
        let view = IsolatedRichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.isRichText = true
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.textStorage?.setAttributedString(content)
        view.isolatedUndoManager.groupsByEvent = false
        view.isolatedUndoManager.removeAllActions()
        return view
    }

    /// Test the native consumer of a plain-string pasteboard, not cross-process
    /// event delivery. The explicit undo group models the single paste event.
    @MainActor
    private func paste(_ text: String, into view: IsolatedRichTextView,
                       file: StaticString = #filePath, line: UInt = #line) {
        let board = NSPasteboard(name: NSPasteboard.Name("app.wordglide.rich-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString(text, forType: .string), file: file, line: line)
        let manager = view.isolatedUndoManager
        manager.beginUndoGrouping()
        let read = view.readSelection(from: board)
        manager.endUndoGrouping()
        XCTAssertTrue(read, file: file, line: line)
        XCTAssertEqual(manager.groupingLevel, 0, file: file, line: line)
    }

    @MainActor func testPlainPasteKeepsUnselectedFontAndLinkAndUndoRestoresEveryAttribute() {
        let prefix = "前缀 😀e\u{301} "
        let selected = "中文"
        let suffix = " 后缀 🎯a\u{308}"
        let content = NSMutableAttributedString(string: prefix + selected + suffix,
            attributes: [.font: NSFont.systemFont(ofSize: 14)])
        content.addAttributes([.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.systemBlue],
                              range: NSRange(location: 0, length: prefix.utf16.count))
        let link = URL(string: "https://example.com/wordglide-test")!
        content.addAttributes([.link: link, .underlineStyle: NSUnderlineStyle.single.rawValue],
                              range: NSRange(location: prefix.utf16.count + selected.utf16.count, length: suffix.utf16.count))
        let view = makeView(content)
        view.setSelectedRange(NSRange(location: prefix.utf16.count, length: selected.utf16.count))
        let original = NSAttributedString(attributedString: view.attributedString())

        paste("English", into: view)
        let expected = prefix + "English" + suffix
        XCTAssertEqual(Array(view.string.utf16), Array(expected.utf16))
        XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       original.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let combiningPrefix = (prefix as NSString).range(of: "e\u{301}").location
        XCTAssertEqual(view.textStorage?.attribute(.font, at: combiningPrefix, effectiveRange: nil) as? NSFont,
                       original.attribute(.font, at: combiningPrefix, effectiveRange: nil) as? NSFont)
        let newSuffix = prefix.utf16.count + "English".utf16.count
        let combiningSuffix = newSuffix + (suffix as NSString).range(of: "a\u{308}").location
        XCTAssertEqual(view.textStorage?.attribute(.link, at: combiningSuffix, effectiveRange: nil) as? URL, link)
        XCTAssertEqual(view.textStorage?.attribute(.underlineStyle, at: newSuffix + 1, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        let pasted = NSAttributedString(attributedString: view.attributedString())
        let manager = view.isolatedUndoManager
        guard manager.canUndo else { return XCTFail("Native paste did not create an undo operation") }

        manager.undo()
        XCTAssertTrue(view.attributedString().isEqual(to: original))
        XCTAssertEqual(Array(view.string.utf16), Array(content.string.utf16))
        XCTAssertFalse(manager.canUndo, "One undo should consume the one paste operation")
        guard manager.canRedo else { return XCTFail("Native paste undo did not create redo") }
        manager.redo()
        XCTAssertTrue(view.attributedString().isEqual(to: pasted))
    }

    @MainActor func testWholeFieldPlainPasteCanUndoAndRedoCompleteRichText() {
        let content = NSMutableAttributedString(string: "你好😀，e\u{301}世界。",
            attributes: [.font: NSFont.systemFont(ofSize: 15)])
        content.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 19), range: NSRange(location: 0, length: 2))
        content.addAttributes([.link: URL(string: "https://example.com/rich-text-test")!,
                               .foregroundColor: NSColor.systemRed], range: (content.string as NSString).range(of: "世界"))
        let view = makeView(content)
        view.setSelectedRange(NSRange(location: 0, length: content.length))
        let original = NSAttributedString(attributedString: view.attributedString())

        let translated = "Hello 😀, e\u{301}world."
        paste(translated, into: view)
        XCTAssertEqual(Array(view.string.utf16), Array(translated.utf16))
        let pasted = NSAttributedString(attributedString: view.attributedString())
        let manager = view.isolatedUndoManager
        guard manager.canUndo else { return XCTFail("Whole-field native paste did not create undo") }
        manager.undo()
        XCTAssertTrue(view.attributedString().isEqual(to: original))
        XCTAssertEqual(Array(view.string.utf16), Array(content.string.utf16))
        XCTAssertFalse(manager.canUndo)
        guard manager.canRedo else { return XCTFail("Whole-field native paste undo did not create redo") }
        manager.redo()
        XCTAssertTrue(view.attributedString().isEqual(to: pasted))
    }
}
