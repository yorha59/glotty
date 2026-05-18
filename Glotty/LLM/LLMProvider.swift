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

/// What kind of polish to run. Drives both the prompt and the UI:
///   - `.variants`: cross-language case (selection is in language A, output language B).
///     The LLM returns 2-3 native-style ways to express the same meaning in B.
///   - `.proofreadAndPolish`: same-language case (selection is in language B, output
///     also B — i.e. you wrote rough English and want it tidied up). The LLM lists
///     grammar/usage issues *and* returns 1-3 polished rewrites.
///
/// `nativeLanguage` is the user's native tongue. If non-nil and different from the
/// target, the LLM is asked to also produce a back-translation in that language for
/// each variant so the user can verify the rewrite captured their intent.
enum PolishMode: Sendable, Equatable {
    case variants(target: String, nativeLanguage: String?)
    case proofreadAndPolish(target: String, nativeLanguage: String?)

    var target: String {
        switch self {
        case .variants(let t, _), .proofreadAndPolish(let t, _): return t
        }
    }

    var nativeLanguage: String? {
        switch self {
        case .variants(_, let n), .proofreadAndPolish(_, let n): return n
        }
    }
}

/// One grammar/usage issue called out by the LLM. `original` is the offending span
/// (or `nil` if the LLM didn't isolate one); `explanation` is the one-line fix.
struct GrammarIssue: Sendable, Equatable, Hashable {
    let original: String?
    let explanation: String
}

/// One polished suggestion. `backTranslation` is the same sentence rendered in
/// the user's native language so they can verify the rewrite captures their intent.
struct PolishVariant: Sendable, Equatable, Hashable {
    let text: String
    let backTranslation: String?
}

/// Structured polish output. `variants` is always populated (we surface the raw
/// response as a single variant when the JSON shape doesn't parse cleanly).
/// `issues` is only populated for `.proofreadAndPolish` mode.
struct PolishResult: Sendable, Equatable {
    let variants: [PolishVariant]
    let issues: [GrammarIssue]

    static let empty = PolishResult(variants: [], issues: [])

    /// Parse a raw LLM text response (expected to be JSON matching our schema)
    /// into a `PolishResult`. Accepts both the legacy `"variants":["a","b"]` shape
    /// and the richer `"variants":[{"text":"a","back":"..."}]` shape so old models
    /// and old prompt-templates keep working. Tolerant of code fences and
    /// non-conforming JSON (surfaces raw text as a single variant in that case).
    static func parse(_ raw: String) -> PolishResult {
        let stripped = stripCodeFences(raw)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PolishResult(variants: [PolishVariant(text: raw, backTranslation: nil)],
                                issues: [])
        }

        let variants = parseVariants(json["variants"])

        let issuesRaw = (json["issues"] as? [[String: Any]]) ?? []
        let issues: [GrammarIssue] = issuesRaw.compactMap { entry in
            let original = (entry["original"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let explanation = (entry["explanation"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !explanation.isEmpty else { return nil }
            return GrammarIssue(
                original: (original?.isEmpty == false) ? original : nil,
                explanation: explanation
            )
        }

        if variants.isEmpty && issues.isEmpty {
            return PolishResult(variants: [PolishVariant(text: raw, backTranslation: nil)],
                                issues: [])
        }
        return PolishResult(variants: variants, issues: issues)
    }

    /// Accept either an array of strings (legacy schema) or an array of objects
    /// with `text` + optional `back`/`backTranslation`/`native` (new schema).
    private static func parseVariants(_ value: Any?) -> [PolishVariant] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { item -> PolishVariant? in
            if let s = item as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil
                    : PolishVariant(text: trimmed, backTranslation: nil)
            }
            if let dict = item as? [String: Any] {
                let textRaw = (dict["text"] as? String)
                    ?? (dict["variant"] as? String)
                    ?? ""
                let text = textRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let backRaw = (dict["back"] as? String)
                    ?? (dict["backTranslation"] as? String)
                    ?? (dict["native"] as? String)
                let back = backRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PolishVariant(text: text,
                                     backTranslation: (back?.isEmpty == false) ? back : nil)
            }
            return nil
        }
    }

    /// Strip ```json … ``` or bare ``` fences if the model wrapped its JSON in them.
    private static func stripCodeFences(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal protocol every LLM backend implements.
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func isAvailable() -> Bool
    func polish(_ text: String, mode: PolishMode) async throws -> PolishResult
}

/// Static registry of all known providers + the user's current selection.
/// More providers (Apple Foundation, Claude, OpenAI) join this list later.
enum LLMRegistry {
    static let all: [LLMProvider] = [
        ZAIProvider(),
        KimiCodingProvider(),
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
