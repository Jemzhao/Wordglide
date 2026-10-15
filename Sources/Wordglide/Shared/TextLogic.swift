// Adapted from Hover Translate. Copyright (c) 2026 Kianzzz.
// Distributed under the MIT License; see THIRD_PARTY_NOTICES.md.
import Foundation
import NaturalLanguage
import AppKit

enum TextLogic {
    static let maximumInputLength = 8_000
    static let maximumHoverLength = 1_200

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if recognizer.dominantLanguage == .simplifiedChinese || recognizer.dominantLanguage == .traditionalChinese { return "zh-Hans" }
        if recognizer.dominantLanguage == .english { return "en" }
        let chinese = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        return chinese > latin / 2 ? "zh-Hans" : "en"
    }

    static func hasEnglish(_ text: String) -> Bool {
        text.range(of: "[A-Za-z]", options: .regularExpression) != nil && language(of: text) == "en"
    }

    static func segment(_ text: String, utf16Offset: Int, word: Bool) -> String? {
        guard !text.isEmpty, utf16Offset >= 0, utf16Offset < text.utf16.count else { return nil }
        let utfIndex = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(utfIndex, within: text) else { return nil }
        let tokenizer = NLTokenizer(unit: word ? .word : .sentence)
        tokenizer.string = text
        let range = tokenizer.tokenRange(at: index)
        let result = clean(String(text[range]))
        return !result.isEmpty && result.count <= maximumHoverLength ? result : nil
    }

    /// Cocoa uses bottom-left coordinates; AX and screen capture use top-left.
    /// desktopTop is the MAIN display's Cocoa maxY, not the union of all displays.
    /// This keeps displays above, below, or left of the main display aligned.
    static func quartzPoint(_ cocoa: CGPoint, desktopTop: CGFloat) -> CGPoint {
        CGPoint(x: cocoa.x, y: desktopTop - cocoa.y)
    }

    static func cocoaRect(_ quartz: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: desktopTop - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    static func panelFrame(anchor: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let safe = ScreenGeometry.safeFrame(visible: visible)
        let fitted = ScreenGeometry.constrainedFrame(CGRect(origin: safe.origin, size: size), visible: visible)
        let validAnchor = !anchor.isNull && !anchor.isInfinite && anchor.minX.isFinite && anchor.minY.isFinite
            && anchor.maxX.isFinite && anchor.maxY.isFinite
        let anchor = validAnchor ? anchor : CGRect(origin: safe.origin, size: .zero)
        var y = anchor.minY - fitted.height - 12
        if y < safe.minY { y = anchor.maxY + 12 }
        return ScreenGeometry.constrainedFrame(CGRect(x: anchor.minX, y: y, width: fitted.width, height: fitted.height), visible: visible)
    }

    static func badgeFrame(pointer: CGPoint, visible: CGRect, source: CGRect = .zero) -> CGRect {
        let size: CGFloat = 30, gap: CGFloat = 6
        let safe = ScreenGeometry.safeFrame(visible: visible, margin: 6)
        func clamped(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(x, safe.minX), safe.maxX - size),
                   y: min(max(y, safe.minY), safe.maxY - size), width: size, height: size)
        }
        // Use real text bounds when available. Prefer the closest edge, not the
        // end of a long sentence. Keep the badge fixed while the pointer travels.
        if !source.isEmpty, !source.isInfinite, !source.isNull {
            let options = [
                clamped(pointer.x - size / 2, source.minY - gap - size),
                clamped(pointer.x - size / 2, source.maxY + gap),
                clamped(source.maxX + gap, pointer.y - size / 2),
                clamped(source.minX - gap - size, pointer.y - size / 2)
            ].filter { !$0.intersects(source.insetBy(dx: -3, dy: -3)) }
            if let closest = options.min(by: { distance(pointer, to: $0) < distance(pointer, to: $1) }),
               distance(pointer, to: closest) <= 64 { return closest }
        }
        // Some apps expose the entire container instead of a text line. Do not
        // send the icon to that container's distant edge.
        let x = pointer.x + gap + size <= safe.maxX ? pointer.x + gap : pointer.x - size - gap
        let y = pointer.y - size - gap >= safe.minY ? pointer.y - size - gap : pointer.y + gap
        return clamped(x, y)
    }

    static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
              max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    static func movingTowardBadge(from previous: CGPoint, to point: CGPoint, badge: CGRect) -> Bool {
        let dx = point.x - previous.x, dy = point.y - previous.y
        let length = hypot(dx, dy)
        guard length >= 0.5 else { return false }
        let tx = badge.midX - previous.x, ty = badge.midY - previous.y
        let targetLength = hypot(tx, ty)
        guard targetLength > 0 else { return false }
        // A generous approach cone permits diagonal movement and curved paths.
        return (dx * tx + dy * ty) / (length * targetLength) >= 0.35
            && distance(point, to: badge) < distance(previous, to: badge)
    }

    static func hoverTransitContains(_ point: CGPoint, from source: CGRect, to destination: CGRect) -> Bool {
        // A narrow bridge keeps the icon reachable without retaining unrelated screen areas.
        let start = CGPoint(x: min(max(destination.midX, source.minX), source.maxX),
                            y: min(max(destination.midY, source.minY), source.maxY))
        let end = CGPoint(x: destination.midX, y: destination.midY)
        let dx = end.x - start.x, dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        let t = denominator > 0 ? min(1, max(0, ((point.x-start.x)*dx + (point.y-start.y)*dy) / denominator)) : 0
        return hypot(point.x - (start.x + t*dx), point.y - (start.y + t*dy)) <= 15
    }
}

