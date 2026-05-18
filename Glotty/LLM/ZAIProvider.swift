import Foundation

/// One model that can be picked from Settings → Language Model → Model.
struct ZAIModelOption: Identifiable, Hashable {
    let id: String          // e.g. "glm-5.1" — sent verbatim as `model` in the API call
    let displayName: String // e.g. "GLM-5.1" — shown in the dropdown
    let summary: String     // one-line guidance shown below the dropdown
}

/// Z.AI (Zhipu AI) coding-plan provider via the OpenAI-compatible endpoint.
/// Default endpoint + model match the published "international coding plan" URLs;
/// both can be overridden in Settings (`glotty.zai.endpoint`, `glotty.zai.model`).
struct ZAIProvider: LLMProvider {
    let id = "zai"
    let displayName = "Z.AI (GLM)"

    static let keychainAccount = "zai"
    static let defaultEndpoint = "https://api.z.ai/api/coding/paas/v4/chat/completions"
    static let defaultModel = "glm-5.1"

    /// Models exposed in Settings. Each one's `summary` is shown below the picker
    /// when that model is selected — gives the user enough context to decide.
    static let supportedModels: [ZAIModelOption] = [
        ZAIModelOption(
            id: "glm-4.5-air",
            displayName: "GLM-4.5-Air",
            summary: "Lightest and fastest. Best for short polishes where latency matters; quality is the lowest of the lineup."
        ),
        ZAIModelOption(
            id: "glm-5-turbo",
            displayName: "GLM-5-Turbo",
            summary: "Newer small/fast tier. Good speed-vs-quality balance for one-shot rewrites."
        ),
        ZAIModelOption(
            id: "glm-4.7",
            displayName: "GLM-4.7",
            summary: "Mid-tier reasoning model. Solid quality, moderate speed."
        ),
        ZAIModelOption(
            id: "glm-5.1",
            displayName: "GLM-5.1",
            summary: "Flagship — highest quality, slower and more expensive. Default."
        ),
    ]

    static func model(for id: String) -> ZAIModelOption? {
        supportedModels.first { $0.id == id }
    }

    private var endpointURL: URL {
        let raw = UserDefaults.standard.string(forKey: "glotty.zai.endpoint")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (raw?.isEmpty == false ? raw! : Self.defaultEndpoint)
        return URL(string: candidate) ?? URL(string: Self.defaultEndpoint)!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.zai.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false ? raw! : Self.defaultModel)
    }

    func isAvailable() -> Bool {
        Keychain.read(account: Self.keychainAccount)?.isEmpty == false
    }

    func polish(_ text: String, mode: PolishMode) async throws -> PolishResult {
        guard let apiKey = Keychain.read(account: Self.keychainAccount),
              !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        let prompt = PolishPrompt.build(text: text, mode: mode)
        // GLM-5.1 is a reasoning model that, by default, spends its token budget on
        // internal `reasoning_content` before producing the answer. Polish is a quick
        // task that doesn't need that — disable thinking so we get the rewrite directly.
        // Without this, `max_tokens=256` returns an empty `content` and the model gets
        // cut off mid-reasoning.
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.3,
            "stream": false,
            "thinking": ["type": "disabled"],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.networkFailure(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse(detail: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF8 body)"
            throw LLMError.httpError(status: http.statusCode, body: body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedResponse(detail: "JSON parse failed")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.malformedResponse(detail: "missing choices[0].message.content")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return PolishResult.parse(trimmed)
    }
}
