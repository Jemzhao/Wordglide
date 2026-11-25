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
}
