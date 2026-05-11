import SwiftUI
import Translation

/// Standard macOS preferences pane. Opens via ⌘, or the menu-bar "Settings…" item.
struct SettingsView: View {
    var body: some View {
        TabView {
            TranslationSettingsTab()
                .tabItem { Label("Translation", systemImage: "globe") }
            DictionarySettingsTab()
                .tabItem { Label("Dictionaries", systemImage: "books.vertical") }
            HotkeySettingsTab()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

private struct TranslationSettingsTab: View {
    @AppStorage("glotty.sourceLang") private var sourceLang: String = ""
    @AppStorage("glotty.targetLang") private var targetLang: String = ""
    @State private var availableLanguages: [Locale.Language] = []
    @State private var packStatus: PackStatus = .unknown
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var lastError: String?

    enum PackStatus {
        case unknown
        case installed
        case needsDownload
        case unsupported
        case downloading
    }

    var body: some View {
        Form {
            Section {
                Picker("Default source language", selection: $sourceLang) {
                    Text("Auto detect").tag("")
                    ForEach(availableLanguages, id: \.minimalIdentifier) { lang in
                        let id = lang.minimalIdentifier
                        Text(localizedName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Default target language", selection: $targetLang) {
                    Text("Auto (based on source)").tag("")
                    ForEach(availableLanguages, id: \.minimalIdentifier) { lang in
                        let id = lang.minimalIdentifier
                        Text(localizedName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)

                if !targetLang.isEmpty {
                    statusRow
                }
            } footer: {
                Text("Source can stay on Auto detect — the popup runs language detection on the selected text. Pin it if you only translate from a fixed language. The popup has a per-translation target switcher too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backend") {
                LabeledContent("Translation engine", value: "Apple Translation (on-device)")
                    .foregroundStyle(.secondary)
                Text("Other engines (DeepL, Google, Claude, GPT) coming after the spike validates the core flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadAvailableLanguages() }
        .task(id: "\(sourceLang)|\(targetLang)") { await refreshPackStatus() }
        // `prepareTranslation()` runs inside a translationTask. Setting downloadConfig
        // triggers the OS download flow (system sheet); clearing it on completion lets
        // future taps re-trigger.
        .translationTask(downloadConfig) { session in
            await runDownload(using: session)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch packStatus {
            case .unknown:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Language pack installed").foregroundStyle(.secondary)
            case .needsDownload:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("Pack not installed").foregroundStyle(.secondary)
                Spacer()
                Button("Download") { startDownload() }
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            case .unsupported:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Apple Translation can't translate this pair").foregroundStyle(.secondary)
            }
        }
        .font(.callout)

        if let lastError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func loadAvailableLanguages() async {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        let unique = supported.filter { seen.insert($0.minimalIdentifier).inserted }
        availableLanguages = unique.sorted {
            localizedName(for: $0.minimalIdentifier)
                .localizedCaseInsensitiveCompare(localizedName(for: $1.minimalIdentifier))
                == .orderedAscending
        }
    }

    /// When source is pinned, check exactly that pair. When source is Auto, check
    /// English ↔ target as a representative pair (English is the most common source).
    private func refreshPackStatus() async {
        guard !targetLang.isEmpty else {
            packStatus = .unknown
            return
        }
        packStatus = .unknown
        let avail = LanguageAvailability()
        let target = Locale.Language(identifier: targetLang)
        let effectiveSource = sourceLang.isEmpty ? "en" : sourceLang
        let source = Locale.Language(identifier: effectiveSource)

        let forward = await avail.status(from: source, to: target)
        // Reverse direction is useful too — Apple's framework needs both packs for
        // the language pair to be fully usable. Skip the reverse check when source
        // and target are the same language.
        let reverse: LanguageAvailability.Status
        if effectiveSource == targetLang {
            reverse = forward
        } else {
            reverse = await avail.status(from: target, to: source)
        }

        if forward == .unsupported || reverse == .unsupported {
            packStatus = .unsupported
        } else if forward == .installed && reverse == .installed {
            packStatus = .installed
        } else {
            packStatus = .needsDownload
        }
    }

    private func startDownload() {
        guard !targetLang.isEmpty else { return }
        lastError = nil
        packStatus = .downloading
        let effectiveSource = sourceLang.isEmpty ? "en" : sourceLang
        downloadConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: effectiveSource),
            target: Locale.Language(identifier: targetLang)
        )
    }

    private func runDownload(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            downloadConfig = nil
            await refreshPackStatus()
        } catch {
            downloadConfig = nil
            lastError = error.localizedDescription
            await refreshPackStatus()
        }
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private struct DictionarySettingsTab: View {
    @AppStorage("glotty.selectedDictionaryIDs") private var selectedDictionaryIDsData: Data = Data()
    @State private var availableDictionaries: [DictionaryLookup.DictionaryInfo] = []
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        Form {
            Section {
                if availableDictionaries.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading dictionaries…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(availableDictionaries) { dict in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(dict.id) },
                            set: { isOn in
                                if isOn {
                                    selectedIDs.insert(dict.id)
                                } else {
                                    selectedIDs.remove(dict.id)
                                }
                                saveSelection()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dict.name)
                                    .font(.body)
                                Text(dict.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text("Active dictionaries")
            } footer: {
                Text("Glotty queries only the checked dictionaries when looking up words. If none are selected, all enabled dictionaries are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            availableDictionaries = DictionaryLookup.availableDictionaries()
        }
        .onAppear {
            loadSelection()
        }
    }

    private func loadSelection() {
        if let ids = try? JSONDecoder().decode([String].self, from: selectedDictionaryIDsData) {
            selectedIDs = Set(ids)
        }
    }

    private func saveSelection() {
        if let data = try? JSONEncoder().encode(Array(selectedIDs)) {
            selectedDictionaryIDsData = data
        }
    }
}

private struct HotkeySettingsTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Leader key", value: "Fn")
                LabeledContent("Translate", value: "Fn → T")
            } footer: {
                Text("Hotkey customization will arrive after the spike. For now the leader is fixed to Fn and the translate command is T.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
