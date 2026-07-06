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

/// One grammar/usage issue called out by the LLM. `original` is the offending
/// span shown in the popup (or `nil` if the LLM didn't isolate one);
/// `explanation` is the one-line fix; `category` is a short label of the
/// mistake *type* (used only by the Memory tab to aggregate patterns —
/// "Subject-verb agreement", "Article usage", etc. — without persisting the
/// user's literal text).
struct GrammarIssue: Sendable, Equatable, Hashable {
    let category: String?
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
    /// True when the parser couldn't extract a structured response and
    /// surfaced the raw text as a single variant. The popup still renders
    /// this (so the user sees *something*), but the Memory recorder skips
    /// fallback runs — there's no clean structure to replay.
    let isFallback: Bool

    init(variants: [PolishVariant], issues: [GrammarIssue], isFallback: Bool = false) {
        self.variants = variants
        self.issues = issues
        self.isFallback = isFallback
    }

    static let empty = PolishResult(variants: [], issues: [])

    /// Parse a raw LLM text response (expected to be JSON matching our schema)
    /// into a `PolishResult`. Accepts both the legacy `"variants":["a","b"]` shape
    /// and the richer `"variants":[{"text":"a","back":"..."}]` shape so old models
    /// and old prompt-templates keep working. Tolerant of code fences and
    /// non-conforming JSON (surfaces raw text as a single variant in that case,
    /// with `isFallback = true` so memory recording can skip it).
    static func parse(_ raw: String) -> PolishResult {
        let stripped = stripCodeFences(raw)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PolishResult(variants: [PolishVariant(text: raw, backTranslation: nil)],
                                issues: [],
                                isFallback: true)
        }

        let variants = parseVariants(json["variants"])

