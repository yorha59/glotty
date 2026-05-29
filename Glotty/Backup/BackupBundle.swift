import Foundation

/// Versioned export/import format for Glotty settings + data. One
/// JSON file per backup, written via `NSSavePanel` and re-loaded via
/// `NSOpenPanel`. Designed for "moving to a new machine" or "rolling
/// back to a known-good state", not partial restore (the user picked
/// replace-on-import as the default behavior — see `BackupService`).
///
/// Excluded by design:
///   - API keys (live in Keychain; bundle would become sensitive).
///   - Token usage (not requested).
///   - Anything in Application Support that isn't an enumerated
///     store below — keeps the bundle deterministic / auditable.
struct BackupBundle: Codable {
    /// Constant magic value so import can sanity-check the file
    /// before attempting to apply.
    static let format = "glotty-backup"
    /// Bump when the bundle shape changes incompatibly. Importer
    /// rejects unknown versions to avoid silent data loss.
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let appVersion: String

    let preferences: [String: BackupPreferenceValue]
    let memories: [LearnedMemory]
    let contexts: [MemoryContext]
    let chatThreads: [DailyChatThread]
    let historyEvents: [MemoryEvent]
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

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case string, int, double, bool }

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
        }
    }

    /// Construct from a raw UserDefaults value if it's one of the
    /// supported scalar types. Returns nil for arrays / dicts / data
    /// — Glotty doesn't currently store those as preferences, so a
    /// nil return signals "skip this key".
    static func from(_ any: Any) -> BackupPreferenceValue? {
        // Bool check must come before Int — NSNumber satisfies both.
        if let b = any as? Bool, !(any is Int) { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        // NSNumber that wasn't picked up above.
        if let n = any as? NSNumber {
            // CFBoolean special-case — NSNumber may wrap a Bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .int(n.intValue)
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

        // Practice / chat reminders
        "glotty.practice.intervalMinutes",

        // Memory
        "glotty.memory.enabled",            // history-recording toggle
        "glotty.memory.extractionMode",     // auto / manual / off
        "glotty.memory.activeContextID",
    ]
}
