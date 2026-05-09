import Testing
import NaturalLanguage
@testable import Glotty

@Suite("Pronunciation — dictionary parser")
struct DictionaryParserTests {
    @Test("Empty input returns no entries")
    func empty() {
        #expect(Pronunciation.parseDictionaryDefinition("") == [])
    }

    @Test("Definition without pipes returns no entries")
    func noPipes() {
        let result = Pronunciation.parseDictionaryDefinition("translation noun a translated text")
        #expect(result == [])
    }

    @Test("Single IPA produces one unlabeled entry")
    func singleVariant() {
        let entries = Pronunciation.parseDictionaryDefinition("tomato | təˈmeɪtoʊ | noun a red fruit")
        #expect(entries.count == 1)
        #expect(entries[0].label == nil)
        #expect(entries[0].value == "/təˈmeɪtoʊ/")
        #expect(entries[0].voiceLocale == nil)
    }

    @Test("Two distinct IPAs produce BrE + AmE entries")
    func twoVariants() {
        let entries = Pronunciation.parseDictionaryDefinition(
            "schedule | ˈʃɛdjuːl, ˈskɛdʒuːl | noun"
        )
        #expect(entries.count == 2)
        #expect(entries[0].label == "BrE")
        #expect(entries[0].value == "/ˈʃɛdjuːl/")
        #expect(entries[0].voiceLocale == "en-GB")
        #expect(entries[1].label == "AmE")
        #expect(entries[1].value == "/ˈskɛdʒuːl/")
        #expect(entries[1].voiceLocale == "en-US")
    }

    @Test("Identical IPAs are deduped to a single entry")
    func dedupesIdentical() {
        let entries = Pronunciation.parseDictionaryDefinition(
            "word | təˈmeɪtoʊ, təˈmeɪtoʊ | noun"
        )
        #expect(entries.count == 1)
        #expect(entries[0].label == nil)
    }

    @Test("Variants differing only in whitespace are deduped")
    func dedupesWhitespaceOnly() {
        let entries = Pronunciation.parseDictionaryDefinition(
            "word | təˈmeɪtoʊ ,  təˈmeɪtoʊ | noun"
        )
        #expect(entries.count == 1)
    }

    @Test("More than two variants are capped at two")
    func capsAtTwo() {
        let entries = Pronunciation.parseDictionaryDefinition(
            "word | aaa, bbb, ccc, ddd | noun"
        )
        #expect(entries.count == 2)
        #expect(entries[0].value == "/aaa/")
        #expect(entries[1].value == "/bbb/")
    }

    @Test("Pre-existing slashes inside the dict block are stripped before re-wrapping")
    func stripsSlashes() {
        let entries = Pronunciation.parseDictionaryDefinition(
            "word | /təˈmeɪtoʊ/ | noun"
        )
        #expect(entries.count == 1)
        #expect(entries[0].value == "/təˈmeɪtoʊ/")
    }
}

@Suite("Pronunciation — transliterate")
struct TransliterateTests {
    @Test("Simplified Chinese produces pinyin")
    func chinesePinyin() {
        let result = Pronunciation.transliterate("你好", from: .simplifiedChinese)
        #expect(result != nil)
        #expect(result != "你好")
        // Tone marks vary across OS versions; strip them and match the syllables.
        let folded = result?
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "en_US"))
            .lowercased()
        #expect(folded?.contains("ni") == true)
        #expect(folded?.contains("hao") == true)
    }

    @Test("English input returns nil — no transform applies")
    func englishReturnsNil() {
        #expect(Pronunciation.transliterate("hello", from: .english) == nil)
    }

    @Test("Nil language returns nil")
    func nilLanguage() {
        #expect(Pronunciation.transliterate("anything", from: nil) == nil)
    }
}
