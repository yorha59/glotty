import SwiftUI
import Translation
import UniformTypeIdentifiers
import AppKit

/// Standard macOS preferences pane. Opens via ⌘, or the menu-bar "Settings…" item.
/// Split into four tabs — each groups together everything related to one feature
/// area (Translation, Dictionaries, Polish, Hotkey).
struct SettingsView: View {
    var body: some View {
        TabView {
            userProfileTab
                .tabItem { Text("Profile") }
            translationTab
                .tabItem { Text("Translation") }
            dictionariesTab
                .tabItem { Text("Dictionaries") }
            languageModelTab
                .tabItem { Text("Language Model") }
            polishTab
                .tabItem { Text("Polish") }
            hotkeyTab
                .tabItem { Text("Hotkey") }
        }
        // Forms with TextEditors and long lists have unbounded intrinsic size, which
        // crashes the auto-layout pass under `.preferredContentSize`. Use a sensible
        // minimum and let the window owner pick the initial size + remain resizable.
        .frame(minWidth: 560, minHeight: 460)
    }

    private var userProfileTab: some View {
        Form { UserProfileSection() }
            .formStyle(.grouped)
    }

    private var translationTab: some View {
        Form { TranslationSettingsSection() }
            .formStyle(.grouped)
    }

    private var dictionariesTab: some View {
        Form { DictionarySettingsSection() }
            .formStyle(.grouped)
    }

    /// LLM-engine config: which provider, API key, endpoint, model.
    private var languageModelTab: some View {
        Form { LanguageModelSettingsSection() }
            .formStyle(.grouped)
    }

