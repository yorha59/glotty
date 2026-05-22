import Foundation

/// Helpers for extracting token-usage statistics from streaming LLM responses
/// and forwarding them to `UsageStore`. Each provider plugs in the helper that
/// matches its API shape; the per-format SSE parsing lives here so new
/// providers don't have to reimplement it.
///
/// To wire up a new provider:
/// - **OpenAI-compatible streaming** (Z.AI, OpenAI, Together, Groq, …):
///   spread `OpenAIUsageStream.streamOptions` into the request body, then call
///   `OpenAIUsageStream.record(from:providerID:)` once per parsed SSE event.
/// - **Anthropic-compatible streaming** (Claude, Kimi-for-coding, …): create
///   an `AnthropicUsageStream(providerID:)` before the parse loop, call
///   `observe(event:)` for each parsed event, and `finalize()` once after the
///   stream ends.
///
/// If a future provider speaks a third format, add a new helper here rather
/// than scattering parsing logic across providers.

enum OpenAIUsageStream {
    /// Request-body fragment that opts the stream into populating the final
    /// SSE chunk's `usage` block. Without this, OpenAI-shaped streaming
    /// responses report `null` usage and tokens can't be billed.
    static let streamOptions: [String: Any] = ["include_usage": true]

    /// Inspect a parsed SSE event for a `usage` block and record it to
    /// `UsageStore` if present. OpenAI sends one such block in the very last
    /// chunk (where `choices` is empty). Returns whether anything was recorded
    /// so callers can decide to skip the rest of their event-handling logic.
    @discardableResult
    static func record(from event: [String: Any], providerID: String) -> Bool {
        guard let usage = event["usage"] as? [String: Any] else { return false }
        let prompt = (usage["prompt_tokens"] as? Int) ?? 0
        let completion = (usage["completion_tokens"] as? Int) ?? 0
        guard prompt > 0 || completion > 0 else { return false }
        UsageStore.recordFromProvider(
            providerID: providerID,
            promptTokens: prompt,
            completionTokens: completion
        )
        return true
    }
}

/// Stateful accumulator for Anthropic-shaped streams. Token counts arrive in
/// two places: `message_start.message.usage.input_tokens` carries the prompt
/// count, and each `message_delta.usage.output_tokens` carries a cumulative
/// completion count. Use one instance per request.
final class AnthropicUsageStream {
    private var promptTokens = 0
    private var completionTokens = 0
    private let providerID: String

    init(providerID: String) {
        self.providerID = providerID
    }

    /// Feed each parsed SSE event in. Cheap no-op for events that don't carry
    /// usage data.
    func observe(event: [String: Any]) {
        let type = event["type"] as? String
        if type == "message_start",
           let message = event["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            promptTokens = (usage["input_tokens"] as? Int) ?? promptTokens
            completionTokens = (usage["output_tokens"] as? Int) ?? completionTokens
        } else if type == "message_delta",
                  let usage = event["usage"] as? [String: Any] {
            completionTokens = (usage["output_tokens"] as? Int) ?? completionTokens
        }
    }

    /// Write the accumulated counts to `UsageStore`. Call once after the
    /// stream ends; no-op if neither counter was populated.
    func finalize() {
        guard promptTokens > 0 || completionTokens > 0 else { return }
        UsageStore.recordFromProvider(
            providerID: providerID,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}
