import Foundation

/// User-customizable description of who "Glotty" is in chat. Drives
/// the system prompt for the conversational chat mode (Fn → C) and
/// the proactive notification content. Persisted in UserDefaults so
/// it survives launches; reads default to "Glotty" + a warm, casual
/// manner with brief replies if the user hasn't customized.
struct GlottyPersona: Equatable {
    enum Manner: String, CaseIterable, Identifiable, Codable {
        case warm
        case casual
        case playful
        case professional
        case formal

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .warm:         return "Warm"
            case .casual:       return "Casual"
            case .playful:      return "Playful"
            case .professional: return "Professional"
            case .formal:       return "Formal"
            }
        }
        /// One short clause appended to the system prompt to set tone.
        var promptHint: String {
            switch self {
            case .warm:         return "warm and supportive, like a close friend who cheers you on"
            case .casual:       return "casual and relaxed, like chatting with a peer"
            case .playful:      return "playful and curious, occasionally cheeky"
            case .professional: return "polite and helpful, like a knowledgeable colleague"
            case .formal:       return "courteous and formal"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable, Codable {
        case brief
        case chatty
        case detailed

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .brief:    return "Brief"
            case .chatty:   return "Chatty"
            case .detailed: return "Detailed"
            }
        }
        var promptHint: String {
            switch self {
            case .brief:    return "Reply in 1-2 sentences. Be economical with words."
            case .chatty:   return "Reply in 2-3 sentences with one follow-up question."
            case .detailed: return "Reply in 3-5 sentences. Share examples or asides naturally."
            }
        }
    }

    var name: String
    var manner: Manner
    var style: Style
    /// Freeform character note from the user — e.g. "Loves indie
    /// games and dry humor. Bilingual in French." Injected verbatim
    /// into the system prompt so the persona feels distinct.
    var character: String

    static let `default` = GlottyPersona(
        name: "Glotty",
        manner: .warm,
        style: .brief,
        character: ""
    )
}

extension GlottyPersona {
    /// UserDefaults keys. Keep flat so SwiftUI `@AppStorage` can bind
    /// each field directly in the Settings UI.
    enum DefaultsKey {
        static let name      = "glotty.persona.name"
        static let manner    = "glotty.persona.manner"
        static let style     = "glotty.persona.style"
        static let character = "glotty.persona.character"
    }

    /// Read the current persona from UserDefaults, falling back to
    /// the default when nothing has been written.
    static func current() -> GlottyPersona {
        let defaults = UserDefaults.standard
        let name = (defaults.string(forKey: DefaultsKey.name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mannerRaw = defaults.string(forKey: DefaultsKey.manner) ?? ""
        let styleRaw = defaults.string(forKey: DefaultsKey.style) ?? ""
        let character = (defaults.string(forKey: DefaultsKey.character) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GlottyPersona(
            name: name.isEmpty ? `default`.name : name,
            manner: Manner(rawValue: mannerRaw) ?? `default`.manner,
            style: Style(rawValue: styleRaw) ?? `default`.style,
            character: character
        )
    }

    /// The chunk injected into TutorPrompt's system block describing
    /// who the assistant is and how they should sound. Trimmed to
    /// one paragraph so the rest of the prompt stays compact.
    var systemDescription: String {
        var parts = ["You are \(name), a conversation partner who is \(manner.promptHint)."]
        parts.append(style.promptHint)
        if !character.isEmpty {
            parts.append("Personal style notes: \(character)")
        }
        return parts.joined(separator: " ")
    }
}
