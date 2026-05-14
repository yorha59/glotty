import Testing
import Foundation
@testable import Glotty

@Suite("PolishPrompt — builder")
struct PolishPromptTests {
    @Test("English target produces an 'English' rewrite instruction")
    func englishTarget() {
        let prompt = PolishPrompt.build(text: "I want make meeting", targetLanguage: "en")
        #expect(prompt.contains("English"))
        #expect(prompt.contains("I want make meeting"))
    }

    @Test("Chinese target uses the English-locale language name for stable prompting")
    func chineseTargetUsesEnglishName() {
        // We resolve the language name in en_US so the LLM gets a consistent
        // English-language instruction regardless of the user's UI locale.
        let prompt = PolishPrompt.build(text: "我想开会", targetLanguage: "zh-Hans")
        #expect(prompt.contains("Chinese"))
        #expect(!prompt.contains("中文"))
    }

    @Test("Original text is trimmed of leading/trailing whitespace")
    func trimsWhitespace() {
        let prompt = PolishPrompt.build(text: "  hello   \n", targetLanguage: "en")
        #expect(prompt.contains("Original: hello"))
        #expect(!prompt.contains("Original:   hello"))
    }

    @Test("Unknown identifier falls back to the raw string")
    func unknownIdentifier() {
        let name = PolishPrompt.englishName(for: "xx-Zzzz-XX")
        #expect(name == "xx-Zzzz-XX" || name.contains("Zzzz") || name.contains("xx"))
    }

    @Test("Prompt instructs the model to output only the rewrite")
    func instructsOutputOnly() {
        let prompt = PolishPrompt.build(text: "hi", targetLanguage: "en")
        #expect(prompt.lowercased().contains("only"))
        #expect(prompt.lowercased().contains("no explanations"))
    }
}
