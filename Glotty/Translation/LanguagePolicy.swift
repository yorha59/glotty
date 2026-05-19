import Foundation
import NaturalLanguage

/// Pure language-routing decisions extracted from the popup so they can be unit tested.
/// Nothing in here touches Apple's Translation framework or any global state — it's all
/// inputs in, decision out.
enum LanguagePolicy {
    /// Heuristic: a single word for phonetic-display purposes is non-empty trimmed
    /// text, at most 32 chars, that `NLTokenizer` segments into exactly one word.
    /// Whitespace alone isn't a reliable signal because CJK sentences have no
    /// spaces — using the system word tokenizer correctly identifies `翻译` as one
    /// word and `四肢被绳子绑在椅子上` as multiple.
    static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 32 { return false }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var wordCount = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            wordCount += 1
            return wordCount <= 1   // bail as soon as we know there are 2+ words
        }
        return wordCount == 1
    }

    /// Default target when the user has no saved preference. English source → user's
    /// locale (or zh-Hans if the user is already English-locale); anything else → English.
    static func preferredTarget(for source: NLLanguage?, userLocale: Locale = .current) -> String {
        let userLang = userLocale.language.languageCode?.identifier ?? "en"
        if source == .english {
            return userLang == "en" ? "zh-Hans" : userLang
        }
        return "en"
    }

    /// Detect the source language with bias toward English + the user's locale. For
    /// low-confidence ASCII-only input ("water" type ambiguity) we fall back to English.
    static func detectSourceLanguage(_ text: String, userLocale: Locale = .current) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()

        var hints: [NLLanguage: Double] = [.english: 1.0]
        if let userCode = userLocale.language.languageCode?.identifier, userCode != "en" {
            hints[NLLanguage(rawValue: userCode)] = 1.0
        }
        recognizer.languageHints = hints
        recognizer.processString(text)

        guard let candidate = recognizer.dominantLanguage else { return nil }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[candidate] ?? 0
        let isAsciiLatin = text.unicodeScalars.allSatisfy { $0.isASCII }

        if isAsciiLatin && confidence < 0.85 {
            return .english
        }
        return candidate
    }
}
