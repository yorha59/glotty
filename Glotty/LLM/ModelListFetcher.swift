import Foundation

/// One snapshot of a provider's model catalog, fetched from its
/// `/models` endpoint and persisted so we don't hit the network on
/// every Settings open.
struct CachedModelList: Codable, Sendable {
    let providerID: String
    let modelIDs: [String]
    let fetchedAt: Date
}

/// Discovers model ids from a provider's HTTP endpoint. Both OpenAI's
/// and Anthropic's `/models` return JSON with a top-level
/// `data: [{ id, ... }]` array, so one fetcher covers every provider
/// we ship — only the auth header differs.
enum ModelListFetcher {
    /// Which authentication header the server expects. Bearer is the
    /// OpenAI-compatible default (OpenAI, DeepSeek, OpenRouter, Z.AI,
    /// Gemini's OpenAI-shim, custom user endpoints). Anthropic uses
    /// `x-api-key` + a fixed `anthropic-version` header (Kimi).
    enum AuthStyle: Sendable {
        case bearer
        case anthropic(version: String, userAgent: String?)
    }

    /// GET `<base>/models` and return the list of ids, sorted. The
    /// `endpoint` argument is the chat-completions / messages URL the
    /// caller already has; we derive the listing URL by chopping the
    /// trailing chat path segment(s) and appending `models`. OpenAI-
    /// style endpoints have two trailing segments (`/chat/completions`)
    /// whose `/models` sibling lives one level up, while Anthropic-
    /// style and other single-segment endpoints (`/messages`) sit at
    /// the same level as `/models`.
    static func fetchModels(
        endpoint: URL,
        apiKey: String,
        auth: AuthStyle
    ) async throws -> [String] {
        let modelsURL = derivedModelsURL(from: endpoint)
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .bearer:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic(let version, let userAgent):
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(version, forHTTPHeaderField: "anthropic-version")
            if let userAgent {
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.networkFailure(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse(detail: "no HTTPURLResponse from /models")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(status: http.statusCode, body: body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["data"] as? [[String: Any]] else {
            throw LLMError.malformedResponse(detail: "expected `{\"data\": [...]}` from /models")
        }
        let ids = array.compactMap { $0["id"] as? String }
        // De-dupe and stable-sort so the picker order is predictable
        // across calls. Servers sometimes return duplicates.
        return Array(Set(ids)).sorted()
    }

    /// Derive the `/models` listing URL from a chat-style endpoint.
    /// Two cases:
    ///   - `<base>/chat/completions` (OpenAI, DeepSeek, OpenRouter,
    ///      Z.AI, Gemini's OpenAI shim) → `<base>/models`. Z.AI
    ///      lives at `.../v4/chat/completions`; the previous one-
    ///      segment strip produced `.../v4/chat/models` and 404ed.
    ///   - any other single-segment ending (`/messages` for Kimi's
    ///      Anthropic-compatible endpoint) → strip one segment, append
    ///      `models`.
    static func derivedModelsURL(from endpoint: URL) -> URL {
        let path = endpoint.path
        if path.hasSuffix("/chat/completions") {
            return endpoint
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("models")
        }
        return endpoint
            .deletingLastPathComponent()
            .appendingPathComponent("models")
    }
}

/// UserDefaults-backed cache for fetched model lists. Keyed by provider
/// id so each provider has its own slot. Threading: backed by
/// UserDefaults, which is thread-safe; no actor isolation needed.
enum ModelListCache {
    /// Posted after `set(_:)` / `clear(for:)` so the Settings UI can
    /// refresh its picker without waiting for the user to re-open it.
    static let didChangeNotification = Notification.Name("glotty.modelList.didChange")

    static func cached(for providerID: String) -> CachedModelList? {
        guard let data = UserDefaults.standard.data(forKey: key(for: providerID)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedModelList.self, from: data)
    }

    static func save(_ list: CachedModelList) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key(for: list.providerID))
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func clear(for providerID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: providerID))
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func key(for providerID: String) -> String {
        "glotty.modelList.\(providerID)"
    }
}
