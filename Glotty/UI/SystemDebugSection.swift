import AppKit
import SwiftUI

/// Settings → System → "Debug" + "Translations" sections. Houses
/// developer affordances and the user-facing "Refresh
/// translations" button that re-runs the LLM filler against the
/// catalog with the user's current memories steering wording.
struct SystemDebugSection: View {
    @State private var refreshProgress: (done: Int, total: Int)?
    @State private var refreshResult: String?

    var body: some View {
        Group {
            translationsSection
            // `debugSection` (the "Capture all settings tabs" button)
            // is intentionally not rendered. End users never need
            // it. The dev / agent still triggers captures via the
            // `SettingsSnapshotter` distributed notification — see
            // `SettingsSnapshotter.captureNotificationName` and the
            // observer installed in `AppDelegate`.
        }
    }

    private var translationsSection: some View {
        Section {
            Button {
                Task { await refreshTranslations() }
            } label: {
                Label("Refresh translations", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .disabled(refreshProgress != nil
                      || SystemLanguageManager.current.bundleLocaleID == nil
                      || SystemLanguageManager.current.bundleLocaleID == "en")

            if let p = refreshProgress {
                progressRow(p)
            }
            if let msg = refreshResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Translations")
        } footer: {
            Text("Re-translates the UI in the current language via the LLM, applying any wording preferences from your accepted memories.")
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
    private func refreshTranslations() async {
        guard let lang = SystemLanguageManager.current.bundleLocaleID,
              lang != "en", !lang.hasPrefix("en-") else { return }
        refreshResult = nil
        // Union of bundled catalog + previously-encountered runtime
        // strings — same set the language-switch flow uses.
        let bundled = LocalizationCatalog.bundledSourceStrings()
        let encountered = Array(LocalizationCache.shared.encounteredSources)
        var seen = Set<String>()
        let sources = (bundled + encountered).filter { seen.insert($0).inserted }
        guard !sources.isEmpty else {
            refreshResult = String(localized: "Nothing to translate.")
            return
        }
        refreshProgress = (done: 0, total: sources.count)
        let result = await LocalizationFiller.fill(
            sources: sources,
            targetLanguage: lang,
            forceRetranslate: true,
            progress: { done, total in
                Task { @MainActor in refreshProgress = (done: done, total: total) }
            }
        )
        refreshProgress = nil
        refreshResult = "Refreshed: \(result.translated) translated, \(result.failed) failed."
        // Notify all views so they re-render with the new cache.
        NotificationCenter.default.post(name: LocalizationCache.didUpdateNotification, object: nil)
    }
}
