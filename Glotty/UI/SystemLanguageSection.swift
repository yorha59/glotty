import SwiftUI

/// Settings → Profile → "Language" section. Picker for Glotty's
/// UI language. Writes the choice into `AppleLanguages` so
/// Foundation's localization machinery (and therefore the bundled
/// `Localizable.xcstrings` catalog) uses it on the next launch.
///
/// Mid-session re-localization isn't really feasible in SwiftUI on
/// macOS — many strings are resolved once and cached — so the
/// section shows a small "restart required" hint after a change.
struct SystemLanguageSection: View {
    @AppStorage(SystemLanguageManager.defaultsKey)
    private var rawLanguage: String = SystemLanguage.system.rawValue
    /// Progress state while the LLM batch-translates the catalog.
    /// Drives the inline indicator below the picker.
    @State private var fillProgress: (done: Int, total: Int)?
    @State private var fillError: String?

    var body: some View {
        Section {
            Picker("System language", selection: Binding<SystemLanguage>(
                // Reading via `.current` (not `rawLanguage` directly)
                // surfaces the implicit native-language fallback in
                // the picker UI — otherwise the user sees "Use system
                // default" even when behavior actually follows their
                // saved `native_language`. See SystemLanguageManager.
                get: { SystemLanguageManager.current },
                set: { newValue in
                    Task { await switchLanguage(to: newValue) }
                }
            )) {
                ForEach(SystemLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .disabled(fillProgress != nil)

            if let progress = fillProgress {
                progressRow(progress)
            }
            if let err = fillError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Glotty's UI language")
        } footer: {
            Text("Glotty's UI language. Switching translates any missing strings and relaunches the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressRow(_ p: (done: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Translating UI… \(p.done) / \(p.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
        }
    }

    @MainActor
    private func switchLanguage(to newValue: SystemLanguage) async {
        fillError = nil
        rawLanguage = newValue.rawValue
        SystemLanguageManager.set(newValue)
        // Source language? No translation work to do — relaunch.
        guard let target = newValue.bundleLocaleID, target != "en", !target.hasPrefix("en-") else {
            SystemLanguageManager.relaunch()
            return
        }
        // Pre-fill cache. Union of:
        //   - source strings declared in the bundled .xcstrings
        //   - source strings the running app has actually requested
        //     this session and in prior sessions (recorded by the
        //     Bundle swizzle into LocalizationCache.encounteredSources)
        // The encountered set is what makes "all displayed text"
        // achievable — anything the user has ever rendered in
        // English will be translated and ready after relaunch.
        let bundled = LocalizationCatalog.bundledSourceStrings()
        let encountered = Array(LocalizationCache.shared.encounteredSources)
        var seen = Set<String>()
        let sources = (bundled + encountered).filter { seen.insert($0).inserted }
        guard !sources.isEmpty else {
            // No catalog? Just relaunch and let the swizzle fall
            // through to whatever Foundation knows.
            SystemLanguageManager.relaunch()
            return
        }
        fillProgress = (done: 0, total: sources.count)
        let result = await LocalizationFiller.fill(
            sources: sources,
            targetLanguage: target,
            progress: { done, total in
                Task { @MainActor in fillProgress = (done: done, total: total) }
            }
        )
        fillProgress = nil
        if result.translated == 0 && result.requested > 0 {
            fillError = "Couldn't translate any strings (LLM unavailable?). Relaunching anyway."
        }
        SystemLanguageManager.relaunch()
    }
}
