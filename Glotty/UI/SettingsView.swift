import SwiftUI
import Translation
import UniformTypeIdentifiers
import AppKit

/// Standard macOS preferences pane. Opens via ⌘, or the menu-bar "Settings…" item.
struct SettingsView: View {
    var body: some View {
        Form {
            TranslationSettingsSection()
            DictionarySettingsSection()
            HotkeySettingsSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 520)
    }
}

private struct TranslationSettingsSection: View {
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
        }
        .task { await loadAvailableLanguages() }
        .task(id: "\(sourceLang)|\(targetLang)") {
            await refreshPackStatus()
        }
        .translationTask(downloadConfig) { session in
            await runDownload(using: session)
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
        let downloadedPaths = downloadedDictionaryPaths()
        downloadedDictionaryPathsByName = downloadedPaths
        let dicts = DictionaryLookup.availableDictionaries()
        availableDictionaries = dictionariesMergedWithActivePreferences(
            dicts,
            downloadedPathsByName: downloadedPaths
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

        return merged
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

    private func mobileAssetCatalogDictionaryItems() -> [DictionaryLibraryItem] {
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

        availableDictionaries = merged
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
        name.lowercased()
            .replacingOccurrences(of: ".dictionary", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let roots = [
            "/System/Library/AssetsV2",
            "/Library/Dictionaries",
            NSHomeDirectory() + "/Library/Dictionaries",
        ]
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
                pathsByName[normalizedDictionaryName(name)] = fullPath
                enumerator.skipDescendants()
            }
        }

        return pathsByName
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
        let ordered = DictionarySelection.orderedDictionaries(
            source: pair.source,
            target: pair.target,
            dictionaries: availableDictionaries
        )
        orderedDictionaryIDs = ordered.map(\.id)
        if let configured = DictionarySelection.configuredIDs(source: pair.source, target: pair.target) {
            let visibleSet = Set(orderedDictionaryIDs)
            selectedDictionaryIDs = configured.filter { visibleSet.contains($0) }
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
        DictionarySelection.resetSelection(source: pair.source, target: pair.target)
        orderedDictionaryIDs = visibleDictionaries.map(\.id)
        selectedDictionaryIDs = orderedDictionaryIDs
    }

    private func saveSelection() {
        let pair = effectivePair
        let orderedIDs = orderedDictionaryIDs.filter { selectedIDSet.contains($0) }
        DictionarySelection.saveSelectedIDs(orderedIDs, source: pair.source, target: pair.target)
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private struct HotkeySettingsSection: View {
    var body: some View {
        Section {
            LabeledContent("Leader key", value: "Fn")
            LabeledContent("Translate", value: "Fn → T")
        } header: {
            Text("Hotkey")
        } footer: {
            Text("Hotkey customization will arrive after the spike. For now the leader is fixed to Fn and the translate command is T.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
