import Foundation

/// Batched LLM translator. Takes a list of English UI source
/// strings, sends them to the configured LLM with context about
/// what Glotty is and how the strings are used, and persists the
/// resulting translations into `LocalizationCache`.
///
/// Context matters: "Polish" alone is ambiguous (country vs. verb).
/// The prompt explicitly grounds the LLM in Glotty's product
/// description so translations land naturally for a translation /
/// language-learning desktop app — not literal word-for-word.
@MainActor
enum LocalizationFiller {

    /// Cap per LLM request. Keeps prompt size reasonable and gives
    /// the model a tractable chunk. Hundreds of strings are split
    /// across multiple batches.
    static let batchSize = 40

    /// Distributed-notification name the agent can post from bash
    /// to trigger a full refresh of UI translations without needing
    /// the user to click the Settings → System button. Mirror of
    /// the snapshotter's remote trigger.
    static let refreshNotificationName = Notification.Name("com.ruojunye.glotty.refreshTranslations")

    /// One-time install — call from AppDelegate.
    nonisolated static func installRemoteTriggerObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: refreshNotificationName,
            object: nil,
            queue: .main,
            using: { _ in
                Task { @MainActor in
                    await refreshFromRemoteTrigger()
                }
            }
        )
    }

    /// Same path as the System → Refresh button: union of catalog +
    /// encountered strings, force-retranslate, post the cache-
    /// update notification so live views re-render.
    @MainActor
    private static func refreshFromRemoteTrigger() async {
        guard let lang = SystemLanguageManager.current.bundleLocaleID,
              lang != "en", !lang.hasPrefix("en-") else {
            dbg("refresh SKIP — language is English / system")
            return
        }
        let bundled = LocalizationCatalog.bundledSourceStrings()
        let encountered = Array(LocalizationCache.shared.encounteredSources)
        var seen = Set<String>()
        let sources = (bundled + encountered).filter { seen.insert($0).inserted }
        dbg("refresh ENTER — \(sources.count) sources for \(lang)")
        let result = await fill(
            sources: sources,
            targetLanguage: lang,
            forceRetranslate: true
        )
        dbg("refresh DONE — translated=\(result.translated), failed=\(result.failed)")
        NotificationCenter.default.post(name: LocalizationCache.didUpdateNotification, object: nil)
    }

    /// Result reported back to UI: how many strings we asked the
    /// LLM about, and how many came back with valid translations.
    struct Result {
        let requested: Int
        let translated: Int
        let failed: Int
    }

    /// Translate `sources` to `targetLanguage`, caching results.
    ///
    /// By default skips:
    ///   - strings already in the LLM cache (already translated)
    ///   - strings hand-translated in the bundled `.xcstrings` —
    ///     shipped translations are higher quality and free
    ///
    /// Pass `forceRetranslate: true` from the "Refresh translations"
    /// button to bypass both checks. Useful when the user wants to
    /// regenerate everything against current memory context.
    @discardableResult
    static func fill(
        sources: [String],
        targetLanguage: String,
        forceRetranslate: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> Result {
        let cache = LocalizationCache.shared
        let cached = cache.translatedSources(for: targetLanguage)
        let shippedInBundle = LocalizationCatalog.translatedInBundle(language: targetLanguage)
        // Dedup + skip already-handled unless we're force-refreshing.
        // Preserve order so the user sees a sensible progress
        // sequence in the UI.
        var seen = Set<String>()
        let needed = sources.filter { source in
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(source).inserted else { return false }
            if forceRetranslate { return true }
            return !cached.contains(source) && !shippedInBundle.contains(source)
        }
        dbg("fill ENTER — needed=\(needed.count) lang=\(targetLanguage) force=\(forceRetranslate)")
        guard !needed.isEmpty else {
            dbg("fill SKIP — nothing needed")
            return Result(requested: 0, translated: 0, failed: 0)
        }
        guard let provider = LLMRegistry.current() else {
            dbg("fill SKIP — no LLM provider configured")
            return Result(requested: needed.count, translated: 0, failed: needed.count)
        }
        dbg("fill CALL — provider=\(provider.id), \(needed.count) strings in \((needed.count + batchSize - 1) / batchSize) batches")

        var translated = 0
        var failed = 0
        let total = needed.count
        var done = 0

        for batch in needed.chunks(of: batchSize) {
            let prompt = buildPrompt(strings: batch, targetLanguage: targetLanguage)
            var raw = ""
            do {
                try await UsageContext.$mode.withValue(.chat) {
                    for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                        raw = chunk
                    }
                }
            } catch {
                dbg("fill BATCH FAIL — \(error.localizedDescription)")
                failed += batch.count
                done += batch.count
                progress?(done, total)
                continue
            }
            dbg("fill BATCH OK — raw=\(raw.count) chars")
            // `parse` returns index → translation. Map indices back
            // to source strings via the batch order so the cache is
            // keyed by the English source the swizzle will look up.
            let indexed = parse(raw)
            var useful: [String: String] = [:]
            for (idxStr, value) in indexed {
                guard let idx = Int(idxStr), idx >= 0, idx < batch.count else { continue }
                let source = batch[idx]
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                useful[source] = trimmed
            }
            cache.merge(useful, language: targetLanguage)
            translated += useful.count
            failed += batch.count - useful.count
            done += batch.count
            dbg("fill BATCH PARSED — got \(useful.count)/\(batch.count) translations")
            progress?(done, total)
        }
        dbg("fill DONE — translated=\(translated), failed=\(failed)")
        return Result(requested: needed.count, translated: translated, failed: failed)
    }

    private static func dbg(_ message: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.localization, message, file: file, line: line)
    }

    // MARK: - Prompt

    private static func buildPrompt(strings: [String], targetLanguage: String) -> String {
        let langName = PolishPrompt.englishName(for: targetLanguage)
        // Number the strings so the LLM's JSON keys are unambiguous —
        // it returns by index, then we map back to source strings.
        // Keeps quoting / escaping out of the JSON layer.
        let listed = strings.enumerated()
            .map { idx, s in "\(idx). \(s.replacingOccurrences(of: "\n", with: "\\n"))" }
            .joined(separator: "\n")

        // User-controlled steering. We pull memories scoped to the
        // *target* language — those are the ones expressing wording
        // preferences a Chinese-speaking user has voiced about their
        // Chinese UI (e.g. "I prefer 「润色」 over 「打磨」"). Memories
        // scoped to the English source — typically glossary entries
        // like "Polish means the feature, not the country" — are
        // statements ABOUT English usage; injecting them here biased
        // the LLM toward preserving the English term verbatim instead
        // of translating it, which was the whole bug the user
        // reported. Language-nil memories (cross-language defaults
        // like "user prefers concise UI") still apply.
        //
        // Source text "" because translation requests don't have one;
        // the glossary haystack scan is a no-op and only the
        // always-on preference/fact/project lines feed through.
        let userSteering = MainActor.assumeIsolated {
            LearnedMemoryStore.shared.contextBlock(for: "", targetLanguage: targetLanguage)
        }
        let steeringBlock = userSteering.isEmpty
            ? ""
            : """

            Translation steering from the user's saved memories — apply where relevant to word choice and register:
            \(userSteering)
            """

        return """
        You are localizing the UI of Glotty, a macOS translation and language-learning desktop app. The app helps users translate selections from any app, polish their writing, look up dictionary entries, chat with a friendly AI tutor in their target language, and review the memories the AI has saved about them.

        Translate each of these English UI strings into \(langName). They are short labels: section headers, button captions, picker options, footer hints, menu items. Apply these rules:

        Translation rules:
        - Translate by intent and convention, not word-by-word. Use the natural \(langName) phrasing a native designer would write for the same kind of UI element.
        - The action verbs "Polish", "Explain", "Chat", and "Translate" are Glotty's four core features. ALWAYS translate these to native \(langName) action words. NEVER preserve them in English in your output, even when they appear as labels, in lists alongside one another, or in section headers like "2.2 Polish". For Chinese specifically: Polish → 润色, Explain → 解释, Chat → 聊天, Translate → 翻译. ("Polish" is the verb meaning "to refine writing", NOT the country/language Poland.)
        - "Memory" / "Memories" mean facts the AI has saved about the user (preferences, projects, glossary).
        - "Context" / "Contexts" mean named memory scopes (a user's "Work" context vs. "Travel" context).
        - "Source" means the language the user is translating FROM.
        - "Target" means the language they are translating INTO.
        - Preserve capitalization style and trailing punctuation as much as makes sense — if a button is "Done", the translation is also a single bare word.
        - Keep ellipsis "…" if present (means a dialog will open).
        - For strings with `%@` / `\\(...)` placeholders, KEEP THEM IN PLACE in the translation so runtime interpolation still works.
        - Brand names like "Glotty", "macOS", "GitHub", "OpenAI", "Anthropic" stay in English.
        \(steeringBlock)

        Strings to translate:
        \(listed)

        Output STRICT JSON only — no markdown fences, no preamble:

        {"translations": {"0": "<\(langName) for string 0>", "1": "<\(langName) for string 1>", ...}}
        """
    }

    /// Lenient JSON parser. Strips code fences if the model added
    /// them; tolerates missing keys (those just don't get cached).
    /// Returns a mapping `english_source → translation`.
    private static func parse(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first < last else { return [:] }
        let body = String(trimmed[first...last])
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = dict["translations"] as? [String: Any] else {
            return [:]
        }
        // We sent strings as a numbered list — but we don't have the
        // original list here. The caller passes `batch` and intersects
        // by source string keys instead, so we return mapping from
        // INDEX (as a stringified Int) to translation. Caller maps
        // back via the batch order.
        // Returning `[String: String]` keyed by source: the caller
        // (`fill`) passes batch, so let's just convert indices →
        // source strings via the batch closure — but `parse` doesn't
        // know the batch. To keep parse pure, we keep its return as
        // `[index_string: translation]`. The caller then maps.
        var result: [String: String] = [:]
        for (key, value) in translations {
            if let s = value as? String { result[key] = s }
        }
        return result
    }
}

private extension Array {
    /// Split into fixed-size chunks. Last chunk may be smaller.
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}
