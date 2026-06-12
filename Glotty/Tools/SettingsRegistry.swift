import Foundation

/// Designed to be MCP-shaped without actually running an MCP server:
/// every entry has a stable string id, a JSON-schema-style value
/// descriptor, a sensitivity tier, and uniform read / write closures.
/// If we later expose Glotty as a real MCP server, this registry can
/// be re-served via a thin wrapper without rewriting the entries.
///
/// Today, the only consumer is the chat tutor (Fn → C). When the LLM
/// emits a `set_setting` tool call, the tutor's confirmation pipeline
/// validates the key + value against this registry, shows a Confirm
/// card, and applies via the entry's `write` closure on success.

/// Allowed value shape for one setting. JSON-schema flavored so the
/// LLM prompt can describe what counts as valid, and the parser can
/// reject out-of-range values before the user is asked to confirm.
enum SettingValueKind: Sendable {
    /// One of a fixed set of values. `options` is the canonical list;
    /// `display` (optional) maps each option to a localized label for
    /// the confirmation card.
    case enumeration(options: [String], display: [String: String] = [:])
    /// Free-form string. `placeholder` is a hint for the LLM.
    case freeformString(placeholder: String)
    /// Integer with inclusive lower / upper bounds.
    case integer(min: Int, max: Int)
    /// Boolean true / false.
    case boolean
}

/// Confirmation effort required before applying a change.
enum SettingSensitivity: Sendable {
    /// Single Confirm tap is enough. Lang pickers, persona, etc.
    case normal
    /// Two-step confirm with a warning row. Provider / API key / hotkey.
    /// NOT IMPLEMENTED IN V1 — kept on the type so we can declare
    /// sensitivities up front and the UI layer can grow into it.
    case sensitive
    /// Chat cannot touch this setting at all. `set_setting` requests
    /// targeting a blocked entry are rejected by the validator with a
    /// system turn pointing the user back to Settings. Used for
    /// destructive ops ("Clear all memory") and the LLM provider /
    /// API key surface (changing those mid-chat would break the
    /// chat itself).
    case blocked
}

/// One setting the chat agent can read / write.
struct SettingEntry: Sendable {
    /// Stable id used in tool-call args. Lowercase snake_case so the
    /// LLM produces consistent values across rephrasings. Doesn't
    /// have to match the UserDefaults key — many entries do, some
    /// route through Keychain or a custom subsystem.
    let id: String
    /// Localized user-facing name for the confirmation card.
    let displayName: String
    /// Plain English description for the LLM. One sentence — explain
    /// what the setting controls and (when relevant) how it relates
    /// to other settings.
    let description: String
    let kind: SettingValueKind
    let sensitivity: SettingSensitivity
    /// Read the current persisted value. Returns nil when no value
    /// has been written yet (LLM gets "(unset)" in the prompt).
    /// Not @Sendable — the whole registry is @MainActor, so these
    /// closures always run on main and can capture main-isolated state
    /// (MemoryContextStore, SystemLanguageManager) directly.
    let read: () -> String?
    /// Persist a validated value. Validation has already happened by
    /// the time this is invoked — the closure can assume the input
    /// matches `kind`'s constraints.
    let write: (String) -> Void
    /// Optional human-readable rendering of a value for the
    /// confirmation card. Defaults to the raw value when nil.
    /// (e.g. `"zh-Hans" → "简体中文"`.)
    let displayValue: ((String) -> String)?
    /// Extra sentence appended to the system turn after the user
    /// confirms. Use for settings whose effect isn't immediate (e.g.
    /// system language requires a relaunch). Nil for the common case
    /// where the change takes effect right away via `@AppStorage`.
    let postApplyNote: String?
    /// True when applying this setting requires the app to relaunch
    /// before the user sees the effect. The confirmation badge
    /// shows a "Relaunch now" button when this is set, on top of
    /// the `postApplyNote` text. Settings that take effect via
    /// `@AppStorage` KVO leave this false.
    let requiresRelaunch: Bool

    init(
        id: String,
        displayName: String,
        description: String,
        kind: SettingValueKind,
        sensitivity: SettingSensitivity,
        read: @escaping () -> String?,
        write: @escaping (String) -> Void,
        displayValue: ((String) -> String)? = nil,
        postApplyNote: String? = nil,
        requiresRelaunch: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.kind = kind
        self.sensitivity = sensitivity
        self.read = read
        self.write = write
        self.displayValue = displayValue
        self.postApplyNote = postApplyNote
        self.requiresRelaunch = requiresRelaunch
    }
}

