import Foundation

/// Pure prompt builders for the polish flow (Fn → R).
/// Two prompt templates, one per `PolishMode`. The templates are user-editable in
/// Settings — `build` reads `UserDefaults` overrides first and falls back to the
/// built-in defaults below. Placeholders inside the templates:
///   - `${language}` — English name of the target language (e.g. "English", "Chinese")
///   - `${text}`     — the user's original selection, trimmed
enum PolishPrompt {
    static let variantsTemplateKey  = "glotty.polishPrompt.variants"
    static let proofreadTemplateKey = "glotty.polishPrompt.proofread"

    /// Single source of truth for "languages Glotty can polish into". Used by
    /// both the Settings → Polish output language picker and the per-chat
    /// "Reply in" picker on the polish popup, so the two stay in sync.
    /// Order matches the Settings dropdown so users see the same menu.
    static let outputLanguageOptions: [(id: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
    ]

    static let defaultVariantsTemplate = """
    You are a native speaker of ${language}. The user wrote the following text and \
    wants it expressed in idiomatic, native ${language}. Provide 2 to 3 distinct \
    natural ways a fluent speaker would say the same thing. Keep proper nouns intact.

    For each variant, also include a faithful translation into the user's native \
    language (${native}) so they can verify the rewrite matches their intent. \
    If ${native} is the same as ${language}, leave `back` as an empty string.

    Output STRICT JSON only — no markdown fences, no preamble, no trailing prose:

    {"variants": [{"text": "<polished>", "back": "<native-language translation>"}, ...]}

    Original: ${text}
    """

    static let defaultProofreadTemplate = """
    You are a native ${language} editor. The user wrote the following text in \
    ${language}. It may contain grammar mistakes, awkward word choices, or \
    unidiomatic phrasing.

    1. List any grammar or usage issues briefly. Each issue has three fields:
       - `category`: a short type label naming the *kind* of mistake. Pick one of \
    these when possible: "Article usage", "Subject-verb agreement", "Verb tense", \
    "Pluralization", "Preposition", "Word order", "Word choice", "Punctuation", \
    "Spelling", "Capitalization", "Sentence structure", "Pronoun reference", \
    "Register/tone". If none fit, invent a short label of two or three words. \
    Never include the user's literal text in this field.
       - `original`: quote the offending span verbatim.
       - `explanation`: one short sentence explaining the fix.
    2. Provide 1 to 3 natural ${language} rewrites of the whole text.
    3. For each variant, include a faithful translation into the user's native \
    language (${native}) so they can verify the rewrite matches their intent. \
    If ${native} is the same as ${language}, leave `back` as an empty string.

    If the original is already idiomatic and error-free, return an empty `issues` \
    array and a single unchanged variant.

    Output STRICT JSON only — no markdown fences, no preamble, no trailing prose:

    {
      "issues": [{"category": "<type>", "original": "<span>", "explanation": "<short fix>"}],
      "variants": [{"text": "<polished>", "back": "<native-language translation>"}, ...]
    }

    Original: ${text}
    """

    /// English-language name (e.g. `en` → "English", `zh-Hans` → "Chinese"). We keep
    /// the instruction in English regardless of UI locale so the LLM behaves
    /// consistently.
    static func englishName(for languageIdentifier: String) -> String {
        let englishLocale = Locale(identifier: "en_US")
        if let name = englishLocale.localizedString(forIdentifier: languageIdentifier),
           !name.isEmpty {
            return name
        }
        return languageIdentifier
    }

    static func build(text: String, mode: PolishMode) -> String {
        let template: String
        switch mode {
        case .variants:
            template = currentTemplate(forKey: variantsTemplateKey,
                                       default: defaultVariantsTemplate)
        case .proofreadAndPolish:
            template = currentTemplate(forKey: proofreadTemplateKey,
                                       default: defaultProofreadTemplate)
        }
        return render(template: template,
                      target: mode.target,
                      nativeLanguage: mode.nativeLanguage,
                      text: text)
    }

    /// Pure renderer — swap `${language}`, `${native}`, and `${text}` placeholders.
    /// `nativeLanguage` falls back to the target if nil, so back-translation
    /// instructions degrade to a no-op rather than referring to a missing language.
    static func render(template: String,
                       target: String,
                       nativeLanguage: String?,
                       text: String) -> String {
        let lang = englishName(for: target)
        let native = englishName(for: nativeLanguage ?? target)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return template
            .replacingOccurrences(of: "${language}", with: lang)
            .replacingOccurrences(of: "${native}", with: native)
            .replacingOccurrences(of: "${text}", with: trimmed)
    }

    private static func currentTemplate(forKey key: String, default fallback: String) -> String {
        let saved = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : fallback
    }
}
