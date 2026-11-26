import XCTest
@testable import Wordglide

final class TextLanguageTests: XCTestCase {
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
