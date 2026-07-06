import AppKit
import SwiftUI

/// Settings → System → "Debug" + "Translations" sections. Houses
/// developer affordances and the user-facing "Refresh
/// translations" button that re-runs the LLM filler against the
/// catalog with the user's current memories steering wording.
struct SystemDebugSection: View {
    @State private var refreshProgress: (done: Int, total: Int)?
    @State private var refreshResult: String?
    @State private var exportResult: String?

    var body: some View {
        Group {
            translationsSection
            diagnosticsSection
            // `debugSection` (the "Capture all settings tabs" button)
            // is intentionally not rendered. End users never need
            // it. The dev / agent still triggers captures via the
            // `SettingsSnapshotter` distributed notification — see
            // `SettingsSnapshotter.captureNotificationName` and the
            // observer installed in `AppDelegate`.
        }
    }

    /// "Export logs" lives here so users can grab Glotty's debug
    /// file when filing a report. Dumps /tmp/glotty-debug.log (plus
    /// the rotated .1 segment, in chronological order) to the
    /// Desktop and reveals the result in Finder.
    private var diagnosticsSection: some View {
        Section {
            Button {
                if let url = Log.exportToDesktop() {
                    exportResult = String(format: "Exported to %@".t, url.path)
                } else {
                    exportResult = "Couldn't export logs (no log file yet, or Desktop unavailable).".t
                }
            } label: {
                Label {
                    Text("Export logs".t)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .controlSize(.large)

            if let msg = exportResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Diagnostics".t)
        } footer: {
            Text("Saves Glotty's debug log to your Desktop and reveals it in Finder. Attach it when reporting an issue.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var translationsSection: some View {
        let canRefresh = refreshProgress == nil
            && SystemLanguageManager.current.bundleLocaleID != nil
            && SystemLanguageManager.current.bundleLocaleID != "en"
        return Section {
            HStack(spacing: 8) {
                Button {
                    Task { await refreshTranslations(memoryAffectedOnly: false) }
                } label: {
                    // Use the closure-based Label form with explicit
                    // `.t` so the title goes through our swizzle on
                    // macOS 26 — the convenience `Label("...", ...)`
                    // initializer uses LocalizedStringResource and
                    // bypasses Bundle.localizedString.
                    Label {
                        Text("Refresh all".t)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .controlSize(.large)
                .disabled(!canRefresh)

                // Cheaper second pass: re-translate ONLY strings whose
                // source mentions a term from accepted memory. Useful
                // right after you accept or edit a glossary entry —
                // you get the new wording everywhere it applies
                // without paying for the whole catalog again.
                Button {
                    Task { await refreshTranslations(memoryAffectedOnly: true) }
                } label: {
                    Label {
                        Text("Memory-affected only".t)
                    } icon: {
                        Image(systemName: "brain")
                    }
                }
                .controlSize(.large)
                .disabled(!canRefresh || memoryTerms().isEmpty)
            }

            if let p = refreshProgress {
                progressRow(p)
            }
            if let msg = refreshResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Localization".t)
        } footer: {
            Text("Re-translates the UI in the current language via the LLM, applying any wording preferences from your accepted memories. The partial refresh only touches strings that mention a term from your memories — cheaper after a single glossary change.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressRow(_ p: (done: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: "Translating UI… %d / %d".t, p.done, p.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
        }
    }

    @MainActor
    private func refreshTranslations(memoryAffectedOnly: Bool) async {
        guard let lang = SystemLanguageManager.current.bundleLocaleID,
              lang != "en", !lang.hasPrefix("en-") else { return }
        refreshResult = nil
        // Union of bundled catalog + previously-encountered runtime
        // strings — same set the language-switch flow uses.
        let bundled = LocalizationCatalog.bundledSourceStrings()
        let encountered = Array(LocalizationCache.shared.encounteredSources)
        var seen = Set<String>()
        var sources = (bundled + encountered).filter { seen.insert($0).inserted }

        if memoryAffectedOnly {
            let terms = memoryTerms()
            guard !terms.isEmpty else {
                refreshResult = "No memory terms to filter by.".t
                return
            }
            // Case-insensitive substring match. Source strings are
            // English UI labels; glossary terms are typically short
            // English nouns ("Polish", "Explain"). A simple
            // contains-check is enough — the LLM filter the prompt
            // already does the heavy lifting.
            let lowered = terms.map { $0.lowercased() }
            sources = sources.filter { source in
                let s = source.lowercased()
                return lowered.contains(where: { s.contains($0) })
            }
            guard !sources.isEmpty else {
                refreshResult = "No UI strings mention your memory terms.".t
                return
            }
        }

        guard !sources.isEmpty else {
            refreshResult = "Nothing to translate.".t
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

    /// Terms from accepted memories worth filtering UI sources by.
    /// Right now: glossary `term` field only — those are the entries
    /// that name a specific word the user has wording preferences
    /// about. Preference/fact/project memories steer tone globally;
    /// they don't map to a specific substring in the UI.
    private func memoryTerms() -> [String] {
        LearnedMemoryStore.shared.accepted().compactMap { memory in
            guard memory.kind == .glossary,
                  let term = memory.term?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !term.isEmpty else { return nil }
            return term
        }
    }
}
