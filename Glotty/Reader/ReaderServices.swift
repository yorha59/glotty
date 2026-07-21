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
    /// Providers the user has configured, with their models and which is live.
    /// Async because the standalone Reader has to ask Glotty over IPC — it
    /// doesn't link the LLM registry.
    func providers() async -> [ReaderProvider]
    /// Switch the active provider and/or model.
    func selectModel(providerID: String, modelID: String)
}

/// One configured provider as the reader sees it — enough to render a menu,
/// nothing about how it's reached.
struct ReaderProvider: Identifiable, Equatable, Codable {
    struct Model: Identifiable, Equatable, Codable {
        let id: String
        let name: String
    }
    let id: String
    let name: String
    let models: [Model]
    /// True for the provider currently in use.
    var isActive: Bool
    /// Model id currently selected for this provider, when it has one.
    var activeModelID: String?
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
    /// Glotty → Reader: the finished look-up/translate result to record + underline.
    static let resultName = Notification.Name("com.ruojunye.glotty.reader.result")
    /// Reader → Glotty: a chat prompt; Glotty streams the reply back.
    static let chatRequestName = Notification.Name("com.ruojunye.glotty.reader.chat.request")
    static let chatChunkName   = Notification.Name("com.ruojunye.glotty.reader.chat.chunk")
    static let chatDoneName    = Notification.Name("com.ruojunye.glotty.reader.chat.done")
    /// Reader → Glotty: "what providers/models are configured?"; Glotty replies
    /// on `providersReplyName` with a JSON payload (userInfo values have to be
    /// small strings, so the list travels encoded rather than as a dictionary).
    static let providersRequestName = Notification.Name("com.ruojunye.glotty.reader.providers.request")
    static let providersReplyName   = Notification.Name("com.ruojunye.glotty.reader.providers.reply")
    /// Reader → Glotty: switch provider/model. userInfo: `["provider", "model"]`.
    static let selectModelName = Notification.Name("com.ruojunye.glotty.reader.model.select")
    static let glottyBundleID = "com.ruojunye.glotty"
}
