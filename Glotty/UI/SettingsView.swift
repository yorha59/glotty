import SwiftUI
import Translation
import UniformTypeIdentifiers
import AppKit

/// User-selectable app appearance. Glotty is a menu-bar agent whose only
/// real surfaces are the Welcome / Settings / popup / chat windows, so we
/// drive the whole app's look from a single `NSApp.appearance` override
/// rather than per-window flags. `.system` clears the override and follows
/// the OS setting.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System".t
        case .light:  return "Light".t
        case .dark:   return "Dark".t
        }
    }

    /// nil = follow the system (no override).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Central appearance control. The mode is persisted under a single
/// UserDefaults key (also bound by `@AppStorage` in the Appearance picker)
/// so launch and live changes read the same source of truth.
enum Theme {
    static let defaultsKey = "glotty.appearance"

    /// Current mode. Defaults to `.system` — the web build has always
    /// followed the OS appearance, so keep that unless the user opts in.
    static var mode: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .system
    }

    /// Push the stored mode onto `NSApp`. Safe to call repeatedly; call once
    /// at launch and again whenever the picker changes.
    @MainActor
    static func apply() {
        NSApp.appearance = mode.nsAppearance
    }
}

/// Settings → System: Light / Dark / follow-System appearance. Bound to the
/// same key `Theme` reads at launch, so a change applies live.
struct AppearanceSection: View {
    @AppStorage(Theme.defaultsKey) private var mode: String = AppearanceMode.system.rawValue

