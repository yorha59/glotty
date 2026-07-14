import Foundation

/// The core AI actions the reader needs but doesn't own. Inside the Glotty
/// menu-bar app these run in-process (see `GlottyReaderServices`); the standalone
/// Reader app will implement the same protocol over IPC to a running Glotty.
/// Keeping the reader behind this seam means `Reader/` compiles into either app
/// without referencing `AppDelegate`, the LLM registry, or the popup directly.
@MainActor
protocol ReaderServices: AnyObject {
    /// Explain a tapped word / phrase — opens Glotty's explain popup.
    func lookUp(_ text: String)
    /// Translate a selection — opens Glotty's translate popup.
    func translate(_ text: String)
    /// Stream a chat completion for `prompt`; nil when no provider is available.
    func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>?
}

/// Set once at launch by whichever app hosts the reader window.
@MainActor
enum ReaderCore {
    static var services: ReaderServices?
}

/// Shared IPC constants for the standalone Reader ↔ Glotty channel (both targets
/// compile `Reader/`, so this stays in one place).
enum ReaderIPC {
    /// Distributed notification the Reader app posts; Glotty observes it and
    /// runs the matching popup. userInfo: `["action": "explain"|"translate",
    /// "text": <selection>]`.
    static let requestName = Notification.Name("com.ruojunye.glotty.reader.request")
    static let glottyBundleID = "com.ruojunye.glotty"
}