/// Outcome of a validation attempt on a setting key + value.
enum SettingValidation: Sendable {
    case ok
    case unknownSetting
    case blocked(reason: String)
    case invalidValue(reason: String)
}

/// All settings the chat agent is aware of.
/// `@MainActor` because the dynamic entries touch main-isolated stores
/// (`MemoryContextStore`, `SystemLanguageManager`, …). All callers
/// (`SettingsView`, `PopupView`, the chat turn pipeline) already run
/// on main, so this is a constraint that lines up with reality.
@MainActor
enum SettingsRegistry {
    static var all: [SettingEntry] { Self.buildAll() }

    static func find(id: String) -> SettingEntry? {
        all.first { $0.id == id }
    }

    /// Validate a `set_setting` request before showing the
    /// confirmation card. Returns the resolved entry on success so
    /// the caller doesn't have to look it up again.
    static func validate(id: String, value: String) -> (SettingEntry?, SettingValidation) {
        guard let entry = find(id: id) else {
            return (nil, .unknownSetting)
        }
        if case .blocked = entry.sensitivity {
            return (entry, .blocked(reason: "This setting can only be changed from Settings."))
        }
        switch entry.kind {
        case .enumeration(let options, _):
            if !options.contains(value) {
                return (entry, .invalidValue(reason: "Allowed values: \(options.joined(separator: ", "))."))
            }
        case .integer(let min, let max):
            guard let n = Int(value) else {
                return (entry, .invalidValue(reason: "Expected an integer."))
            }
            if n < min || n > max {
                return (entry, .invalidValue(reason: "Value must be between \(min) and \(max)."))
            }
        case .boolean:
            if !["true", "false"].contains(value.lowercased()) {
                return (entry, .invalidValue(reason: "Expected `true` or `false`."))
            }
        case .freeformString:
            // No content-level validation; the write closure handles
            // any subsystem-specific normalisation (trimming etc.).
            break
        }
        return (entry, .ok)
    }

    /// Snapshot of `(id, current value)` pairs for every non-blocked
    /// entry, formatted for direct injection into the chat prompt's
    /// "available settings" section. Excludes blocked entries since
    /// the LLM can't change them anyway.
    static func snapshotForPrompt() -> [(entry: SettingEntry, currentValue: String?)] {
        all
            .filter { entry in
                if case .blocked = entry.sensitivity { return false }
                return true
            }
            .map { ($0, $0.read()) }
    }

    /// JSON-schema-ish description of what a single setting accepts,
    /// suitable for embedding in the prompt or a future MCP
    /// `inputSchema`. Returns a short human-readable line for now —
    /// we'll lift it to actual JSON Schema when we expose this as
    /// MCP.
    static func describe(kind: SettingValueKind) -> String {
        switch kind {
        case .enumeration(let options, _):
            return "one of: " + options.joined(separator: ", ")
        case .freeformString(let placeholder):
            return "string — \(placeholder)"
        case .integer(let min, let max):
            return "integer between \(min) and \(max)"
        case .boolean:
            return "true / false"
        }
    }

