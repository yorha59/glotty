import Foundation

/// Generates the mistake-category starter list for a polish target
/// language. Makes ONE LLM call per language asking the model for
/// ~10 common mistake categories appropriate to that language,
/// parses the JSON array, persists to disk so subsequent polishes
/// in the same language reuse it without another LLM call.
///
/// Same mechanism for every language, English included — there's no
/// hand-curated fallback. Pre-warm fires from the Settings → Polish
/// output picker on selection change; a lazy bootstrap in
/// `PopupView.runPolish` covers users who haven't been to Settings.
///
/// Cache file:
///   `~/Library/Application Support/Glotty/polish-categories.json`
///   shape: `[ lang: [String] ]`
@MainActor
enum PolishCategoryBootstrap {
    /// In-memory mirror of the cache file. Loaded once on first
    /// access, written back whenever a new language gets bootstrapped.
    private static var cache: [String: [String]] = loadCache()

    /// Synchronous lookup. Returns nil if this language hasn't been
    /// bootstrapped yet — caller should kick off `bootstrap(for:)`
    /// to populate it.
    static func cached(for language: String) -> [String]? {
        if let hit = cache[language], !hit.isEmpty { return hit }
        return nil
    }

    /// One-shot LLM call to generate a starter list for `language`.
    /// Persists to disk on success. Returns nil on LLM failure or
    /// unparseable response — caller should treat that as "no
    /// suggestions, let the LLM invent freely this time and try
    /// again later."
    static func bootstrap(for language: String) async -> [String]? {
        if let hit = cached(for: language) { return hit }
        guard let provider = LLMRegistry.current() else { return nil }
        let langName = PolishPrompt.englishName(for: language)
        let prompt = """
        I'm building a writing-assistant feature that tags grammar / usage / style mistakes in \(langName) drafts with short category labels (e.g. for English: "Article usage", "Verb tense", "Word choice").

        List 10 to 12 mistake categories that learners and intermediate users of \(langName) commonly need flagged. Pick categories that are SPECIFIC to \(langName) — things that wouldn't apply or wouldn't matter in another language. Don't include categories that don't apply to \(langName) (e.g. don't list "Article usage" for a language without articles).

        Output STRICT JSON only — no markdown fences, no preamble:

        {"categories": ["<short label in \(langName)>", "<another short label in \(langName)>", ...]}

        Each label should be:
        - 2 to 4 words
        - In \(langName), written the way the category would be displayed in a settings UI in \(langName)
        - Unambiguous — a learner reading it should know what kind of mistake it covers
        """

        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.chat) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return nil
        }

        let parsed = parse(raw)
        guard !parsed.isEmpty else { return nil }
        cache[language] = parsed
        persistCache()
        return parsed
    }

    /// Force a refresh — drops the cached list for `language` and
    /// re-runs the LLM call. Exposed for a possible future "redo
    /// categories" affordance; not currently wired to UI.
    static func refresh(for language: String) async -> [String]? {
        cache[language] = nil
        persistCache()
        return await bootstrap(for: language)
    }

    // MARK: - Parsing + IO

    private static func parse(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first < last else { return [] }
        let body = String(trimmed[first...last])
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = dict["categories"] as? [String] else {
            return []
        }
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("polish-categories.json")
    }()

    private static func loadCache() -> [String: [String]] {
        guard let data = try? Data(contentsOf: cacheURL),
              let parsed = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return parsed
    }

    private static func persistCache() {
        let snapshot = cache
        let url = cacheURL
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