struct CapturedText: Sendable {
    let text: String
    let bounds: CGRect
    let method: String
}

struct SelectionEdit: Sendable {
    let value: String
    let selected: String
    let range: NSRange

    func replacing(with translation: String) -> String? {
        let text = value as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.length, range.length <= text.length - range.location,
              Range(range, in: value) != nil,
              text.substring(with: range) == selected else { return nil }
        return text.replacingCharacters(in: range, with: translation)
    }
}

/// Small deterministic checks used by the app's --self-test command.
/// AX permission and real OCR/selection behavior require the separate manual checks.
extension TextLogic {
    static func coreCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }
        check(clean(" \nHello\u{00a0}world\n ") == "Hello world", "clean nonbreaking spaces")
        check(language(of: "你好，世界。") == "zh-Hans", "Chinese source language")
        check(hasEnglish("I"), "one-letter English word")
        check(!hasEnglish("你好世界"), "Chinese does not trigger English hover")
        let sentence = "First sentence. Second sentence!"
        check(segment(sentence, utf16Offset: 17, word: true) == "Second", "word under pointer")
        check(segment(sentence, utf16Offset: 17, word: false) == "Second sentence!", "sentence under pointer")
        check(segment("😀 hello", utf16Offset: 3, word: true) == "hello", "UTF-16 offset after emoji")
        check(segment("😀 hello", utf16Offset: 1, word: true) == nil, "reject split surrogate offset")
        check(segment("hello", utf16Offset: -1, word: true) == nil, "negative token offset")
        check(segment("hello", utf16Offset: 5, word: true) == nil, "end token offset")
        check(segment(String(repeating: "x", count: maximumHoverLength + 1), utf16Offset: 0, word: true) == nil,
              "long hover input limit")
        let edit = SelectionEdit(value: "a😀b", selected: "😀", range: NSRange(location: 1, length: 2))
        check(edit.replacing(with: "好") == "a好b", "UTF-16 replacement")
        check(SelectionEdit(value: "hello", selected: "wrong", range: NSRange(location: 0, length: 5)).replacing(with: "好") == nil,
              "reject changed original selection")
        check(SelectionEdit(value: "hello", selected: "hello", range: NSRange(location: NSNotFound, length: 5)).replacing(with: "好") == nil,
              "reject missing selection range")
        check(SelectionEdit(value: "hello", selected: "hello", range: NSRange(location: 4, length: Int.max)).replacing(with: "好") == nil,
              "reject overflowing selection range")
        let cocoa = CGPoint(x: -900, y: 1_100)
        check(quartzPoint(cocoa, desktopTop: 900) == CGPoint(x: -900, y: -200), "secondary display point")
        check(cocoaRect(CGRect(x: -900, y: -200, width: 40, height: 20), desktopTop: 900)
              == CGRect(x: -900, y: 1_080, width: 40, height: 20), "secondary display rectangle")
        let screen = CGRect(x: -1_200, y: -500, width: 1_200, height: 900)
        check(screen.contains(panelFrame(anchor: CGRect(x: -10, y: -480, width: 8, height: 18),
                                         size: CGSize(width: 360, height: 240), visible: screen)), "panel screen clamping")
        check(screen.contains(badgeFrame(pointer: CGPoint(x: -3, y: -498), visible: screen)), "badge screen clamping")
        let badge = CGRect(x: 50, y: 0, width: 30, height: 30)
        check(movingTowardBadge(from: CGPoint(x: 0, y: 15), to: CGPoint(x: 20, y: 15), badge: badge), "badge approach")
        check(!movingTowardBadge(from: CGPoint(x: 20, y: 15), to: CGPoint(x: 0, y: 15), badge: badge), "badge departure")
        check(hoverTransitContains(CGPoint(x: 40, y: 15), from: CGRect(x: 0, y: 0, width: 20, height: 30), to: badge), "reachable hover bridge")
        check(!hoverTransitContains(CGPoint(x: 40, y: 80), from: CGRect(x: 0, y: 0, width: 20, height: 30), to: badge), "hover bridge excludes distant areas")
        return failures
    }
}

