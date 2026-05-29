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
        let lang: String? = {
            // Read directly from UserDefaults rather than going
            // through `@MainActor SystemLanguageManager`, since this
            // hook can fire from background threads inside SwiftUI.
            if let arr = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
               let first = arr.first {
                return first
            }
            return nil
        }()
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
        let resolved = self.glotty_localizedString(forKey: key, value: value, table: table)
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