    var body: some View {
        Section {
            Picker("Appearance".t, selection: $mode) {
                ForEach(AppearanceMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { Theme.apply() }
        } header: {
            Text("Appearance".t)
        } footer: {
            Text("Pick Light, Dark, or follow the system setting.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One row in the Settings sidebar. Order here = display order in the list.
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case profile
    case translation
    case dictionaries
    case languageModel
    case polish
    case hotkey
    case voice
    case history
    case memory
    case chat
    case usage
    case backup
    case system
    case permissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .profile:       return "Profile"
        case .translation:   return "Translation"
        case .dictionaries:  return "Dictionaries"
        case .languageModel: return "Language Model"
        case .polish:        return "Polish"
        case .hotkey:        return "Hotkey"
        case .voice:         return "Voice"
        case .history:       return "History"
        case .memory:        return "Memory"
        case .chat:          return "Chat"
        case .usage:         return "Usage"
        case .backup:        return "Backup"
        case .system:        return "System"
        case .permissions:   return "Permissions"
        }
    }

    /// SF Symbol shown in the sidebar row. Picked to evoke each tab's purpose
    /// without leaning too heavily on language-related glyphs (which would all
    /// blur together).
    var icon: String {
        switch self {
        case .profile:       return "person.crop.circle"
        case .translation:   return "character.bubble"
        case .dictionaries:  return "book.closed"
        case .languageModel: return "sparkles"
        case .polish:        return "wand.and.stars"
        case .hotkey:        return "keyboard"
        case .voice:         return "speaker.wave.2"
        case .history:       return "clock.arrow.circlepath"
        case .memory:        return "brain"
        case .chat:          return "bubble.left.and.bubble.right"
        case .usage:         return "chart.bar"
        case .backup:        return "externaldrive"
        case .system:        return "gearshape.2"
        case .permissions:   return "lock.shield"
        }
    }
}

/// Standard macOS preferences pane. Opens via ⌘, or the menu-bar "Settings…" item.
/// Uses a sidebar list (the System Settings pattern) so the seven sections have
/// room to breathe — `TabView` ran out of horizontal space once we passed five
/// tabs. The sidebar auto-scrolls when there are more sections than fit.
struct SettingsView: View {
    init(initialTab: SettingsTab = .profile) {
        self._selection = State(initialValue: initialTab)
    }

    /// Default to Profile on first open. State lives in SettingsView (not
    /// persisted) so reopening the window starts at the top of the sidebar —
    /// matches what System Settings does.
    @State private var selection: SettingsTab = .profile

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.label.t, systemImage: tab.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView(for: selection)
                .navigationTitle(selection.label.t)
        }
        .frame(minWidth: 720, minHeight: 480)
        .localizationAware()
    }

    @ViewBuilder
    private func detailView(for tab: SettingsTab) -> some View {
        switch tab {
        case .profile:       userProfileTab
        case .translation:   translationTab
        case .dictionaries:  dictionariesTab
        case .languageModel: languageModelTab
        case .polish:        polishTab
        case .hotkey:        hotkeyTab
        case .voice:         voiceTab
        case .history:       memoryTab
        case .memory:        memoryDetailTab
        case .chat:          chatTab
        case .usage:         usageTab
        case .backup:        backupTab
        case .system:        systemTab
        case .permissions:   permissionsTab
        }
    }

    private var userProfileTab: some View {
        Form { UserProfileSection() }
            .formStyle(.grouped)
    }

    /// Settings → System: things that affect Glotty itself rather
    /// than learning preferences. UI language picker (was under
    /// Profile) and the dev-mode debug helpers (were under Backup).
    private var systemTab: some View {
        Form {
            AppearanceSection()
            SystemLanguageSection()
            SystemDebugSection()
        }
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

    /// Polish behavior: output language only. The prompt-template editor
    /// (`PolishPromptsSection`) is hidden from Settings — templates live in
    /// `PolishPrompt.defaultVariantsTemplate` / `defaultProofreadTemplate` and
    /// can still be overridden via `UserDefaults` for power-user tweaks.
    private var polishTab: some View {
        Form {
            PolishOutputLanguageSection()
            PolishCommonMistakesSection()
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form { HotkeySettingsSection() }
            .formStyle(.grouped)
    }

    private var voiceTab: some View {
        Form { VoiceSettingsSection() }
            .formStyle(.grouped)
    }

    private var memoryDetailTab: some View {
        Form { LearnedMemorySettingsSection() }
            .formStyle(.grouped)
    }

    private var memoryTab: some View {
        Form { MemorySettingsSection() }
            .formStyle(.grouped)
    }

    private var chatTab: some View {
        Form {
            GlottyPersonaSection()
            ChatSettingsSection()
        }
        .formStyle(.grouped)
    }

    private var usageTab: some View {
        Form { UsageSettingsSection() }
            .formStyle(.grouped)
    }

    private var backupTab: some View {
        Form { BackupSettingsSection() }
            .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        // PermissionsView already implements the full permissions guide
        // (status rows, "Open Settings" / "Re-register" buttons, troubleshooting
        // disclosure). Embedding it directly keeps the code single-sourced.
        PermissionsView(onClose: nil)
            .frame(maxHeight: .infinity)
    }
}

/// Internal (was private) so the Welcome window can embed this
/// inline on step 4 — keeps first-provider setup inside onboarding
/// instead of bouncing the user to a separate Settings panel.
struct LanguageModelSettingsSection: View {
    /// When false, the section header ("Language Model") and the
    /// long footer paragraph are suppressed. The Welcome window
    /// passes `false` because the step's title already says "Set
    /// up your AI provider" — repeating the header makes the rows
    /// look pushed down and out of alignment.
    var showChrome: Bool = true

    @AppStorage("glotty.llmProvider") private var providerID: String = "zai"
    @AppStorage("glotty.kimi.endpoint") private var kimiEndpoint: String = ""
    @AppStorage("glotty.kimi.model") private var kimiModel: String = ""
    @AppStorage("glotty.minimax.endpoint") private var minimaxEndpoint: String = ""
    @AppStorage("glotty.minimax.model") private var minimaxModel: String = ""
    @AppStorage("glotty.deepseek.endpoint") private var deepseekEndpoint: String = ""
    @AppStorage("glotty.deepseek.model") private var deepseekModel: String = ""
    @State private var apiKey: String = ""
    @State private var apiKeyPlaceholder: String = ""
    @State private var testStatus: TestStatus = .idle
    /// Bumped on CustomProviderStore changes so the picker re-reads the list.
    @State private var customRefreshToken: Int = 0
    /// Bumped on ModelListCache changes so model pickers refresh after a
    /// successful `/models` fetch.
    @State private var modelListRefreshToken: Int = 0
    /// Provider id whose model list is currently being fetched (drives
    /// the per-row spinner). Nil when nothing's in-flight.
    @State private var modelFetchingProviderID: String?
    /// Most-recent model-fetch error, by provider id. Cleared on the
    /// next successful fetch for the same provider.
    @State private var modelFetchError: [String: String] = [:]
    /// Set to a non-nil config when the user taps "Add custom" or "Edit" on a
    /// custom entry — drives the sheet.
    @State private var customEditorSeed: CustomProviderEditorSeed?

    enum TestStatus: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    @ViewBuilder
    private var sectionContent: some View {
        // Use a Menu (not a Picker) so the "Add custom provider…" action
        // can live as the bottom item inside the dropdown — same
        // discoverability pattern as macOS's "Other Network…" /
        // "Customize Toolbar…". A Picker would have consumed the full
        // row width and clipped any sibling control.
        LabeledContent("Provider") {
            Menu {
                providerPickerMenu
            } label: {
                Text(currentProviderDisplayName)
            }
            .id(customRefreshToken)
        }

        providerFields
    }

    var body: some View {
        Group {
            if showChrome {
                Section {
                    sectionContent
                } header: {
                    Text("Language Model")
                } footer: {
                    Text("The engine that powers Fn → R polish. API keys are stored in macOS Keychain. OpenAI-compatible providers (OpenAI, DeepSeek, OpenRouter, Z.AI, plus any custom endpoint you add) share the same wire format. Polish output language and prompt templates live in the Polish tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section { sectionContent }
            }
        }
        .onAppear { loadKey() }
        .onReceive(NotificationCenter.default.publisher(for: CustomProviderStore.didChangeNotification)) { _ in
            customRefreshToken &+= 1
            loadKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelListCache.didChangeNotification)) { _ in
            modelListRefreshToken &+= 1
        }
        .sheet(item: $customEditorSeed) { seed in
            CustomProviderEditor(seed: seed) { savedID in
                // Switch to the newly-saved provider so the user can immediately
                // enter the API key without an extra click in the picker.
                if let savedID { providerID = savedID }
                customEditorSeed = nil
                loadKey()
            }
        }
    }

    /// Menu rows for every provider — stock OpenAI-compatible presets,
    /// dedicated classes (DeepSeek, Kimi), and user-added custom entries —
    /// in one flat list with no dividers. The user picks a provider; the
    /// underlying wire format isn't their concern, so we don't surface it.
    /// The "Add custom provider…" action moved out to the testRow next to
    /// "Test connection", so it isn't tucked inside this dropdown.
    @ViewBuilder
    private var providerPickerMenu: some View {
        ForEach(OpenAIStockPresets.all) { preset in
            providerMenuButton(id: preset.id, label: preset.displayName)
        }
        providerMenuButton(id: "deepseek", label: "DeepSeek")
        providerMenuButton(id: "kimi-coding", label: "Kimi For Coding")
        providerMenuButton(id: "minimax-coding", label: "MiniMax (Coding)")
        // On-device Apple model — only offered when the OS reports it usable.
        if AppleFoundationProvider().isAvailable() {
            providerMenuButton(id: "apple-foundation", label: "Apple Intelligence (On-Device)")
        }
        ForEach(CustomProviderStore.all()) { config in
            providerMenuButton(id: config.providerID, label: config.displayName)
        }
    }

    /// One selectable provider row in the menu. Adds a checkmark
    /// glyph to the currently-active provider so the user can see
    /// what's selected without opening the menu twice.
    @ViewBuilder
    private func providerMenuButton(id: String, label: String) -> some View {
        Button {
            providerID = id
            // Picker used `.onChange(of: providerID)` to re-load the
            // saved API key for the newly-selected provider; with a
            // Menu we drive it directly from the row action.
            loadKey()
        } label: {
            if id == providerID {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// Human-readable name of the currently-selected provider, used as
    /// the Menu's label. Falls back to the raw id for entries we can't
    /// resolve (e.g. a custom entry that's been deleted).
    private var currentProviderDisplayName: String {
        if let preset = OpenAIStockPresets.find(id: providerID) {
            return preset.displayName
        }
        if let uuid = customProviderUUID(from: providerID),
           let config = CustomProviderStore.find(id: uuid) {
            return config.displayName
        }
        if providerID == "deepseek" { return "DeepSeek" }
        if providerID == "kimi-coding" { return "Kimi For Coding" }
        if providerID == "minimax-coding" { return "MiniMax (Coding)" }
        if providerID == "apple-foundation" { return "Apple Intelligence (On-Device)" }
        return providerID
    }

    /// Per-provider configuration fields, dispatched by `providerID`.
    @ViewBuilder
    private var providerFields: some View {
        if let preset = OpenAIStockPresets.find(id: providerID) {
            stockPresetFields(preset)
        } else if let uuid = customProviderUUID(from: providerID),
                  let config = CustomProviderStore.find(id: uuid) {
            customProviderFields(config)
        } else if providerID == "deepseek" {
            deepseekFields
        } else if providerID == "kimi-coding" {
            kimiFields
        } else if providerID == "minimax-coding" {
            minimaxFields
        } else if providerID == "apple-foundation" {
            appleFoundationFields
        } else {
            // Selected id doesn't match any known provider — likely a custom
            // entry was deleted while selected. Surface a hint and let the
            // picker re-select.
            Text("Provider not found. Pick another from the menu above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Apple Intelligence (on-device) fields

    /// No API key, endpoint, or model to configure — it's the OS model. Just
    /// explain what it is. The row only appears when the provider is available,
    /// so we don't need an unavailable state here.
    @ViewBuilder
    private var appleFoundationFields: some View {
        Text("Runs Apple's on-device foundation model. No API key, no network — your text never leaves the Mac, and it works offline. Requires an Apple Silicon Mac with Apple Intelligence enabled (macOS 26+). Output quality is lighter than the larger cloud models; switch providers above for the most demanding polish.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Stock preset fields

    @ViewBuilder
    private func stockPresetFields(_ preset: OpenAIStockPresets.Preset) -> some View {
        apiKeyRow(promptText: "Paste your \(preset.displayName) API key")

        TextField("Endpoint",
                  text: endpointBinding(for: preset),
                  prompt: Text(preset.defaultEndpoint))
            .textContentType(.URL)

        HStack {
            modelIDInput(
                label: "Model",
                binding: rawModelBinding(for: preset),
                placeholder: preset.defaultModel,
                suggestions: preset.availableModels().map { ($0.id, $0.displayName.t) }
            )
            .id(modelListRefreshToken)
            modelRefreshControl(providerID: preset.id) {
                let endpoint = URL(string: preset.currentEndpoint())
                    ?? URL(string: preset.defaultEndpoint)!
                await refreshModels(
                    providerID: preset.id,
                    endpoint: endpoint,
                    keychainAccount: preset.id,
                    auth: .bearer
                )
            }
        }

        if let summary = preset.model(forID: modelBinding(for: preset).wrappedValue)?.summary {
            Text(summary.t)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let signup = preset.signupURL {
            Link("Get an API key →", destination: signup)
                .font(.caption)
        }

        testRow
    }

    /// Endpoint TextField binding — falls back to the preset default for
    /// display but persists user edits to the preset's UserDefaults key.
    private func endpointBinding(for preset: OpenAIStockPresets.Preset) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: preset.endpointUserDefaultsKey) ?? "" },
            set: { UserDefaults.standard.set($0, forKey: preset.endpointUserDefaultsKey) }
        )
    }

    /// Model picker binding — collapses empty AppStorage to the preset default
    /// so the picker always has a valid selection.
    private func modelBinding(for preset: OpenAIStockPresets.Preset) -> Binding<String> {
        Binding(
            get: {
                let raw = UserDefaults.standard.string(forKey: preset.modelUserDefaultsKey) ?? ""
                return raw.isEmpty ? preset.defaultModel : raw
            },
            set: { UserDefaults.standard.set($0, forKey: preset.modelUserDefaultsKey) }
        )
    }

    // MARK: - Custom provider fields

    @ViewBuilder
    private func customProviderFields(_ config: CustomProviderConfig) -> some View {
        apiKeyRow(promptText: "Paste API key for \(config.displayName)")

        HStack {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            Text(config.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }

        HStack {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            // If we've fetched the server's `/models` for this custom
            // provider, present it as a dropdown so switching is one
            // tap. Otherwise just show the current model id as text
            // (the user typed it in the editor sheet).
            if let cache = ModelListCache.cached(for: config.providerID),
               !cache.modelIDs.isEmpty {
                Menu {
                    ForEach(cache.modelIDs, id: \.self) { mid in
                        Button {
                            var updated = config
                            updated.model = mid
                            CustomProviderStore.upsert(updated)
                        } label: {
                            if mid == config.model {
                                Label(mid, systemImage: "checkmark")
                            } else {
                                Text(mid)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(config.model)
                            .font(.caption.monospaced())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .id(modelListRefreshToken)
            } else {
                Text(config.model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            modelRefreshControl(providerID: config.providerID) {
                let endpoint = URL(string: config.endpoint)
                    ?? URL(string: "https://invalid.local/")!
                await refreshModels(
                    providerID: config.providerID,
                    endpoint: endpoint,
                    keychainAccount: config.providerID,
                    auth: .bearer
                )
            }
        }

        HStack {
            Button("Edit") {
                customEditorSeed = .edit(config)
            }
            .controlSize(.small)
            Button("Delete", role: .destructive) {
                CustomProviderStore.delete(id: config.id)
                // Switch back to the default provider if we just deleted the
                // active one. Otherwise the body would render the "not found"
                // hint until the user picks something.
                if providerID == config.providerID {
                    providerID = OpenAIStockPresets.all.first?.id ?? "zai"
                }
            }
            .controlSize(.small)
            Spacer()
        }

        testRow
    }

    /// Decode a `custom-<uuid>` provider id back into its UUID. Returns nil
    /// for non-custom ids.
    private func customProviderUUID(from id: String) -> UUID? {
        guard id.hasPrefix("custom-") else { return nil }
        return UUID(uuidString: String(id.dropFirst("custom-".count)))
    }

    // MARK: - DeepSeek fields (dedicated class — handles reasoner CoT)

    private var deepseekModelBinding: Binding<String> {
        Binding(
            get: { deepseekModel.isEmpty ? DeepSeekProvider.defaultModel : deepseekModel },
            set: { deepseekModel = $0 }
        )
    }

    @ViewBuilder
    private var deepseekFields: some View {
        apiKeyRow(promptText: "Paste your DeepSeek API key")

        TextField("Endpoint",
                  text: $deepseekEndpoint,
                  prompt: Text(DeepSeekProvider.defaultEndpoint))
            .textContentType(.URL)

        HStack {
            modelIDInput(
                label: "Model",
                binding: $deepseekModel,
                placeholder: DeepSeekProvider.defaultModel,
                suggestions: DeepSeekProvider.availableModels().map { ($0.id, $0.displayName) }
            )
            .id(modelListRefreshToken)
            modelRefreshControl(providerID: "deepseek") {
                let raw = (deepseekEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           ? DeepSeekProvider.defaultEndpoint : deepseekEndpoint)
                let endpoint = URL(string: raw) ?? URL(string: DeepSeekProvider.defaultEndpoint)!
                await refreshModels(
                    providerID: "deepseek",
                    endpoint: endpoint,
                    keychainAccount: DeepSeekProvider.keychainAccount,
                    auth: .bearer
                )
            }
        }

        if let summary = DeepSeekProvider.model(for: deepseekModelBinding.wrappedValue)?.summary {
            Text(summary.t)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Link("Get an API key →",
             destination: URL(string: "https://platform.deepseek.com/api_keys")!)
            .font(.caption)

        testRow
    }

    // MARK: - Kimi fields (Anthropic-compatible — kept alongside plugin model)

    private var kimiModelBinding: Binding<String> {
        Binding(
            get: { kimiModel.isEmpty ? KimiCodingProvider.defaultModel : kimiModel },
            set: { kimiModel = $0 }
        )
    }

    @ViewBuilder
    private var kimiFields: some View {
        apiKeyRow(promptText: "Paste your Kimi API key")

        TextField("Endpoint",
                  text: $kimiEndpoint,
                  prompt: Text(KimiCodingProvider.defaultEndpoint))
            .textContentType(.URL)

        HStack {
            modelIDInput(
                label: "Model",
                binding: $kimiModel,
                placeholder: KimiCodingProvider.defaultModel,
                suggestions: KimiCodingProvider.availableModels().map { ($0.id, $0.displayName.t) }
            )
            .id(modelListRefreshToken)
            modelRefreshControl(providerID: "kimi-coding") {
                let raw = (kimiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           ? KimiCodingProvider.defaultEndpoint : kimiEndpoint)
                let endpoint = URL(string: raw) ?? URL(string: KimiCodingProvider.defaultEndpoint)!
                await refreshModels(
                    providerID: "kimi-coding",
                    endpoint: endpoint,
                    keychainAccount: KimiCodingProvider.keychainAccount,
                    auth: .anthropic(version: "2023-06-01", userAgent: "KimiCLI/1.5")
                )
            }
        }

        if let summary = KimiCodingProvider.model(for: kimiModelBinding.wrappedValue)?.summary {
            Text(summary.t)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        testRow
    }

    // MARK: - MiniMax fields (Anthropic-compatible, Bearer auth)

    private var minimaxModelBinding: Binding<String> {
        Binding(
            get: { minimaxModel.isEmpty ? MiniMaxCodingProvider.defaultModel : minimaxModel },
            set: { minimaxModel = $0 }
        )
    }

    @ViewBuilder
    private var minimaxFields: some View {
        apiKeyRow(promptText: "Paste your MiniMax API key")

        TextField("Endpoint",
                  text: $minimaxEndpoint,
                  prompt: Text(MiniMaxCodingProvider.defaultEndpoint))
            .textContentType(.URL)

        HStack {
            modelIDInput(
                label: "Model",
                binding: $minimaxModel,
                placeholder: MiniMaxCodingProvider.defaultModel,
                suggestions: MiniMaxCodingProvider.availableModels().map { ($0.id, $0.displayName.t) }
            )
            .id(modelListRefreshToken)
            modelRefreshControl(providerID: "minimax-coding") {
                let raw = (minimaxEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           ? MiniMaxCodingProvider.defaultEndpoint : minimaxEndpoint)
                let endpoint = URL(string: raw) ?? URL(string: MiniMaxCodingProvider.defaultEndpoint)!
                await refreshModels(
                    providerID: "minimax-coding",
                    endpoint: endpoint,
                    keychainAccount: MiniMaxCodingProvider.keychainAccount,
                    auth: .bearer
                )
            }
        }

        if let summary = MiniMaxCodingProvider.model(for: minimaxModelBinding.wrappedValue)?.summary {
            Text(summary.t)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("MiniMax's coding plan uses the same Anthropic-compatible API as Claude Code. International host: api.minimax.io · China: api.minimaxi.com (edit the endpoint above).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        testRow
    }

    // MARK: - Shared rows

    @ViewBuilder
    private func apiKeyRow(promptText: String) -> some View {
        HStack {
            SecureField("API key", text: $apiKey,
                        prompt: Text(apiKeyPlaceholder.isEmpty ? promptText : apiKeyPlaceholder))
            Button("Save") { saveKey() }
                .disabled(apiKey.isEmpty)
            if !apiKeyPlaceholder.isEmpty {
                Button("Clear", role: .destructive) { clearKey() }
            }
        }
    }

    /// Test button + Add-custom button + status. Sharing one row keeps both
    /// provider-level actions together at the bottom of the section, and
    /// keeps the Add-custom affordance discoverable without burying it in
    /// the picker dropdown.
    @ViewBuilder
    private var testRow: some View {
        HStack {
            Button("Test connection") { Task { await test() } }
                .disabled(testStatus == .running)
            Button {
                customEditorSeed = .new
            } label: {
                Label("Add custom provider", systemImage: "plus")
            }
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

    /// Which Keychain account holds the active provider's key. Now that every
    /// provider stores keys in its own account, the mapping is just "providerID".
    /// Custom entries derive their account from the UUID-suffixed id.
    private var currentKeychainAccount: String? {
        // Stock presets keep their existing accounts (id == account).
        if OpenAIStockPresets.find(id: providerID) != nil { return providerID }
        if customProviderUUID(from: providerID) != nil { return providerID }
        if providerID == "deepseek" { return DeepSeekProvider.keychainAccount }
        if providerID == "kimi-coding" { return KimiCodingProvider.keychainAccount }
        return nil
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

    /// Fetch the latest model list from the given provider's `/models`
    /// endpoint and save it to `ModelListCache`. The picker re-reads
    /// via `modelListRefreshToken` once the notification fires. No-op
    /// if the keychain doesn't yet hold an API key for this provider
    /// (the server will reject the request).
    private func refreshModels(
        providerID: String,
        endpoint: URL,
        keychainAccount: String,
        auth: ModelListFetcher.AuthStyle
    ) async {
        guard let key = Keychain.read(account: keychainAccount), !key.isEmpty else {
            modelFetchError[providerID] = "Save your API key first."
            return
        }
        modelFetchingProviderID = providerID
        defer { modelFetchingProviderID = nil }
        do {
            let ids = try await ModelListFetcher.fetchModels(
                endpoint: endpoint,
                apiKey: key,
                auth: auth
            )
            ModelListCache.save(CachedModelList(
                providerID: providerID,
                modelIDs: ids,
                fetchedAt: Date()
            ))
            modelFetchError.removeValue(forKey: providerID)
        } catch {
            modelFetchError[providerID] = error.localizedDescription
        }
    }

    /// Free-form model id input with a "Known models" menu next to it.
    /// Lets users paste a brand-new model id from a provider release
    /// note without waiting for our hardcoded catalog or `/models`
    /// cache to catch up. The menu still surfaces the merged
    /// hardcoded + fetched list as one-tap suggestions; selecting an
    /// item writes it into the same binding the TextField writes to,
    /// so the two stay in sync.
    @ViewBuilder
    private func modelIDInput(
        label: LocalizedStringKey,
        binding: Binding<String>,
        placeholder: String,
        suggestions: [(id: String, displayName: String)]
    ) -> some View {
        HStack(spacing: 4) {
            TextField(label, text: binding, prompt: Text(placeholder))
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.id) { suggestion in
                        Button {
                            binding.wrappedValue = suggestion.id
                        } label: {
                            if suggestion.id == binding.wrappedValue {
                                Label(suggestion.displayName, systemImage: "checkmark")
                            } else {
                                Text(suggestion.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Pick from known models".t)
            }
        }
    }

    /// Raw binding for a stock preset's model id — empty string when
    /// nothing's saved (TextField then shows the placeholder). The
    /// fall-back-to-default logic lives in the consumer.
    private func rawModelBinding(for preset: OpenAIStockPresets.Preset) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: preset.modelUserDefaultsKey) ?? "" },
            set: { UserDefaults.standard.set($0, forKey: preset.modelUserDefaultsKey) }
        )
    }

    /// Compact refresh button + per-provider status badge. Shown next
    /// to each provider's Model picker. Spinner while in flight,
    /// error in red if the last fetch failed, "✓ <n>" success badge
    /// when the cache has been populated.
    @ViewBuilder
    private func modelRefreshControl(providerID: String, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await action() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(modelFetchingProviderID == providerID)
            .help("Fetch this provider's current model list from its /models endpoint")

            if modelFetchingProviderID == providerID {
                ProgressView().controlSize(.small)
            } else if let msg = modelFetchError[providerID] {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .help(msg)
            } else if let cache = ModelListCache.cached(for: providerID) {
                Text("\(cache.modelIDs.count) models · \(cache.fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func test() async {
        testStatus = .running
        guard let provider = LLMRegistry.current() else {
            testStatus = .failed("No provider selected.")
            return
        }
        do {
            let result = try await UsageContext.$mode.withValue(.polish) {
                try await provider.polish("hello world",
                                          mode: .variants(target: "en", nativeLanguage: nil))
            }
            let preview = result.variants.first?.text ?? "(no variants)"
            testStatus = .ok("OK · \(preview.prefix(40))\(preview.count > 40 ? "…" : "")")
        } catch {
            testStatus = .failed(error.localizedDescription)
        }
    }
}

/// Drives the custom provider editor sheet. `.new` opens with blank fields and
/// a fresh UUID on save; `.edit(config)` opens with the config pre-filled and
/// upserts on save under the same UUID.
enum CustomProviderEditorSeed: Identifiable {
    case new
    case edit(CustomProviderConfig)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let c): return c.id.uuidString
        }
    }
}

/// Modal editor for a custom OpenAI-compatible provider. The user fills in
/// the display name, endpoint URL, and model id; on Save the config is
/// persisted via `CustomProviderStore` and the calling section is notified
/// (so it can switch the active provider to the new entry).
private struct CustomProviderEditor: View {
    let seed: CustomProviderEditorSeed
    /// Called on save/cancel. The String parameter is the providerID to switch
    /// to (nil on cancel or when staying on the existing selection).
    let onClose: (String?) -> Void

    @State private var displayName: String = ""
    @State private var endpoint: String = ""
    @State private var model: String = ""

    /// Existing UUID when editing, fresh one when creating. Frozen for the
    /// life of the sheet so a quick double-tap doesn't create duplicates.
    @State private var id: UUID = UUID()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $displayName,
                          prompt: Text("e.g. Groq, Together, Local Ollama"))
                TextField("Endpoint", text: $endpoint,
                          prompt: Text("https://…/v1/chat/completions"))
                    .textContentType(.URL)
                TextField("Model", text: $model,
                          prompt: Text("e.g. llama-3.1-70b-versatile"))
            } header: {
                Text("Provider")
            } footer: {
                Text("Any service that speaks the OpenAI chat completions wire format works. The API key goes in the main Language Model panel after you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose(nil) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: hydrate)
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: endpoint.trimmingCharacters(in: .whitespaces)) != nil
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func hydrate() {
        switch seed {
        case .new:
            id = UUID()
            displayName = ""
            endpoint = ""
            model = ""
        case .edit(let c):
            id = c.id
            displayName = c.displayName
            endpoint = c.endpoint
            model = c.model
        }
    }

    private func save() {
        let trimmed = CustomProviderConfig(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            endpoint: endpoint.trimmingCharacters(in: .whitespaces),
            model: model.trimmingCharacters(in: .whitespaces)
        )
        CustomProviderStore.upsert(trimmed)
        onClose(trimmed.providerID)
    }
}

private struct UserProfileSection: View {
    @AppStorage("glotty.user.displayName") private var displayName: String = ""
    @AppStorage("glotty.user.pronouns") private var pronouns: String = ""
    @AppStorage("glotty.user.about") private var about: String = ""
    @AppStorage("glotty.user.nativeLanguage") private var nativeLang: String = ""

    /// Drives the display-name field's "fade out once you've typed something"
    /// behavior. Once the user enters a name and unfocuses, we collapse the
    /// row to a read-only label. Clicking the label flips this back to true
    /// and re-focuses the field for re-edit.
    @State private var nameEditing = false
    @FocusState private var nameFocused: Bool

    /// Gender choices stored as the third-person pronouns we'd use in prompts.
    /// Empty string == "Prefer not to say".
    private let pronounOptions: [(id: String, label: String)] = [
        ("",        "Prefer not to say"),
        ("he/him",  "Male"),
        ("she/her", "Female"),
    ]

    /// Shared with every other "static" language picker — see
    /// `LanguageOptions.all`.
    private var options: [LanguageOptions.Option] { LanguageOptions.all }

    /// Picker binding: empty stored value means "use the system locale". The default
    /// shown in the picker becomes the user's macOS locale on first launch.
    private var selection: Binding<String> {
        Binding(
            get: { nativeLang.isEmpty ? systemLocaleCode() : nativeLang },
            set: { nativeLang = $0 }
        )
    }

    var body: some View {
        Group {
            Section {
                Group {
                    if displayName.isEmpty || nameEditing {
                        TextField("Display name", text: $displayName, prompt: Text("What should Glotty call you?"))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onSubmit { nameEditing = false }
                            .onChange(of: nameFocused) { _, focused in
                                Log.debug(.settings,
                                    "displayName field focus → \(focused) keyWindow=\(NSApp.keyWindow?.title ?? "nil")",
                                    op: "open-settings")
                                if !focused { nameEditing = false }
                            }
                            .transition(.opacity)
                    } else {
                        LabeledContent("Display name") {
                            HStack(spacing: 6) {
                                Text(displayName)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            nameEditing = true
                            // @FocusState updates need to land after the
                            // TextField has been added back to the tree.
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: nameEditing)
                .animation(.easeInOut(duration: 0.2), value: displayName.isEmpty)

                Picker("Gender", selection: $pronouns) {
                    ForEach(pronounOptions, id: \.id) { option in
                        Text(option.label.t).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("About you")
            } footer: {
                Text("Optional. Used to address you in practice feedback and chat replies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Native language", selection: selection) {
                    ForEach(options) { option in
                        Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Your native language".t)
            } footer: {
                Text("The language you speak natively. Drives auto-detected source / target choices and biases translation behavior toward what you're likely reading or writing. Also the language Fn → E (Explain) renders its explanations in, and — unless you've overridden it in the System tab — the language Glotty's UI uses on the next launch.".t)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $about)
                    .frame(minHeight: 80)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                    .overlay(alignment: .topLeading) {
                        if about.isEmpty {
                            Text("e.g. \"I'm learning German for a job in Berlin. Native English speaker, intermediate level.\"")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Notes for Glotty")
            } footer: {
                Text("A short blurb about your learning goals or background — fed into LLM prompts so suggestions feel tailored. Optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func systemLocaleCode() -> String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}

private struct TranslationSettingsSection: View {
    @AppStorage("glotty.sourceLang") private var sourceLang: String = ""
    @AppStorage("glotty.targetLang") private var targetLang: String = ""
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
                    ForEach(LanguageOptions.all) { option in
                        Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Default target language", selection: $targetLang) {
                    Text("Auto (based on source)").tag("")
                    ForEach(LanguageOptions.all) { option in
                        Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
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
                LabeledContent("Translation engine", value: String(localized: "Apple Translation (on-device)"))
                    .foregroundStyle(.secondary)
                Text("Other engines (DeepL, Google, Claude, GPT) coming after the spike validates the core flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Intelligence") {
                appleIntelligenceStatusRow
            }
        }
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

}

private struct DictionarySettingsSection: View {
    @AppStorage("glotty.sourceLang") private var sourceLang: String = ""
    @AppStorage("glotty.targetLang") private var targetLang: String = ""
    /// When ON, the translation popup renders every enabled dict that
    /// returned content (one card per dict, in priority order). When
    /// OFF, only the top-priority dict in each kind is shown — more
    /// compact but loses the per-dict comparison.
    @AppStorage("glotty.dictionary.showAllMatches")
    private var dictShowAll: Bool = true
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
        String(localized: "\(LanguageOptions.localizedName(for: effectivePair.source))-\(LanguageOptions.localizedName(for: effectivePair.target)) dictionaries")
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
                Toggle(isOn: $dictShowAll) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show all matching dictionaries")
                        Text("When off, only the top-priority dict in each kind (monolingual + bilingual) is shown in the translation popup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Display")
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
                        Text("Used for \(LanguageOptions.localizedName(for: effectivePair.source)) → \(LanguageOptions.localizedName(for: effectivePair.target))")
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
                            dictionaryArea(title: String(localized: "\(LanguageOptions.localizedName(for: effectivePair.source)) dictionaries"), dictionaries: sourceMonolingualDictionaries)
                            dictionaryArea(title: String(localized: "\(LanguageOptions.localizedName(for: effectivePair.target)) dictionaries"), dictionaries: targetMonolingualDictionaries)
                            dictionaryArea(title: String(localized: "Other dictionaries"), dictionaries: uncategorizedMonolingualDictionaries)
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
                    Text("\(LanguageOptions.localizedName(for: effectivePair.source)) → \(LanguageOptions.localizedName(for: effectivePair.target))")
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
                installDialogEmptyState
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        installDictionaryArea(title: bilingualDictionaryTitle, dictionaries: displayedBilingualInstallDictionaries)
                        installDictionaryArea(title: String(localized: "\(LanguageOptions.localizedName(for: effectivePair.source)) dictionaries"), dictionaries: displayedSourceMonolingualInstallDictionaries)
                        installDictionaryArea(title: String(localized: "\(LanguageOptions.localizedName(for: effectivePair.target)) dictionaries"), dictionaries: displayedTargetMonolingualInstallDictionaries)
                        installDictionaryArea(title: String(localized: "Other dictionaries"), dictionaries: displayedUncategorizedMonolingualInstallDictionaries)
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

    /// Look for the system Dictionary app on disk. macOS ships it at
    /// `/System/Applications/Dictionary.app` on modern releases; older
    /// builds (or certain restored systems) keep a copy at
    /// `/Applications/Dictionary.app`. Returns the first existing URL
    /// or nil if neither is present — which is the "user truly
    /// doesn't have Dictionary.app" case.
    private static func dictionaryAppURL() -> URL? {
        let candidates = [
            "/System/Applications/Dictionary.app",
            "/Applications/Dictionary.app",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Empty-state body for the Install Dictionary sheet. We split this
    /// into three cases so the user always has *something* to do —
    /// previously the dialog showed a one-line "No available
    /// dictionaries…" message and looked broken to users who don't
    /// have Dictionary.app or whose system catalog hasn't been
    /// primed yet.
    @ViewBuilder
    private var installDialogEmptyState: some View {
        let catalogEmpty = availableLibraryDictionaries.isEmpty
        let installable = languageMatchedLibraryDictionaries.filter { !isInstalled($0) }
        let dictAppURL = Self.dictionaryAppURL()
        VStack(spacing: 12) {
            Image(systemName: catalogEmpty
                  ? (dictAppURL == nil ? "exclamationmark.triangle" : "books.vertical")
                  : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(dictAppURL == nil && catalogEmpty ? .orange : .secondary)

            if catalogEmpty {
                // No catalog entries at all. Split on whether Apple's
                // Dictionary.app is present, since the action the user
                // can take differs sharply: opening the app vs.
                // recovering a missing system app.
                if let dictAppURL {
                    Text("No dictionaries are discoverable yet")
                        .font(.headline)
                    Text("Glotty reads the dictionary catalog Apple's built-in **Dictionary** app populates. Open it once — it pulls the available list down — then come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                    HStack(spacing: 8) {
                        Button("Open Dictionary.app") {
                            NSWorkspace.shared.open(dictAppURL)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Retry") {
                            loadLibraryDictionaries()
                        }
                    }
                } else {
                    // Dictionary.app genuinely isn't on disk. It ships
                    // with macOS and can't be re-installed via the App
                    // Store — the only real fixes are System Update or
                    // an OS reinstall. Surface that honestly rather
                    // than pretend a button can fix it.
                    Text("Dictionary.app is missing on this Mac")
                        .font(.headline)
                    Text("Glotty relies on Apple's built-in **Dictionary** app, normally at /System/Applications/Dictionary.app. It's part of macOS — to restore it, run a System Update or use Migration Assistant. Glotty's other features (Translate, Polish, Explain, Chat) still work without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                    HStack(spacing: 8) {
                        Button("Open System Settings → Software Update") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Apple Support") {
                            if let url = URL(string: "https://support.apple.com/guide/dictionary/welcome/mac") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } else if languageMatchedLibraryDictionaries.isEmpty {
                Text("No dictionaries for this language pair")
                    .font(.headline)
                Text("Glotty's catalog has \(availableLibraryDictionaries.count) dictionaries total, but none match **\(LanguageOptions.localizedName(for: effectivePair.source)) → \(LanguageOptions.localizedName(for: effectivePair.target))**. Try a different language pair, or clear the search to widen the list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            } else if installable.isEmpty {
                Text("Everything matching is already installed")
                    .font(.headline)
                Text("All dictionaries Glotty knows about for **\(LanguageOptions.localizedName(for: effectivePair.source)) → \(LanguageOptions.localizedName(for: effectivePair.target))** are already in your list — nothing new to add.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            } else {
                Text("No matches for the current search")
                    .font(.headline)
                Text("Clear the search field above to see all \(installable.count) installable dictionaries for this language pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
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
            case (.some(.monolingual), _): return "Mono".t + " ✓"
            case (.some(.bilingual), _):   return "Bi".t + " ✓"
            case (nil, .monolingual):      return "Mono".t
            case (nil, .bilingual):        return "Bi".t
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

}

private struct PolishOutputLanguageSection: View {
    @AppStorage("glotty.polishLang") private var polishLang: String = "en"
    /// Shown inline under the picker while the LLM is generating the
    /// mistake-category starter list for a freshly-picked language.
    /// Driven by `bootstrappingLanguage`; nil when nothing is running.
    @State private var bootstrappingLanguage: String?

    var body: some View {
        Section {
            Picker("Polish output language", selection: $polishLang) {
                // Same list every Glotty language picker uses — see
                // `LanguageOptions.all`. Single source of truth for
                // dropdown items app-wide.
                ForEach(LanguageOptions.all) { option in
                    Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            // Pre-warm mistake categories the moment the user commits
            // to a new polish target. One LLM call per language ever
            // (cached to disk). Lazy bootstrap in `runPolish` still
            // covers users who never visit Settings, but most polishes
            // will hit a warm cache thanks to this trigger.
            .onChange(of: polishLang) { _, newValue in
                primeCategoriesIfNeeded(for: newValue)
            }
            .onAppear { primeCategoriesIfNeeded(for: polishLang) }

            if let lang = bootstrappingLanguage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing mistake categories for \(LanguageOptions.localizedName(for: lang))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("The language Fn → R rewrites your selection into. Not the same as Translation's target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func primeCategoriesIfNeeded(for language: String) {
        guard PolishCategoryBootstrap.cached(for: language) == nil else { return }
        bootstrappingLanguage = language
        Task { @MainActor in
            _ = await PolishCategoryBootstrap.bootstrap(for: language)
            if bootstrappingLanguage == language {
                bootstrappingLanguage = nil
            }
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

/// Text-to-speech backend — the optional ElevenLabs cloud voice for Fn+V and
/// the popup speak buttons. Off by default (uses the on-device system voice).
private struct VoiceSettingsSection: View {
    @AppStorage(ElevenLabsTTS.enabledDefaultsKey) private var ttsEnabled: Bool = false
    @AppStorage(ElevenLabsTTS.voiceDefaultsKey)   private var voiceID: String = ElevenLabsTTS.defaultVoiceID
    @State private var elevenKey: String = ""
    @State private var elevenKeyStored: Bool = false
    @State private var voices: [ElevenLabsTTS.Voice] = []
    @State private var voicesLoading: Bool = false
    @State private var voicesError: String?
    @State private var cacheSize: Int = 0
    @State private var cachedItems: [VoiceCache.Entry] = []
    @State private var selectedClip: VoiceCache.Entry?

    private func loadVoices() async {
        guard let key = Keychain.read(account: ElevenLabsTTS.keychainAccount), !key.isEmpty else { return }
        voicesLoading = true
        voicesError = nil
        do {
            voices = try await ElevenLabsTTS.listVoices(apiKey: key)
            // The hardcoded default (Rachel, 21m00Tcm4TlvDq8ikWAM) is a Voice-
            // Library voice that free plans can't call via the API — every
            // Speak then 402s "payment_required". `listVoices` returns exactly
            // the voices THIS account/plan can use, so if the saved voice isn't
            // among them, switch to the first usable one automatically.
            if !voices.isEmpty, !voices.contains(where: { $0.id == voiceID }) {
                voiceID = voices[0].id
            }
        } catch {
            voicesError = String(format: String(localized: "Couldn't load voices: %@"),
                                 error.localizedDescription)
        }
        voicesLoading = false
    }

    var body: some View {
        Section {
            Toggle("Speak with ElevenLabs (cloud voice)", isOn: $ttsEnabled)
            HStack {
                SecureField("ElevenLabs API key", text: $elevenKey,
                            prompt: Text(elevenKeyStored
                                         ? "Key saved — paste to replace"
                                         : "Paste your ElevenLabs API key"))
                Button("Save") {
                    if Keychain.write(elevenKey, account: ElevenLabsTTS.keychainAccount) {
                        elevenKey = ""
                        elevenKeyStored = true
                        Task { await loadVoices() }
                    }
                }
                .disabled(elevenKey.isEmpty)
                if elevenKeyStored {
                    Button("Clear", role: .destructive) {
                        Keychain.delete(account: ElevenLabsTTS.keychainAccount)
                        elevenKey = ""
                        elevenKeyStored = false
                        voices = []
                    }
                }
            }
            if elevenKeyStored {
                Label("Key saved to Keychain.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                HStack {
                    Picker("Voice", selection: $voiceID) {
                        if !voices.contains(where: { $0.id == voiceID }) {
                            Text(voiceID == ElevenLabsTTS.defaultVoiceID ? "Default (Rachel)" : voiceID)
                                .tag(voiceID)
                        }
                        ForEach(voices) { v in Text(v.name).tag(v.id) }
                    }
                    Button {
                        Task { await loadVoices() }
                    } label: {
                        if voicesLoading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(voicesLoading)
                    .help("Load your ElevenLabs voices")
                }
                if let voicesError {
                    Text(voicesError).font(.caption).foregroundStyle(.red)
                }
            }
            if let url = URL(string: "https://elevenlabs.io/app/settings/api-keys") {
                Link("Get an ElevenLabs API key →", destination: url)
                    .font(.caption)
            }
            Button(role: .destructive) {
                VoiceCache.clear()
                cacheSize = 0
                cachedItems = []
            } label: {
                Text(String(format: String(localized: "Clear voice cache (%@)"),
                            ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)))
            }
            .disabled(cacheSize == 0)
        } header: {
            Text("Speech")
        } footer: {
            Text("Off → Fn+V uses the built-in macOS voice (offline, free). On (with a key) → Fn+V and the popup speak buttons use ElevenLabs: higher quality, but a network call billed to your own ElevenLabs plan. Falls back to the system voice if a request fails.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            elevenKeyStored = (Keychain.read(account: ElevenLabsTTS.keychainAccount).map { !$0.isEmpty } ?? false)
            cacheSize = VoiceCache.sizeBytes()
            cachedItems = VoiceCache.entries()
            if elevenKeyStored { Task { await loadVoices() } }
        }

        if !cachedItems.isEmpty {
            Section {
                ForEach(cachedItems) { item in
                    Button {
                        selectedClip = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle")
                                .foregroundStyle(.secondary)
                            Text(item.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Cached clips")
            }
            .sheet(item: $selectedClip) { entry in
                ClipPlaybackView(entry: entry)
            }
        }
    }
}

private struct HotkeySettingsSection: View {
    #if !MAS
    @AppStorage(Keycode.translateDefaultsKey) private var translateKey: Int = Keycode.defaultTranslate
    @AppStorage(Keycode.explainDefaultsKey)   private var explainKey:   Int = Keycode.defaultExplain
    @AppStorage(Keycode.polishDefaultsKey)    private var polishKey:    Int = Keycode.defaultPolish
    @AppStorage(Keycode.chatDefaultsKey)      private var chatKey:      Int = Keycode.defaultChat
    @AppStorage(Keycode.replaceDefaultsKey)   private var replaceKey:   Int = Keycode.defaultReplace
    @AppStorage(Keycode.speakDefaultsKey)     private var speakKey:     Int = Keycode.defaultSpeak
    @AppStorage(Keycode.leaderDefaultsKey)    private var leaderRaw:    String = Keycode.defaultLeader.rawValue
    @AppStorage(SelectionHoverWatcher.enabledKey) private var hoverEnabled: Bool = true
    @AppStorage(SelectionHoverWatcher.dwellKey)   private var hoverDwell: Double = SelectionHoverWatcher.defaultDwell

    private var leaderBinding: Binding<LeaderKey> {
        Binding(
            get: { LeaderKey(rawValue: leaderRaw) ?? Keycode.defaultLeader },
            set: { leaderRaw = $0.rawValue }
        )
    }

    private var hasCollision: Bool {
        let codes = [translateKey, explainKey, polishKey, chatKey, replaceKey, speakKey]
        return Set(codes).count < codes.count
    }
    #endif

    var body: some View {
        #if MAS
        masBody
        #else
        Section {
            LeaderRecorderRow(leader: leaderBinding,
                              defaultLeader: Keycode.defaultLeader)
        } header: {
            Text("Leader key")
        } footer: {
            Text("The leader is the first key of every shortcut. Hold it, then tap the command key below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            KeyRecorderRow(
                title: "Translate (target → native)",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $translateKey,
                defaultKeycode: Keycode.defaultTranslate
            )

            KeyRecorderRow(
                title: "Explain (LLM)",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $explainKey,
                defaultKeycode: Keycode.defaultExplain
            )

            KeyRecorderRow(
                title: "Polish to idiomatic",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $polishKey,
                defaultKeycode: Keycode.defaultPolish
            )

            KeyRecorderRow(
                title: "Chat with Glotty",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $chatKey,
                defaultKeycode: Keycode.defaultChat
            )

            KeyRecorderRow(
                title: "Correct spelling of selected word",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $replaceKey,
                defaultKeycode: Keycode.defaultReplace
            )

            KeyRecorderRow(
                title: "Speak the selection aloud",
                prefix: "\(leaderBinding.wrappedValue.label) →",
                keycode: $speakKey,
                defaultKeycode: Keycode.defaultSpeak
            )

            if hasCollision {
                Label("Two commands are bound to the same key — only the first will fire.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Press **Record**, then tap the key you want as the second step of the hotkey. **Esc** during recording cancels. **Reset** restores the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Show the action menu when hovering a selection", isOn: $hoverEnabled)
            if hoverEnabled {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $hoverDwell,
                               in: SelectionHoverWatcher.dwellRange, step: 0.1)
                            .frame(width: 160)
                        Text(String(format: "%.1fs", hoverDwell))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Hover delay")
                }
            }
        } header: {
            Text("Hover menu")
        } footer: {
            Text("Prefer not to memorize shortcuts? Select text, then rest the pointer on it for a moment — a menu with the same commands pops up to click. Works wherever the app exposes text to macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    #if MAS
    /// App Store build: no Fn-leader and no hover. Translate / Explain / Polish
    /// run on the selection through the macOS Services menu (right-click →
    /// Services) with default ⌘⌥ shortcuts that macOS manages; chat is a
    /// built-in ⌘⌥C global hotkey.
    @ViewBuilder
    private var masBody: some View {
        Section {
            LabeledContent("Translate") { shortcutTag("⌘⌥T") }
            LabeledContent("Explain") { shortcutTag("⌘⌥E") }
            LabeledContent("Polish") { shortcutTag("⌘⌥P") }
            LabeledContent("Chat") { shortcutTag("⌘⌥C") }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Translate, Explain, and Polish act on the selected text via the macOS Services menu (right-click → Services). Those shortcuts are managed by macOS — enable or rebind them in System Settings → Keyboard → Keyboard Shortcuts → Services. Chat (⌘⌥C) works anywhere and is built in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button("Open Keyboard Shortcuts…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func shortcutTag(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
    }
    #endif
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
        LabeledContent(title.t) {
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


/// Memory tab — shows what the user has been looking up and the grammar
/// mistakes that keep coming back through Polish. Reads from MemoryStore on
/// every appear; tapping Clear wipes the on-disk JSONL.
@MainActor
private struct MemorySettingsSection: View {
    /// Every MemoryEvent in the current time range, newest first. Replaces
    /// the old aggregate "Frequently looked up" rollup — each row is now a
    /// single event the user can click to reopen the popup they originally
    /// saw. Capped at `Self.historyDisplayLimit` for rendering cost.
    @State private var historyEvents: [MemoryEvent] = []
    @State private var topIssues: [MemoryAggregate] = []
    @State private var totalEvents: Int = 0
    @State private var recordingEnabled: Bool = MemoryStore.shared.isRecordingEnabled
    @State private var showingClearConfirmation = false

    /// Soft cap on how many rows the History section renders. Beyond this
    /// the user can either tighten the time range or wipe history.
    private static let historyDisplayLimit = 200
    /// Display-only filter — the underlying history isn't pruned, so toggling
    /// back to "All time" surfaces everything.
    @AppStorage("glotty.memory.range") private var rangeRaw: String = MemoryTimeRange.week.rawValue

    private var range: MemoryTimeRange {
        MemoryTimeRange(rawValue: rangeRaw) ?? .week
    }

    var body: some View {
        Group {
            Section {
                Toggle("Record history", isOn: $recordingEnabled)
                    .onChange(of: recordingEnabled) { _, newValue in
                        MemoryStore.shared.isRecordingEnabled = newValue
                    }
                Picker("Show records from", selection: $rangeRaw) {
                    ForEach(MemoryTimeRange.allCases) { range in
                        Text(range.label.t).tag(range.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: rangeRaw) { _, _ in refresh() }
                LabeledContent("Events recorded") {
                    Text("\(totalEvents)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Glotty saves what you searched and which mistakes Polish flagged. Stored locally in Application Support; never sent off-device. The time range only filters the lists below — history itself is never pruned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if historyEvents.isEmpty {
                    Text("No activity yet. Use Fn → T / E / P and your runs will show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historyEvents) { event in
                        historyRow(event)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { openEvent(event) }
                    }
                    if MemoryStore.shared.count > historyEvents.count {
                        Text("Showing the most recent \(historyEvents.count) of \(MemoryStore.shared.count) events. Narrow the time range above to see fewer.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Every translate, explain, and polish run, newest first. Click any row to reopen the original popup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Common mistake types section moved to Settings → Polish
            // (PolishCommonMistakesSection) — the data is polish-
            // specific so it lives next to the polish output language
            // picker now.

            Section {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear history…", systemImage: "trash")
                }
                .confirmationDialog(
                    "Clear all memory?",
                    isPresented: $showingClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear history", role: .destructive) {
                        MemoryStore.shared.clearAll()
                        refresh()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This deletes every recorded lookup and polish issue. Cannot be undone.")
                }
            }
        }
        .onAppear { refresh() }
    }

    /// Reopen the popup that produced a specific MemoryEvent. Replay is
    /// used when the event has the richer stored fields
    /// (`PopupReplayPayload.from` non-nil); otherwise the popup falls back
    /// to a live re-run.
    private func openEvent(_ event: MemoryEvent) {
        let replay = PopupReplayPayload.from(event)
        let mode: PopupMode
        switch event.kind {
        case .translate: mode = .translate
        case .explain:   mode = .explain
        case .polish:    mode = .polish
        }
        NSApp.activate(ignoringOtherApps: true)
        PopupController.shared.show(sourceText: event.sourceText, mode: mode, replay: replay)
    }

    private func refresh() {
        let cutoff = range.since()
        // History: every event in range, newest first, capped for render cost.
        let all = MemoryStore.shared.allEvents()
        let filtered = cutoff.map { c in all.filter { $0.timestamp >= c } } ?? all
        historyEvents = Array(filtered.reversed().prefix(Self.historyDisplayLimit))
        topIssues = MemoryStore.shared.topGrammarIssues(limit: 20, since: cutoff)
        totalEvents = MemoryStore.shared.count
        recordingEnabled = MemoryStore.shared.isRecordingEnabled
    }

    /// One row in the History section. Shows kind badge + source-text
    /// snippet + relative timestamp. The whole row is the Button label so
    /// any tap inside it triggers `openEvent`.
    @ViewBuilder
    private func historyRow(_ event: MemoryEvent) -> some View {
        HStack(spacing: 12) {
            Text(historyKindLabel(event.kind).t)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(historyKindColor(event.kind).opacity(0.18)))
                .foregroundStyle(historyKindColor(event.kind))
                .frame(minWidth: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.sourceText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let result = event.result, !result.isEmpty {
                    Text(result)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(relativeDate(event.timestamp))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func historyKindLabel(_ kind: MemoryEventKind) -> String {
        switch kind {
        case .translate: return "Translate"
        case .explain:   return "Explain"
        case .polish:    return "Polish"
        }
    }

    private func historyKindColor(_ kind: MemoryEventKind) -> Color {
        switch kind {
        case .translate: return .blue
        case .explain:   return .purple
        case .polish:    return .orange
        }
    }

    private func memoryRow(key: String, count: Int, lastSeen: Date) -> some View {
        HStack(spacing: 12) {
            // No `.textSelection` — it would intercept the parent row's
            // `.onTapGesture` (selectable Text wins drag/click in macOS).
            Text(key)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(relativeDate(lastSeen))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("\(count)x")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}


/// Chat tab — controls Glotty's proactive chat-reminder nudges.
/// The scheduler posts a macOS notification at the configured
/// interval; clicking it opens a fresh chat with Glotty (same surface
/// as Fn → C). Default is off, so Glotty only becomes proactive if
/// the user opts in.
@MainActor
private struct ChatSettingsSection: View {
    @AppStorage(ReminderScheduler.intervalKey)
    private var intervalMinutes: Int = ReminderScheduler.defaultIntervalMinutes
    /// Language Glotty replies in during Fn → C chats. Empty = unset, which
    /// falls back to the system language at runtime (see PopupView's
    /// `tutorReplyLanguage`). Same key the in-chat "Reply in" picker writes.
    @AppStorage("glotty.chat.tutorLanguage")
    private var chatLanguage: String = ""

    private struct Frequency: Hashable, Identifiable {
        let label: String
        let minutes: Int
        var id: Int { minutes }
    }
    private let frequencies: [Frequency] = [
        .init(label: "Off",           minutes: 0),
        .init(label: "Every hour",    minutes: 60),
        .init(label: "Every 4 hours", minutes: 240),
        .init(label: "Daily",         minutes: 1440),
        .init(label: "Weekly",        minutes: 10080),
    ]

    @State private var historyRefreshToken = 0

    var body: some View {
        Group {
            Section {
                Picker("Reply language", selection: $chatLanguage) {
                    Text(String(format: "System language (%@)".t,
                                LanguageOptions.localizedName(for: LanguageOptions.systemDefault())))
                        .tag("")
                    Divider()
                    ForEach(LanguageOptions.all) { option in
                        Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Chat language")
            } footer: {
                Text("The language Glotty replies in during Fn → C chats. Leave on \"System language\" to follow your Mac's language, or pick one to practice in. The in-chat picker changes this too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Reminder frequency", selection: $intervalMinutes) {
                    ForEach(frequencies) { f in
                        Text(f.label.t).tag(f.minutes)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: intervalMinutes) { _, _ in ReminderScheduler.shared.start() }

                Button("Send a chat reminder now") {
                    Task { await ReminderScheduler.shared.fireSessionNow() }
                }
            } header: {
                Text("Proactive chat reminders")
            } footer: {
                Text("Glotty posts a notification at the cadence you pick. Click the notification to open a chat in your target language. Same as triggering Fn → C manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            chatHistorySection
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatStore.didChangeNotification)) { _ in
            historyRefreshToken &+= 1
        }
    }

    private var chatHistorySection: some View {
        let threads = readThreads()
        return Section {
            if threads.isEmpty {
                Text("No chats yet. Trigger Fn → C to start one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(threads) { thread in
                    chatHistoryRow(thread)
                }
                HStack {
                    Spacer()
                    Button("Clear all", role: .destructive) {
                        ChatStore.shared.clearAll()
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            HStack {
                Text("History")
                if !threads.isEmpty {
                    Text("\(threads.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        } footer: {
            Text("One thread per day (boundary 4 AM local). Click a row to open a read-only view of that conversation. Today's chat resumes on Fn → C until 4 AM rollover.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chatHistoryRow(_ thread: DailyChatThread) -> some View {
        let preview = thread.turns.first(where: { $0.role == .user })?.reply
            ?? thread.turns.first?.reply
            ?? "(no messages)"
        let userTurns = thread.turns.filter { $0.role == .user }.count
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ChatDay.displayLabel(for: thread.dayKey))
                        .font(.callout.bold())
                    Text(String(format: "%@ from you".t, "\(userTurns)"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                ChatStore.shared.delete(id: thread.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete this day's chat")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            ChatHistoryWindowController.shared.show(threadID: thread.id)
        }
    }

    private func readThreads() -> [DailyChatThread] {
        _ = historyRefreshToken
        return ChatStore.shared.allThreads()
    }
}

// MARK: - Usage tab

/// Shows token-usage totals over a selectable time window (today / this week /
/// this month / all time), broken down by feature (translate/explain/polish/
/// chat) and by provider (Z.AI / Kimi). Data comes from `UsageStore`.
@MainActor
private struct UsageSettingsSection: View {
    @ObservedObject private var store = UsageStore.shared
    @State private var rangeSelection: RangeOption = .today
    @State private var showClearConfirm = false

    private enum RangeOption: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return String(localized: "Today")
            case .week:  return String(localized: "This week")
            case .month: return String(localized: "This month")
            case .all:   return String(localized: "All time")
            }
        }
        var cutoff: Date? {
            switch self {
            case .today: return UsageStore.startOfToday()
            case .week:  return UsageStore.startOfWeek()
            case .month: return UsageStore.startOfMonth()
            case .all:   return nil
            }
        }
    }

    var body: some View {
        Group {
            Section {
                Picker("Time range", selection: $rangeSelection) {
                    ForEach(RangeOption.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                let totals = store.totals(since: rangeSelection.cutoff)
                totalsCard(totals)
            } header: {
                Text("Token usage")
            } footer: {
                Text("Tokens consumed by the configured LLM provider. Stored locally at ~/Library/Application Support/Glotty/usage.jsonl.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("By feature") {
                let rows = store.byMode(since: rangeSelection.cutoff)
                if rows.isEmpty {
                    Text("No usage in this range.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.mode) { row in
                        breakdownRow(label: row.mode.displayName, totals: row.totals)
                    }
                }
            }

            Section("By provider") {
                let rows = store.byProvider(since: rangeSelection.cutoff)
                if rows.isEmpty {
                    Text("No usage in this range.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.provider) { row in
                        breakdownRow(label: providerLabel(row.provider), totals: row.totals)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear all usage history")
                    }
                    .disabled(store.events.isEmpty)
                }
            }
        }
        .confirmationDialog("Clear all token-usage history?",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded LLM call from local history. The setting cannot be undone.")
        }
    }

    private func totalsCard(_ t: UsageTotals) -> some View {
        // 2-column Grid so the second column (Calls / Completion) lines up
        // between rows regardless of the first column's text width. The
        // previous HStack-of-VStacks let each cell consume only its
        // intrinsic width, leaving the values out of alignment.
        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 14) {
            GridRow {
                metric(label: "Total tokens", value: numberFormatted(t.total), bold: true)
                metric(label: "Calls", value: numberFormatted(t.calls), bold: false)
            }
            GridRow {
                metric(label: "Prompt", value: numberFormatted(t.prompt), bold: false)
                metric(label: "Completion", value: numberFormatted(t.completion), bold: false)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(label: String, value: String, bold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.t)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(bold ? .title2 : .body)
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
        }
        // Make every metric cell occupy the full column width so the trailing
        // edge of the cell — not the trailing edge of its label — is what
        // separates "Total" from "Calls".
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdownRow(label: String, totals: UsageTotals) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%@ tokens · %@ calls".t,
                        numberFormatted(totals.total),
                        numberFormatted(totals.calls)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func numberFormatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Resolve a provider id to its human-readable display name. Asks the
    /// registry so stock presets, custom entries, and Kimi are all covered
    /// without per-provider branching here.
    private func providerLabel(_ id: String) -> String {
        LLMRegistry.displayName(for: id)
    }
}
