import Foundation

/// Errors surfaced by `LLMProvider` implementations.
enum LLMError: LocalizedError {
    case missingAPIKey(providerName: String)
    case providerUnavailable(reason: String)
    case networkFailure(underlying: Error)
    case httpError(status: Int, body: String)
    case emptyResponse
    case malformedResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "\(name) needs an API key. Add it in Settings → Language Model."
        case .providerUnavailable(let reason):
            return "Provider unavailable — \(reason)"
        case .networkFailure(let err):
            return "Network failure: \(err.localizedDescription)"
        case .httpError(let status, let body):
            let preview = body.prefix(160)
            return "HTTP \(status): \(preview)"
        case .emptyResponse:
            return "Empty response from the model."
        case .malformedResponse(let detail):
            return "Malformed response — \(detail)"
        }
    }
}

/// Minimal protocol every LLM backend implements.
/// `polish` rewrites `text` into idiomatic native `targetLanguage`.
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func isAvailable() -> Bool
    func polish(_ text: String, targetLanguage: String) async throws -> String
}

/// Static registry of all known providers + the user's current selection.
/// More providers (Apple Foundation, Claude, OpenAI) join this list later.
enum LLMRegistry {
    static let all: [LLMProvider] = [
        ZAIProvider(),
    ]

    private static let selectionKey = "glotty.llmProvider"
    private static let defaultID = "zai"

    static func currentProviderID() -> String {
        UserDefaults.standard.string(forKey: selectionKey) ?? defaultID
    }

    static func setCurrentProviderID(_ id: String) {
        UserDefaults.standard.set(id, forKey: selectionKey)
    }

    static func current() -> LLMProvider? {
        let id = currentProviderID()
        return all.first { $0.id == id } ?? all.first
    }
}
