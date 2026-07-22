import Foundation

/// The reader's own provider + model choice, independent of the one Glotty
/// uses for polish / explain / translate.
///
/// They're different jobs: the popup does short, latency-sensitive rewrites
/// where a fast small model is right, while reading a dense book is a
/// long-form comprehension task worth a stronger (slower, pricier) model.
/// Sharing one setting meant tuning either surface retuned the other.
///
/// Unset means "follow Glotty", so this only diverges once the reader is
/// pointed somewhere explicitly — no migration, and no surprise for anyone
/// who never touches it.
@MainActor
enum ReaderModelSelection {
    private static let providerKey = "glotty.reader.llmProvider"
    private static func modelKey(_ providerID: String) -> String {
        "glotty.reader.model.\(providerID)"
    }

    /// Provider the reader should use — its own, or Glotty's when unset.
    static var providerID: String {
        let raw = UserDefaults.standard.string(forKey: providerKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return LLMRegistry.currentProviderID() }
        return raw
    }

    /// True when the reader has been pointed somewhere of its own.
    static var isOverridden: Bool {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? ""
        return !raw.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Model for `provider` in the reader's scope; nil means "whatever Glotty
    /// uses for that provider".
    static func modelID(for provider: String) -> String? {
        let raw = UserDefaults.standard.string(forKey: modelKey(provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    static func select(providerID id: String, modelID model: String) {
        UserDefaults.standard.set(id, forKey: providerKey)
        if !model.isEmpty { UserDefaults.standard.set(model, forKey: modelKey(id)) }
    }

    /// Go back to following Glotty's choice.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: providerKey)
    }

    /// The provider instance the reader's chat should talk to, with its model
    /// override applied.
    static func provider() -> LLMProvider? {
        LLMRegistry.provider(id: providerID, modelOverride: modelID(for: providerID))
    }
}
