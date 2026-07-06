import Foundation

/// Single source of truth for language pickers across the app.
/// Every language dropdown (Profile → Native, Translation defaults,
/// Polish output, popup chat "Reply in", popup footer target swap)
/// pulls its options and display names from here so they stay in
/// sync and translate naturally with the UI language.
///
/// Labels are produced by `Locale.current.localizedString(forIdentifier:)`
/// — Foundation already knows every language name in every locale, so
/// when the user runs Glotty in Chinese they see "英语 / 中文（简体）"
/// without any LLM-cache round-trip. The hand-written English name
/// on each option is only used as a fallback for the rare identifier
/// Foundation doesn't recognize.
enum LanguageOptions {
    /// One row in the master list. `id` is a BCP-47 identifier
    /// persisted in UserDefaults and used in LLM prompts; `englishName`
    /// is the literal English name shipped with the app, used as a
    /// safety fallback only.
    struct Option: Identifiable, Hashable {
        let id: String
        let englishName: String
    }

    /// Master list — every language picker in the app draws from this
    /// list, so the dropdown the user sees is identical everywhere
    /// (Profile Native, Translation source / target, Polish output,
    /// popup chat "Reply in", popup footer target swap). Ordering
    /// matches the historical Profile picker so existing users see
    /// the same shape.
    ///
    /// Translation pickers used to be filtered to the Apple Translation
    /// framework's `availableLanguages` set — that meant the dropdown
    /// shrank as packs were uninstalled. We let users pick anything
    /// here instead; the pack-status row in Settings → Translation
    /// surfaces the download prompt when a pinned target lacks a pack.
    static let all: [Option] = [
        Option(id: "en",      englishName: "English"),
        Option(id: "zh-Hans", englishName: "Chinese (Simplified)"),
        Option(id: "zh-Hant", englishName: "Chinese (Traditional)"),
        Option(id: "ja",      englishName: "Japanese"),
        Option(id: "ko",      englishName: "Korean"),
        Option(id: "fr",      englishName: "French"),
        Option(id: "de",      englishName: "German"),
        Option(id: "es",      englishName: "Spanish"),
        Option(id: "it",      englishName: "Italian"),
        Option(id: "pt",      englishName: "Portuguese"),
        Option(id: "ru",      englishName: "Russian"),
        Option(id: "ar",      englishName: "Arabic"),
        Option(id: "hi",      englishName: "Hindi"),
        Option(id: "vi",      englishName: "Vietnamese"),
        Option(id: "th",      englishName: "Thai"),
    ]

    /// User-facing label for `identifier`, localized into whatever
    /// language the app's UI is currently running in. Returns the
    /// hand-written English name if Foundation has no localized name
    /// for the identifier (e.g. a region tag we haven't seen).
    ///
    /// English locale gives us `"Chinese, Simplified"`; we reshape it
    /// to `"Chinese (Simplified)"` to match the Figma style. Non-English
    /// locales (Chinese, Japanese, …) already use their own
    /// punctuation and don't contain `", "`, so the reshape is a
    /// no-op for them.
    /// The system language, mapped to the closest id in `all` — the
    /// guaranteed-supported fallback when a language setting is unset.
    /// Chinese needs script/region disambiguation (the master list has
    /// `zh-Hans` / `zh-Hant`, not a bare `zh`); anything we don't carry
    /// falls back to English.
    static func systemDefault() -> String {
        let language = Locale.current.language
        let base = language.languageCode?.identifier ?? "en"
        if base == "zh" {
            if language.script?.identifier == "Hant" { return "zh-Hant" }
            if let region = language.region?.identifier,
               ["TW", "HK", "MO"].contains(region) { return "zh-Hant" }
            return "zh-Hans"
        }
        return all.contains(where: { $0.id == base }) ? base : "en"
    }

    static func localizedName(for identifier: String) -> String {
        let raw: String
        if let name = Locale.current.localizedString(forIdentifier: identifier),
           !name.isEmpty {
            raw = name
        } else if let option = all.first(where: { $0.id == identifier }) {
            raw = option.englishName
        } else {
            raw = identifier
        }
        if let commaRange = raw.range(of: ", ") {
            return "\(raw[..<commaRange.lowerBound]) (\(raw[commaRange.upperBound...]))"
        }
        return raw
    }
}
