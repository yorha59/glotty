import Foundation

/// Tiny utility for displaying macOS virtual keycodes as labels.
/// Used by the Settings → Hotkey recorder UI.
enum Keycode {
    /// Defaults for Glotty's leader-key commands.
    /// T = Translate (decode: foreign → native, one-line). E = Explain (richer
    /// LLM-generated explanation, also in the user's native language). P =
    /// Polish (LLM rewrite of the user's own draft). Chat is also a
    /// proactive surface — triggered by the macOS notification posted
    /// by `ReminderScheduler`.
    static let defaultTranslate = 17  // T
    static let defaultExplain   = 14  // E
    static let defaultPolish    = 35  // P
    static let defaultChat      = 8   // C — open a free-form chat with Glotty
    static let defaultReplace   = 15  // R — polish the selection and write it back in place
    static let defaultSpeak     = 9   // V — speak the selection aloud (text-to-speech)

    /// User-defaults keys that override the defaults above. NB: the persisted
    /// key for Explain still uses the legacy "express" identifier so that any
    /// rebind from the previous build keeps working without a migration.
    static let translateDefaultsKey = "glotty.hotkey.translate"
    static let explainDefaultsKey   = "glotty.hotkey.express"
    static let polishDefaultsKey    = "glotty.hotkey.polish"
    static let chatDefaultsKey      = "glotty.hotkey.chat"
    static let replaceDefaultsKey   = "glotty.hotkey.replace"
    static let speakDefaultsKey     = "glotty.hotkey.speak"
    static let leaderDefaultsKey    = "glotty.hotkey.leader"

    /// Default leader (matches the spike's original "Fn → key" behavior).
    static let defaultLeader: LeaderKey = .fn

    /// Read the active leader from UserDefaults (or the default).
    static func currentLeader() -> LeaderKey {
        let raw = UserDefaults.standard.string(forKey: leaderDefaultsKey) ?? ""
        return LeaderKey(rawValue: raw) ?? defaultLeader
    }

    /// Common Mac virtual keycodes → display label. Covers all letters, digits, and
    /// the keys users are realistically going to bind. Anything else falls back to
    /// `"key #N"` so the UI never breaks.
    static let labels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
        6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        76: "Enter",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
    ]

    static func label(for keycode: Int) -> String {
        labels[keycode] ?? "key #\(keycode)"
    }

    /// Read the active translate keycode (defaults override or hardcoded default).
    static func currentTranslate() -> Int {
        let stored = UserDefaults.standard.object(forKey: translateDefaultsKey) as? Int
        return stored ?? defaultTranslate
    }

    /// Read the active express keycode (defaults override or hardcoded default).
    static func currentExplain() -> Int {
        let stored = UserDefaults.standard.object(forKey: explainDefaultsKey) as? Int
        return stored ?? defaultExplain
    }

    /// Read the active polish keycode (defaults override or hardcoded default).
    static func currentPolish() -> Int {
        let stored = UserDefaults.standard.object(forKey: polishDefaultsKey) as? Int
        return stored ?? defaultPolish
    }

    /// Read the active chat keycode (defaults override or hardcoded default).
    static func currentChat() -> Int {
        let stored = UserDefaults.standard.object(forKey: chatDefaultsKey) as? Int
        return stored ?? defaultChat
    }

    /// Read the active replace keycode (defaults override or hardcoded default).
    static func currentReplace() -> Int {
        let stored = UserDefaults.standard.object(forKey: replaceDefaultsKey) as? Int
        return stored ?? defaultReplace
    }

    /// Read the active speak (text-to-speech) keycode.
    static func currentSpeak() -> Int {
        let stored = UserDefaults.standard.object(forKey: speakDefaultsKey) as? Int
        return stored ?? defaultSpeak
    }
}
