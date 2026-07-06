import Foundation

/// Versioned export/import format for Glotty settings + data. One
/// JSON file per backup, written via `NSSavePanel` and re-loaded via
/// `NSOpenPanel`. Designed for "moving to a new machine" or "rolling
/// back to a known-good state", not partial restore (the user picked
/// replace-on-import as the default behavior — see `BackupService`).
///
/// Included as of v2:
///   - API keys for every provider (read from Keychain). This makes
///     the bundle a complete machine-migration artifact — but also
///     sensitive, which is why exports are always password-encrypted
///     (see BackupCrypto). The plaintext bundle never touches disk.
///   - Dictionary + LLM provider settings (see BackupPreferences).
///
/// Excluded by design:
///   - Token usage (not requested).
///   - Model-list caches (re-fetched on demand; not worth persisting).
///   - Anything in Application Support that isn't an enumerated
///     store below — keeps the bundle deterministic / auditable.
struct BackupBundle: Codable {
    /// Constant magic value so import can sanity-check the file
    /// before attempting to apply.
    static let format = "glotty-backup"
    /// Bump when the bundle shape changes incompatibly. Importer
    /// accepts the current version and the listed older ones.
    /// v1 → v2: added `apiKeys` + dictionary/LLM preference keys.
    static let currentVersion = 2
    static let supportedVersions: Set<Int> = [1, 2]

    let format: String
    let version: Int
    let exportedAt: Date
    let appVersion: String

    let preferences: [String: BackupPreferenceValue]
    let memories: [LearnedMemory]
    let contexts: [MemoryContext]
    let chatThreads: [DailyChatThread]
    let historyEvents: [MemoryEvent]
    /// Keychain account → secret. Absent in v1 bundles, hence
    /// optional; defaults to empty on decode of an older file.
    let apiKeys: [String: String]

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, appVersion
        case preferences, memories, contexts, chatThreads, historyEvents, apiKeys
    }

    init(format: String, version: Int, exportedAt: Date, appVersion: String,
         preferences: [String: BackupPreferenceValue], memories: [LearnedMemory],
         contexts: [MemoryContext], chatThreads: [DailyChatThread],
         historyEvents: [MemoryEvent], apiKeys: [String: String]) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.preferences = preferences
        self.memories = memories
        self.contexts = contexts
        self.chatThreads = chatThreads
        self.historyEvents = historyEvents
        self.apiKeys = apiKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        preferences = try c.decode([String: BackupPreferenceValue].self, forKey: .preferences)
        memories = try c.decode([LearnedMemory].self, forKey: .memories)
        contexts = try c.decode([MemoryContext].self, forKey: .contexts)
        chatThreads = try c.decode([DailyChatThread].self, forKey: .chatThreads)
        historyEvents = try c.decode([MemoryEvent].self, forKey: .historyEvents)
        // v1 bundles predate apiKeys — tolerate its absence.
        apiKeys = try c.decodeIfPresent([String: String].self, forKey: .apiKeys) ?? [:]
    }
}

/// JSON-friendly type-preserving wrapper for UserDefaults values.
/// UserDefaults is a `[String: Any]`; for export we need to round-trip
/// through JSON. The types Glotty actually uses are limited to these
/// four, so we don't need full `AnyCodable`.
enum BackupPreferenceValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// A key whose UserDefaults value is raw `Data` (Codable structs
    /// the app persists itself — e.g. `glotty.customProviders`,
    /// `glotty.dictionarySelectionsByPairAndKind`). Stored base64.
    case data(Data)
    /// A container value (dictionary / array) that isn't scalar and
    /// isn't raw Data — e.g. `glotty.dictionaryKindOverrides`
    /// ([String:String]). Captured as a binary property list so any
    /// plist-representable structure round-trips. Stored base64.
    case plist(Data)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case string, int, double, bool, data, plist }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try c.encode(Kind.string, forKey: .type)
            try c.encode(v, forKey: .value)
        case .int(let v):
            try c.encode(Kind.int, forKey: .type)
            try c.encode(v, forKey: .value)
        case .double(let v):
            try c.encode(Kind.double, forKey: .type)
            try c.encode(v, forKey: .value)
        case .bool(let v):
            try c.encode(Kind.bool, forKey: .type)
            try c.encode(v, forKey: .value)
        case .data(let v):
            try c.encode(Kind.data, forKey: .type)
            try c.encode(v.base64EncodedString(), forKey: .value)
        case .plist(let v):
            try c.encode(Kind.plist, forKey: .type)
            try c.encode(v.base64EncodedString(), forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .string: self = .string(try c.decode(String.self, forKey: .value))
        case .int:    self = .int(try c.decode(Int.self, forKey: .value))
        case .double: self = .double(try c.decode(Double.self, forKey: .value))
        case .bool:   self = .bool(try c.decode(Bool.self, forKey: .value))
        case .data:
            let b64 = try c.decode(String.self, forKey: .value)
            self = .data(Data(base64Encoded: b64) ?? Data())
        case .plist:
            let b64 = try c.decode(String.self, forKey: .value)
            self = .plist(Data(base64Encoded: b64) ?? Data())
        }
    }

    /// Construct from a raw UserDefaults value. Scalars map to their
    /// case; raw `Data` maps to `.data`; any other plist-serializable
    /// container (dict/array) maps to `.plist`. Returns nil only for
    /// values that can't be represented at all.
    static func from(_ any: Any) -> BackupPreferenceValue? {
        // Bool check must come before Int — NSNumber satisfies both.
        if let b = any as? Bool, !(any is Int) { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        if let data = any as? Data { return .data(data) }
        // NSNumber that wasn't picked up above.
        if let n = any as? NSNumber {
            // CFBoolean special-case — NSNumber may wrap a Bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .int(n.intValue)
        }
        // Containers (dictionary / array) → binary plist.
        if PropertyListSerialization.propertyList(any, isValidFor: .binary),
           let plist = try? PropertyListSerialization.data(
               fromPropertyList: any, format: .binary, options: 0) {
            return .plist(plist)
        }
        return nil
    }

    /// The unwrapped value, suitable for `UserDefaults.set(_:forKey:)`.
    var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v):    return v
        case .double(let v): return v
        case .bool(let v):   return v
        case .data(let v):   return v
        case .plist(let v):
            return (try? PropertyListSerialization.propertyList(
                from: v, options: [], format: nil)) ?? Data()
        }
    }
}

