import XCTest
@testable import Wordglide

final class TextLanguageTests: XCTestCase {
    func testParagraphHoverKeepsACompleteParagraphOrShortLabel() {
        let paragraph = "Read the document. Check the details."
        XCTAssertEqual(TextLogic.hoverSegment(paragraph + "\nNext paragraph.", utf16Offset: 4, scope: .paragraph)?.text, paragraph)
        XCTAssertEqual(TextLogic.hoverSegment("Save", utf16Offset: 1, scope: .paragraph)?.text, "Save")
        XCTAssertEqual(TextLogic.hoverSegment("Settings and privacy", utf16Offset: 2, scope: .paragraph)?.text, "Settings and privacy")
    }

    func testParagraphHoverFallsBackToTheSentenceAndWordUnderThePointer() {
        let sentence = "Read the document."
        let longTail = "Keep " + String(repeating: "additional words ", count: 100) + "before printing."
        let shortSentence = TextLogic.hoverSegment(sentence + " " + longTail, utf16Offset: 6, scope: .paragraph)
        XCTAssertEqual(shortSentence?.scope, .sentence)
        XCTAssertEqual(shortSentence?.text, sentence)

        let offset = (longTail as NSString).range(of: "printing").location
        let word = TextLogic.hoverSegment(longTail, utf16Offset: offset, scope: .paragraph)
        XCTAssertEqual(word?.scope, .word)
        XCTAssertEqual(word?.text, "printing")
        XCTAssertEqual(TextLogic.hoverSegment(longTail, utf16Offset: offset, scope: .sentence)?.text, "printing")
        XCTAssertEqual(TextLogic.hoverSegment(sentence, utf16Offset: 7, scope: .word)?.text, "the")
    }

    func testUnsupportedTextDoesNotTriggerEnglishHover() {
        for text in ["Bonjour, comment allez-vous aujourd’hui ?", "¿Cómo estás?", "今日はとても良い天気です。",
                     "これは TODO", "日本語 TODO", "Привет"] {
            XCTAssertNil(TextLogic.language(of: text), text)
            XCTAssertFalse(TextLogic.hasEnglish(text), text)
        }
    }

    func testShortLabelsAndMixedTextKeepEnglishAndChineseDetection() {
        for text in ["I", "Hi", "Hi …", "Save", "Cancel", "Wordglide…", "Hello 世界, this is an English example."] {
            XCTAssertEqual(TextLogic.language(of: text), "en", text)
            XCTAssertTrue(TextLogic.hasEnglish(text), text)
        }
        for text in ["你好", "謝謝", "東京", "这次 update 修好了", "这是一个 TODO", "這是一個 TODO", "中文 TODO", "TODO 中文"] {
            XCTAssertEqual(TextLogic.language(of: text), "zh-Hans", text)
            XCTAssertFalse(TextLogic.hasEnglish(text), text)
        }
    }

    func testShortForeignWordsNeedStrongerEnglishEvidenceToTriggerHover() {
        for text in ["Bonjour", "Bonjour !", "Hola", "Hola!"] {
            XCTAssertEqual(TextLogic.hoverLanguage(of: text), .unsupported, text)
        }
        XCTAssertEqual(TextLogic.language(of: "Bonjour"), "en", "Keep an explicit short-text request available")
    }

    func testOCRRejectsDamagedUnicodeEvenWhenEnglishSurvives() {
        let invalidScalars = [0xFFFC, 0xFFFD, 0xFFFF, 0xFDD0, 0x10FFFF, 0x001B, 0xE000]
        for value in invalidScalars {
            let invalid = String(Unicode.Scalar(value)!)
            XCTAssertFalse(TextLogic.hasEnglishOCR("Open \(invalid) Wordglide 0.3.3"), String(value, radix: 16))
        }
    }

    func testOCRNeedsEnglishEvidenceForMultiwordNoiseButKeepsCommonLabels() {
        for text in ["lfiTr,kl&E 0.3.3. IA Wordglide X*V & rb", "J ylj G)4fRpxEÈf%1F * *",
                     "我已确认更新源提供 0.3.3。从 Wordglide 菜单栏点检查更新。"] {
            XCTAssertFalse(TextLogic.hasEnglishOCR(text), text)
        }
        for text in ["I", "Hi", "on.", "OK", "Save", "Read more", "GitHub Releases",
                     "3D, HDR, Pro", "A / B test", "Try vO.3.3 in Wordglide.", "Welcome to Wordglide.",
                     "C++ Reference: std::optional<T>"] {
            XCTAssertTrue(TextLogic.hasEnglishOCR(text), text)
        }
    }
}
