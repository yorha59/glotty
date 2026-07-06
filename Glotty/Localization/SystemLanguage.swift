import AppKit
import Foundation

/// Glotty UI language. Drives every localized `Text(_:)`,
/// `String(localized:)`, and `LocalizedStringKey` in the app via
/// the bundled `Localizable.xcstrings` catalog. Stored in
/// UserDefaults as the chat / settings preference; on launch
/// `applyAtLaunch()` writes the choice into `AppleLanguages` so
/// Foundation's localization machinery picks it up before any UI
/// renders.
enum SystemLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Use whatever macOS reports for the user's preferred system
    /// language. Glotty falls through to the standard Bundle
    /// resolution — if there's a matching `.xcstrings` localization
    /// it's used; otherwise we get English (the source language).
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case es
    case fr
    case de

    var id: String { rawValue }

    /// User-facing label for the picker. Shown in the language
    /// itself (endonym), which is the convention for language
    /// pickers and makes the option immediately legible to a
    /// speaker of that language regardless of current UI locale.
    var displayName: String {
        switch self {
        case .system: return String(localized: "Use system default")
        case .en:     return "English"
        case .zhHans: return "中文（简体）"
        case .zhHant: return "中文（繁體）"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .es:     return "Español"
        case .fr:     return "Français"
        case .de:     return "Deutsch"
        }
    }

    /// The bundle-locale identifier to write into `AppleLanguages`
    /// when this language is chosen. `nil` for `.system` — that
    /// case removes the override and falls back to the OS choice.
    var bundleLocaleID: String? {
        switch self {
        case .system: return nil
        default:      return rawValue
        }
    }
}

/// Helpers for reading/writing the user's UI-language preference
/// and applying it to the running app. Apple's localization
/// resolution reads `AppleLanguages` at launch, so toggling the
/// picker mid-session can't fully take effect until restart.
@MainActor
enum SystemLanguageManager {
    /// UserDefaults key holding the user's pick (raw value).
    static let defaultsKey = "glotty.systemLanguage"

    /// Apple's per-process locale-override key. Foundation reads
    /// this on launch to determine which `.lproj` / `.xcstrings`
    /// localization to use. Setting `nil` removes the override.
    static let appleLanguagesKey = "AppleLanguages"

    static var current: SystemLanguage {
        // 1. Explicit pick — Settings → Profile → System language.
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let lang = SystemLanguage(rawValue: raw) {
            return lang
        }
        // 2. Implicit default — follow `native_language` (onboarding
        //    Q3 / Profile → Native language). The two are conceptually
        //    aligned: the language you speak natively is almost always
        //    the language you want Glotty's UI in. Only kicks in when
        //    the user hasn't touched the System language picker yet,
        //    so an explicit pick is never overridden.
        if let native = UserDefaults.standard.string(forKey: "glotty.user.nativeLanguage")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !native.isEmpty,
           let lang = SystemLanguage(rawValue: native) {
            return lang
        }
        // 3. Fall through to the OS preference.
        return .system
    }

    /// Persist the user's choice and rewrite `AppleLanguages` so
    /// later launches pick it up. Most strings won't re-localize
    /// until restart — UIKit/AppKit/SwiftUI cache the resolved
    /// bundle on first read.
    static func set(_ language: SystemLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        writeAppleLanguages(for: language)
    }

    /// Called from `AppDelegate.applicationDidFinishLaunching` so
    /// the override is in `UserDefaults` before any view renders.
    /// Without this, the very first launch after a picker change
    /// uses the old language.
    static func applyAtLaunch() {
        writeAppleLanguages(for: current)
    }

    /// UserDefaults flag the next launch consults to decide whether
    /// to reopen the chat popup on its own. Set by
    /// `relaunch(reopenChatOnLaunch:)` and consumed (then cleared)
    /// by `AppDelegate.applicationDidFinishLaunching`.
    static let reopenChatOnLaunchKey = "glotty.relaunch.reopenChat"

    /// Relaunch Glotty in-place — used after a language change so
    /// the new locale takes effect on the very next render (most
    /// SwiftUI / AppKit strings are resolved once and cached).
    /// Spawns a detached `/usr/bin/open` on this bundle so the OS
    /// re-launches after we exit, then calls `NSApp.terminate`.
    /// When `reopenChatOnLaunch` is true, persists a flag the next
    /// launch reads to re-open the chat popup automatically so the
    /// in-flight conversation isn't lost behind the restart.
    static func relaunch(reopenChatOnLaunch: Bool = false) {
        if reopenChatOnLaunch {
            UserDefaults.standard.set(true, forKey: reopenChatOnLaunchKey)
            // Force a synchronous write before we terminate so the
            // next launch is guaranteed to see the flag.
            UserDefaults.standard.synchronize()
        }
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func writeAppleLanguages(for language: SystemLanguage) {
        if let locale = language.bundleLocaleID {
            UserDefaults.standard.set([locale], forKey: appleLanguagesKey)
        } else if let osMatch = osMatchedAppLocalization() {
            // `.system` (follow the OS). Removing the key let Foundation
            // fall back to the development region (en) on a fresh
            // install even on a non-English Mac — so SwiftUI Text /
            // navigationTitle (which read Bundle.main directly) showed
            // English. Pin the concrete OS-matched localization so
            // Bundle.main resolves it. Takes effect next launch (the
            // app relaunches on an explicit pick; the implicit .system
            // case is written here at applyAtLaunch for subsequent
            // launches).
            UserDefaults.standard.set([osMatch], forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
    }

    /// Best match between the OS's GLOBAL preferred languages and the
    /// localizations the app actually ships. e.g. a zh-Hans Mac with
    /// a zh-Hans.lproj → "zh-Hans"; an en Mac → "en" (which the
    /// caller treats as "no override needed"). nil only if matching
    /// fails entirely.
    private static func osMatchedAppLocalization() -> String? {
        let global = (CFPreferencesCopyAppValue("AppleLanguages" as CFString,
                                                kCFPreferencesAnyApplication) as? [String])
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                             forPreferences: global).first
    }
}
