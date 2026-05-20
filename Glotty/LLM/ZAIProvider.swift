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
        // Reuse the streaming path and just collect the final snapshot. Keeps
        // a single transport implementation; the `polish` callers (tests, any
        // future non-UI consumer) still get the blocking shape they expect.
        var last = PolishResult.empty
        for try await snapshot in polishStream(text, mode: mode) {
            last = snapshot
        }
        return last
    }

    func polishStream(_ text: String, mode: PolishMode) -> AsyncThrowingStream<PolishResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(text: text, mode: mode, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Plain-text streaming used by Explain. Same SSE transport as polish but
    /// without the JSON parsing layer — each emission is the accumulated
    /// completion text.
    func chatCompletionStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runChatStream(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        text: String,
        mode: PolishMode,
        continuation: AsyncThrowingStream<PolishResult, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount),
              !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        let prompt = PolishPrompt.build(text: text, mode: mode)
        // GLM-5.1 is a reasoning model that, by default, spends its token budget on
        // internal `reasoning_content` before producing the answer. Polish is a quick
        // task that doesn't need that — disable thinking so we get the rewrite directly.
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.3,
            "stream": true,
            "thinking": ["type": "disabled"],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        // 60s inactivity timeout — streaming resets the timer on every chunk,
        // so the only way to hit this is if the model truly stops producing
        // tokens. Bumped from 30s for headroom on slower providers.
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw LLMError.networkFailure(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse(detail: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: body)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()

            // Z.AI emits OpenAI-style SSE: lines look like `data: {...}` with
            // empty lines as event separators and `data: [DONE]` as the
            // terminator. Anything that isn't a `data:` line is ignored.
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String,
                  !chunk.isEmpty else { continue }

            accumulated += chunk
            let snapshot = PolishResult.parsePartial(accumulated)
            if snapshot != .empty {
                continuation.yield(snapshot)
            }
        }

        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LLMError.emptyResponse }
        // Emit one last full-parse snapshot — covers the case where the partial
        // parser was bailing out on every chunk and only the complete JSON
        // produces a usable result.
        continuation.yield(PolishResult.parse(final))
    }

    /// Same SSE transport as runStream but emits raw accumulated text instead
    /// of PolishResult snapshots. Used by Explain. Factored separately to keep
    /// runStream focused on the polish-specific JSON-parsing path.
    private func runChatStream(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount),
              !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.5,   // a touch warmer than polish — explanations benefit from some variation
            "stream": true,
            "thinking": ["type": "disabled"],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw LLMError.networkFailure(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse(detail: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            var bodyStr = ""
            for try await line in bytes.lines { bodyStr += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: bodyStr)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String,
                  !chunk.isEmpty else { continue }

            accumulated += chunk
            continuation.yield(accumulated)
        }

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
    }
}
