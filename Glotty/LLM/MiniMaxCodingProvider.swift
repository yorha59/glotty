import Foundation

/// One model that can be picked from Settings → Language Model → MiniMax.
struct MiniMaxModelOption: Identifiable, Hashable {
    let id: String          // sent verbatim as `model` in the API call
    let displayName: String
    let summary: String
}

/// MiniMax Coding Plan. Like Kimi it speaks an **Anthropic-compatible** API
/// (`/anthropic/v1/messages`, `content_block_delta` SSE), but it authenticates
/// with `Authorization: Bearer <key>` (the `ANTHROPIC_AUTH_TOKEN` style) rather
/// than Kimi's `x-api-key`. International host is `api.minimax.io`; mainland
/// China is `api.minimaxi.com` (override the endpoint in Settings).
struct MiniMaxCodingProvider: LLMProvider {
    let id = "minimax-coding"
    let displayName = "MiniMax (Coding)"

    static let keychainAccount = "minimax-coding"
    static let defaultEndpoint = "https://api.minimax.io/anthropic/v1/messages"
    static let defaultModel = "MiniMax-M2.7"

    static let supportedModels: [MiniMaxModelOption] = [
        MiniMaxModelOption(
            id: "MiniMax-M2.7",
            displayName: "MiniMax-M2.7",
            summary: "MiniMax's current coding/agentic model on the Anthropic-compatible coding-plan endpoint."
        ),
        MiniMaxModelOption(
            id: "MiniMax-M2.5",
            displayName: "MiniMax-M2.5",
            summary: "Previous coding model. Use if your plan hasn't been moved to M2.7."
        ),
        MiniMaxModelOption(
            id: "MiniMax-M3",
            displayName: "MiniMax-M3",
            summary: "Newer flagship where available on the coding plan."
        ),
    ]

    static func model(for id: String) -> MiniMaxModelOption? {
        availableModels().first { $0.id == id }
    }

    /// Picker models — union of fetched ids and the hardcoded list. Falls back
    /// to the hardcoded list when no `/models` fetch has been cached.
    static func availableModels() -> [MiniMaxModelOption] {
        let providerID = "minimax-coding"
        guard let cache = ModelListCache.cached(for: providerID),
              !cache.modelIDs.isEmpty else {
            return supportedModels
        }
        let hardcodedByID = Dictionary(uniqueKeysWithValues: supportedModels.map { ($0.id, $0) })
        var merged: [MiniMaxModelOption] = []
        var seen: Set<String> = []
        for fetchedID in cache.modelIDs {
            let option = hardcodedByID[fetchedID] ?? MiniMaxModelOption(
                id: fetchedID,
                displayName: fetchedID,
                summary: "Auto-fetched from MiniMax. No bundled description."
            )
            merged.append(option)
            seen.insert(fetchedID)
        }
        for hardcoded in supportedModels where !seen.contains(hardcoded.id) {
            merged.append(hardcoded)
        }
        return merged
    }

    private var endpointURL: URL {
        let raw = UserDefaults.standard.string(forKey: "glotty.minimax.endpoint")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (raw?.isEmpty == false ? raw! : Self.defaultEndpoint)
        return URL(string: candidate) ?? URL(string: Self.defaultEndpoint)!
    }

    private var model: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.minimax.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false ? raw! : Self.defaultModel)
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

    /// Stamp the shared Anthropic headers. The only real difference from Kimi:
    /// `Authorization: Bearer` instead of `x-api-key`.
    private func makeRequest(apiKey: String, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // streaming resets the inactivity timer per chunk
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func runStream(
        text: String,
        mode: PolishMode,
        continuation: AsyncThrowingStream<PolishResult, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        // Build the prompt on the main actor — PolishPrompt.build reads
        // main-isolated MemoryStore state. (See KimiCodingProvider.)
        let prompt = await MainActor.run { PolishPrompt.build(text: text, mode: mode) }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "temperature": 0.3,
            "stream": true,
            "messages": [["role": "user", "content": prompt]],
        ]
        let req = try makeRequest(apiKey: apiKey, body: body)

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
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: errBody)
        }

        var accumulated = ""
        let usage = AnthropicUsageStream(providerID: self.id)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            usage.observe(event: event)
            let eventType = event["type"] as? String
            if eventType == "message_stop" { break }
            guard eventType == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let chunk = delta["text"] as? String, !chunk.isEmpty else { continue }
            accumulated += chunk
            let snapshot = PolishResult.parsePartial(accumulated)
            if snapshot != .empty { continuation.yield(snapshot) }
        }
        usage.finalize()

        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LLMError.emptyResponse }
        continuation.yield(PolishResult.parse(final))
    }

    private func runChatStream(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let apiKey = Keychain.read(account: Self.keychainAccount), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "temperature": 0.5,
            "stream": true,
            "messages": [["role": "user", "content": prompt]],
        ]
        let req = try makeRequest(apiKey: apiKey, body: body)

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
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: errBody)
        }

        var accumulated = ""
        let usage = AnthropicUsageStream(providerID: self.id)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            usage.observe(event: event)
            let eventType = event["type"] as? String
            if eventType == "message_stop" { break }
            guard eventType == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let chunk = delta["text"] as? String, !chunk.isEmpty else { continue }
            accumulated += chunk
            continuation.yield(accumulated)
        }
        usage.finalize()

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
    }
}