    // MARK: - Registry contents
    //
    // Build the list dynamically so each entry can capture its own
    // defaults / closures without a sprawling static initialiser.
    private static func buildAll() -> [SettingEntry] {
        var entries: [SettingEntry] = []

        // MARK: Languages — all four use the same picker shape
        entries.append(.languagePicker(
            id: "polish_output_language",
            defaultsKey: "glotty.polishLang",
            displayName: String(localized: "Polish output language"),
            description: "The language Fn → R rewrites the user's selection into."
        ))
        entries.append(.languagePicker(
            id: "native_language",
            defaultsKey: "glotty.user.nativeLanguage",
            displayName: String(localized: "Native language"),
            description: "The language the user speaks natively. Drives default translation direction and prompt phrasing, is the language Fn → E (Explain) renders its explanations in, and — unless the user has explicitly picked one — also becomes Glotty's UI language on the next launch."
        ))

        // Translation defaults use the "+ sentinel" variant — empty
        // string on disk means "auto-detect", surfaced to the LLM as
        // a real option so it can say "stop pinning, let it auto".
        entries.append(.languagePickerWithSentinel(
            id: "default_translation_source",
            defaultsKey: "glotty.sourceLang",
            displayName: String(localized: "Default source language"),
            description: "The source language pinned for Fn → T translations. `auto` (default) lets Glotty detect per-selection.",
            sentinelID: "auto",
            sentinelLabel: String(localized: "Auto detect")
        ))
        entries.append(.languagePickerWithSentinel(
            id: "default_translation_target",
            defaultsKey: "glotty.targetLang",
            displayName: String(localized: "Default target language"),
            description: "The target language pinned for Fn → T translations. `auto` (default) picks based on the detected source.",
            sentinelID: "auto",
            sentinelLabel: String(localized: "Auto detect")
        ))
        entries.append(.languagePicker(
            id: "chat_reply_language",
            defaultsKey: "glotty.chat.tutorLanguage",
            displayName: String(localized: "Chat reply language"),
            description: "The language Glotty replies in during chat. Pin to a specific BCP-47 language code (`en`, `zh-Hans`, etc.). When unset (empty string on disk), chat reply falls back to the user's native language."
        ))

        // MARK: Profile
        entries.append(.freeformString(
            id: "display_name",
            defaultsKey: "glotty.user.displayName",
            displayName: String(localized: "Display name"),
            description: "What Glotty should call the user in chat replies.",
            placeholder: "the user's preferred name"
        ))
        entries.append(.enumeration(
            id: "pronouns",
            defaultsKey: "glotty.user.pronouns",
            displayName: String(localized: "Pronouns"),
            description: "Third-person pronouns Glotty uses when referring to the user. Empty string means prefer not to say.",
            options: ["", "he/him", "she/her"]
        ))
        entries.append(.freeformString(
            id: "about_me",
            defaultsKey: LearnedMemoryStore.userNotesKey,
            displayName: String(localized: "About you"),
            description: "Free-form notes about the user — interests, goals, what they're learning and why — that Glotty keeps in mind during chat. Update this when the user shares lasting context about themselves.",
            placeholder: "a short bio / notes about the user"
        ))

        // MARK: Persona
        entries.append(.freeformString(
            id: "persona_name",
            defaultsKey: GlottyPersona.DefaultsKey.name,
            displayName: String(localized: "Glotty's name"),
            description: "The name the chat persona introduces itself with. Default is `Glotty`.",
            placeholder: "the persona's display name"
        ))
        entries.append(.enumeration(
            id: "persona_manner",
            defaultsKey: GlottyPersona.DefaultsKey.manner,
            displayName: String(localized: "Persona manner"),
            description: "Tone the chat persona uses — warm / casual / playful / professional / formal.",
            options: GlottyPersona.Manner.allCases.map(\.rawValue)
        ))
        entries.append(.enumeration(
            id: "persona_style",
            defaultsKey: GlottyPersona.DefaultsKey.style,
            displayName: String(localized: "Speaking style"),
            description: "How long the persona's replies should be — brief / chatty / detailed.",
            options: GlottyPersona.Style.allCases.map(\.rawValue)
        ))

        // MARK: Dictionary display
        entries.append(.boolean(
            id: "show_all_dictionaries",
            defaultsKey: "glotty.dictionary.showAllMatches",
            displayName: String(localized: "Show all matching dictionaries"),
            description: "When true, the translation popup renders every enabled dictionary that has content for the selection. When false, only the top-priority dictionary in each kind (monolingual / bilingual) is shown."
        ))

        // MARK: Hover action menu
        // Default-true boolean, so we read via `object(forKey:)` rather than
        // the `.boolean` factory (which returns false for an unset key).
        entries.append(SettingEntry(
            id: "hover_menu",
            displayName: String(localized: "Hover action menu"),
            description: "Whether resting the pointer on a text selection pops up the action menu (Translate / Explain / Polish / Chat / Correct spelling). On by default.",
            kind: .boolean,
            sensitivity: .normal,
            read: {
                (UserDefaults.standard.object(forKey: SelectionHoverWatcher.enabledKey) as? Bool ?? true)
                    ? "true" : "false"
            },
            write: {
                UserDefaults.standard.set($0.lowercased() == "true", forKey: SelectionHoverWatcher.enabledKey)
            }
        ))
        let dwellMinMs = Int(SelectionHoverWatcher.dwellRange.lowerBound * 1000)
        let dwellMaxMs = Int(SelectionHoverWatcher.dwellRange.upperBound * 1000)
        entries.append(SettingEntry(
            id: "hover_delay_ms",
            displayName: String(localized: "Hover delay"),
            description: "How long (in milliseconds) the pointer must rest on a selection before the hover action menu appears. Only relevant when the hover menu is on.",
            kind: .integer(min: dwellMinMs, max: dwellMaxMs),
            sensitivity: .normal,
            read: {
                let v = UserDefaults.standard.object(forKey: SelectionHoverWatcher.dwellKey) as? Double
                    ?? SelectionHoverWatcher.defaultDwell
                return String(Int((v * 1000).rounded()))
            },
            write: { value in
                if let ms = Int(value) {
                    UserDefaults.standard.set(Double(ms) / 1000.0, forKey: SelectionHoverWatcher.dwellKey)
                }
            },
            displayValue: { ms in Int(ms).map { "\($0) ms" } ?? ms }
        ))

        // MARK: System (UI) language
        // Special: writing this updates AppleLanguages too, and the
        // change only fully takes effect after a relaunch. We do the
        // write here (so the next launch picks it up); the system
        // turn after confirmation tells the user a relaunch is
        // needed. We don't auto-relaunch — would kill an active chat.
        let systemLangOptions = SystemLanguage.allCases.map(\.rawValue)
        let systemLangDisplay: [String: String] = Dictionary(
            uniqueKeysWithValues: SystemLanguage.allCases.map { ($0.rawValue, $0.displayName) }
        )
        entries.append(SettingEntry(
            id: "system_language",
            displayName: String(localized: "Glotty's UI language"),
            description: "The language Glotty itself uses for buttons, menus, settings. Takes effect after a relaunch. Use `system` to follow the OS preference.",
            kind: .enumeration(options: systemLangOptions, display: systemLangDisplay),
            sensitivity: .normal,
            read: { UserDefaults.standard.string(forKey: SystemLanguageManager.defaultsKey) },
            write: { value in
                if let lang = SystemLanguage(rawValue: value) {
                    Task { @MainActor in SystemLanguageManager.set(lang) }
                }
            },
            displayValue: { value in
                SystemLanguage(rawValue: value)?.displayName ?? value
            },
            postApplyNote: String(localized: "Relaunch Glotty for the change to take effect."),
            requiresRelaunch: true
        ))

        // MARK: Active memory context
        // Contexts are user-named scopes (Work, Travel, ...). Active
        // context's memories inject alongside Global ones; switching
        // is a frequent ask, so the chat agent can do it.
        // Options are built dynamically from the current store —
        // when the user creates a new context in Settings, it shows
        // up here on the next registry build without any other code
        // change. "none" disables scoped injection.
        let contextStore = MemoryContextStore.shared
        let contextOptions: [String] = ["none"] + contextStore.all().map(\.name)
        var contextDisplay: [String: String] = ["none": String(localized: "None (global only)")]
        for ctx in contextStore.all() { contextDisplay[ctx.name] = ctx.name }
        entries.append(SettingEntry(
            id: "active_memory_context",
            displayName: String(localized: "Active memory context"),
            description: "Which named memory context is active. The active context's scoped memories inject alongside global ones. `none` means only global memories inject.",
            kind: .enumeration(options: contextOptions, display: contextDisplay),
            sensitivity: .normal,
            read: {
                if let active = contextStore.active { return active.name }
                return "none"
            },
            write: { value in
                Task { @MainActor in
                    if value == "none" {
                        contextStore.activeContextID = nil
                    } else if let match = contextStore.all().first(where: { $0.name == value }) {
                        contextStore.activeContextID = match.id
                    }
                }
            },
            displayValue: { name in contextDisplay[name] ?? name }
        ))

        // MARK: Memory + reminders
        entries.append(.enumeration(
            id: "memory_extraction_mode",
            defaultsKey: "glotty.memory.extractionMode",
            displayName: String(localized: "Memory extraction"),
            description: "When Glotty proposes new memories from chats — auto (after every reply), manual (only on explicit request), off.",
            options: MemoryExtractor.Mode.allCases.map(\.rawValue)
        ))
        entries.append(.integer(
            id: "reminder_interval_minutes",
            defaultsKey: ReminderScheduler.intervalKey,
            displayName: String(localized: "Chat reminder frequency"),
            description: "How often (in minutes) the proactive chat reminder fires. 0 disables reminders entirely.",
            min: 0,
            max: 1440,
            // Reschedule so the new interval kicks in immediately;
            // without this the next fire still uses the old gap.
            onChange: { ReminderScheduler.shared.start() }
        ))

        // MARK: Model (active provider only)
        // The model choice is per-provider — switching the model key
        // for ZAI doesn't affect Kimi. We register exactly one entry
        // for whichever provider the user is currently running, so
        // the LLM doesn't see two near-identical options and the
        // valid-values list always matches the active backend.
        // Provider switching itself stays blocked (see below).
        let activeProviderID = LLMRegistry.currentProviderID()
        // Resolve the active provider to (options, ud-key, description) so the
        // registry entry covers every provider type without per-id branching.
        // Stock OpenAI-compatible presets share a uniform shape; DeepSeek and
        // Kimi are dedicated classes with their own model lists.
        let modelSpec: (options: [(id: String, name: String)],
                        userDefaultsKey: String,
                        description: String)?
        if let preset = OpenAIStockPresets.find(id: activeProviderID) {
            modelSpec = (
                options: preset.models.map { ($0.id, $0.displayName) },
                userDefaultsKey: preset.modelUserDefaultsKey,
                description: "The \(preset.displayName) model used for polish, explain, and chat. Switching takes effect on the next LLM call."
            )
        } else if activeProviderID == "deepseek" {
            modelSpec = (
                options: DeepSeekProvider.supportedModels.map { ($0.id, $0.displayName) },
                userDefaultsKey: "glotty.deepseek.model",
                description: "The DeepSeek model used for polish, explain, and chat. Switching takes effect on the next LLM call."
            )
        } else if activeProviderID == "kimi-coding" {
            modelSpec = (
                options: KimiCodingProvider.supportedModels.map { ($0.id, $0.displayName) },
                userDefaultsKey: "glotty.kimi.model",
                description: "The Kimi model used for polish, explain, and chat. Switching takes effect on the next LLM call."
            )
        } else if activeProviderID == "minimax-coding" {
            modelSpec = (
                options: MiniMaxCodingProvider.supportedModels.map { ($0.id, $0.displayName) },
                userDefaultsKey: "glotty.minimax.model",
                description: "The MiniMax model used for polish, explain, and chat. Switching takes effect on the next LLM call."
            )
        } else {
            // Custom OpenAI-compatible providers don't have an enumerated
            // model list — the user supplies a free-text model id when they
            // create the entry. Skip registration.
            modelSpec = nil
        }
        if let spec = modelSpec {
            let display: [String: String] = Dictionary(
                uniqueKeysWithValues: spec.options.map { ($0.id, $0.name) }
            )
            entries.append(SettingEntry(
                id: "model",
                displayName: String(localized: "Model"),
                description: spec.description,
                kind: .enumeration(options: spec.options.map(\.id), display: display),
                sensitivity: .normal,
                read: { UserDefaults.standard.string(forKey: spec.userDefaultsKey) },
                write: { UserDefaults.standard.set($0, forKey: spec.userDefaultsKey) },
                displayValue: { id in display[id] ?? id }
            ))
        }

        // MARK: Blocked — surface to the prompt as "ask in Settings"
        // so the LLM doesn't pretend it can change these.
        entries.append(SettingEntry(
            id: "llm_provider",
            displayName: String(localized: "LLM provider"),
            description: "The cloud LLM service Glotty calls for polish / explain / chat. Changing it can break the running chat — user must update in Settings.",
            kind: .freeformString(placeholder: "provider id"),
            sensitivity: .blocked,
            read: { UserDefaults.standard.string(forKey: "glotty.llm.providerID") },
            write: { _ in }
        ))
        entries.append(SettingEntry(
            id: "api_key",
            displayName: String(localized: "API key"),
            description: "Secret credential for the LLM provider. Stored in macOS Keychain; never changed from chat.",
            kind: .freeformString(placeholder: "secret"),
            sensitivity: .blocked,
            read: { nil },
            write: { _ in }
        ))

        return entries
    }
}