        let issuesRaw = (json["issues"] as? [[String: Any]]) ?? []
        let issues: [GrammarIssue] = issuesRaw.compactMap { entry in
            let category = (entry["category"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let original = (entry["original"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let explanation = (entry["explanation"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !explanation.isEmpty else { return nil }
            return GrammarIssue(
                category: (category?.isEmpty == false) ? category : nil,
                original: (original?.isEmpty == false) ? original : nil,
                explanation: explanation
            )
        }

        if variants.isEmpty && issues.isEmpty {
            return PolishResult(variants: [PolishVariant(text: raw, backTranslation: nil)],
                                issues: [],
                                isFallback: true)
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

    /// Streaming-friendly counterpart to `parse(_:)`. Tolerates JSON that's still
    /// being emitted by an LLM — an open string is closed with `"`, open arrays
    /// with `]`, open objects with `}` — then runs the normal tolerant parser.
    /// Returns `.empty` when nothing parseable is in the buffer yet (e.g. the
    /// model has only emitted whitespace or an opening `{`).
    static func parsePartial(_ raw: String) -> PolishResult {
        let stripped = stripPartialCodeFences(raw)
        guard !stripped.isEmpty else { return .empty }

        // Fast path: well-formed JSON parses without repair.
        if let data = stripped.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
            return parse(stripped)
        }

        // Repair: scan to track whether we're inside a string and what nesting
        // is still open, then append the missing closers.
        let repaired = closeOpenJSONStructures(stripped)
        guard let data = repaired.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return .empty
        }
        // Don't surface raw text as a fallback variant during streaming — that
        // would flash the JSON skeleton in the UI for a frame. parse() does that
        // on its own when called via the normal path.
        let parsed = parse(repaired)
        if parsed.variants.count == 1,
           parsed.variants[0].text.hasPrefix("{") {
            return .empty
        }
        return parsed
    }

    /// Walk the buffer once tracking open `{`/`[` and whether we're inside a
    /// `"…"` string (accounting for `\"` escapes), then append the missing
    /// closing tokens.
    static func closeOpenJSONStructures(_ raw: String) -> String {
        var inString = false
        var escape = false
        var stack: [Character] = []   // pushed: '{' or '['

        for c in raw {
            if escape { escape = false; continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":  stack.append("{")
            case "[":  stack.append("[")
            case "}":  if stack.last == "{" { stack.removeLast() }
            case "]":  if stack.last == "[" { stack.removeLast() }
            default:   break
            }
        }

        var out = raw
        if inString { out += "\"" }
        while let top = stack.popLast() {
            out += (top == "{" ? "}" : "]")
        }
        return out
    }

    /// Like `stripCodeFences` but tolerant of the trailing ``` not having
    /// arrived yet — only strips the prefix fence and lets the parser handle
    /// the unterminated suffix.
    private static func stripPartialCodeFences(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                // Just `` ```json`` so far — nothing to parse yet.
                return ""
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
///
/// Token-usage tracking is a cross-cutting concern handled by the helpers in
/// `Usage/UsageReporter.swift` — providers feed their parsed SSE chunks into
/// `OpenAIUsageStream` or `AnthropicUsageStream` rather than reimplementing
/// the format-specific accounting per provider.
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func isAvailable() -> Bool
    func polish(_ text: String, mode: PolishMode) async throws -> PolishResult
    /// Streaming variant of polish — emits a fresh `PolishResult` snapshot each
    /// time the provider has parsed more of the model's output. Final emission
    /// is the fully parsed result; the stream then finishes. Default impl wraps
    /// the non-streaming `polish` so providers can opt out per-protocol.
    func polishStream(_ text: String, mode: PolishMode) -> AsyncThrowingStream<PolishResult, Error>
    /// Streaming explanation — emits the **accumulated** text so far on each
    /// chunk, so the popup can render a growing prose block. Plain text, no
    /// JSON. Default impl builds the explain prompt and feeds it through
    /// `chatCompletionStream`, which providers override for the real SSE
    /// transport.
    func explainStream(_ text: String, targetLanguage: String) -> AsyncThrowingStream<String, Error>
    /// Provider-specific raw chat completion stream. Declared on the protocol
    /// (not just the extension) so conformances override it via dynamic
    /// dispatch — without this declaration, the extension's "not implemented"
    /// default wins even when a provider supplies its own SSE implementation.
    func chatCompletionStream(prompt: String) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    /// Fallback streaming polish for providers that don't override: do one
    /// blocking `polish` call and emit a single snapshot. Loses the smooth UI
    /// fill-in but keeps the rest of the codebase uniform.
    func polishStream(_ text: String, mode: PolishMode) -> AsyncThrowingStream<PolishResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await polish(text, mode: mode)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default explainStream — feeds the explain prompt through the same
    /// transport as polish (a single user message, plain-text response). Each
    /// emission is the accumulated explanation text so far. Providers override
    /// only if they need a different prompt/transport for explain.
    func explainStream(_ text: String, targetLanguage: String) -> AsyncThrowingStream<String, Error> {
        let prompt = ExplainPrompt.build(text: text, targetLanguage: targetLanguage)
        return chatCompletionStream(prompt: prompt)
    }

    /// Default chat-completion stream: errors out. Providers that support
    /// Explain implement this with their real SSE transport. Listed here so the
    /// protocol requirement compiles even for hypothetical future providers
    /// that don't support plain-text streaming.
    func chatCompletionStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: LLMError.providerUnavailable(
                    reason: "Provider does not implement plain-text streaming."
                )
            )
        }
    }
}

/// Runtime registry of LLM providers. Resolves to:
///   1. Every `OpenAIStockPresets` entry, materialised into an
///      `OpenAICompatibleProvider` with the user's current endpoint/model
///      overrides applied. (OpenAI, DeepSeek, OpenRouter, Z.AI today.)
///   2. Every user-defined entry in `CustomProviderStore`, also materialised
///      as an `OpenAICompatibleProvider`.
///   3. The `KimiCodingProvider` — Anthropic-shaped, so it sits next to the
///      plugin model rather than inside it.
///
/// `all` is computed each access so config changes (model picked, custom
/// provider added) are visible immediately. The list is small enough that the
/// extra UserDefaults reads per call don't matter.
enum LLMRegistry {
    static var all: [LLMProvider] {
        var providers: [LLMProvider] = OpenAIStockPresets.all.map(makeProvider(for:))
        providers.append(contentsOf: CustomProviderStore.all().map(makeProvider(for:)))
        // DeepSeek and Kimi are dedicated classes — each handles a quirk the
        // generic plugin shape can't express (DeepSeek's reasoning_content,
        // Kimi's Anthropic-format API).
        providers.append(DeepSeekProvider())
        providers.append(KimiCodingProvider())
        // MiniMax coding plan — Anthropic-shaped like Kimi but Bearer-auth.
        providers.append(MiniMaxCodingProvider())
        // Apple's on-device model — only when the OS reports it usable
        // (Apple Silicon + macOS 26 + Apple Intelligence enabled + model
        // downloaded). Gated here so it never shows on machines that can't
        // run it; the Settings row is gated on the same `isAvailable()`.
        let appleFoundation = AppleFoundationProvider()
        if appleFoundation.isAvailable() {
            providers.append(appleFoundation)
        }
        return providers
    }

    /// Build an `OpenAICompatibleProvider` from a stock preset, applying any
    /// user overrides for endpoint and model from UserDefaults.
    static func makeProvider(for preset: OpenAIStockPresets.Preset) -> OpenAICompatibleProvider {
        let endpoint = URL(string: preset.currentEndpoint())
            ?? URL(string: preset.defaultEndpoint)!
        return OpenAICompatibleProvider(
            id: preset.id,
            displayName: preset.displayName,
            endpointURL: endpoint,
            model: preset.currentModel(),
            keychainAccount: preset.id,
            extraBodyJSON: preset.extraBodyJSON
        )
    }

    /// Build an `OpenAICompatibleProvider` from a user-defined custom entry.
    /// Falls back to a placeholder URL if the user typed something
    /// unparseable — `isAvailable()` will return false on the next request
    /// and the UI surfaces the config error.
    static func makeProvider(for config: CustomProviderConfig) -> OpenAICompatibleProvider {
        let endpoint = URL(string: config.endpoint)
            ?? URL(string: "https://invalid.local/")!
        return OpenAICompatibleProvider(
            id: config.providerID,
            displayName: config.displayName,
            endpointURL: endpoint,
            model: config.model,
            keychainAccount: config.providerID,
            extraBodyJSON: nil
        )
    }

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
        let list = all
        return list.first { $0.id == id } ?? list.first
    }

    /// Look up a provider's display name by id. Used by the usage tab so the
    /// table renders human-readable rows regardless of where the provider came
    /// from (stock / custom / Kimi).
    static func displayName(for id: String) -> String {
        all.first { $0.id == id }?.displayName ?? id
    }
}