/// Single source of truth for which UserDefaults keys belong to
/// Glotty (and therefore get included in / restored from the backup
/// bundle). Adding a new preference key elsewhere in the app means
/// adding it here too — without that, the key won't round-trip.
enum BackupPreferences {
    static let knownKeys: [String] = [
        // Profile
        "glotty.user.displayName",
        "glotty.user.about",
        "glotty.user.nativeLanguage",
        "glotty.user.pronouns",

        // Glotty persona (chat)
        "glotty.persona.name",
        "glotty.persona.manner",
        "glotty.persona.style",
        "glotty.persona.character",

        // Translation
        "glotty.sourceLang",
        "glotty.targetLang",

        // Polish
        "glotty.polishLang",

        // LLM provider selection + per-provider endpoint/model.
        // API keys themselves live in Keychain and are carried in
        // BackupBundle.apiKeys, not here.
        "glotty.llmProvider",
        "glotty.openai.endpoint",     "glotty.openai.model",
        "glotty.gemini.endpoint",     "glotty.gemini.model",
        "glotty.openrouter.endpoint", "glotty.openrouter.model",
        "glotty.zai.endpoint",        "glotty.zai.model",
        "glotty.grok.endpoint",       "glotty.grok.model",
        "glotty.deepseek.endpoint",   "glotty.deepseek.model",
        "glotty.kimi.endpoint",       "glotty.kimi.model",
        "glotty.minimax.endpoint",    "glotty.minimax.model",
        "glotty.customProviders",     // [CustomProviderConfig] as Data

        // Chat / tutor behavior
        "glotty.chat.tutorLanguage",
        "glotty.chat.autoApproveTools",
        "glotty.chat.allowSettingsChanges",

        // Dictionary selection + classification
        "glotty.dictionary.showAllMatches",
        "glotty.dictionaries.guidanceShown",
        "glotty.dictionaryKindOverrides",            // [String:String]
        "glotty.dictionarySelectionsByPairAndKind",  // Data
        "glotty.dictionarySelectionsByPair",         // legacy Data

        // Prompt template overrides (rare — power-user)
        "glotty.explainPrompt",
        "glotty.polishPrompt.variants",
        "glotty.polishPrompt.proofread",
        "glotty.quizPrompt",

        // Hotkeys
        "glotty.hotkey.translate",
        "glotty.hotkey.express",   // legacy persisted name for "explain"
        "glotty.hotkey.polish",
        "glotty.hotkey.chat",
        "glotty.hotkey.leader",

        // Chat reminders
        "glotty.reminder.intervalMinutes",

        // Memory
        "glotty.memory.enabled",            // history-recording toggle
        "glotty.memory.extractionMode",     // auto / manual / off
        "glotty.memory.activeContextID",
        "glotty.memory.range",              // history/mistakes time window

        // App / UI
        "glotty.systemLanguage",            // in-app UI language override
    ]

    /// Glotty UserDefaults keys that are deliberately NOT part of a backup:
    /// transient launch/relaunch coordination flags and device-local
    /// onboarding state. Listed explicitly so the debug audit
    /// (`auditUnknownKeys`) can tell "intentionally skipped" apart from
    /// "someone added a setting and forgot the whitelist".
    static let excludedKeys: Set<String> = [
        "glotty.settings.launchRegular",
        "glotty.settings.reopenOnLaunch",
        "glotty.welcome.reopenOnLaunch",
        "glotty.relaunch.reopenChat",
        "glotty.welcomeShown",              // device-local onboarding flag
    ]

    /// DEBUG-only guard against the whitelist silently falling behind the
    /// app. Scans live UserDefaults for `glotty.*` keys that are neither
    /// backed up (`knownKeys`) nor explicitly excluded (`excludedKeys`) and
    /// logs a warning naming each one. A new setting then surfaces during
    /// development instead of quietly not travelling with backups. No-op in
    /// release builds.
    static func auditUnknownKeys() {
        #if DEBUG
        let known = Set(knownKeys)
        let unknown = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("glotty.") }
            .filter { !known.contains($0) && !excludedKeys.contains($0) }
            .sorted()
        guard !unknown.isEmpty else { return }
        Log.debug(.settings, "backup whitelist gap — these glotty.* keys are in "
                  + "UserDefaults but neither in knownKeys nor excludedKeys; add "
                  + "them to one or the other: \(unknown.joined(separator: ", "))",
                  op: "audit")
        #endif
    }
}
