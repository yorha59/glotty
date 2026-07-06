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
        availableModels().first { $0.id == id }
    }

    /// Picker models — union of fetched ids and the hardcoded list.
    /// Falls back to the hardcoded list when no `/models` fetch has
    /// been cached.
    static func availableModels() -> [KimiModelOption] {
        let providerID = "kimi-coding"
        guard let cache = ModelListCache.cached(for: providerID),
              !cache.modelIDs.isEmpty else {
            return supportedModels
        }
        let hardcodedByID = Dictionary(
            uniqueKeysWithValues: supportedModels.map { ($0.id, $0) }
        )
        var merged: [KimiModelOption] = []
        var seen: Set<String> = []
        for fetchedID in cache.modelIDs {
            let option = hardcodedByID[fetchedID] ?? KimiModelOption(
                id: fetchedID,
                displayName: fetchedID,
                summary: "Auto-fetched from Kimi. No bundled description."
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
        guard let apiKey = Keychain.read(account: Self.keychainAccount),
              !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerName: displayName)
        }

        // Build the prompt on the main actor. `PolishPrompt.build` reads
        // main-isolated MemoryStore state via `MainActor.assumeIsolated`,
        // which crashes if called from the background. Provider stream
        // tasks aren't main-actor-isolated (Task {} doesn't inherit
        // MainActor), so we hop explicitly here.
        let prompt = await MainActor.run { PolishPrompt.build(text: text, mode: mode) }
        // Anthropic Messages API body. `stream: true` switches the response to
        // SSE with `content_block_delta` events carrying the incremental text.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "temperature": 0.3,
            "stream": true,
            "messages": [
                ["role": "user", "content": prompt]
            ],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        // 60s inactivity timeout — streaming resets it per chunk.
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Moonshot's docs reference KimiCLI/1.5 as a default UA on this endpoint.
        req.setValue("KimiCLI/1.5", forHTTPHeaderField: "User-Agent")
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
        let usage = AnthropicUsageStream(providerID: self.id)
        // Anthropic SSE structure: `event: <name>\ndata: {…}\n\n`. We only care
        // about `content_block_delta` events whose payload contains a
        // `delta.text` token.
        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            usage.observe(event: event)
            let eventType = event["type"] as? String

            // `message_stop` ends the stream; nothing else to do.
            if eventType == "message_stop" { break }
            guard eventType == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let chunk = delta["text"] as? String,
                  !chunk.isEmpty else { continue }

            accumulated += chunk
            let snapshot = PolishResult.parsePartial(accumulated)
            if snapshot != .empty {
                continuation.yield(snapshot)
            }
        }

        usage.finalize()

        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw LLMError.emptyResponse }
        continuation.yield(PolishResult.parse(final))
    }

    /// Anthropic-flavoured chat streaming for Explain. Emits accumulated text
    /// per chunk; no JSON parsing layer.
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
            "max_tokens": 3000,
            "temperature": 0.5,
            "stream": true,
            "messages": [
                ["role": "user", "content": prompt]
            ],
        ]

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("KimiCLI/1.5", forHTTPHeaderField: "User-Agent")
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
        let usage = AnthropicUsageStream(providerID: self.id)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
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
                  let chunk = delta["text"] as? String,
                  !chunk.isEmpty else { continue }

            accumulated += chunk
            continuation.yield(accumulated)
        }

        usage.finalize()

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
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
