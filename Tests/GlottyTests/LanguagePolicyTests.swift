import Testing
import Foundation
import NaturalLanguage
@testable import Glotty

@Suite("LanguagePolicy.isSingleWord")
struct IsSingleWordTests {
    @Test("Empty string is not a single word")
    func empty() {
        #expect(LanguagePolicy.isSingleWord("") == false)
    }

    @Test("Whitespace-only string is not a single word")
    func whitespaceOnly() {
        #expect(LanguagePolicy.isSingleWord("   \n\t") == false)
    }

    @Test("A single ASCII word is detected")
    func ascii() {
        #expect(LanguagePolicy.isSingleWord("translation") == true)
    }

    @Test("A single CJK word is detected")
    func cjk() {
        #expect(LanguagePolicy.isSingleWord("翻译") == true)
    }

    @Test("A CJK sentence without whitespace is NOT a single word")
    func cjkSentenceIsMultipleWords() {
        // Previously the no-whitespace shortcut treated this as a single word —
        // CJK sentences have no spaces. Use NLTokenizer instead.
        #expect(LanguagePolicy.isSingleWord("你好世界今天天气") == false)
    }

    @Test("A CJK phrase with punctuation is not a single word")
    func cjkPhraseWithComma() {
        #expect(LanguagePolicy.isSingleWord("你好，世界") == false)
    }
}

@Suite("PopupView.flattenWhitespace")
struct FlattenWhitespaceTests {
    @Test("Newlines collapse to single spaces")
    func newlinesCollapse() {
        #expect(PopupView.flattenWhitespace("hello\nworld") == "hello world")
        #expect(PopupView.flattenWhitespace("hello\r\nworld") == "hello world")
    }

    @Test("Multiple whitespace runs become one space")
    func multipleSpacesCollapse() {
        #expect(PopupView.flattenWhitespace("hello   world\n\nagain") == "hello world again")
    }

    @Test("Leading and trailing whitespace are dropped")
    func trimsEdges() {
        #expect(PopupView.flattenWhitespace("  hello world  \n") == "hello world")
    }

    @Test("Single-line input passes through unchanged")
    func passesThrough() {
        #expect(PopupView.flattenWhitespace("hello world") == "hello world")
    }

    @Test("Two words separated by space are not a single word")
    func twoWords() {
        #expect(LanguagePolicy.isSingleWord("hello world") == false)
    }

    @Test("Surrounding whitespace is trimmed before checking")
    func trimsWhitespace() {
        #expect(LanguagePolicy.isSingleWord("  word  ") == true)
    }

    @Test("More than 32 chars is not a single word")
    func tooLong() {
        let long = String(repeating: "a", count: 33)
        #expect(LanguagePolicy.isSingleWord(long) == false)
    }

    @Test("Exactly 32 chars is still a single word")
    func boundary() {
        let edge = String(repeating: "a", count: 32)
        #expect(LanguagePolicy.isSingleWord(edge) == true)
    }
}

@Suite("LanguagePolicy.preferredTarget")
struct PreferredTargetTests {
    @Test("English source + English locale → zh-Hans (so user gets a non-identity translation)")
    func englishToChinese() {
        let target = LanguagePolicy.preferredTarget(
            for: .english,
            userLocale: Locale(identifier: "en_US")
        )
        #expect(target == "zh-Hans")
    }

    @Test("English source + Chinese locale → zh")
    func englishToUserLocale() {
        let target = LanguagePolicy.preferredTarget(
            for: .english,
            userLocale: Locale(identifier: "zh_CN")
        )
        #expect(target == "zh")
    }

    @Test("English source + Spanish locale → es")
    func englishToSpanish() {
        let target = LanguagePolicy.preferredTarget(
            for: .english,
            userLocale: Locale(identifier: "es_ES")
        )
        #expect(target == "es")
    }

    @Test("Non-English source → English")
    func chineseSourceGoesToEnglish() {
        let target = LanguagePolicy.preferredTarget(
            for: .simplifiedChinese,
            userLocale: Locale(identifier: "zh_CN")
        )
        #expect(target == "en")
    }

    @Test("French source → English (regardless of user locale)")
    func frenchSourceGoesToEnglish() {
        let target = LanguagePolicy.preferredTarget(
            for: .french,
            userLocale: Locale(identifier: "fr_FR")
        )
        #expect(target == "en")
    }

    @Test("Nil source → English")
    func nilSourceGoesToEnglish() {
        let target = LanguagePolicy.preferredTarget(
            for: nil,
            userLocale: Locale(identifier: "en_US")
        )
        #expect(target == "en")
    }
}

@Suite("LanguagePolicy.detectSourceLanguage")
struct DetectSourceLanguageTests {
    @Test("Single ambiguous ASCII word falls back to English (the 'water' bug)")
    func waterFallsBackToEnglish() {
        // The original bug: NLLanguageRecognizer flagged 'water' as Dutch with low
        // confidence because it's a real word in both languages. The bias + ASCII
        // fallback should now produce English.
        let detected = LanguagePolicy.detectSourceLanguage("water",
                                                            userLocale: Locale(identifier: "en_US"))
        #expect(detected == .english)
    }

    @Test("Empty string returns nil")
    func empty() {
        #expect(LanguagePolicy.detectSourceLanguage("") == nil)
    }

    @Test("Long English sentence is detected as English with confidence")
    func longEnglish() {
        let detected = LanguagePolicy.detectSourceLanguage(
            "The quick brown fox jumps over the lazy dog repeatedly each morning."
        )
        #expect(detected == .english)
    }

    @Test("Chinese text is detected as Chinese")
    func chineseDetected() {
        let detected = LanguagePolicy.detectSourceLanguage("这是一个中文句子，用于测试语言识别功能。")
        // Could be either simplified or traditional depending on recognizer; both fine.
        #expect(detected == .simplifiedChinese || detected == .traditionalChinese)
    }

    @Test("Japanese text is detected as Japanese (bypasses ASCII fallback)")
    func japaneseDetected() {
        let detected = LanguagePolicy.detectSourceLanguage("これは日本語の文章です。")
        #expect(detected == .japanese)
    }

    @Test("Cyrillic text bypasses the ASCII fallback")
    func cyrillicBypassesFallback() {
        let detected = LanguagePolicy.detectSourceLanguage("Привет мир")
        // Should be Russian (or another Cyrillic language); definitely NOT English.
        #expect(detected != .english)
        #expect(detected != nil)
    }
}