enum CardLayout {
    static let minimumWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 520
    static let translationFontSize: CGFloat = 17
    static let sourceFontSize: CGFloat = 13
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 48
    static let horizontalPadding: CGFloat = 20
    static let bodyVerticalPadding: CGFloat = 20
    static let sourceGap: CGFloat = 14
    static let replacementMessageHeight: CGFloat = 56
    // Below this size the fixed header/footer and three bottom actions cannot
    // remain usable. AppKit declines presentation instead of clipping controls.
    static let minimumContentSize = CGSize(width: 320, height: 260)

    struct Metrics {
        let width: CGFloat
        let sourceHeight: CGFloat
        let bodyHeight: CGFloat
        let height: CGFloat
    }

    static func canPresent(in visible: CGRect) -> Bool {
        let safe = ScreenGeometry.safeFrame(visible: visible)
        return safe.width >= minimumContentSize.width && safe.height >= minimumContentSize.height
    }

    static func metrics(source: String, result: String, showsSource: Bool, loading: Bool, choosing: Bool,
                        failure: Bool, hasMessage: Bool, visibleFrame: CGRect) -> Metrics {
        let available = ScreenGeometry.safeFrame(visible: visibleFrame)
        let width = min(Self.width(source: source, result: result), available.width)
        let reserved = headerHeight + footerHeight + bodyVerticalPadding * 2 + (hasMessage ? replacementMessageHeight : 0)
        let sourceBudget = max(0, available.height - reserved - sourceGap - 32)
        let sourceHeight = showsSource ? min(Self.sourceHeight(source, width: width), sourceBudget) : 0
        let fixed = reserved + (showsSource ? sourceHeight + sourceGap : 0)
        let measured = bodyHeight(result: result, width: width, loading: loading, choosing: choosing, failure: failure)
        let body = min(measured, max(0, available.height - fixed))
        return Metrics(width: width, sourceHeight: sourceHeight, bodyHeight: body, height: fixed + body)
    }

    static func width(source: String, result: String) -> CGFloat {
        let content = [source, result].flatMap { $0.components(separatedBy: .newlines) }
            .map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: translationFontSize)]).width }
            .max() ?? 0
        return min(maximumWidth, max(minimumWidth, ceil(content + horizontalPadding * 2)))
    }

    private static func measuredHeight(_ text: String, width: CGFloat, fontSize: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: max(1, width - horizontalPadding * 2), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph]).height) + 2
    }

    static func sourceHeight(_ source: String, width: CGFloat) -> CGFloat {
        min(100, max(22, measuredHeight(source, width: width, fontSize: sourceFontSize, lineSpacing: 4)))
    }

    static func bodyHeight(result: String, width: CGFloat, loading: Bool, choosing: Bool, failure: Bool) -> CGFloat {
        if loading || choosing { return 44 }
        let content = measuredHeight(result, width: width, fontSize: translationFontSize, lineSpacing: 5)
        return min(240, max(failure ? 76 : 32, content + (failure ? 28 : 0)))
    }
}
