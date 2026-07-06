import Foundation

/// Pre-configured OpenAI-compatible providers exposed in Settings as
/// one-click options. Each preset captures defaults (endpoint, model, signup
/// URL, list of recognised models) but the user can still override the
/// endpoint and selected model via UserDefaults — same per-provider keys the
/// hardcoded ZAIProvider used, so existing users keep their config.
///
/// To add a new preset: append an entry below and (optionally) add a
/// `ModelOption` list so the Settings picker can guide users. Nothing else
/// needs to change — `LLMRegistry` materialises the preset into an
/// `OpenAICompatibleProvider` on demand.
enum OpenAIStockPresets {
    /// One concrete model offered by a preset. `summary` shows under the
    /// picker so users get enough context to choose.
    struct ModelOption: Identifiable, Hashable {
        let id: String          // sent verbatim as `model`
        let displayName: String
        let summary: String
    }

    /// Static description of a stock preset. Materialised into a runtime
    /// `OpenAICompatibleProvider` by `LLMRegistry`.
    struct Preset: Identifiable, Hashable {
        let id: String                      // stable provider id (also the keychain account)
        let displayName: String             // shown in pickers
        let defaultEndpoint: String         // chat-completions URL
        let defaultModel: String            // sent if user hasn't picked one
        let models: [ModelOption]           // exposed in the model picker
        let signupURL: URL?                 // "Get an API key" link in Settings
        /// Extra request-body fields as JSON. Pre-encoded so the runtime
        /// provider stays Sendable. Only set for presets that need it
        /// (Z.AI's `thinking=disabled`).
        let extraBodyJSON: Data?

        static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        /// UserDefaults key holding the user's endpoint override.
        var endpointUserDefaultsKey: String { "glotty.\(id).endpoint" }
        /// UserDefaults key holding the user's selected model.
        var modelUserDefaultsKey: String { "glotty.\(id).model" }

