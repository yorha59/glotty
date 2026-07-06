import Foundation

/// Prompt builder for Fn → E (Explain). Same direction as Translate (output in
/// the user's native language), but asks the LLM for a richer explanation —
/// meaning, context, usage — rather than a one-line gloss. Plain prose
/// response, no JSON, so it streams nicely as token-by-token text.
enum ExplainPrompt {
    static let templateKey = "glotty.explainPrompt"

    static let defaultTemplate = """
    Explain the following selection in ${language}. Structure your answer as \
    exactly four titled sections. Each section has a short title on its own \
    line, prefixed with `## `, followed by a body paragraph.

    Format:
    ## <title in ${language}>
    <body paragraph in ${language}>

    Use these four sections (translate the title into ${language}):
    1. **Direct meaning** — what the selection literally says or denotes. For a \
    single word, give the definition and part of speech; for a phrase or \
    sentence, paraphrase it.
    2. **Implication** — what it connotes, when and why someone would use it, \
    the tone or register, any cultural / historical context worth knowing.
    3. **Real-world example** — one brief scenario or sentence that shows the \
    term in use. Keep the example in the source language; add a short \
    ${language} gloss after it if the language differs.
    4. **Other contexts** — how the meaning, tone, or usage shifts across \
    different contexts (formal vs casual, literary vs everyday, professional vs \
    social, regional variants). Give two or three short contrasting situations. \
    If the selection has essentially one meaning, give two or three different \
    *kinds* of speakers or settings where it would be used and how the framing \
    changes.

    Separate the four sections with a blank line. Body paragraphs are one to \
    three sentences, plain prose. No preamble like "Sure, here is...", no \
    other markdown beyond the `## ` title prefix, no bullet points inside the \
    body.

    Selection:
    ${text}
    """

    /// Resolve the active template — user override (Settings) wins; falls back
    /// to the built-in default.
    static func currentTemplate() -> String {
        let saved = UserDefaults.standard.string(forKey: templateKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : defaultTemplate
    }

    /// Render the template with `${language}` and `${text}` substituted.
    /// `language` is given to the LLM in English (e.g. "Chinese (Simplified)")
    /// so the instruction is locale-independent — the actual response is still
    /// expected in that language.
    static func build(text: String, targetLanguage: String) -> String {
        let lang = PolishPrompt.englishName(for: targetLanguage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = currentTemplate()
            .replacingOccurrences(of: "${language}", with: lang)
            .replacingOccurrences(of: "${text}", with: trimmed)
        // Same memory injection used by polish — see
        // PolishPrompt.prependedWithUserContext for the why.
        return PolishPrompt.prependedWithUserContext(body, sourceText: trimmed)
    }
}
