import AppKit

/// Single-word spell correction backed by the system `NSSpellChecker` — the same
/// engine the OS spell-check menu uses. Entirely local and instant (no LLM), so
/// it's a good fit for the Fn → R "correct the word I selected" command.
enum SpellCorrection {
    enum Result {
        /// Selection was empty or contained more than one word.
        case notAWord
        /// The word is already spelled correctly. `alternatives` are
        /// completion candidates (longer/related words that start with it) the
        /// user can still swap to — empty when the checker has none.
        case correct(alternatives: [String])
        /// The word is misspelled; `guesses` are the suggested corrections
        /// (possibly empty if the checker had no ideas).
        case corrections([String])
    }

    /// Cap on how many candidates we surface — completions for a short word can
    /// run into the dozens; a tidy short list is more useful than a wall.
    private static let maxCandidates = 8

    /// Check a selected fragment. Only single words are considered — anything
    /// with internal whitespace returns `.notAWord` (the feature is explicitly
    /// word-scoped).
    @MainActor
    static func check(_ text: String) -> Result {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return .notAWord
        }

        let checker = NSSpellChecker.shared
        // Check against ONE language — the one the user writes in — not the
        // multilingual auto-detector. With auto-detection a short word is
        // accepted if it's valid in *any* enabled language (e.g. "parten" is a
        // real German word), so genuine English typos read as "correct". A
        // single fixed language gives intuitive, predictable results.
        checker.automaticallyIdentifiesLanguages = false
        let language = resolveLanguage(for: checker)

        let nsWord = word as NSString
        let wholeRange = NSRange(location: 0, length: nsWord.length)
        let misspelledRange = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil)

        if misspelledRange.location == NSNotFound {
            // Already correct — offer autocomplete-style alternatives so the
            // user can still swap to a longer/related word if they meant one.
            let completions = checker.completions(
                forPartialWordRange: wholeRange,
                in: word,
                language: language,
                inSpellDocumentWithTag: 0
            ) ?? []
            return .correct(alternatives: dedupe(completions, excluding: word))
        }

        let guesses = checker.guesses(
            forWordRange: wholeRange,
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
        return .corrections(dedupe(guesses, excluding: word))
    }

    /// The language to spell-check against. Prefers the user's Polish output
    /// language (the language they're actively writing/improving in), then the
    /// system language, then English — each validated against the dictionaries
    /// the spell checker actually has installed. Returns `nil` only if none
    /// match, letting the checker fall back to its own current language.
    private static func resolveLanguage(for checker: NSSpellChecker) -> String? {
        let available = checker.availableLanguages
        let preferred = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let systemCode = Locale.current.language.languageCode?.identifier
        let candidates = [preferred, systemCode, "en"].compactMap { $0 }.filter { !$0.isEmpty }

        for candidate in candidates {
            // Exact match first ("en" → "en"), then root-prefix
            // ("en" → "en_GB", "fr" → "fr_FR", "zh-Hans" → "zh_…").
            if let hit = available.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return hit
            }
            let root = candidate.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? candidate
            if let hit = available.first(where: { $0.lowercased().hasPrefix(root.lowercased()) }) {
                return hit
            }
        }
        return nil
    }

    /// Drop entries equal to the input word (some checkers echo it) and cap the
    /// list length.
    private static func dedupe(_ words: [String], excluding word: String) -> [String] {
        Array(
            words
                .filter { $0.caseInsensitiveCompare(word) != .orderedSame }
                .prefix(maxCandidates)
        )
    }

    /// LLM fallback for the cases `NSSpellChecker` can't handle — a word too
    /// mangled for its dictionary edit-distance to reach (e.g. "simotanious" →
    /// "simultaneous"). Only used when the local checker returns no guesses, so
    /// the fast path stays LLM-free. Returns up to a few candidate corrections
    /// (single word each), or `[]` if there's no provider / nothing usable.
    @MainActor
    static func llmGuesses(for word: String) async -> [String] {
        guard let provider = LLMRegistry.current() else { return [] }
        let prompt = """
            The single word below is misspelled. Reply with ONLY the corrected \
            spelling — just the word, or up to 3 likely corrections separated by \
            commas. No explanation, no quotes, no punctuation other than the commas.

            Word: \(word)
            """
        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.polish) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return []
        }
        // Parse comma/newline-separated single-word candidates; drop anything
        // multi-word, empty, or identical to the input.
        let parts = raw.split(whereSeparator: { ",;\n".contains($0) })
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }
            .filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        return dedupe(cleaned, excluding: word)
    }
}
