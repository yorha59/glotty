import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM provider backed by Apple's Foundation Models framework
/// (`LanguageModelSession` over `SystemLanguageModel.default`).
///
/// Unlike every other provider, this one is **free, private, and offline** —
/// no API key, no network, nothing leaves the Mac. It's only useful when
/// `AppleIntelligenceStatus.current() == .available` (Apple Silicon, macOS 26+,
/// Apple Intelligence enabled, model downloaded), so `LLMRegistry` only appends
/// it when `isAvailable()` is true and Settings only shows its row then. On a
/// machine where Apple Intelligence is off/ineligible it simply never appears.
///
/// It reuses the same `PolishPrompt` / `ExplainPrompt` builders and the same
/// `PolishResult` JSON parsing as the cloud providers — the on-device model is
/// instructed to emit the same strict-JSON shape, and we feed its streamed text
/// through `PolishResult.parsePartial` exactly like the SSE providers do. That
/// keeps the popup/memory/usage layers provider-agnostic.
///
/// Temperatures match `OpenAICompatibleProvider` (0.3 for polish JSON, 0.5 for
/// the prose explain stream) so output style is consistent across engines.
struct AppleFoundationProvider: LLMProvider {
    let id = "apple-foundation"
    let displayName = "Apple Intelligence (On-Device)"

    func isAvailable() -> Bool {
        AppleIntelligenceStatus.current() == .available
    }

    func polish(_ text: String, mode: PolishMode) async throws -> PolishResult {
        // Drain the stream and keep the last snapshot — mirrors
        // OpenAICompatibleProvider so the two share one code path shape.
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
                    // PolishPrompt.build reads main-isolated MemoryStore state;
                    // hop to main before building, like the cloud providers.
                    let prompt = await MainActor.run { PolishPrompt.build(text: text, mode: mode) }
                    var lastText = ""
                    for try await chunk in streamText(prompt: prompt, temperature: 0.3) {
                        try Task.checkCancellation()
                        lastText = chunk
                        let snapshot = PolishResult.parsePartial(lastText)
                        if snapshot != .empty {
                            continuation.yield(snapshot)
                        }
                    }
                    let final = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !final.isEmpty else { throw LLMError.emptyResponse }
                    // Final full parse — covers the case where parsePartial bailed
                    // on every intermediate chunk.
                    continuation.yield(PolishResult.parse(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chatCompletionStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var last = ""
                    for try await chunk in streamText(prompt: prompt, temperature: 0.5) {
                        try Task.checkCancellation()
                        last = chunk
                        continuation.yield(last)
                    }
                    guard !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw LLMError.emptyResponse
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Bridge the Foundation Models response stream into a plain
    /// `AsyncThrowingStream<String>` of **cumulative** text snapshots, so the
    /// polish/explain code above looks identical to the SSE path. Each
    /// `ResponseStream` snapshot's `.content` is the full text generated so far.
    private func streamText(prompt: String, temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // FoundationModels symbols are macOS 26+. The app's deployment
            // target is lower (Sequoia), so guard explicitly — `isAvailable()`
            // already keeps the provider out of the registry below 26, this is
            // just the compiler-required floor.
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let task = Task {
                    do {
                        let session = LanguageModelSession()
                        let options = GenerationOptions(temperature: temperature)
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            try Task.checkCancellation()
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.finish(
                    throwing: LLMError.providerUnavailable(
                        reason: "Apple Intelligence requires macOS 26 or newer."
                    )
                )
            }
            #else
            continuation.finish(
                throwing: LLMError.providerUnavailable(
                    reason: "Apple Intelligence is not available on this system."
                )
            )
            #endif
        }
    }

    /// Map Foundation Models errors onto `LLMError` so the popup surfaces a
    /// readable message. Guardrail refusals and unavailable-model cases become
    /// `providerUnavailable`; cancellation is passed through untouched.
    private static func mapError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let llm = error as? LLMError { return llm }
        return LLMError.providerUnavailable(reason: error.localizedDescription)
    }
}
