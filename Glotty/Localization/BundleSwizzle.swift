import Foundation
import ObjectiveC

/// Hooks `Bundle.localizedString(forKey:value:table:)` so every
/// SwiftUI `Text("…")`, `Button("…")`, etc. consults `LocalizationCache`
/// first. Cache hit → return the LLM-produced translation. Miss →
/// fall through to Foundation's normal lookup (which reads the
/// bundled `Localizable.xcstrings`). That two-layer system means
/// catalog strings get translated at build time AND any string the
/// user adds in dev or that we missed gets translated at runtime
/// via `LocalizationFiller`, with results persisted forever.
///
/// Method swizzling is a well-trodden pattern for runtime
/// localization on Apple platforms (frame­works like Localize-Swift
/// and BartyCrouch do the same). Risky-looking but safe in this
/// narrow use — we intercept ONE method and always either return
/// our cache value or call straight through to the original.
enum BundleSwizzle {
    /// Idempotent. Safe to call multiple times — second and later
    /// calls no-op.
    static func installOnce() {
        struct Once { static var done = false }
        guard !Once.done else { return }
        Once.done = true

        let cls: AnyClass = Bundle.self
        let originalSelector = #selector(Bundle.localizedString(forKey:value:table:))
        let swizzledSelector = #selector(Bundle.glotty_localizedString(forKey:value:table:))
        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    /// The localization `.t` lookups resolve against. Prefers the
    /// app-specific `AppleLanguages` override (set by the System-
    /// language picker, which relaunches). When that's absent — the
    /// "follow the OS" default on a fresh install — Foundation's own
    /// resolution falls back to the development region (en) even on a
    /// zh-Hans Mac, which is why a fresh install showed English in
    /// the Settings tabs while the Welcome page (which forces the OS
    /// language) was Chinese. We match the OS's GLOBAL preferred
    /// languages against the bundle's shipped localizations ourselves.
    /// Computed once — a language change relaunches the app, so this
    /// is constant for the process lifetime.
    static let effectiveLanguage: String? = {
        if let arr = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let first = arr.first {
            return first
        }
        let global = (CFPreferencesCopyAppValue("AppleLanguages" as CFString,
                                                kCFPreferencesAnyApplication) as? [String])
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                             forPreferences: global).first
    }()

    /// `.lproj` bundle to read catalog values from on a cache miss.
    /// Resolving against this matched bundle (not `Bundle.main`) is
    /// what makes a fresh install show the shipped translation:
    /// `Bundle.main` may have booted in en, but the matched lproj has
    /// the real value. nil when the effective language is the source
    /// (en) or the app ships no matching lproj.
    static let effectiveLprojBundle: Bundle? = {
        guard let lang = effectiveLanguage,
              lang != "en", !lang.hasPrefix("en-") else { return nil }
        let avail = Bundle.main.localizations
        let match = avail.contains(lang)
            ? lang
            : Bundle.preferredLocalizations(from: avail, forPreferences: [lang]).first
        guard let m = match,
              let p = Bundle.main.path(forResource: m, ofType: "lproj"),
              let b = Bundle(path: p) else { return nil }
        return b
    }()
}

extension Bundle {
    /// Replacement implementation — after `method_exchangeImplementations`,
    /// CALLING `self.glotty_localizedString(...)` actually runs the
    /// original Foundation implementation, so the fallback is just
    /// `self.glotty_localizedString(forKey:value:table:)`.
    @objc dynamic func glotty_localizedString(forKey key: String,
                                              value: String?,
                                              table: String?) -> String {
        // Skip the cache for the source language — every lookup
        // would otherwise pointlessly miss. The cache is also keyed
        // by source string, which IS the English text, so returning
        // the key directly is correct.
        // App-override language, else the OS-matched shipped
        // localization (see BundleSwizzle.effectiveLanguage). Process-
        // constant, so safe to read from any thread this hook fires on.
        let lang: String? = BundleSwizzle.effectiveLanguage
        // Always record the source string so the filler can cover
        // strings not in the bundled catalog (dynamic Text(...) sites
        // we missed). Cheap — Set.insert is O(1).
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                LocalizationCache.shared.recordEncountered(key)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LocalizationCache.shared.recordEncountered(key)
                }
            }
        }

        guard let lang, lang != "en", !lang.hasPrefix("en-") else {
            return self.glotty_localizedString(forKey: key, value: value, table: table)
        }
        // Cache lookup is main-actor isolated; this hook may not be
        // on main. Use a synchronous DispatchQueue.main.sync only if
        // we're not already on main, to avoid deadlock.
        let cached: String? = {
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    LocalizationCache.shared.translation(for: key, language: lang)
                }
            } else {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        LocalizationCache.shared.translation(for: key, language: lang)
                    }
                }
            }
        }()
        if let cached { return cached }
        // Cache miss. Resolve through Foundation first — that hits
        // the bundled `.xcstrings` catalog and returns either the
        // hand-translated value (good) or the English source (no
        // translation shipped). Only queue an LLM translation if
        // Foundation gave us back the source unchanged, meaning the
        // catalog has no translation for this key. Without this
        // check, the LLM would re-translate strings the catalog
        // already covers — and its result (cached forever) would
        // then OVERRIDE the better catalog value.
        // Resolve against the OS-matched lproj bundle, not `self`
        // (Bundle.main) — on a fresh install Bundle.main may have
        // booted in en, so its lookup would return the source string
        // even though the shipped catalog has the translation.
        let resolved = (BundleSwizzle.effectiveLprojBundle ?? self)
            .glotty_localizedString(forKey: key, value: value, table: table)
        if resolved != key {
            return resolved
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                LocalizationCache.shared.queueMissingForTranslation(key, language: lang)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LocalizationCache.shared.queueMissingForTranslation(key, language: lang)
                }
            }
        }
        return resolved
    }
}
