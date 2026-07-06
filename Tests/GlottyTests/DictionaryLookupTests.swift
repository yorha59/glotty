import Testing
import Foundation
@testable import Glotty

@Suite("DictionaryLookup — bilingual (Chinese-English) format")
struct BilingualParserTests {
    /// Mirrors the actual `DCSCopyTextDefinition` output for "hello" on the user's host:
    /// single line, dialect-labeled IPAs, `A. noun ...` / `B. exclamation ...` POS markers,
    /// `①②③` numbered senses.
    static let helloEntry = "hello | BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ | A. noun 问候 wènhòu B. exclamation ① (greeting) 你好 nǐ hǎo; (on phone) 喂 wèi ② British (in surprise) 嘿 hēi"

    @Test("Parses both POS sections from the 'hello' bilingual entry")
    func parsesBothPOSSections() {
        let entry = DictionaryLookup.parseEntry(Self.helloEntry)
        #expect(entry.parts.count == 2)
        #expect(entry.parts[0].label == "noun")
        #expect(entry.parts[1].label == "exclamation")
    }

    @Test("Noun section has one unnumbered def with the Chinese gloss (pinyin stripped)")
    func nounSection() {
        let entry = DictionaryLookup.parseEntry(Self.helloEntry)
        let noun = entry.parts[0]
        #expect(noun.definitions.count == 1)
        #expect(noun.definitions[0].text.contains("问候"))
        // Pinyin (wènhòu) should NOT appear — strip pinyin removes it.
        #expect(!noun.definitions[0].text.contains("wènhòu"))
        #expect(noun.definitions[0].number == nil)
    }

    @Test("Exclamation section has two senses numbered 1 and 2")
    func exclamationSection() {
        let entry = DictionaryLookup.parseEntry(Self.helloEntry)
        let excl = entry.parts[1]
        #expect(excl.definitions.count == 2)
        #expect(excl.definitions[0].number == 1)
        #expect(excl.definitions[0].text.contains("你好"))
        #expect(excl.definitions[1].number == 2)
        #expect(excl.definitions[1].text.contains("嘿"))
    }

    @Test("BrE and AmE phonetics are extracted (not the legacy comma-only path)")
    func dialectIPAs() {
        let entry = DictionaryLookup.parseEntry(Self.helloEntry)
        #expect(entry.phonetics.count == 2)
        #expect(entry.phonetics[0].label == "BrE")
        #expect(entry.phonetics[0].value == "/həˈləʊ/")
        #expect(entry.phonetics[0].voiceLocale == "en-GB")
        #expect(entry.phonetics[1].label == "AmE")
        #expect(entry.phonetics[1].value == "/həˈloʊ/")
        #expect(entry.phonetics[1].voiceLocale == "en-US")
    }
}

@Suite("DictionaryLookup — Oxford monolingual format")
struct OxfordParserTests {
    @Test("Single POS with one numbered definition")
    func singlePOSOneDefinition() {
        let text = """
        hello | həˈləʊ | exclamation
        1 used as a greeting: hello there, Katie.
        """
        let entry = DictionaryLookup.parseEntry(text)
        #expect(entry.parts.count == 1)
        #expect(entry.parts[0].label == "exclamation")
        #expect(entry.parts[0].definitions.count == 1)
        #expect(entry.parts[0].definitions[0].number == 1)
        #expect(entry.parts[0].definitions[0].text == "used as a greeting")
        #expect(entry.parts[0].definitions[0].example == "hello there, Katie")
    }

    @Test("Multiple numbered definitions under one POS")
    func multipleDefinitions() {
        let text = """
        translation | tranzˈleɪʃən | noun
        1 the process of translating words: a Latin translation of Greek.
        2 the conversion of something from one form to another: research into practice.
        3 movement of a body from one point of space to another.
        """
        let entry = DictionaryLookup.parseEntry(text)
        #expect(entry.parts.count == 1)
        #expect(entry.parts[0].label == "noun")
        #expect(entry.parts[0].definitions.count == 3)
        #expect(entry.parts[0].definitions[0].number == 1)
        #expect(entry.parts[0].definitions[1].number == 2)
        #expect(entry.parts[0].definitions[2].number == 3)
        #expect(entry.parts[0].definitions[2].example == nil)
    }

    @Test("Single comma-separated alternates produce BrE + AmE entries")
    func alternatesIPAs() {
        let text = "schedule | ˈʃɛdjuːl, ˈskɛdʒuːl | noun"
        let entry = DictionaryLookup.parseEntry(text)
        #expect(entry.phonetics.count == 2)
        #expect(entry.phonetics[0].label == "BrE")
        #expect(entry.phonetics[1].label == "AmE")
    }

