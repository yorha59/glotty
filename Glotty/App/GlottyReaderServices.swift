import AppKit

/// In-process `ReaderServices` for the Glotty menu-bar app: the reader lives in
/// the same process as the core, so it just calls straight through. The
/// standalone Reader app ships a different implementation that relays over IPC.
@MainActor
final class GlottyReaderServices: ReaderServices {
    func lookUp(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.handleFire(mode: .explain, providedText: text)
    }

    func translate(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.handleFire(mode: .translate, providedText: text)
    }

    func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>? {
        LLMRegistry.current()?.chatCompletionStream(prompt: prompt)
    }
}
