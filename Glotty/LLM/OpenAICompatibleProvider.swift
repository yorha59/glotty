import Foundation

/// Plugin LLM provider for any OpenAI-compatible chat completions endpoint.
///
/// The OpenAI chat-completions wire format (Bearer auth + `model`/`messages`
/// body + SSE `data:` lines with `choices[0].delta.content`) is the de-facto
/// standard. By treating it as the plugin contract, Glotty can talk to OpenAI,
/// DeepSeek, OpenRouter, Groq, Z.AI, vLLM/Ollama, and most "coding plan"
/// services with a single class — only the endpoint, model, and key differ.
///
/// Anthropic-shaped APIs (Claude, Kimi-for-coding's coding endpoint) speak a
/// different protocol and stay in their own provider classes.
struct OpenAICompatibleProvider: LLMProvider {
    let id: String
    let displayName: String
    let endpointURL: URL
    let model: String
    /// Keychain account holding the bearer token. Derived per-instance so stock
    /// presets and custom entries don't collide on a single shared slot.
    let keychainAccount: String
    /// Optional JSON-encoded request-body fragment merged into every call.
    /// Use for provider-specific extensions (e.g. GLM's
    /// `{"thinking":{"type":"disabled"}}` to skip reasoning tokens for polish).
    /// Pre-encoded as `Data` so the struct stays `Sendable`.
    let extraBodyJSON: Data?
    /// Ask the provider to search the web when the model judges it useful.
    /// Only set for providers with a native web-search tool (Z.AI); ignored by
    /// everyone else. Set on the reader's provider, not Glotty's own, so the
    /// popup's polish/explain stay fast and offline-of-the-web.
    var webSearchEnabled = false

    func isAvailable() -> Bool {
        Keychain.read(account: keychainAccount)?.isEmpty == false
    }

    func polish(_ text: String, mode: PolishMode) async throws -> PolishResult {
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
        guard let apiKey = Keychain.read(account: keychainAccount), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }
        // PolishPrompt.build reads main-isolated MemoryStore state via
        // `MainActor.assumeIsolated`; this Task isn't main-actor-isolated,
        // so we hop explicitly before building the prompt.
        let prompt = await MainActor.run { PolishPrompt.build(text: text, mode: mode) }
        let bytes = try await openJSONStream(apiKey: apiKey, prompt: prompt, temperature: 0.3)

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parseSSELine(line) else { continue }
            OpenAIUsageStream.record(from: event, providerID: id)

            guard let chunk = chunkText(from: event), !chunk.isEmpty else { continue }
            accumulated += chunk
            let snapshot = PolishResult.parsePartial(accumulated)
            if snapshot != .empty {
                continuation.yield(snapshot)
            }
        }

        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LLMError.emptyResponse }
        // Final full-parse pass — covers the case where parsePartial bailed on
        // every chunk and only the complete JSON yields a usable result.
        continuation.yield(PolishResult.parse(final))
    }

    private func runChatStream(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let apiKey: String
        switch Keychain.readResult(account: keychainAccount) {
        case .value(let k): apiKey = k
        case .locked: throw LLMError.keychainLocked(providerName: displayName)
        case .missing: throw LLMError.missingAPIKey(providerName: displayName)
        }
        let bodyData = try makeBody(prompt: prompt, temperature: 0.5, webSearch: webSearchEnabled)
        let bytes = try await openSSEStream(apiKey: apiKey, body: bodyData)

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parseSSELine(line) else { continue }
            OpenAIUsageStream.record(from: event, providerID: id)

            guard let chunk = chunkText(from: event), !chunk.isEmpty else { continue }
            accumulated += chunk
            continuation.yield(accumulated)
        }

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
    }

    /// Build the request body. Merges `extraBodyJSON` last so preset-specific
    /// extensions can override defaults if a future preset needs to.
    /// Whether this exact model has already rejected `response_format`, so the
    /// probe only ever costs one extra round-trip per model.
    private var jsonModeRejectedKey: String { "glotty.jsonMode.rejected.\(id).\(model)" }
    private var jsonModeRejected: Bool {
        UserDefaults.standard.bool(forKey: jsonModeRejectedKey)
    }

    private func makeBody(prompt: String, temperature: Double,
                          jsonMode: Bool = false, webSearch: Bool = false) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            // 3000 covers Chinese explanations (~1.5 tokens/char so
            // 1024 capped at ~600 chars and truncated mid-sentence)
            // and polish JSON with 2-3 long variants + issues. Polish
            // typically uses much less; the headroom is free.
            "max_tokens": 3000,
            "temperature": temperature,
            "stream": true,
            "stream_options": OpenAIUsageStream.streamOptions,
        ]
        // Ask for guaranteed-parseable JSON where the caller needs it (polish).
        // Not set for prose replies — explain/chat must stay Markdown.
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        // Z.AI's native web-search tool: the model calls it when it judges the
        // question needs current or outside information, and folds the results
        // into its answer server-side — no client tool loop.
        if webSearch { body["tools"] = [["type": "web_search", "web_search": ["enable": true]]] }
        if let extraBodyJSON,
           let extra = try? JSONSerialization.jsonObject(with: extraBodyJSON) as? [String: Any] {
            for (k, v) in extra { body[k] = v }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Open the stream asking for JSON mode, degrading gracefully if this model
    /// doesn't support `response_format`.
    ///
    /// Which models accept it can't be known up front: Z.AI documents
    /// glm-4.5/4.6/4.7/5, but the preset also offers glm-5.1, glm-5-turbo and
    /// glm-4.5-air, which the docs don't name — and custom providers are a
    /// complete unknown. Rather than hardcode a list that goes stale, ask once
    /// and remember a rejection, so an unsupported model costs one extra
    /// request ever instead of failing outright.
    private func openJSONStream(apiKey: String, prompt: String,
                                temperature: Double) async throws -> URLSession.AsyncBytes {
        guard !jsonModeRejected else {
            return try await openSSEStream(
                apiKey: apiKey,
                body: try makeBody(prompt: prompt, temperature: temperature))
        }
        do {
            return try await openSSEStream(
                apiKey: apiKey,
                body: try makeBody(prompt: prompt, temperature: temperature, jsonMode: true))
        } catch let LLMError.httpError(status, body) where status == 400 &&
                    body.lowercased().contains("response_format") {
            UserDefaults.standard.set(true, forKey: jsonModeRejectedKey)
            return try await openSSEStream(
                apiKey: apiKey,
                body: try makeBody(prompt: prompt, temperature: temperature))
        }
    }

    /// Open the SSE byte stream and validate the HTTP response. Centralises
    /// the auth-header and error-mapping boilerplate so polish / explain paths
    /// don't repeat it.
    private func openSSEStream(apiKey: String, body: Data) async throws -> URLSession.AsyncBytes {
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        // 60s inactivity timeout — every SSE chunk resets the URLSession timer,
        // so only a fully stalled model trips this.
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = body

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
            var dump = ""
            for try await line in bytes.lines { dump += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: dump)
        }
        return bytes
    }

    /// Parse one `data: {...}` SSE line into a JSON object, or nil for
    /// non-data lines, `[DONE]`, and unparseable payloads.
    private func parseSSELine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" || payload.isEmpty { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Extract `choices[0].delta.content` from a parsed event.
    private func chunkText(from event: [String: Any]) -> String? {
        guard let choices = event["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }
}
