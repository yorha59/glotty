import Foundation

/// One DeepSeek model that can be picked from Settings → Language Model.
struct DeepSeekModelOption: Identifiable, Hashable {
    let id: String          // sent verbatim as `model` in the API call
    let displayName: String
    let summary: String
    /// Reasoning models emit `delta.reasoning_content` chain-of-thought before
    /// the real `delta.content` answer arrives. Flagged here so the streamer
    /// knows to surface a "Thinking…" indicator instead of silently waiting.
    let isReasoner: Bool
}

/// DeepSeek's chat-completions API speaks the standard OpenAI wire format
/// (Bearer auth, `model`+`messages` body, SSE `data:` lines). What earns it
/// a dedicated class — separate from the generic `OpenAICompatibleProvider`
/// plugin — is `deepseek-reasoner`, which emits the chain-of-thought in a
/// non-standard `delta.reasoning_content` field for up to ~30 seconds before
/// the real answer starts. Treating it as a vanilla OpenAI provider means
/// the user sits in silence the whole time.
///
/// This class:
///   - Reads `delta.reasoning_content` and `delta.content` separately during
///     streaming
///   - For polish (JSON output): silently discards reasoning_content — the
///     JSON parser can't tolerate prose prefix anyway
///   - For chat / explain: yields a "🧠 Thinking…" preamble while reasoning is
///     in-flight, then crossfades to the real answer once content starts
///
/// All other behaviour (auth, request body, error mapping) matches
/// `OpenAICompatibleProvider` — just inlined here so the reasoning branches
/// stay readable and the generic provider doesn't grow optional hooks.
struct DeepSeekProvider: LLMProvider {
    let id = "deepseek"
    let displayName = "DeepSeek"

    static let keychainAccount = "deepseek"
    static let defaultEndpoint = "https://api.deepseek.com/v1/chat/completions"
    static let defaultModel = "deepseek-chat"

    /// Catalogue exposed in the model picker. Summaries reflect DeepSeek's
    /// published guidance: deepseek-chat = V3 unified model (fast, cheap,
    /// solid for polish); deepseek-reasoner = R1 with explicit CoT (slower
    /// but stronger on hard rewrites).
    static let supportedModels: [DeepSeekModelOption] = [
        DeepSeekModelOption(
            id: "deepseek-chat",
            displayName: "DeepSeek-Chat (V3)",
            summary: "Unified V3 model — fast, very cheap (~$0.27/1M input), strong general performance. Recommended default for polish and explain.",
            isReasoner: false
        ),
        DeepSeekModelOption(
            id: "deepseek-reasoner",
            displayName: "DeepSeek-Reasoner (R1)",
            summary: "R1 reasoning model with explicit chain-of-thought. Higher quality on complex rewrites; expect a 10-30s think pause before the answer streams.",
            isReasoner: true
        ),
    ]

    static func model(for id: String) -> DeepSeekModelOption? {
        supportedModels.first { $0.id == id }
    }

    private var endpointURL: URL {
        let raw = UserDefaults.standard.string(forKey: "glotty.deepseek.endpoint")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (raw?.isEmpty == false ? raw! : Self.defaultEndpoint)
        return URL(string: candidate) ?? URL(string: Self.defaultEndpoint)!
    }

    private var modelID: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.deepseek.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false ? raw! : Self.defaultModel)
    }

    private var isReasoner: Bool {
        Self.model(for: modelID)?.isReasoner ?? false
    }

    func isAvailable() -> Bool {
        Keychain.read(account: Self.keychainAccount)?.isEmpty == false
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
                    try await runPolish(text: text, mode: mode, continuation: continuation)
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
                    try await runChat(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Polish (JSON output)

    /// Polish path. Discards `reasoning_content` entirely — the polish prompt
    /// asks the model for JSON, so any prose prefix would break parsing. The
    /// PopupView already shows a "Polishing…" spinner during the wait, so
    /// users still see the popup is alive even on reasoner mode.
    private func runPolish(
        text: String,
        mode: PolishMode,
        continuation: AsyncThrowingStream<PolishResult, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        // PolishPrompt.build reads main-isolated MemoryStore state via
        // `MainActor.assumeIsolated`; this Task isn't main-actor-isolated,
        // so we hop explicitly before building the prompt.
        let prompt = await MainActor.run { PolishPrompt.build(text: text, mode: mode) }
        let body = try makeBody(prompt: prompt, temperature: 0.3)
        let bytes = try await openStream(apiKey: apiKey, body: body)

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parseSSE(line) else { continue }
            OpenAIUsageStream.record(from: event, providerID: id)

            // Polish only reads content — reasoning_content is discarded.
            guard let chunk = deltaContent(from: event), !chunk.isEmpty else { continue }
            accumulated += chunk
            let snapshot = PolishResult.parsePartial(accumulated)
            if snapshot != .empty {
                continuation.yield(snapshot)
            }
        }

        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LLMError.emptyResponse }
        continuation.yield(PolishResult.parse(final))
    }

    // MARK: - Chat / Explain (text output with reasoning surface)

    /// Chat / explain path. For reasoner models, emit a "🧠 Thinking…"
    /// preamble while `reasoning_content` is in-flight so the popup shows
    /// progress instead of a frozen spinner. Once `content` starts arriving,
    /// the yielded value flips to just the real answer (the preamble is
    /// discarded — the UI replaces the whole accumulated string on each
    /// emission).
    private func runChat(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        let body = try makeBody(prompt: prompt, temperature: 0.5)
        let bytes = try await openStream(apiKey: apiKey, body: body)

        var reasoningBuf = ""
        var contentBuf = ""
        let surfaceReasoning = isReasoner

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parseSSE(line) else { continue }
            OpenAIUsageStream.record(from: event, providerID: id)

            if let r = deltaReasoning(from: event), !r.isEmpty, surfaceReasoning {
                reasoningBuf += r
                if contentBuf.isEmpty {
                    // Show reasoning as a transient preface. Once content
                    // starts, this whole emission is replaced by the answer.
                    continuation.yield("🧠 Thinking…\n\n" + reasoningBuf)
                }
            }

            if let c = deltaContent(from: event), !c.isEmpty {
                contentBuf += c
                continuation.yield(contentBuf)
            }
        }

        let trimmed = contentBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
    }

    // MARK: - HTTP / SSE helpers

    private func makeBody(prompt: String, temperature: Double) throws -> Data {
        // Reasoner models ignore temperature server-side; passing it anyway
        // is harmless and keeps polish/chat consistent.
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 3000,
            "temperature": temperature,
            "stream": true,
            "stream_options": OpenAIUsageStream.streamOptions,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func openStream(apiKey: String, body: Data) async throws -> URLSession.AsyncBytes {
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        // Reasoner can think for 30s+; 90s inactivity timeout gives headroom
        // before the URLSession layer trips on a model that's still working
        // but hasn't emitted a token yet.
        req.timeoutInterval = 90
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

    private func parseSSE(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" || payload.isEmpty { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func deltaContent(from event: [String: Any]) -> String? {
        delta(from: event)?["content"] as? String
    }

    private func deltaReasoning(from event: [String: Any]) -> String? {
        delta(from: event)?["reasoning_content"] as? String
    }

    private func delta(from event: [String: Any]) -> [String: Any]? {
        guard let choices = event["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        return first["delta"] as? [String: Any]
    }
}
