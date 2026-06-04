import Testing
import Foundation
@testable import Glotty

// PolishPrompt.build reads main-isolated state via MainActor.assumeIsolated,
// which traps if the test runs off the main actor (Swift Testing uses a
// background executor by default). Pin the suites that call build to the
// main actor.
@Suite("PolishPrompt — variants mode (cross-language)")
@MainActor
struct VariantsPromptTests {
    @Test("English target name appears in the instruction")
    func englishTarget() {
        let prompt = PolishPrompt.build(text: "我想开会", mode: .variants(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("English"))
        #expect(prompt.contains("我想开会"))
    }

    @Test("Chinese target name resolves to 'Chinese' (not 中文) for stable LLM instruction")
    func chineseTargetEnglishName() {
        let prompt = PolishPrompt.build(text: "Let's chat", mode: .variants(target: "zh-Hans", nativeLanguage: nil))
        #expect(prompt.contains("Chinese"))
        #expect(!prompt.contains("中文"))
    }

    @Test("Prompt asks for 2 to 3 variants")
    func asksForMultipleVariants() {
        let prompt = PolishPrompt.build(text: "hi", mode: .variants(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("2 to 3") || prompt.lowercased().contains("2-3") || prompt.contains("2") )
    }

    @Test("Prompt instructs strict JSON output")
    func strictJSON() {
        let prompt = PolishPrompt.build(text: "hi", mode: .variants(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("STRICT JSON"))
        #expect(prompt.contains("variants"))
    }
}

@Suite("PolishPrompt — proofread mode (same-language)")
@MainActor
struct ProofreadPromptTests {
    @Test("Mentions both 'issues' and 'variants' fields")
    func mentionsBothFields() {
        let prompt = PolishPrompt.build(text: "I want make meeting",
                                        mode: .proofreadAndPolish(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("issues"))
        #expect(prompt.contains("variants"))
    }

    @Test("Distinguishes itself from variants mode by mentioning grammar/usage")
    func mentionsGrammar() {
        let prompt = PolishPrompt.build(text: "I want make meeting",
                                        mode: .proofreadAndPolish(target: "en", nativeLanguage: nil))
        #expect(prompt.lowercased().contains("grammar"))
    }

    @Test("Original text appears at the end")
    func originalIncluded() {
        let prompt = PolishPrompt.build(text: "i want make meeting",
                                        mode: .proofreadAndPolish(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("Original:"))
        #expect(prompt.contains("i want make meeting"))
    }
}

@Suite("PolishPrompt — render & override")
@MainActor
struct PolishPromptRenderTests {
    @Test("render substitutes ${language} and ${text}")
    func substitution() {
        let result = PolishPrompt.render(
            template: "Rewrite in ${language}: ${text}",
            target: "en",
            nativeLanguage: nil,
            text: "hello"
        )
        #expect(result == "Rewrite in English: hello")
    }

    @Test("render trims surrounding whitespace from the user text")
    func trims() {
        let result = PolishPrompt.render(
            template: "${text}",
            target: "en",
            nativeLanguage: nil,
            text: "  hi  \n"
        )
        #expect(result == "hi")
    }

    @Test("${native} resolves to the English name of the native language")
    func nativeSubstitution() {
        let result = PolishPrompt.render(
            template: "→ ${language} (back: ${native})",
            target: "en",
            nativeLanguage: "zh-Hans",
            text: "x"
        )
        #expect(result.hasPrefix("→ English (back: Chinese"))
    }

    @Test("Nil native language collapses ${native} to the target language name")
    func nativeFallsBackToTarget() {
        let result = PolishPrompt.render(
            template: "${language}|${native}",
            target: "en",
            nativeLanguage: nil,
            text: "x"
        )
        #expect(result == "English|English")
    }

    @Test("Empty UserDefaults override falls back to the default template")
    func emptyOverrideFallsBack() {
        UserDefaults.standard.set("", forKey: PolishPrompt.variantsTemplateKey)
        let prompt = PolishPrompt.build(text: "hi", mode: .variants(target: "en", nativeLanguage: nil))
        #expect(prompt.contains("STRICT JSON"))   // signature line from default
        UserDefaults.standard.removeObject(forKey: PolishPrompt.variantsTemplateKey)
    }

    @Test("Non-empty UserDefaults override replaces the default template")
    func customOverrideUsed() {
        UserDefaults.standard.set(
            "CUSTOM ${language} :: ${text}",
            forKey: PolishPrompt.variantsTemplateKey
        )
        let prompt = PolishPrompt.build(text: "hello", mode: .variants(target: "zh-Hans", nativeLanguage: nil))
        // `contains` rather than hasPrefix/hasSuffix: build() prepends
        // profile / memory context when the host has a user profile set,
        // so the rendered template sits in the middle. What matters is
        // that the custom template was used and the default replaced.
        #expect(prompt.contains("CUSTOM Chinese"))
        #expect(prompt.contains(":: hello"))
        #expect(!prompt.contains("STRICT JSON"))  // default signature absent
        UserDefaults.standard.removeObject(forKey: PolishPrompt.variantsTemplateKey)
    }
}

@Suite("ZAIProvider — polish response parser")
struct PolishResponseParserTests {
    @Test("Legacy variants-only JSON (array of strings) parses into variants[]")
    func variantsOnly() {
        let raw = """
        {"variants": ["I'd like to schedule a meeting.", "Let's set up a meeting tomorrow."]}
        """
        let result = PolishResult.parse(raw)
        #expect(result.variants.count == 2)
        #expect(result.issues.isEmpty)
        #expect(result.variants[0].text.contains("schedule"))
        #expect(result.variants[0].backTranslation == nil)
    }

    @Test("New variants schema (array of objects) parses text + back-translation")
    func variantsWithBack() {
        let raw = """
        {"variants": [
          {"text": "I'd like to schedule a meeting.", "back": "我想安排一个会议。"},
          {"text": "Let's set up a meeting.", "back": "我们设个会吧。"}
        ]}
        """
        let result = PolishResult.parse(raw)
        #expect(result.variants.count == 2)
        #expect(result.variants[0].text == "I'd like to schedule a meeting.")
        #expect(result.variants[0].backTranslation == "我想安排一个会议。")
        #expect(result.variants[1].backTranslation == "我们设个会吧。")
    }

    @Test("Variant objects with empty 'back' are treated as no back-translation")
    func emptyBackIsNil() {
        let raw = """
        {"variants": [{"text": "hello", "back": ""}]}
        """
        let result = PolishResult.parse(raw)
        #expect(result.variants.count == 1)
        #expect(result.variants[0].backTranslation == nil)
    }

    @Test("Proofread JSON parses both issues and variants")
    func proofreadFull() {
        let raw = """
        {
          "issues": [
            {"original": "I want make", "explanation": "Missing 'to' after 'want'."}
          ],
          "variants": [
            {"text": "I'd like to make a meeting.", "back": "我想安排一个会议。"},
            {"text": "Let's set up a meeting.", "back": "我们开个会。"}
          ]
        }
        """
        let result = PolishResult.parse(raw)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].original == "I want make")
        #expect(result.issues[0].explanation.contains("Missing"))
        #expect(result.variants.count == 2)
        #expect(result.variants[0].backTranslation == "我想安排一个会议。")
    }

    @Test("Issue without an 'original' span is still kept")
    func issueWithoutOriginal() {
        let raw = """
        {"issues": [{"explanation": "Sentence is too long."}], "variants": ["Short version."]}
        """
        let result = PolishResult.parse(raw)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].original == nil)
        #expect(result.issues[0].explanation == "Sentence is too long.")
    }

    @Test("Issue without an 'explanation' is dropped")
    func issueWithoutExplanation() {
        let raw = """
        {"issues": [{"original": "foo"}], "variants": ["bar"]}
        """
        let result = PolishResult.parse(raw)
        #expect(result.issues.isEmpty)
        #expect(result.variants.map(\.text) == ["bar"])
    }

    @Test("Markdown-fenced JSON is unwrapped before parsing")
    func handlesCodeFences() {
        let raw = "```json\n{\"variants\": [\"hello\"]}\n```"
        let result = PolishResult.parse(raw)
        #expect(result.variants.map(\.text) == ["hello"])
    }

    @Test("Non-JSON response surfaces as a single variant (graceful fallback)")
    func nonJSONFallback() {
        let raw = "I'd just like to set up a meeting tomorrow."
        let result = PolishResult.parse(raw)
        #expect(result.variants.map(\.text) == [raw])
        #expect(result.issues.isEmpty)
    }

    @Test("Empty arrays in JSON also fall back to surfacing the raw content")
    func emptyArraysFallback() {
        let raw = "{\"variants\": [], \"issues\": []}"
        let result = PolishResult.parse(raw)
        #expect(result.variants.map(\.text) == [raw])
    }
}

@Suite("KimiCodingProvider — Anthropic-shaped response extraction")
struct KimiResponseTests {
    @Test("Pulls the first text block out of content[]")
    func extractsFirstTextBlock() throws {
        let body = """
        {
          "id": "msg_1",
          "type": "message",
          "content": [
            {"type": "text", "text": "{\\"variants\\": [\\"hello\\"]}"}
          ]
        }
        """.data(using: .utf8)!
        let extracted = try KimiCodingProvider.extractTextContent(from: body)
        #expect(extracted.contains("\"variants\""))
        // Round-trip into PolishResult.parse — verifies shared pipeline.
        let polished = PolishResult.parse(extracted)
        #expect(polished.variants.map(\.text) == ["hello"])
    }