    @Test("Single IPA produces an unlabeled phonetic entry")
    func singleIPA() {
        let text = "tomato | təˈmeɪtoʊ | noun"
        let entry = DictionaryLookup.parseEntry(text)
        #expect(entry.phonetics.count == 1)
        #expect(entry.phonetics[0].label == nil)
        #expect(entry.phonetics[0].value == "/təˈmeɪtoʊ/")
    }
}

@Suite("DictionaryLookup — fallbacks and edge cases")
struct DictionaryParserEdgeTests {
    @Test("Empty input gives an empty entry")
    func emptyInput() {
        let entry = DictionaryLookup.parseEntry("")
        #expect(entry.parts.isEmpty)
        #expect(entry.phonetics.isEmpty)
        #expect(entry.hasContent == false)
    }

    @Test("Definition without pipes still surfaces no phonetics but may have a body")
    func noPipes() {
        let entry = DictionaryLookup.parseEntry("translation noun the act of translating")
        #expect(entry.phonetics.isEmpty)
    }

    @Test("Recognizes 'noun' as a POS keyword")
    func recognizesNoun() {
        #expect(DictionaryLookup.matchPartOfSpeech("noun") == "noun")
        #expect(DictionaryLookup.matchPartOfSpeech("noun (plural hellos)") == "noun")
    }

    @Test("Disambiguates 'verb' from 'adverb'")
    func disambiguatesVerb() {
        #expect(DictionaryLookup.matchPartOfSpeech("verb") == "verb")
        #expect(DictionaryLookup.matchPartOfSpeech("adverb") == "adverb")
    }

    @Test("Definition with colon splits gloss from example")
    func splitsExample() {
        let def = DictionaryLookup.splitDefinitionAndExample(
            text: "say hello: she helloed at me",
            number: 1
        )
        #expect(def.text == "say hello")
        #expect(def.example == "she helloed at me")
    }

    @Test("Body-after-IPA-block extraction")
    func bodyAfterIPA() {
        let body = DictionaryLookup.bodyAfterIPABlock(
            "hello | həˈləʊ | exclamation A greeting"
        )
        #expect(body == "exclamation A greeting")
    }

    @Test("Pinyin tokens are stripped from definition text")
    func stripsPinyin() {
        // `wènhòu` follows `问候`; `nǐ hǎo` follows `你好`. Both should be removed.
        let cleaned = DictionaryLookup.stripPinyin("问候 wènhòu")
        #expect(cleaned == "问候")

        let cleanedComplex = DictionaryLookup.stripPinyin("(greeting) 你好 nǐ hǎo; (on phone) 喂 wèi")
        #expect(cleanedComplex == "(greeting) 你好; (on phone) 喂")
    }

    @Test("Pinyin stripping leaves English / Chinese-only / no-pinyin text untouched")
    func leavesUntouched() {
        #expect(DictionaryLookup.stripPinyin("hello world") == "hello world")
        #expect(DictionaryLookup.stripPinyin("你好") == "你好")
        #expect(DictionaryLookup.stripPinyin("") == "")
    }

    @Test("Bilingual entry (with Chinese) is flagged as having translation content")
    func bilingualHasTranslation() {
        let entry = DictionaryLookup.parseEntry(BilingualParserTests.helloEntry)
        #expect(entry.hasBilingualContent == true)
    }

    @Test("Monolingual English entry is NOT flagged — it's just an English dictionary entry")
    func monolingualNoTranslation() {
        // Real DCSCopyTextDefinition output for 'transduction' on the user's host.
        let text = "transduction trans·duc·tion | ˌtranzˈdəkSHən | noun the action of transducing a signal: the network of genes involved in transduction."
        let entry = DictionaryLookup.parseEntry(text)
        #expect(entry.hasContent == true)             // Parser found the entry…
        #expect(entry.hasBilingualContent == false)   // …but it's monolingual English.
    }
}

@Suite("DictionaryLookup — sourceAndTarget filtering")
struct SourceAndTargetFilteringTests {
    @Test("Empty selectedIDs queries all dictionaries")
    func emptySelectedIDs() {
        let entries = DictionaryLookup.allEntries(for: "hello", selectedIDs: [])
        #expect(entries.count >= 1)
    }

    @Test("Non-matching selectedIDs returns no entries")
    func nonMatchingSelectedIDs() {
        let entries = DictionaryLookup.allEntries(for: "hello", selectedIDs: ["com.fake.dictionary"])
        #expect(entries.isEmpty)
    }
}

@Suite("DictionaryLookup — diagnostic")
struct DictionaryDiagnosticTests {
    @Test("Dump raw entry for a chosen word")
    func dumpRaw() {
        for word in ["hello", "translation", "schedule"] {
            let cfText = word as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(cfText))
            guard let unmanaged = DCSCopyTextDefinition(nil, cfText, range) else {
                print("[diag] no entry for '\(word)'")
                continue
            }
            let raw = unmanaged.takeRetainedValue() as String
            print("[diag] '\(word)' (\(raw.count) chars): \(raw)")
        }
    }
}
