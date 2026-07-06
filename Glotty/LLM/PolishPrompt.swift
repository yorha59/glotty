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

    /// Languages Glotty can polish into. Thin wrapper around the
    /// app-wide `LanguageOptions.all` list so prompt code doesn't
    /// import the SwiftUI layer; the tuple shape is kept for
    /// backwards compatibility with existing call sites.
    static let outputLanguageOptions: [(id: String, name: String)] = LanguageOptions
        .all
        .map { (id: $0.id, name: $0.englishName) }

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
       - `category`: a short type label naming the *kind* of mistake. Pick one \
    from the suggested categories below when possible — using the exact wording \
    so the aggregator can count related mistakes together. Only invent a NEW \
    short label (2-4 words in ${language}) if NONE of the suggestions fit.
    ${categories}
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

    static func build(text: String,
                      mode: PolishMode,
                      categories overrideCategories: [String]? = nil) -> String {
        let template: String
        switch mode {
        case .variants:
            template = currentTemplate(forKey: variantsTemplateKey,
                                       default: defaultVariantsTemplate)
        case .proofreadAndPolish:
            template = currentTemplate(forKey: proofreadTemplateKey,
                                       default: defaultProofreadTemplate)
        }
        // Resolve the category list. Override wins (mostly for tests
        // or where the caller already pre-computed). Otherwise:
        //   1. Categories the LLM has already used for this language
        //      (consistency — prevents drift across polish runs).
        //   2. Bootstrapped cache for the target language (one-shot
        //      LLM call, persisted forever — see PolishCategoryBootstrap).
        //   The bootstrap module is async-only; this builder is sync,
        //   so we only consult the SYNC `cached()` lookup here. A
        //   background bootstrap call should be kicked off either at
        //   language-change time in Settings (pre-warm) or lazily by
        //   `runPolish` in PopupView when the cache misses.
        let categories: [String]
        if let overrideCategories {
            categories = overrideCategories
        } else {
            categories = MainActor.assumeIsolated {
                resolvedCategories(for: mode.target)
            }
        }
        let body = render(template: template,
                          target: mode.target,
                          nativeLanguage: mode.nativeLanguage,
                          text: text,
                          categories: categories)
        return prependedWithUserContext(body, sourceText: text)
    }

    /// Synchronous category resolution — see `build` for the priority
    /// order. Public so the caller can `await` a bootstrap first when
    /// the cache misses.
    @MainActor
    static func resolvedCategories(for language: String) -> [String] {
        let seen = MemoryStore.shared.knownCategories(for: language)
        let suggested = PolishCategoryBootstrap.cached(for: language) ?? []
        // Seen-first preserves the model's prior choices. Bootstrap
        // entries are appended for cases the LLM hasn't explored yet.
        // Dedup case-insensitively so capitalization drift doesn't
        // bloat the list.
        var merged: [String] = []
        var seenLower: Set<String> = []
        for label in Array(seen).sorted() + suggested {
            let key = label.lowercased()
            if seenLower.insert(key).inserted {
                merged.append(label)
            }
        }
        // Cap at 20 to keep the prompt size sane.
        return Array(merged.prefix(20))
    }

    /// Prepend the learned-memory context block (notes + relevant
    /// glossary + profile facts) to a prompt body. Returns the body
    /// unchanged when there's no context to inject. Centralized here
    /// rather than in each call site so explain/polish/chat all
    /// share the same injection format.
    static func prependedWithUserContext(_ body: String,
                                         sourceText: String,
                                         purpose: MemoryInjectionPurpose = .general) -> String {
        // Hop to the main actor to read the store. Awaiting from a
        // potentially-non-main caller is the wrong shape (prompt
        // builders are sync), so use MainActor.assumeIsolated — the
        // store is touched on main from every call site we have.
        let context = MainActor.assumeIsolated {
            LearnedMemoryStore.shared.contextBlock(for: sourceText, purpose: purpose)
        }
        guard !context.isEmpty else { return body }
        return context + "\n\n" + body
    }

    /// Pure renderer — swap `${language}`, `${native}`, `${categories}`,
    /// and `${text}` placeholders. `nativeLanguage` falls back to the
    /// target if nil, so back-translation instructions degrade to a
    /// no-op rather than referring to a missing language. `categories`
    /// is rendered as a bulleted list inline; when empty, the
    /// `${categories}` placeholder is replaced with an instruction
    /// to invent labels freely (no suggested list available).
    static func render(template: String,
                       target: String,
                       nativeLanguage: String?,
                       text: String,
                       categories: [String] = []) -> String {
        let lang = englishName(for: target)
        let native = englishName(for: nativeLanguage ?? target)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoriesBlock: String
        if categories.isEmpty {
            categoriesBlock = "    (No suggested categories provided — invent short labels in \(lang) as needed.)"
        } else {
            let bullets = categories
                .map { "      - \"\($0)\"" }
                .joined(separator: "\n")
            categoriesBlock = "    Suggested categories (in \(lang) — prefer reusing these):\n\(bullets)"
        }
        return template
            .replacingOccurrences(of: "${language}", with: lang)
            .replacingOccurrences(of: "${native}", with: native)
            .replacingOccurrences(of: "${categories}", with: categoriesBlock)
            .replacingOccurrences(of: "${text}", with: trimmed)
    }

    private static func currentTemplate(forKey key: String, default fallback: String) -> String {
        let saved = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : fallback
    }
}
