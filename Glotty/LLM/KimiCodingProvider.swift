import Foundation

/// One model that can be picked from Settings → Language Model → Kimi.
struct KimiModelOption: Identifiable, Hashable {
    let id: String          // sent verbatim as `model` in the API call
    let displayName: String
    let summary: String
}

/// Kimi For Coding (Moonshot AI). Uses an **Anthropic-compatible** API — different
/// auth header (`x-api-key`), different request body (no top-level `stream`), and a
/// different response shape (`content[0].text`) than Z.AI's OpenAI-compatible one.
struct KimiCodingProvider: LLMProvider {
    let id = "kimi-coding"
    let displayName = "Kimi For Coding"

    static let keychainAccount = "kimi-coding"
    static let defaultEndpoint = "https://api.kimi.com/coding/v1/messages"
    static let defaultModel = "kimi-for-coding"

    /// Single model right now — Kimi For Coding ships one tuned model (K2.6 family).
    /// Versioned aliases (`k2p5`, `k2p6`) collapse to `kimi-for-coding` server-side.
    static let supportedModels: [KimiModelOption] = [
        KimiModelOption(
            id: "kimi-for-coding",
            displayName: "Kimi For Coding (K2.6)",
            summary: "Coding-focused model on Moonshot's Anthropic-compatible API. Single canonical id; aliases like k2p5 / k2p6 normalize to this."
        ),
    ]

    static func model(for id: String) -> KimiModelOption? {
        supportedModels.first { $0.id == id }
    }

    private var endpointURL: URL {
        let raw = UserDefaults.standard.string(forKey: "glotty.kimi.endpoint")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (raw?.isEmpty == false ? raw! : Self.defaultEndpoint)
        return URL(string: candidate) ?? URL(string: Self.defaultEndpoint)!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.kimi.model")?
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
        // Anthropic Messages API body.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.3,
            "messages": [
                ["role": "user", "content": prompt]
            ],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Moonshot's docs reference KimiCLI/1.5 as a default UA on this endpoint.
        req.setValue("KimiCLI/1.5", forHTTPHeaderField: "User-Agent")
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

        let content = try Self.extractTextContent(from: data)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return PolishResult.parse(trimmed)
    }

    /// Pull the first `text` block out of an Anthropic-shaped response:
    /// `{ "content": [{"type": "text", "text": "..."}, …] }`.
    /// Extracted so it's unit-testable without hitting the network.
    static func extractTextContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedResponse(detail: "JSON parse failed")
        }
        guard let blocks = json["content"] as? [[String: Any]] else {
            throw LLMError.malformedResponse(detail: "missing content[]")
        }
        let firstText = blocks
            .compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            .first
        guard let text = firstText else {
            throw LLMError.malformedResponse(detail: "no text block in content[]")
        }
        return text
    }
}