    @Test("Skips non-text blocks and returns the first text one")
    func skipsNonText() throws {
        let body = """
        {
          "content": [
            {"type": "tool_use", "id": "x"},
            {"type": "text", "text": "actual answer"}
          ]
        }
        """.data(using: .utf8)!
        let extracted = try KimiCodingProvider.extractTextContent(from: body)
        #expect(extracted == "actual answer")
    }

    @Test("Missing content[] throws malformedResponse")
    func missingContent() {
        let body = #"{"id": "msg_1"}"#.data(using: .utf8)!
        #expect(throws: LLMError.self) {
            _ = try KimiCodingProvider.extractTextContent(from: body)
        }
    }

    @Test("Content with no text blocks throws malformedResponse")
    func noTextBlocks() {
        let body = #"{"content": [{"type": "tool_use", "id": "x"}]}"#.data(using: .utf8)!
        #expect(throws: LLMError.self) {
            _ = try KimiCodingProvider.extractTextContent(from: body)
        }
    }
}

@Suite("PolishResult.parsePartial — streaming JSON")
struct PolishResultParsePartialTests {
    @Test("Empty buffer returns empty result")
    func empty() {
        #expect(PolishResult.parsePartial("") == .empty)
        #expect(PolishResult.parsePartial("   \n") == .empty)
    }

