import AppKit

/// In-process `ReaderServices` for the Glotty menu-bar app: the reader lives in
/// the same process as the core, so it just calls straight through. The
/// standalone Reader app ships a different implementation that relays over IPC.
@MainActor
final class GlottyReaderServices: ReaderServices {
    func lookUp(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.handleFire(mode: .explain, providedText: text)
    }

    func translate(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.handleFire(mode: .translate, providedText: text)
    }

    func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>? {
        // The reader keeps its own provider/model — see ReaderModelSelection.
        ReaderModelSelection.provider()?.chatCompletionStream(prompt: prompt)
    }

    func providers() async -> [ReaderProvider] { Self.configuredProviders(scope: .reader) }

    func selectModel(providerID: String, modelID: String) {
        Self.applySelection(providerID: providerID, modelID: modelID, scope: .reader)
    }

    /// The provider list the reader's picker shows. Only providers that are
    /// actually usable (a key is set, or none is needed) — offering one that
    /// can't answer just produces a failed reply.
    /// Which surface a provider list / selection belongs to. The reader chats
    /// about long dense text; Glotty's popup does short latency-sensitive
    /// rewrites — different jobs, so they keep separate choices.
    enum Scope { case glotty, reader }

    static func configuredProviders(scope: Scope = .glotty) -> [ReaderProvider] {
        let activeID = scope == .reader ? ReaderModelSelection.providerID
                                        : LLMRegistry.currentProviderID()
        return LLMRegistry.all.compactMap { p -> ReaderProvider? in
            // Skip providers that can't answer (no API key yet) — offering one
            // only produces a failed reply.
            guard p.isAvailable() else { return nil }
            let (models, key) = modelCatalog(for: p.id)
            return ReaderProvider(
                id: p.id,
                name: p.displayName,
                models: models.map { .init(id: $0.id, name: $0.name) },
                isActive: p.id == activeID,
                activeModelID: scope == .reader
                    ? (ReaderModelSelection.modelID(for: p.id)
                       ?? key.flatMap { UserDefaults.standard.string(forKey: $0) })
                    : key.flatMap { UserDefaults.standard.string(forKey: $0) })
        }
    }

    /// Apply a pick from the reader. Provider and model are separate settings,
    /// so both are written; an empty model id means "provider only".
    static func applySelection(providerID: String, modelID: String, scope: Scope = .glotty) {
        if scope == .reader {
            ReaderModelSelection.select(providerID: providerID, modelID: modelID)
            return
        }
        LLMRegistry.setCurrentProviderID(providerID)
        guard !modelID.isEmpty, let key = modelCatalog(for: providerID).key else { return }
        UserDefaults.standard.set(modelID, forKey: key)
    }

    /// A provider's models plus where its choice is stored. Mirrors what
    /// SettingsRegistry does for the active provider, but for any id — the
    /// picker has to describe every provider, not just the current one.
    /// `availableModels()` everywhere, so a fetched /models list shows up here
    /// exactly as it does in Settings and the menu bar.
    private static func modelCatalog(
        for id: String
    ) -> (models: [(id: String, name: String)], key: String?) {
        if let preset = OpenAIStockPresets.find(id: id) {
            return (preset.availableModels().map { ($0.id, $0.displayName) },
                    preset.modelUserDefaultsKey)
        }
        switch id {
        case "deepseek":
            return (DeepSeekProvider.availableModels().map { ($0.id, $0.displayName) },
                    "glotty.deepseek.model")
        case "kimi-coding":
            return (KimiCodingProvider.availableModels().map { ($0.id, $0.displayName) },
                    "glotty.kimi.model")
        case "minimax-coding":
            return (MiniMaxCodingProvider.availableModels().map { ($0.id, $0.displayName) },
                    "glotty.minimax.model")
        default:
            // Custom providers carry a free-text model id, and the on-device
            // model has none — nothing to enumerate.
            return ([], nil)
        }
    }
}