        /// Resolved endpoint: user override if non-empty, else `defaultEndpoint`.
        func currentEndpoint() -> String {
            let raw = UserDefaults.standard.string(forKey: endpointUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw! : defaultEndpoint
        }

        /// Resolved model: user pick if non-empty, else `defaultModel`.
        func currentModel() -> String {
            let raw = UserDefaults.standard.string(forKey: modelUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw! : defaultModel
        }

        func model(forID id: String) -> ModelOption? {
            availableModels().first { $0.id == id }
        }

        /// Models visible in the picker — union of (a) ids fetched from
        /// the server's `/models` endpoint and (b) our hardcoded
        /// catalog. Hardcoded entries keep their summaries; fetched-
        /// only ids show as the bare id with a placeholder summary.
        /// Falls back to the hardcoded list when nothing's cached.
        func availableModels() -> [ModelOption] {
            guard let cache = ModelListCache.cached(for: id), !cache.modelIDs.isEmpty else {
                return models
            }
            let hardcodedByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            var merged: [ModelOption] = []
            var seen: Set<String> = []
            for fetchedID in cache.modelIDs {
                let option = hardcodedByID[fetchedID] ?? ModelOption(
                    id: fetchedID,
                    displayName: fetchedID,
                    summary: "Auto-fetched from \(displayName). No bundled description."
                )
                merged.append(option)
                seen.insert(fetchedID)
            }
            // Append any hardcoded models the server didn't list — keeps
            // the user from "losing" a model they're already selected on
            // if the server's catalog ever drops it temporarily.
            for hardcoded in models where !seen.contains(hardcoded.id) {
                merged.append(hardcoded)
            }
            return merged
        }
    }

    /// All built-in presets, in the order they appear in the Settings picker.
    /// DeepSeek is intentionally absent — it has a dedicated `DeepSeekProvider`
    /// class to handle reasoner-mode chain-of-thought streaming, which doesn't
    /// fit the generic OpenAI-compatible shape.
    static let all: [Preset] = [openai, gemini, openrouter, zai, grok]

    static func find(id: String) -> Preset? { all.first { $0.id == id } }

    // MARK: - Catalogue

    static let openai = Preset(
        id: "openai",
        displayName: "OpenAI",
        defaultEndpoint: "https://api.openai.com/v1/chat/completions",
        defaultModel: "gpt-4o-mini",
        models: [
            ModelOption(
                id: "gpt-4o-mini",
                displayName: "GPT-4o mini",
                summary: "Fast and cheap default — good for polish/explain on short text."
            ),
            ModelOption(
                id: "gpt-4o",
                displayName: "GPT-4o",
                summary: "Flagship multimodal model. Higher quality, ~10x the cost."
            ),
            ModelOption(
                id: "gpt-4.1-mini",
                displayName: "GPT-4.1 mini",
                summary: "Newer small tier with improved instruction-following over 4o-mini."
            ),
            ModelOption(
                id: "gpt-4.1",
                displayName: "GPT-4.1",
                summary: "Highest-quality general model. Slower; recommended only for hard rewrites."
            ),
        ],
        signupURL: URL(string: "https://platform.openai.com/api-keys"),
        extraBodyJSON: nil
    )

    /// Google Gemini via the OpenAI-compatible shim Google ships at
    /// `generativelanguage.googleapis.com/v1beta/openai/`. Strong on Japanese
    /// and Korean (a major reason for adding it as a stock preset for the
    /// JP/KR launch) and cheap at the Flash tier.
    static let gemini = Preset(
        id: "gemini",
        displayName: "Google Gemini",
        defaultEndpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        defaultModel: "gemini-2.0-flash",
        models: [
            ModelOption(
                id: "gemini-2.0-flash",
                displayName: "Gemini 2.0 Flash",
                summary: "Default — fast, very cheap, strong on Japanese / Korean / Chinese. Best all-rounder for polish and explain."
            ),
            ModelOption(
                id: "gemini-2.0-flash-lite",
                displayName: "Gemini 2.0 Flash Lite",
                summary: "Cheapest tier. Use when polishing high volumes of short text and latency matters more than depth."
            ),
            ModelOption(
                id: "gemini-1.5-pro",
                displayName: "Gemini 1.5 Pro",
                summary: "Older flagship — slower and pricier than 2.0 Flash but slightly stronger on long, nuanced rewrites."
            ),
            ModelOption(
                id: "gemini-1.5-flash",
                displayName: "Gemini 1.5 Flash",
                summary: "Legacy fast tier. Keep as fallback if 2.0 ever has availability issues in your region."
            ),
        ],
        signupURL: URL(string: "https://aistudio.google.com/app/apikey"),
        extraBodyJSON: nil
    )

    static let openrouter = Preset(
        id: "openrouter",
        displayName: "OpenRouter",
        defaultEndpoint: "https://openrouter.ai/api/v1/chat/completions",
        defaultModel: "openai/gpt-4o-mini",
        models: [
            ModelOption(
                id: "openai/gpt-4o-mini",
                displayName: "GPT-4o mini (via OpenRouter)",
                summary: "Same model as OpenAI direct, routed through OpenRouter — useful if you only want one API key."
            ),
            ModelOption(
                id: "anthropic/claude-3.5-sonnet",
                displayName: "Claude 3.5 Sonnet (via OpenRouter)",
                summary: "Anthropic via OpenAI-compatible shim. Strong rewriting; pricier per token."
            ),
            ModelOption(
                id: "google/gemini-2.0-flash-001",
                displayName: "Gemini 2.0 Flash (via OpenRouter)",
                summary: "Google's fast multilingual model. Good for non-English polish."
            ),
        ],
        signupURL: URL(string: "https://openrouter.ai/keys"),
        extraBodyJSON: nil
    )

    /// Z.AI (Zhipu GLM) — migrated from the hardcoded ZAIProvider. Keeps the
    /// existing `id`/keychain account and UserDefaults keys so users on the
    /// previous build don't need to re-enter their API key.
    static let zai = Preset(
        id: "zai",
        displayName: "Z.AI (GLM)",
        defaultEndpoint: "https://api.z.ai/api/coding/paas/v4/chat/completions",
        defaultModel: "glm-5.1",
        models: [
            ModelOption(
                id: "glm-4.5-air",
                displayName: "GLM-4.5-Air",
                summary: "Lightest and fastest. Best for short polishes where latency matters; quality is the lowest of the lineup."
            ),
            ModelOption(
                id: "glm-5-turbo",
                displayName: "GLM-5-Turbo",
                summary: "Newer small/fast tier. Good speed-vs-quality balance for one-shot rewrites."
            ),
            ModelOption(
                id: "glm-4.7",
                displayName: "GLM-4.7",
                summary: "Mid-tier reasoning model. Solid quality, moderate speed."
            ),
            ModelOption(
                id: "glm-5.1",
                displayName: "GLM-5.1",
                summary: "Flagship — highest quality, slower and more expensive. Default."
            ),
        ],
        signupURL: URL(string: "https://z.ai/manage-apikey/apikey-list"),
        // GLM-5.1 burns its budget on reasoning tokens by default; polish is a
        // quick task, so disable thinking to get the rewrite directly.
        extraBodyJSON: try? JSONSerialization.data(
            withJSONObject: ["thinking": ["type": "disabled"]]
        )
    )

    /// xAI Grok. OpenAI-compatible chat-completions API at api.x.ai, so it
    /// drops straight into `OpenAICompatibleProvider` like the others. The
    /// hardcoded model list is just a starting point — the provider also
    /// merges in whatever `/models` returns, so newer Grok models appear in
    /// the picker automatically once the key is set.
    static let grok = Preset(
        id: "grok",
        displayName: "xAI (Grok)",
        defaultEndpoint: "https://api.x.ai/v1/chat/completions",
        defaultModel: "grok-3-mini",
        models: [
            ModelOption(
                id: "grok-3-mini",
                displayName: "Grok 3 mini",
                summary: "Lightweight and cheap — best for quick translate/polish where latency and cost matter. Default."
            ),
            ModelOption(
                id: "grok-3",
                displayName: "Grok 3",
                summary: "Strong general model. Good balance of quality and speed for explanations and rewriting."
            ),
            ModelOption(
                id: "grok-4",
                displayName: "Grok 4",
                summary: "Flagship reasoning model — highest quality, slower and pricier. Best for nuanced explanations."
            ),
        ],
        signupURL: URL(string: "https://console.x.ai/"),
        extraBodyJSON: nil
    )
}