    /// Polish behavior: output language + prompt templates. Uses whatever engine is
    /// selected in the Language Model tab.
    private var polishTab: some View {
        Form {
            PolishOutputLanguageSection()
            PolishPromptsSection()
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form { HotkeySettingsSection() }
            .formStyle(.grouped)
    }
}

private struct LanguageModelSettingsSection: View {
    @AppStorage("glotty.llmProvider") private var providerID: String = "zai"
    @AppStorage("glotty.zai.endpoint") private var zaiEndpoint: String = ""
    @AppStorage("glotty.zai.model") private var zaiModel: String = ""
    @AppStorage("glotty.kimi.endpoint") private var kimiEndpoint: String = ""
    @AppStorage("glotty.kimi.model") private var kimiModel: String = ""
    @State private var apiKey: String = ""
    @State private var apiKeyPlaceholder: String = ""
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        Section {
            Picker("Provider", selection: $providerID) {
                ForEach(LLMRegistry.all, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: providerID) { _, _ in loadKey() }

            switch providerID {
            case "zai":           zaiFields
            case "kimi-coding":   kimiFields
            default:              EmptyView()
            }
        } header: {
            Text("Language Model")
        } footer: {
            Text("The engine that powers Fn → R polish. API keys are stored in macOS Keychain. Polish output language and prompt templates live in the Polish tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadKey() }
    }

    @ViewBuilder
    private var zaiFields: some View {
        HStack {
            SecureField("API key", text: $apiKey, prompt: Text(apiKeyPlaceholder.isEmpty ? "Paste your Z.AI API key" : apiKeyPlaceholder))
            Button("Save") { saveKey() }
                .disabled(apiKey.isEmpty)
            if !apiKeyPlaceholder.isEmpty {
                Button("Clear", role: .destructive) { clearKey() }
            }
        }

        TextField("Endpoint",
                  text: $zaiEndpoint,
                  prompt: Text(ZAIProvider.defaultEndpoint))
            .textContentType(.URL)

        Picker("Model", selection: zaiModelBinding) {
            ForEach(ZAIProvider.supportedModels) { option in
                Text(option.displayName).tag(option.id)
            }
        }
        .pickerStyle(.menu)

        if let summary = ZAIProvider.model(for: zaiModelBinding.wrappedValue)?.summary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        testRow
    }

    /// Picker binding that treats empty AppStorage as "use the default model".
    /// When the user picks one, we always write the concrete id (no empty state).
    private var zaiModelBinding: Binding<String> {
        Binding(
            get: { zaiModel.isEmpty ? ZAIProvider.defaultModel : zaiModel },
            set: { zaiModel = $0 }
        )
    }

    private var kimiModelBinding: Binding<String> {
        Binding(
            get: { kimiModel.isEmpty ? KimiCodingProvider.defaultModel : kimiModel },
            set: { kimiModel = $0 }
        )
    }

    @ViewBuilder
    private var kimiFields: some View {
        HStack {
            SecureField("API key", text: $apiKey, prompt: Text(apiKeyPlaceholder.isEmpty ? "Paste your Kimi API key" : apiKeyPlaceholder))
            Button("Save") { saveKey() }
                .disabled(apiKey.isEmpty)
            if !apiKeyPlaceholder.isEmpty {
                Button("Clear", role: .destructive) { clearKey() }
            }
        }

        TextField("Endpoint",
                  text: $kimiEndpoint,
                  prompt: Text(KimiCodingProvider.defaultEndpoint))
            .textContentType(.URL)

        Picker("Model", selection: kimiModelBinding) {
            ForEach(KimiCodingProvider.supportedModels) { option in
                Text(option.displayName).tag(option.id)
            }
        }
        .pickerStyle(.menu)

        if let summary = KimiCodingProvider.model(for: kimiModelBinding.wrappedValue)?.summary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        testRow
    }

    /// Test button + status — shared across providers; uses whichever is currently
    /// selected via `LLMRegistry.current()`.
    @ViewBuilder
    private var testRow: some View {
        HStack {
            Button("Test connection") { Task { await test() } }
                .disabled(testStatus == .running)
            switch testStatus {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .ok(let result):
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    /// Which Keychain account holds the active provider's key. Returns nil for
    /// providers that don't need a key (Apple Foundation, when we add it).
    private var currentKeychainAccount: String? {
        switch providerID {
        case "zai":         return ZAIProvider.keychainAccount
        case "kimi-coding": return KimiCodingProvider.keychainAccount
        default:            return nil
        }
    }

    private func loadKey() {
        guard let account = currentKeychainAccount else {
            apiKey = ""
            apiKeyPlaceholder = ""
            return
        }
        apiKey = ""
        if let existing = Keychain.read(account: account), !existing.isEmpty {
            apiKeyPlaceholder = "Saved (\(existing.prefix(4))…\(existing.suffix(4)))"
        } else {
            apiKeyPlaceholder = ""
        }
        testStatus = .idle
    }

    private func saveKey() {
        guard let account = currentKeychainAccount else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Keychain.write(trimmed, account: account) {
            apiKey = ""
            apiKeyPlaceholder = "Saved (\(trimmed.prefix(4))…\(trimmed.suffix(4)))"
            testStatus = .idle
        } else {
            testStatus = .failed("Failed to write to Keychain.")
        }
    }

    private func clearKey() {
        guard let account = currentKeychainAccount else { return }
        Keychain.delete(account: account)
        apiKey = ""
        apiKeyPlaceholder = ""
        testStatus = .idle
    }

    private func test() async {
        testStatus = .running
        guard let provider = LLMRegistry.current() else {
            testStatus = .failed("No provider selected.")
            return
        }
        do {
            let result = try await provider.polish("hello world",
                                                   mode: .variants(target: "en", nativeLanguage: nil))
            let preview = result.variants.first?.text ?? "(no variants)"
            testStatus = .ok("OK · \(preview.prefix(40))\(preview.count > 40 ? "…" : "")")
        } catch {
            testStatus = .failed(error.localizedDescription)
        }
    }
}

private struct UserProfileSection: View {
    @AppStorage("glotty.user.nativeLanguage") private var nativeLang: String = ""

    /// Common native-language choices. Stored as a Locale identifier so other
    /// features can read it as a `Locale.Language` later.
    private let options: [(id: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
    ]

    /// Picker binding: empty stored value means "use the system locale". The default
    /// shown in the picker becomes the user's macOS locale on first launch.
    private var selection: Binding<String> {
        Binding(
            get: { nativeLang.isEmpty ? systemLocaleCode() : nativeLang },
            set: { nativeLang = $0 }
        )
    }

    var body: some View {
        Section {
            Picker("Native language", selection: selection) {
                ForEach(options, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Profile")
        } footer: {
            Text("Your native language. Used to guide auto-detected source / target choices and to bias translation behavior toward what you're likely reading or writing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func systemLocaleCode() -> String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}

private struct TranslationSettingsSection: View {
    @AppStorage("glotty.sourceLang") private var sourceLang: String = ""
    @AppStorage("glotty.targetLang") private var targetLang: String = ""
    @State private var availableLanguages: [Locale.Language] = []
    @State private var packStatus: PackStatus = .unknown
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var lastError: String?
    @State private var aiStatus: AppleIntelligenceStatus = .unknown("checking…")

    enum PackStatus {
        case unknown
        case installed
        case needsDownload
        case unsupported
        case downloading
    }

    var body: some View {
        Group {
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

                if !targetLang.isEmpty, shouldShowPackStatus {
                    statusRow
                }
            } header: {
                Text("Translation")
            } footer: {
                Text("Source can stay on Auto detect. Pin it if you only translate from a fixed language.")
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

            Section("Apple Intelligence") {
                appleIntelligenceStatusRow
            }
        }
        .task { await loadAvailableLanguages() }
        .task(id: "\(sourceLang)|\(targetLang)") {
            await refreshPackStatus()
        }
        .translationTask(downloadConfig) { session in
            await runDownload(using: session)
        }
        .onAppear { aiStatus = AppleIntelligenceStatus.current() }
    }

    @ViewBuilder
    private var appleIntelligenceStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: aiStatus == .available
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(aiStatus == .available ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(aiStatus.displayName)
                if let fix = aiStatus.fixInstructions {
                    Text(fix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Recheck") { aiStatus = AppleIntelligenceStatus.current() }
                .controlSize(.small)
        }
    }

    private var shouldShowPackStatus: Bool {
        switch packStatus {
        case .needsDownload, .downloading, .unsupported:
            return true
        case .unknown, .installed:
            return lastError != nil
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
        guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }

        let reverse: LanguageAvailability.Status
        if effectiveSource == targetLang {
            reverse = forward
        } else {
            reverse = await avail.status(from: target, to: source)
        }
        guard !Task.isCancelled else { return }

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
            guard !Task.isCancelled else { return }
            downloadConfig = nil
            await refreshPackStatus()
        } catch {
            guard !Task.isCancelled else { return }
            downloadConfig = nil
            lastError = error.localizedDescription
            await refreshPackStatus()
        }
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private struct DictionarySettingsSection: View {
    @AppStorage("glotty.sourceLang") private var sourceLang: String = ""
    @AppStorage("glotty.targetLang") private var targetLang: String = ""
    @State private var availableDictionaries: [DictionaryLookup.DictionaryInfo] = []
    @State private var availableLibraryDictionaries: [DictionaryLibraryItem] = []
    @State private var selectedDictionaryIDs: [String] = []
    @State private var orderedDictionaryIDs: [String] = []
    @State private var draggedDictionaryID: String?
    @State private var installDictionarySearchText: String = ""
    @State private var selectedLibraryDictionaryIDs: Set<String> = []
    @State private var showingInstallDictionaryDialog = false
    @State private var dictionaryImportStatus: String?
    @State private var downloadedDictionaryPathsByName: [String: String] = [:]
    @State private var isCatalogLoading = false
    @State private var isDownloadedPathLoading = false
    private let maxDictionaryListHeight: CGFloat = 180

    private var effectivePair: (source: String, target: String) {
        DictionarySelection.effectiveLanguages(
            sourcePreference: sourceLang,
            targetPreference: targetLang
        )
    }

    private var bilingualDictionaryTitle: String {
        "\(localizedName(for: effectivePair.source))-\(localizedName(for: effectivePair.target)) dictionaries"
    }

    private var visibleDictionaries: [DictionaryLookup.DictionaryInfo] {
        let matching = DictionarySelection.matchingDictionaries(
            source: effectivePair.source,
            target: effectivePair.target,
            dictionaries: availableDictionaries
        )
        guard !orderedDictionaryIDs.isEmpty else { return matching }

        let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
        var ordered = orderedDictionaryIDs.compactMap { byID[$0] }
        let orderedSet = Set(orderedDictionaryIDs)
        ordered.append(contentsOf: matching.filter { !orderedSet.contains($0.id) })
        return ordered
    }

    private var bilingualDictionaries: [DictionaryLookup.DictionaryInfo] {
        visibleDictionaries.filter { DictionarySelection.dictionaryKind(for: $0) == .bilingual }
    }

    private var monolingualDictionaries: [DictionaryLookup.DictionaryInfo] {
        visibleDictionaries.filter { DictionarySelection.dictionaryKind(for: $0) == .monolingual }
    }

    private var sourceMonolingualDictionaries: [DictionaryLookup.DictionaryInfo] {
        monolingualDictionaries.filter {
            monolingualDictionary($0, matches: effectivePair.source)
        }
    }

    private var targetMonolingualDictionaries: [DictionaryLookup.DictionaryInfo] {
        let sourceIDs = Set(sourceMonolingualDictionaries.map(\.id))
        return monolingualDictionaries.filter {
            !sourceIDs.contains($0.id)
                && monolingualDictionary($0, matches: effectivePair.target)
        }
    }

    private var uncategorizedMonolingualDictionaries: [DictionaryLookup.DictionaryInfo] {
        let categorizedIDs = Set((sourceMonolingualDictionaries + targetMonolingualDictionaries).map(\.id))
        return monolingualDictionaries.filter { !categorizedIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            Section {
                HStack {
                    Button {
                        loadDictionaries()
                        loadLibraryDictionaries()
                        installDictionarySearchText = ""
                        selectedLibraryDictionaryIDs = []
                        showingInstallDictionaryDialog = true
                    } label: {
                        Label("Install Dictionary", systemImage: "plus")
                    }

                    Spacer()

                    if let dictionaryImportStatus {
                        Text(dictionaryImportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dictionary library")
            }

            Section {
                if availableDictionaries.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading dictionaries…")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleDictionaries.isEmpty {
                    Text("No installed dictionaries match the default language pair.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Used for \(localizedName(for: effectivePair.source)) → \(localizedName(for: effectivePair.target))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use all") {
                            resetSelection()
                        }
                        .font(.caption)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            dictionaryArea(title: bilingualDictionaryTitle, dictionaries: bilingualDictionaries)
                            dictionaryArea(title: "\(localizedName(for: effectivePair.source)) dictionaries", dictionaries: sourceMonolingualDictionaries)
                            dictionaryArea(title: "\(localizedName(for: effectivePair.target)) dictionaries", dictionaries: targetMonolingualDictionaries)
                            dictionaryArea(title: "Other dictionaries", dictionaries: uncategorizedMonolingualDictionaries)
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: maxDictionaryListHeight)
                }

            } header: {
                Text("Installed dictionaries")
            } footer: {
                Text("Top-to-bottom priority controls lookup order for the current Translation source and target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadDictionaries()
            loadLibraryDictionaries()
        }
        .onChange(of: sourceLang) {
            refreshSelectedDictionaries()
        }
        .onChange(of: targetLang) {
            refreshSelectedDictionaries()
        }
        .sheet(isPresented: $showingInstallDictionaryDialog) {
            installDictionaryDialog
        }
    }

    private func loadDictionaries() {
        removeInvalidAssetDictionaryReferences()
        startDownloadedPathLoadIfNeeded()
        let downloadedPaths = downloadedDictionaryPaths()
        downloadedDictionaryPathsByName = downloadedPaths
        let dicts = DictionaryLookup.availableDictionaries()
        availableDictionaries = dedupedInstalledDictionaries(
            dictionariesMergedWithActivePreferences(
                dicts,
                downloadedPathsByName: downloadedPaths
            )
        )
        refreshSelectedDictionaries()
    }

    private func dictionariesMergedWithActivePreferences(_ dictionaries: [DictionaryLookup.DictionaryInfo],
                                                         downloadedPathsByName: [String: String]) -> [DictionaryLookup.DictionaryInfo] {
        let activeRefs = (CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String]) ?? []
        guard !activeRefs.isEmpty else { return dictionaries }

        var merged = dictionaries
        var knownIDs = Set(dictionaries.map(\.id))
        var knownNames = Set(dictionaries.map { normalizedDictionaryName($0.name) })

        let catalogItems = availableLibraryDictionaries.isEmpty
            ? mobileAssetCatalogDictionaryItems()
            : availableLibraryDictionaries
        var catalogByIdentifier: [String: DictionaryLibraryItem] = [:]
        for item in catalogItems {
            guard let identifier = item.dictionaryIdentifier else { continue }
            catalogByIdentifier[identifier] = item
        }

        for activeRef in activeRefs {
            guard let item = catalogByIdentifier[activeRef] else { continue }
            let normalizedName = normalizedDictionaryName(item.name)
            let resolvedPath = downloadedPathsByName[normalizedName] ?? activeRef
            guard !knownIDs.contains(resolvedPath), !knownNames.contains(normalizedName) else { continue }

            merged.append(DictionaryLookup.DictionaryInfo(
                id: resolvedPath,
                name: item.name,
                path: resolvedPath
            ))
            knownIDs.insert(resolvedPath)
            knownNames.insert(normalizedName)
        }

        return dedupedInstalledDictionaries(merged)
    }

    private func dedupedInstalledDictionaries(_ dictionaries: [DictionaryLookup.DictionaryInfo]) -> [DictionaryLookup.DictionaryInfo] {
        var result: [DictionaryLookup.DictionaryInfo] = []
        var seenKeys = Set<String>()

        for dict in dictionaries {
            let key = installedDictionaryDedupeKey(dict)
            guard seenKeys.insert(key).inserted else { continue }
            result.append(dict)
        }
        return result
    }

    private func installedDictionaryDedupeKey(_ dict: DictionaryLookup.DictionaryInfo) -> String {
        if let catalog = catalogItem(for: dict), let identifier = catalog.dictionaryIdentifier, !identifier.isEmpty {
            return "identifier:\(identifier)"
        }

        let normalizedName = normalizedDictionaryName(dict.name)
        if !normalizedName.isEmpty {
            return "name:\(normalizedName)"
        }

        return "path:\(normalizedDictionaryName(dict.path))"
    }

    private func removeInvalidAssetDictionaryReferences() {
        let active = CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String] ?? []
        let sanitized = active.filter { !$0.hasPrefix("asset:/") }
        guard sanitized.count != active.count else { return }

        CFPreferencesSetAppValue(
            "DCSActiveDictionaries" as CFString,
            sanitized as CFArray,
            "com.apple.DictionaryServices" as CFString
        )
        CFPreferencesAppSynchronize("com.apple.DictionaryServices" as CFString)
    }

    private var languageMatchedLibraryDictionaries: [DictionaryLibraryItem] {
        let metadataMatched = availableLibraryDictionaries.filter {
            matchesCurrentLanguagePair($0)
        }
        let fallbackItems = availableLibraryDictionaries.filter {
            $0.languageCodes.isEmpty
        }
        let fallbackInfos = fallbackItems.map(\.dictionaryInfo)
        let matchedIDs = Set(DictionarySelection.matchingDictionaries(
            source: effectivePair.source,
            target: effectivePair.target,
            dictionaries: fallbackInfos
        ).map(\.id))
        return metadataMatched + fallbackItems.filter { matchedIDs.contains($0.id) }
    }

    private var displayedInstallDialogDictionaries: [DictionaryLibraryItem] {
        let query = installDictionarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return languageMatchedLibraryDictionaries.filter { dict in
            !isInstalled(dict)
                && (query.isEmpty || "\(dict.name) \(dict.reference)".localizedCaseInsensitiveContains(query))
        }
    }

    private var displayedBilingualInstallDictionaries: [DictionaryLibraryItem] {
        displayedInstallDialogDictionaries.filter { installDialogKind(for: $0) == .bilingual }
    }

    private var displayedMonolingualInstallDictionaries: [DictionaryLibraryItem] {
        displayedInstallDialogDictionaries.filter { installDialogKind(for: $0) == .monolingual }
    }

    private var displayedSourceMonolingualInstallDictionaries: [DictionaryLibraryItem] {
        displayedMonolingualInstallDictionaries.filter {
            dictionaryLanguages($0.languageCodes, contain: effectivePair.source)
        }
    }

    private var displayedTargetMonolingualInstallDictionaries: [DictionaryLibraryItem] {
        let sourceIDs = Set(displayedSourceMonolingualInstallDictionaries.map(\.id))
        return displayedMonolingualInstallDictionaries.filter {
            !sourceIDs.contains($0.id)
                && dictionaryLanguages($0.languageCodes, contain: effectivePair.target)
        }
    }

    private var displayedUncategorizedMonolingualInstallDictionaries: [DictionaryLibraryItem] {
        let categorizedIDs = Set((displayedSourceMonolingualInstallDictionaries + displayedTargetMonolingualInstallDictionaries).map(\.id))
        return displayedMonolingualInstallDictionaries.filter { !categorizedIDs.contains($0.id) }
    }

    private func loadLibraryDictionaries() {
        startCatalogLoadIfNeeded()
        startDownloadedPathLoadIfNeeded()

        let references = CFPreferencesCopyAppValue(
            "last available dictionaries" as CFString,
            "com.apple.Dictionary" as CFString
        ) as? [String] ?? []
        let downloadedReferences = downloadedDictionaryPaths().values
        var itemsByReference: [String: DictionaryLibraryItem] = [:]

        for item in mobileAssetCatalogDictionaryItems() {
            itemsByReference[item.reference] = item
        }

        for reference in references + Array(downloadedReferences) where itemsByReference[reference] == nil {
            itemsByReference[reference] = DictionaryLibraryItem(reference: reference)
        }

        availableLibraryDictionaries = Array(itemsByReference.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Cache of the AssetsV2 catalog scan. The catalog doesn't change at runtime so
    /// one walk per process is enough; subsequent tab switches read this instantly.
    /// `nonisolated(unsafe)` is acceptable here because the cache is process-local,
    /// immutable after assignment, and a duplicate background scan is harmless.
    nonisolated(unsafe) private static var cachedCatalogItems: [DictionaryLibraryItem]?
    nonisolated(unsafe) private static var cachedDownloadedDictionaryPaths: [String: String]?

    private func startCatalogLoadIfNeeded() {
        guard Self.cachedCatalogItems == nil, !isCatalogLoading else { return }
        isCatalogLoading = true

        Task {
            let items = await Task.detached(priority: .utility) {
                Self.computeMobileAssetCatalogItems()
            }.value
            Self.cachedCatalogItems = items
            isCatalogLoading = false
            loadLibraryDictionaries()
            loadDictionaries()
        }
    }

    private func startDownloadedPathLoadIfNeeded() {
        guard Self.cachedDownloadedDictionaryPaths == nil, !isDownloadedPathLoading else { return }
        isDownloadedPathLoading = true

        Task {
            let paths = await Task.detached(priority: .utility) {
                Self.computeDownloadedDictionaryPaths(includeAssetV2: true)
            }.value
            Self.cachedDownloadedDictionaryPaths = paths
            isDownloadedPathLoading = false
            loadLibraryDictionaries()
            loadDictionaries()
        }
    }

    /// Cache-aware accessor for the catalog. Returns immediately if loaded; otherwise
    /// returns an empty list while `startCatalogLoadIfNeeded()` performs the expensive
    /// recursive scan off the main thread.
    private func mobileAssetCatalogDictionaryItems() -> [DictionaryLibraryItem] {
        Self.cachedCatalogItems ?? []
    }

    /// The actual catalog walk. Marked nonisolated so it can run via `Task.detached`
    /// (off the main thread) — walking `/System/Library/AssetsV2` recursively is
    /// expensive enough to noticeably lag tab switches.
    nonisolated private static func computeMobileAssetCatalogItems() -> [DictionaryLibraryItem] {
        let root = "/System/Library/AssetsV2"
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: root) else { return [] }

        var itemsByReference: [String: DictionaryLibraryItem] = [:]
        for case let relativePath as String in enumerator {
            guard relativePath.contains("DictionaryServices"),
                  relativePath.hasSuffix(".xml") else { continue }

            let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(relativePath))
            guard let catalog = NSDictionary(contentsOf: url) as? [String: Any],
                  let assets = catalog["Assets"] as? [[String: Any]] else { continue }

            for asset in assets {
                guard let packageName = asset["DictionaryPackageName"] as? String else { continue }
                let referenceName = packageName.hasSuffix(".dictionary") || packageName.hasSuffix(".wikipediadictionary")
                    ? packageName
                    : "\(packageName).dictionary"
                let reference = "asset:/\(referenceName)"
                let displayName = asset["DictionaryPackageDisplayName"] as? String
                let identifier = asset["DictionaryIdentifier"] as? String
                let languages = asset["IndexLanguages"] as? [String]
                let dictionaryType = (asset["DictionaryType"] as? String)?.lowercased()
                let kind: DictionarySelection.DictionaryKind?
                switch dictionaryType {
                case "bilingual":
                    kind = .bilingual
                case "monolingual":
                    kind = .monolingual
                default:
                    kind = nil
                }

                itemsByReference[reference] = DictionaryLibraryItem(
                    reference: reference,
                    displayName: displayName,
                    dictionaryIdentifier: identifier,
                    languageCodes: languages ?? [],
                    kind: kind
                )
            }
        }

        return Array(itemsByReference.values)
    }

    private func matchesCurrentLanguagePair(_ dict: DictionaryLibraryItem) -> Bool {
        guard !dict.languageCodes.isEmpty else { return false }
        switch dict.kind ?? DictionarySelection.dictionaryKind(for: dict.dictionaryInfo) {
        case .bilingual:
            return dictionaryLanguages(dict.languageCodes, contain: effectivePair.source)
                && dictionaryLanguages(dict.languageCodes, contain: effectivePair.target)
        case .monolingual:
            return dictionaryLanguages(dict.languageCodes, contain: effectivePair.source)
                || dictionaryLanguages(dict.languageCodes, contain: effectivePair.target)
        }
    }

    private func monolingualDictionary(_ dict: DictionaryLookup.DictionaryInfo, matches language: String) -> Bool {
        if let catalogItem = catalogItem(for: dict), !catalogItem.languageCodes.isEmpty {
            return dictionaryLanguages(catalogItem.languageCodes, contain: language)
        }

        return !DictionarySelection.matchingDictionaries(
            source: language,
            target: language,
            dictionaries: [dict]
        ).isEmpty
    }

    private func catalogItem(for dict: DictionaryLookup.DictionaryInfo) -> DictionaryLibraryItem? {
        let items = availableLibraryDictionaries.isEmpty
            ? mobileAssetCatalogDictionaryItems()
            : availableLibraryDictionaries
        let normalizedName = normalizedDictionaryName(dict.name)
        let normalizedPath = normalizedDictionaryName(URL(fileURLWithPath: dict.path).lastPathComponent)

        return items.first { item in
            let itemName = normalizedDictionaryName(item.name)
            return itemName == normalizedName
                || itemName == normalizedPath
                || dict.path.localizedCaseInsensitiveContains(item.name)
                || (item.dictionaryIdentifier != nil && item.dictionaryIdentifier == dict.id)
        }
    }

    private func dictionaryLanguages(_ dictionaryLanguages: [String], contain selectedLanguage: String) -> Bool {
        let selected = normalizedDictionaryLanguage(selectedLanguage)
        return dictionaryLanguages.map(normalizedDictionaryLanguage).contains { language in
            language == "*"
                || language == selected
                || (selected == "zh" && (language == "yue" || language.hasPrefix("zh")))
                || (language == "zh" && selected.hasPrefix("zh"))
                || (selected == "yue" && language == "zh")
        }
    }

    private func normalizedDictionaryLanguage(_ identifier: String) -> String {
        let normalized = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") {
            return "zh"
        }
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return "zh"
        }
        return Locale.Language(identifier: normalized).languageCode?.identifier.lowercased() ?? normalized
    }

    private func installDictionary(_ dict: DictionaryLibraryItem) {
        let installReference = installReference(for: dict)
        var active = CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String] ?? []
        active.removeAll { $0 == dict.reference && dict.reference.hasPrefix("asset:/") }
        guard !active.contains(installReference) else {
            dictionaryImportStatus = "Already installed."
            return
        }

        CFPreferencesSetAppValue(
            "DCSActiveDictionaries" as CFString,
            active + [installReference] as CFArray,
            "com.apple.DictionaryServices" as CFString
        )
        CFPreferencesAppSynchronize("com.apple.DictionaryServices" as CFString)
        dictionaryImportStatus = "Installed. Reloading..."
        addInstalledDictionariesToState([dict])
        loadDictionaries()
        addInstalledDictionariesToState([dict])
        loadLibraryDictionaries()
    }

    private func installSelectedDictionaries() {
        let selected = displayedInstallDialogDictionaries.filter {
            selectedLibraryDictionaryIDs.contains($0.id)
        }
        var active = CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String] ?? []
        var installedCount = 0
        var installedDictionaries: [DictionaryLibraryItem] = []

        for dict in selected {
            let installReference = installReference(for: dict)
            active.removeAll { $0 == dict.reference && dict.reference.hasPrefix("asset:/") }
            guard !active.contains(installReference) else { continue }
            active.append(installReference)
            installedCount += 1
            installedDictionaries.append(dict)
        }

        guard installedCount > 0 else {
            dictionaryImportStatus = "No installable dictionaries selected."
            return
        }

        CFPreferencesSetAppValue(
            "DCSActiveDictionaries" as CFString,
            active as CFArray,
            "com.apple.DictionaryServices" as CFString
        )
        CFPreferencesAppSynchronize("com.apple.DictionaryServices" as CFString)
        dictionaryImportStatus = installedCount == 1 ? "Installed 1 dictionary." : "Installed \(installedCount) dictionaries."
        selectedLibraryDictionaryIDs = []
        showingInstallDictionaryDialog = false
        addInstalledDictionariesToState(installedDictionaries)
        loadDictionaries()
        addInstalledDictionariesToState(installedDictionaries)
        loadLibraryDictionaries()
    }

    private func addInstalledDictionariesToState(_ dictionaries: [DictionaryLibraryItem]) {
        guard !dictionaries.isEmpty else { return }

        var merged = availableDictionaries
        var knownIDs = Set(merged.map(\.id))
        var knownNames = Set(merged.map { normalizedDictionaryName($0.name) })

        for dict in dictionaries {
            let info = installedDictionaryInfo(for: dict)
            let normalizedName = normalizedDictionaryName(info.name)
            guard !knownIDs.contains(info.id), !knownNames.contains(normalizedName) else { continue }

            merged.append(info)
            knownIDs.insert(info.id)
            knownNames.insert(normalizedName)
        }

        availableDictionaries = dedupedInstalledDictionaries(merged)
        refreshSelectedDictionaries()
    }

    private func installedDictionaryInfo(for dict: DictionaryLibraryItem) -> DictionaryLookup.DictionaryInfo {
        let normalizedName = normalizedDictionaryName(dict.name)
        let resolvedPath = downloadedDictionaryPathsByName[normalizedName] ?? installReference(for: dict)
        return DictionaryLookup.DictionaryInfo(
            id: resolvedPath,
            name: dict.name,
            path: resolvedPath
        )
    }

    private func normalizedDictionaryName(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        return decoded.lowercased()
            .replacingOccurrences(of: ".dictionary", with: "")
            .replacingOccurrences(of: ".wikipediadictionary", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    private func installReference(for dict: DictionaryLibraryItem) -> String {
        if let identifier = dict.dictionaryIdentifier, !identifier.isEmpty {
            return identifier
        } else if dict.reference.hasPrefix("asset:/") {
            return downloadedDictionaryPathsByName[normalizedDictionaryName(dict.name)] ?? dict.reference
        }
        return dict.reference
    }

    private func isInstalled(_ dict: DictionaryLibraryItem) -> Bool {
        let activeRefs = Set((CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String]) ?? [])
        let activeNames = Set(availableDictionaries.map { normalizedDictionaryName($0.name) })
        return activeRefs.contains(installReference(for: dict))
            || activeNames.contains(normalizedDictionaryName(dict.name))
    }

    private func downloadedDictionaryPaths() -> [String: String] {
        if let cached = Self.cachedDownloadedDictionaryPaths {
            return cached
        }
        // Avoid scanning /System/Library/AssetsV2 on the main thread. The local
        // dictionary folders are small; the full AssetsV2 walk runs in the background.
        return Self.computeDownloadedDictionaryPaths(includeAssetV2: false)
    }

    nonisolated private static func computeDownloadedDictionaryPaths(includeAssetV2: Bool) -> [String: String] {
        var roots = [
            "/Library/Dictionaries",
            NSHomeDirectory() + "/Library/Dictionaries",
        ]
        if includeAssetV2 {
            roots.insert("/System/Library/AssetsV2", at: 0)
        }

        var pathsByName: [String: String] = [:]
        let manager = FileManager.default

        for root in roots {
            guard let enumerator = manager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".dictionary") || relativePath.hasSuffix(".wikipediadictionary") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(relativePath)
                let name = URL(fileURLWithPath: fullPath).lastPathComponent
                    .replacingOccurrences(of: ".dictionary", with: "")
                    .replacingOccurrences(of: ".wikipediadictionary", with: "")
                pathsByName[Self.normalizedDictionaryNameForCache(name)] = fullPath
                enumerator.skipDescendants()
            }
        }

        return pathsByName
    }

    nonisolated private static func normalizedDictionaryNameForCache(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        return decoded.lowercased()
            .replacingOccurrences(of: ".dictionary", with: "")
            .replacingOccurrences(of: ".wikipediadictionary", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    @ViewBuilder
    private var installDictionaryDialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Dictionary")
                        .font(.headline)
                    Text("\(localizedName(for: effectivePair.source)) → \(localizedName(for: effectivePair.target))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    showingInstallDictionaryDialog = false
                }
                .keyboardShortcut(.cancelAction)
            }

            TextField("Search dictionaries", text: $installDictionarySearchText)
                .textFieldStyle(.roundedBorder)

            if displayedInstallDialogDictionaries.isEmpty {
                Text(installDialogEmptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        installDictionaryArea(title: bilingualDictionaryTitle, dictionaries: displayedBilingualInstallDictionaries)
                        installDictionaryArea(title: "\(localizedName(for: effectivePair.source)) dictionaries", dictionaries: displayedSourceMonolingualInstallDictionaries)
                        installDictionaryArea(title: "\(localizedName(for: effectivePair.target)) dictionaries", dictionaries: displayedTargetMonolingualInstallDictionaries)
                        installDictionaryArea(title: "Other dictionaries", dictionaries: displayedUncategorizedMonolingualInstallDictionaries)
                    }
                }
                .frame(height: 260)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
            }

            HStack {
                Text("Only dictionaries that are not installed for this language pair are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Install Selected") {
                    installSelectedDictionaries()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedLibraryDictionaryIDs.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var installDialogEmptyMessage: String {
        let installable = languageMatchedLibraryDictionaries.filter { !isInstalled($0) }
        if languageMatchedLibraryDictionaries.isEmpty {
            return "No available dictionaries match the current language pair."
        }
        if installable.isEmpty {
            return "No new dictionaries are available for this language pair."
        }
        return "No available dictionaries match the search."
    }

    private func installDialogKind(for dict: DictionaryLibraryItem) -> DictionarySelection.DictionaryKind {
        dict.kind ?? DictionarySelection.dictionaryKind(for: dict.dictionaryInfo)
    }

    @ViewBuilder
    private func installDictionaryArea(title: String, dictionaries: [DictionaryLibraryItem]) -> some View {
        if !dictionaries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(Array(dictionaries.enumerated()), id: \.element.id) { index, dict in
                    installDictionaryRow(dict)

                    if index < dictionaries.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func installDictionaryRow(_ dict: DictionaryLibraryItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedLibraryDictionaryIDs.contains(dict.id) },
                set: { isSelected in
                    if isSelected {
                        selectedLibraryDictionaryIDs.insert(dict.id)
                    } else {
                        selectedLibraryDictionaryIDs.remove(dict.id)
                    }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(dict.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(dict.reference)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("Ready")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 6)
    }

    private struct DictionaryLibraryItem: Identifiable, Equatable {
        let reference: String
        var displayName: String?
        var dictionaryIdentifier: String?
        var languageCodes: [String] = []
        var kind: DictionarySelection.DictionaryKind?

        var id: String { reference }

        var dictionaryInfo: DictionaryLookup.DictionaryInfo {
            DictionaryLookup.DictionaryInfo(id: id, name: name, path: reference)
        }

        var name: String {
            if let displayName, !displayName.isEmpty {
                return displayName
            }

            let lastComponent: String
            if reference.hasPrefix("asset:/") {
                lastComponent = String(reference.dropFirst("asset:/".count))
            } else {
                lastComponent = URL(fileURLWithPath: reference).lastPathComponent
            }

            return lastComponent
                .replacingOccurrences(of: ".dictionary", with: "")
                .replacingOccurrences(of: ".wikipediadictionary", with: "")
                .replacingOccurrences(of: "%20", with: " ")
                .replacingOccurrences(of: "%27", with: "'")
        }
    }

    @ViewBuilder
    private func dictionaryArea(title: String,
                                dictionaries: [DictionaryLookup.DictionaryInfo]) -> some View {
        if !dictionaries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 3)

                ForEach(Array(dictionaries.enumerated()), id: \.element.id) { index, dict in
                    dictionaryRow(dict, allowedDropIDs: Set(dictionaries.map(\.id)))

                    if index < dictionaries.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func dictionaryRow(_ dict: DictionaryLookup.DictionaryInfo,
                               allowedDropIDs: Set<String>) -> some View {
        HStack(spacing: 8) {
            Text(dict.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            kindOverrideMenu(for: dict)

            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selectedIDSet.contains(dict.id) },
                    set: { _ in toggleDictionary(dict) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(selectedIDSet.contains(dict.id) ? "Disable dictionary" : "Enable dictionary")

                priorityHandle(for: dict)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .onDrop(
            of: [UTType.text],
            delegate: DictionaryDropDelegate(
                targetID: dict.id,
                allowedIDs: allowedDropIDs,
                draggedID: $draggedDictionaryID,
                orderedIDs: $orderedDictionaryIDs,
                save: saveSelection
            )
        )
    }

    /// Per-dict kind override menu. Shows the effective kind (with a hint when it
    /// was inferred); user can force it to Monolingual / Bilingual or reset to Auto.
    private func kindOverrideMenu(for dict: DictionaryLookup.DictionaryInfo) -> some View {
        let override = DictionarySelection.kindOverride(for: dict.id)
        let effective = DictionarySelection.dictionaryKind(for: dict)
        let label: String = {
            switch (override, effective) {
            case (.some(.monolingual), _): return "Mono ✓"
            case (.some(.bilingual), _):   return "Bi ✓"
            case (nil, .monolingual):      return "Mono"
            case (nil, .bilingual):        return "Bi"
            }
        }()
        let color: Color = override != nil ? Color.accentColor : .secondary

        return Menu {
            Button {
                DictionarySelection.setKindOverride(nil, for: dict.id)
                refreshSelectedDictionaries()
                saveSelection()
            } label: {
                if override == nil {
                    Label("Auto (\(effective == .monolingual ? "Mono" : "Bi"))",
                          systemImage: "checkmark")
                } else {
                    Text("Auto (\(effective == .monolingual ? "Mono" : "Bi"))")
                }
            }
            Button {
                DictionarySelection.setKindOverride(.monolingual, for: dict.id)
                refreshSelectedDictionaries()
                saveSelection()
            } label: {
                if override == .monolingual {
                    Label("Monolingual", systemImage: "checkmark")
                } else {
                    Text("Monolingual")
                }
            }
            Button {
                DictionarySelection.setKindOverride(.bilingual, for: dict.id)
                refreshSelectedDictionaries()
                saveSelection()
            } label: {
                if override == .bilingual {
                    Label("Bilingual", systemImage: "checkmark")
                } else {
                    Text("Bilingual")
                }
            }
        } label: {
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(override != nil
              ? "Kind manually overridden — click to change or reset to Auto."
              : "Kind auto-detected. Click to override.")
    }

    private func priorityHandle(for dict: DictionaryLookup.DictionaryInfo) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .onDrag {
                draggedDictionaryID = dict.id
                return NSItemProvider(object: dict.id as NSString)
            }
    }

    private struct DictionaryDropDelegate: DropDelegate {
        let targetID: String
        let allowedIDs: Set<String>
        @Binding var draggedID: String?
        @Binding var orderedIDs: [String]
        let save: () -> Void

        func dropEntered(info: DropInfo) {
            guard let draggedID,
                  draggedID != targetID,
                  allowedIDs.contains(draggedID),
                  allowedIDs.contains(targetID),
                  let fromIndex = orderedIDs.firstIndex(of: draggedID),
                  let toIndex = orderedIDs.firstIndex(of: targetID) else { return }

            withAnimation(.easeInOut(duration: 0.12)) {
                orderedIDs.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                )
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggedID = nil
            save()
            return true
        }
    }

    private var selectedIDSet: Set<String> {
        Set(selectedDictionaryIDs)
    }

    private func refreshSelectedDictionaries() {
        let pair = effectivePair
        // Two separate priority lists per pair (monolingual + bilingual). Merge them
        // into one flat `orderedDictionaryIDs` for the UI; on save we partition back
        // by kind. Within each visual section users still drag freely.
        let monoOrdered = DictionarySelection.orderedDictionaries(
            kind: .monolingual,
            source: pair.source,
            target: pair.target,
            dictionaries: availableDictionaries
        )
        let biOrdered = DictionarySelection.orderedDictionaries(
            kind: .bilingual,
            source: pair.source,
            target: pair.target,
            dictionaries: availableDictionaries
        )
        orderedDictionaryIDs = monoOrdered.map(\.id) + biOrdered.map(\.id)

        let monoConfigured = DictionarySelection.configuredIDs(
            kind: .monolingual, source: pair.source, target: pair.target
        )
        let biConfigured = DictionarySelection.configuredIDs(
            kind: .bilingual, source: pair.source, target: pair.target
        )
        if monoConfigured != nil || biConfigured != nil {
            let visibleSet = Set(orderedDictionaryIDs)
            let selected = (monoConfigured ?? []) + (biConfigured ?? [])
            selectedDictionaryIDs = selected.filter { visibleSet.contains($0) }
        } else {
            selectedDictionaryIDs = orderedDictionaryIDs
        }
    }

    private func toggleDictionary(_ dict: DictionaryLookup.DictionaryInfo) {
        if let index = selectedDictionaryIDs.firstIndex(of: dict.id) {
            selectedDictionaryIDs.remove(at: index)
        } else {
            selectedDictionaryIDs.append(dict.id)
        }
        saveSelection()
    }

    private func resetSelection() {
        let pair = effectivePair
        DictionarySelection.resetSelection(
            kind: .monolingual, source: pair.source, target: pair.target
        )
        DictionarySelection.resetSelection(
            kind: .bilingual, source: pair.source, target: pair.target
        )
        orderedDictionaryIDs = visibleDictionaries.map(\.id)
        selectedDictionaryIDs = orderedDictionaryIDs
    }

    private func saveSelection() {
        let pair = effectivePair
        var dictByID: [String: DictionaryLookup.DictionaryInfo] = [:]
        for dict in availableDictionaries where dictByID[dict.id] == nil {
            dictByID[dict.id] = dict
        }
        let orderedSelected = orderedDictionaryIDs.filter { selectedIDSet.contains($0) }
        // Partition the user's flat ordered list back into per-kind ordered lists;
        // each kind's relative order is preserved.
        var mono: [String] = []
        var bi: [String] = []
        for id in orderedSelected {
            guard let dict = dictByID[id] else { continue }
            switch DictionarySelection.dictionaryKind(for: dict) {
            case .monolingual: mono.append(id)
            case .bilingual:   bi.append(id)
            }
        }
        DictionarySelection.saveSelectedIDs(
            mono, kind: .monolingual, source: pair.source, target: pair.target
        )
        DictionarySelection.saveSelectedIDs(
            bi, kind: .bilingual, source: pair.source, target: pair.target
        )
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private struct PolishOutputLanguageSection: View {
    @AppStorage("glotty.polishLang") private var polishLang: String = "en"

    /// Common polish targets. Polish is "rewrite into idiomatic X" — X is often the
    /// *opposite* of the translate target (you read Chinese translations of English;
    /// you polish your Chinese drafts into English).
    private let polishLanguageOptions: [(id: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
    ]

    var body: some View {
        Section {
            Picker("Polish output language", selection: $polishLang) {
                ForEach(polishLanguageOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("The language Fn → R rewrites your selection into. Not the same as Translation's target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PolishPromptsSection: View {
    @AppStorage(PolishPrompt.variantsTemplateKey) private var variantsOverride: String = ""
    @AppStorage(PolishPrompt.proofreadTemplateKey) private var proofreadOverride: String = ""

    var body: some View {
        Section {
            promptEditor(
                title: "Variants (cross-language)",
                description: "Used when the selection's language differs from the polish output language. Asks the LLM for 2-3 idiomatic translations.",
                override: $variantsOverride,
                defaultTemplate: PolishPrompt.defaultVariantsTemplate
            )
            Divider()
            promptEditor(
                title: "Proofread (same-language)",
                description: "Used when the selection and output share a language. Asks the LLM for grammar issues plus polished rewrites.",
                override: $proofreadOverride,
                defaultTemplate: PolishPrompt.defaultProofreadTemplate
            )
        } header: {
            Text("Polish Prompts")
        } footer: {
            Text("Placeholders: `${language}` is replaced with the target language name (e.g. English, Chinese); `${text}` is replaced with your selection. Leave a prompt blank to use the built-in default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func promptEditor(title: String,
                              description: String,
                              override: Binding<String>,
                              defaultTemplate: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if !override.wrappedValue.isEmpty {
                    Text("custom").font(.caption2).foregroundStyle(.orange)
                }
                Button("Reset") { override.wrappedValue = "" }
                    .controlSize(.small)
                    .disabled(override.wrappedValue.isEmpty)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: editorBinding(override: override, default: defaultTemplate))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

    /// Editor binding pattern: show the default template when no override exists, but
    /// only write to AppStorage when the user actually changes the text. If they edit
    /// back to the default verbatim, we clear the override too (so future default
    /// updates take effect).
    private func editorBinding(override: Binding<String>, default defaultTemplate: String) -> Binding<String> {
        Binding(
            get: { override.wrappedValue.isEmpty ? defaultTemplate : override.wrappedValue },
            set: { new in
                override.wrappedValue = (new == defaultTemplate) ? "" : new
            }
        )
    }
}

private struct HotkeySettingsSection: View {
    @AppStorage(Keycode.translateDefaultsKey) private var translateKey: Int = Keycode.defaultTranslate
    @AppStorage(Keycode.polishDefaultsKey)    private var polishKey:    Int = Keycode.defaultPolish
    @AppStorage(Keycode.leaderDefaultsKey)    private var leaderRaw:    String = Keycode.defaultLeader.rawValue

    private var leaderBinding: Binding<LeaderKey> {
        Binding(
            get: { LeaderKey(rawValue: leaderRaw) ?? Keycode.defaultLeader },
            set: { leaderRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            LeaderRecorderRow(leader: leaderBinding,
                              defaultLeader: Keycode.defaultLeader)

            KeyRecorderRow(
                title: "Translate",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $translateKey,
                defaultKeycode: Keycode.defaultTranslate
            )

            KeyRecorderRow(
                title: "Polish to idiomatic",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $polishKey,
                defaultKeycode: Keycode.defaultPolish
            )

            if translateKey == polishKey {
                Label("Translate and Polish are bound to the same key — polish won't fire.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Hotkey")
        } footer: {
            Text("Press **Record**, then tap the key you want as the second step of the hotkey. **Esc** during recording cancels. **Reset** restores the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Row for picking the leader (modifier-only). Two modes: dropdown (instant pick)
/// or "Record" (capture the next modifier press). Either way writes the same
/// `LeaderKey` value into `glotty.hotkey.leader`.
private struct LeaderRecorderRow: View {
    @Binding var leader: LeaderKey
    let defaultLeader: LeaderKey

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var baselineFlags: NSEvent.ModifierFlags = []

    var body: some View {
        LabeledContent("Leader key") {
            HStack(spacing: 8) {
                if isRecording {
                    Text("Press a modifier…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $leader) {
                        ForEach(LeaderKey.allCases) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Button(isRecording ? "Cancel" : "Record") {
                    isRecording ? stopRecording(save: nil) : startRecording()
                }
                .buttonStyle(.bordered)

                Button("Reset") { leader = defaultLeader }
                    .buttonStyle(.bordered)
                    .disabled(leader == defaultLeader)
            }
        }
        .onDisappear { stopRecording(save: nil) }
    }

    private func startRecording() {
        isRecording = true
        baselineFlags = NSEvent.modifierFlags
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            // Esc cancels.
            if event.type == .keyDown, event.keyCode == 53 {
                stopRecording(save: nil)
                return nil
            }
            // Find which modifier just became active.
            if event.type == .flagsChanged,
               let key = LeaderKey.newlyPressed(before: baselineFlags,
                                                after: event.modifierFlags) {
                stopRecording(save: key)
                return nil
            }
            return event
        }
    }

    private func stopRecording(save: LeaderKey?) {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
        if let save { leader = save }
    }
}

/// A single row showing the bound key + Record / Reset buttons. Captures the next
/// `.keyDown` via `NSEvent.addLocalMonitorForEvents` while in recording mode, which
/// fires only while the Settings window is frontmost.
private struct KeyRecorderRow: View {
    let title: String
    let prefix: String
    @Binding var keycode: Int
    let defaultKeycode: Int

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(prefix) \(displayLabel)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isRecording ? .secondary : .primary)

                Button(isRecording ? "Press a key…" : "Record") {
                    isRecording ? stopRecording(saveKeycode: nil) : startRecording()
                }
                .buttonStyle(.bordered)

                Button("Reset") { keycode = defaultKeycode }
                    .buttonStyle(.bordered)
                    .disabled(keycode == defaultKeycode)
            }
        }
        .onDisappear { stopRecording(saveKeycode: nil) }
    }

    private var displayLabel: String {
        isRecording ? "—" : Keycode.label(for: keycode)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            // Escape cancels recording without saving.
            if code == 53 {
                stopRecording(saveKeycode: nil)
            } else {
                stopRecording(saveKeycode: code)
            }
            return nil   // consume the event so it doesn't reach the Settings UI
        }
    }

    private func stopRecording(saveKeycode: Int?) {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
        if let saveKeycode { keycode = saveKeycode }
    }
}
