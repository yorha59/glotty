import SwiftUI

/// Settings → Profile → "Language" section. Picker for Glotty's
/// UI language. Writes the choice into `AppleLanguages` so
/// Foundation's localization machinery (and therefore the bundled
/// `Localizable.xcstrings` catalog) uses it on the next launch.
///
/// Switching relaunches Glotty so the new locale takes effect — most
/// SwiftUI/AppKit strings resolve their bundle once and cache it, so
/// mid-session re-localization isn't feasible.
struct SystemLanguageSection: View {
    @AppStorage(SystemLanguageManager.defaultsKey)
    private var rawLanguage: String = SystemLanguage.system.rawValue

    var body: some View {
        Section {
            Picker("System language", selection: Binding<SystemLanguage>(
                // Reading via `.current` (not `rawLanguage` directly)
                // surfaces the implicit native-language fallback in
                // the picker UI — otherwise the user sees "Use system
                // default" even when behavior follows their saved
                // `native_language`. See SystemLanguageManager.
                get: { SystemLanguageManager.current },
                set: { switchLanguage(to: $0) }
            )) {
                ForEach(SystemLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        } header: {
            Text("Glotty's UI language".t)
        } footer: {
            Text("Glotty restarts to apply the new language.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func switchLanguage(to newValue: SystemLanguage) {
        rawLanguage = newValue.rawValue
        SystemLanguageManager.set(newValue)
        // Relaunch immediately. The bundled .xcstrings catalog ships
        // translations for every supported UI language, so the new
        // locale takes full effect on the next launch with ZERO LLM
        // work.
        //
        // This used to `await LocalizationFiller.fill(...)` over every
        // string the app had ever rendered (500+), almost all already
        // covered by the catalog — a multi-minute, flaky LLM batch that
        // blocked the relaunch and made the switch look stuck ("can't
        // switch to Chinese"). Dynamic strings the catalog doesn't cover
        // are filled on demand via Settings → System → Refresh
        // translations, which is the right place for explicit LLM work.
        SystemLanguageManager.relaunch()
    }
}
