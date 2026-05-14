import Foundation

/// Pure prompt builder for the polish flow (Fn → R).
/// Given a piece of source text and a target language code (e.g. `en`, `zh-Hans`),
/// produces the user-facing prompt sent to the LLM. Same prompt across providers.
enum PolishPrompt {
    /// English-language language name resolver — used because we want the prompt
    /// itself in English (most LLMs follow English instructions most reliably),
    /// regardless of the user's UI locale.
    static func englishName(for languageIdentifier: String) -> String {
        let englishLocale = Locale(identifier: "en_US")
        if let name = englishLocale.localizedString(forIdentifier: languageIdentifier),
           !name.isEmpty {
            return name
        }
        return languageIdentifier
    }

    static func build(text: String, targetLanguage: String) -> String {
        let langName = englishName(for: targetLanguage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Rewrite the following text in idiomatic, native \(langName).
        Output the rewrite ONLY — no explanations, no quotes, no preamble.
        Keep proper nouns intact. If the original is already idiomatic \(langName), \
        return it unchanged.

        Original: \(trimmed)
        """
    }
}
