import Testing
import Foundation
import NaturalLanguage
import Translation
@testable import Glotty

/// Tests for the *main* flows users actually hit — not just edge cases.
/// These exercise real Apple APIs (`DCSCopyTextDefinition`, `LanguageAvailability`,
/// `CFStringTransform`) so they require the host to have:
///   - At least one English dictionary enabled in Dictionary.app
///   - Apple Translation framework available (macOS 14+; we target 26)
/// If those preconditions are missing, failures here are environment-real, not bugs.
@Suite("Happy path — pronunciation")
struct PronunciationHappyPathTests {
    @Test("Chinese greeting 你好 produces pinyin starting with 'n' and 'h'")
    func chineseGreeting() {
        let entries = Pronunciation.pronounce("你好", language: .simplifiedChinese)
        #expect(entries.count == 1)
        #expect(entries[0].label == nil)
        let folded = entries[0].value
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "en_US"))
            .lowercased()
        #expect(folded.contains("ni"))
        #expect(folded.contains("hao"))
    }

    @Test("English word 'hello' resolves to at least one IPA entry from Dictionary.app")
    func englishWordHasIPA() {
        let entries = Pronunciation.ipa(for: "hello")
        #expect(entries.count >= 1, "Dictionary.app must have an English dictionary enabled")
        if let first = entries.first {
            #expect(first.value.hasPrefix("/"))
            #expect(first.value.hasSuffix("/"))
            #expect(first.value.count > 2) // not just "//"
        }
    }

    @Test("Pronouncing an English word produces well-formed phonetic entries when the dict has it")
    func englishPronounceShape() {
        let entries = Pronunciation.pronounce("hello", language: .english)
        // hello lands in every English dictionary; ensure the wiring produces well-formed
        // entries (slash-wrapped, non-empty value).
        #expect(entries.count >= 1)
        #expect(entries.allSatisfy { $0.value.hasPrefix("/") && $0.value.hasSuffix("/") })
        #expect(entries.allSatisfy { $0.value.count > 2 })
    }

    @Test("Japanese word ありがとう produces romaji")
    func japaneseRomaji() {
        let entries = Pronunciation.pronounce("ありがとう", language: .japanese)
        #expect(entries.count == 1)
        // Romaji is Latin script — should contain ASCII letters.
        let asciiCount = entries[0].value.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        #expect(asciiCount >= 4)
    }
}

@Suite("Happy path — language detection")
struct LanguageDetectionHappyPathTests {
    @Test("'water' (the original bug) detects as English")
    func waterIsEnglish() {
        let detected = LanguagePolicy.detectSourceLanguage("water")
        #expect(detected == .english)
    }

    @Test("'translation' detects as English")
    func translationIsEnglish() {
        let detected = LanguagePolicy.detectSourceLanguage("translation")
        #expect(detected == .english)
    }

    @Test("'你好' detects as Chinese")
    func chineseGreetingDetected() {
        let detected = LanguagePolicy.detectSourceLanguage("你好")
        #expect(detected == .simplifiedChinese || detected == .traditionalChinese)
    }

    @Test("'こんにちは' detects as Japanese")
    func japaneseGreetingDetected() {
        let detected = LanguagePolicy.detectSourceLanguage("こんにちは")
        #expect(detected == .japanese)
    }

    @Test("Real English sentence detects as English with high confidence")
    func englishSentence() {
        let detected = LanguagePolicy.detectSourceLanguage(
            "Software engineering is the application of engineering principles to software."
        )
        #expect(detected == .english)
    }
}

@Suite("Happy path — Apple Translation framework")
struct TranslationFrameworkHappyPathTests {
    @Test("LanguageAvailability returns a non-empty supported list")
    func supportedLanguagesNonEmpty() async {
        let supported = await LanguageAvailability().supportedLanguages
        #expect(!supported.isEmpty)
        // English is always supported on Apple's Translation framework.
        #expect(supported.contains { $0.minimalIdentifier == "en" })
    }

    @Test("English ↔ Simplified Chinese is at least supported (installed or downloadable)")
    func enZhPairIsSupported() async {
        let avail = LanguageAvailability()
        let forward = await avail.status(
            from: .init(identifier: "en"),
            to: .init(identifier: "zh-Hans")
        )
        #expect(forward != .unsupported)
    }

    @Test("English ↔ Japanese is at least supported")
    func enJaPairIsSupported() async {
        let avail = LanguageAvailability()
        let forward = await avail.status(
            from: .init(identifier: "en"),
            to: .init(identifier: "ja")
        )
        #expect(forward != .unsupported)
    }

    @Test("Building a TranslationSession.Configuration retains source + target")
    func buildsConfiguration() {
        // Note: `minimalIdentifier` collapses defaults — `zh-Hans` becomes `zh` because
        // Hans is the default script for Mandarin. Compare via maximalIdentifier instead.
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
        #expect(config.source != nil)
        #expect(config.target != nil)
        #expect(config.source?.languageCode?.identifier == "en")
        #expect(config.target?.languageCode?.identifier == "zh")
        #expect(config.target?.script?.identifier == "Hans")
    }
}

@Suite("Happy path — settings flow defaults")
struct SettingsFlowHappyPathTests {
    @Test("English source + non-English locale picks the user's locale as target")
    func userInChinaTranslatesEnglishToChinese() {
        let target = LanguagePolicy.preferredTarget(
            for: .english,
            userLocale: Locale(identifier: "zh_CN")
        )
        #expect(target == "zh")
    }

    @Test("Chinese source goes to English regardless of user locale")
    func chineseSourceAlwaysGoesToEnglish() {
        let target = LanguagePolicy.preferredTarget(
            for: .simplifiedChinese,
            userLocale: Locale(identifier: "zh_CN")
        )
        #expect(target == "en")
    }

    @Test("English source + English-locale user gets zh-Hans (not identity)")
    func englishUserGetsChineseTarget() {
        let target = LanguagePolicy.preferredTarget(
            for: .english,
            userLocale: Locale(identifier: "en_US")
        )
        #expect(target == "zh-Hans")
        #expect(target != "en")
    }
}
