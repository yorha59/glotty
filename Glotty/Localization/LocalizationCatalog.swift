import Foundation

/// Helper for reading the source-string list out of the bundled
/// `Localizable.xcstrings` catalog. The catalog file IS just JSON;
/// at runtime we want the list of English keys so the LLM filler
/// knows which strings to translate after a language switch.
enum LocalizationCatalog {
    /// All source-language keys defined in the bundled catalog.
    /// Returns empty if the catalog isn't found in the bundle
    /// (e.g. dev build before xcodegen picked it up).
    static func bundledSourceStrings() -> [String] {
        guard let strings = bundledStringsJSON() else { return [] }
        return Array(strings.keys)
    }

    /// Source strings the bundled catalog ALREADY has a translation
    /// for in the given target language. The LLM filler skips
    /// these — pre-shipped translations are higher-quality than
    /// LLM ones and don't need re-generation. When Glotty ships
    /// with hand-translated Chinese, Japanese, etc. for the top N
    /// strings, the user gets them instantly without LLM cost.
    static func translatedInBundle(language: String) -> Set<String> {
        guard let strings = bundledStringsJSON() else { return [] }
        var done: Set<String> = []
        for (source, entry) in strings {
            guard let dict = entry as? [String: Any],
                  let localizations = dict["localizations"] as? [String: Any],
                  let langEntry = localizations[language] as? [String: Any],
                  let stringUnit = langEntry["stringUnit"] as? [String: Any],
                  let state = stringUnit["state"] as? String,
                  state == "translated",
                  let value = stringUnit["value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            done.insert(source)
        }
        return done
    }

    private static func bundledStringsJSON() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            return nil
        }
        return strings
    }
}