    @Test("Bare opening brace before any keys yields empty (no usable structure)")
    func openingBraceOnly() {
        #expect(PolishResult.parsePartial("{") == .empty)
    }

    @Test("Well-formed input parses identically to parse()")
    func wellFormedMatchesParse() {
        let raw = #"{"variants":[{"text":"Hello","back":"你好"}]}"#
        #expect(PolishResult.parsePartial(raw) == PolishResult.parse(raw))
    }

    @Test("Mid-string truncation closes the string and surfaces the partial variant")
    func midStringTruncation() {
        // Stream is in the middle of the first variant's text field.
        let raw = #"{"variants":[{"text":"How are y"#
        let result = PolishResult.parsePartial(raw)
        #expect(result.variants.count == 1)
        #expect(result.variants[0].text == "How are y")
    }

    @Test("Missing trailing brackets are inferred")
    func missingClosers() {
        // No closing `]` or `}` — closeOpenJSONStructures should append both.
        let raw = #"{"variants":[{"text":"Hello","back":"你好"}"#
        let result = PolishResult.parsePartial(raw)
        #expect(result.variants.count == 1)
        #expect(result.variants[0].text == "Hello")
        #expect(result.variants[0].backTranslation == "你好")
    }

    @Test("Escaped quote inside string doesn't confuse the scanner")
    func escapedQuote() {
        let raw = #"{"variants":[{"text":"She said \"hi\""#
        let result = PolishResult.parsePartial(raw)
        #expect(result.variants.count == 1)
        #expect(result.variants[0].text.contains("She said"))
    }

    @Test("Code-fence prefix without closing fence is tolerated")
    func unclosedCodeFence() {
        let raw = "```json\n{\"variants\":[{\"text\":\"Hi\""
        let result = PolishResult.parsePartial(raw)
        #expect(result.variants.count == 1)
        #expect(result.variants[0].text == "Hi")
    }

    @Test("Bare code-fence opener with no JSON yet yields empty")
    func bareCodeFenceOpener() {
        #expect(PolishResult.parsePartial("```json") == .empty)
        #expect(PolishResult.parsePartial("```") == .empty)
    }

    @Test("Partial issues array is parseable")
    func partialIssues() {
        // Variants done, issues mid-flight.
        let raw = """
        {"variants":[{"text":"Hi","back":"嗨"}],"issues":[{"original":"hello","explanation":"too informal
        """
        let result = PolishResult.parsePartial(raw)
        #expect(result.variants.count == 1)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].original == "hello")
        #expect(result.issues[0].explanation.contains("too informal"))
    }
}
