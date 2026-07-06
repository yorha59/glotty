import Foundation

/// Factory functions on `SettingEntry` for the common shapes. Most
/// settings are "a UserDefaults key + a kind + a display name" —
/// these factories collapse that to one call so the registry stays
/// scannable. The handful of genuinely special entries (model,
/// system_language, api_key, llm_provider, active_memory_context)
/// still use the full `SettingEntry` initialiser directly because
/// each is special in its own way and a factory wouldn't fit.
///
/// All factories are `@MainActor` because:
///   - `SettingsRegistry` is `@MainActor`
///   - The captured closures touch `UserDefaults` which is global
///     but the surrounding code expects main-actor access
@MainActor
extension SettingEntry {
    // MARK: - Language pickers
    //
    // Languages are the most common shape: an enum picker whose
    // options + display names come from `LanguageOptions.all`. Two
    // factory variants:
    //   1. `.languagePicker(...)` — straight `langOptions / langDisplay`
    //   2. `.languagePickerWithSentinel(...)` — like above but with
    //      an extra sentinel option at the head ("auto", "polish_target",
    //      etc.) that gets translated to / from the empty string on
    //      disk. Lets a single picker express "follow the default"
    //      and "pin to a specific language" in one menu.

    static func languagePicker(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String
    ) -> SettingEntry {
        let opts = LanguageOptions.all.map(\.id)
        let display = Dictionary(uniqueKeysWithValues: LanguageOptions.all
            .map { ($0.id, LanguageOptions.localizedName(for: $0.id)) })
        return SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .enumeration(options: opts, display: display),
            sensitivity: .normal,
            read: { UserDefaults.standard.string(forKey: defaultsKey) },
            write: { UserDefaults.standard.set($0, forKey: defaultsKey) },
            displayValue: { LanguageOptions.localizedName(for: $0) }
        )
    }

    static func languagePickerWithSentinel(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String,
        sentinelID: String,
        sentinelLabel: String
    ) -> SettingEntry {
        let opts = [sentinelID] + LanguageOptions.all.map(\.id)
        var display = Dictionary(uniqueKeysWithValues: LanguageOptions.all
            .map { ($0.id, LanguageOptions.localizedName(for: $0.id)) })
        display[sentinelID] = sentinelLabel
        return SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .enumeration(options: opts, display: display),
            sensitivity: .normal,
            read: {
                let v = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
                return v.isEmpty ? sentinelID : v
            },
            write: { value in
                UserDefaults.standard.set(value == sentinelID ? "" : value,
                                          forKey: defaultsKey)
            },
            displayValue: { id in display[id] ?? LanguageOptions.localizedName(for: id) }
        )
    }

    // MARK: - Simple shapes

    /// Free-form string setting. Trims whitespace on write — every
    /// freeform setting we have today does this, so it's the default.
    static func freeformString(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String,
        placeholder: String
    ) -> SettingEntry {
        SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .freeformString(placeholder: placeholder),
            sensitivity: .normal,
            read: { UserDefaults.standard.string(forKey: defaultsKey) },
            write: { UserDefaults.standard.set($0.trimmingCharacters(in: .whitespacesAndNewlines),
                                               forKey: defaultsKey) }
        )
    }

    /// Enumeration over a fixed `[String]` of allowed values. Optional
    /// `display` maps values to their localized labels for the
    /// confirmation card. Use this for small fixed enums (pronouns,
    /// persona manner / style, memory extraction mode).
    static func enumeration(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String,
        options: [String],
        display: [String: String] = [:]
    ) -> SettingEntry {
        SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .enumeration(options: options, display: display),
            sensitivity: .normal,
            read: { UserDefaults.standard.string(forKey: defaultsKey) },
            write: { UserDefaults.standard.set($0, forKey: defaultsKey) },
            displayValue: display.isEmpty ? nil : { display[$0] ?? $0 }
        )
    }

    /// Integer with a closed-range constraint. Optional `onChange`
    /// runs after the value is persisted — used for settings that
    /// need to kick something else (e.g. restart the reminder
    /// scheduler so the new interval takes effect immediately).
    static func integer(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String,
        min: Int,
        max: Int,
        onChange: (() -> Void)? = nil
    ) -> SettingEntry {
        SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .integer(min: min, max: max),
            sensitivity: .normal,
            read: { String(UserDefaults.standard.integer(forKey: defaultsKey)) },
            write: { value in
                UserDefaults.standard.set(Int(value) ?? 0, forKey: defaultsKey)
                onChange?()
            }
        )
    }

    /// Boolean toggle. Stores `Bool` directly via UserDefaults;
    /// converts to/from the registry's string-typed `value` arg.
    static func boolean(
        id: String,
        defaultsKey: String,
        displayName: String,
        description: String
    ) -> SettingEntry {
        SettingEntry(
            id: id,
            displayName: displayName,
            description: description,
            kind: .boolean,
            sensitivity: .normal,
            read: { UserDefaults.standard.bool(forKey: defaultsKey) ? "true" : "false" },
            write: { value in
                UserDefaults.standard.set(value.lowercased() == "true", forKey: defaultsKey)
            }
        )
    }
}
