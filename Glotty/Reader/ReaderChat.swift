import SwiftUI

/// A lightweight tutor chat for the reader's side panel. The user adds a
/// selected passage as context ("Ask"), then asks follow-up questions; replies
/// stream from the configured LLM provider. Session-only (not persisted).
@MainActor
final class ReaderChat: ObservableObject {
    struct Msg: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    @Published var messages: [Msg] = []
    @Published var context: String?          // the attached passage
    @Published var input: String = ""
    @Published var isStreaming = false

    /// What the reply is doing, so the panel can say so instead of showing a
    /// bare "…" that reads identically whether the model is thinking, the
    /// request was dropped, or the app is wedged.
    enum Phase { case idle, waiting, writing }
    @Published private(set) var phase: Phase = .idle
    /// Seconds since the question was sent, ticked once a second while active.
    @Published private(set) var elapsed: TimeInterval = 0

    private var startedAt: Date?
    private var lastChunkAt: Date?
    private var ticker: Timer?

    /// One line describing the in-flight reply, e.g. "Waiting for Glotty… 3s".
    /// The elapsed count is the point: it distinguishes slow from stuck.
    var statusLine: String {
        let secs = Int(elapsed)
        switch phase {
        case .idle:    return ""
        case .waiting: return String(localized: "Waiting for Glotty… \(secs)s")
        case .writing: return String(localized: "Writing… \(secs)s")
        }
    }

    // Book the conversation is about — used to persist the thread.
    private var bookID: String?
    private var bookTitle = ""
    private var bookPath: String?
    private var threadID = UUID()

    private var task: Task<Void, Never>?

    /// Text of the page the reader is looking at, pulled fresh at send time so
    /// the answer is about wherever they are now — not wherever they were when
    /// the panel opened.
    var pageTextProvider: (() -> String)?

    /// Bind the chat to the open book; a different book starts a fresh thread.
    func setBook(_ info: ReaderState.BookInfo?) {
        if info?.id != bookID { reset() }
        bookID = info?.id
        bookTitle = info?.title ?? ""
        bookPath = info?.path
    }

    /// Attach a selection as the passage the conversation is about.
    func attach(_ text: String) {
        context = ReaderState.cleanSelection(text)
    }
    func clearContext() { context = nil }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(Msg(role: .user, text: q))

        let prompt = buildPrompt()
        guard let stream = ReaderCore.services?.chatStream(prompt: prompt) else {
            messages.append(Msg(role: .assistant,
                text: String(localized: "No language model is configured. Choose one in Settings → Language Model.")))
            return
        }

        messages.append(Msg(role: .assistant, text: ""))
        let idx = messages.count - 1
        isStreaming = true
        phase = .waiting
        startedAt = Date()
        startTicking()
        task = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard let self else { return }
                    if self.phase == .waiting { self.phase = .writing }
                    self.lastChunkAt = Date()
                    if self.messages.indices.contains(idx) { self.messages[idx].text = snapshot }
                }
                // A stream that ends without ever producing text isn't a reply.
                if let self, self.messages.indices.contains(idx),
                   self.messages[idx].text.isEmpty {
                    self.messages[idx].text = String(localized: "No reply came back. Try again.")
                }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                if let self, self.messages.indices.contains(idx), self.messages[idx].text.isEmpty {
                    self.messages[idx].text = String(localized: "Couldn't get a reply: ") + error.localizedDescription
                }
            }
            self?.finish()
        }
    }

    /// Give up when nothing has arrived for a while. The reply travels as a
    /// distributed notification, which is fire-and-forget: if Glotty isn't
    /// listening at that moment (restarting, quit, crashed) the request is
    /// dropped with no error at all. Without this the stream never ends, so
    /// `isStreaming` stays true and `send`'s guard silently swallows every
    /// later message — the panel wedges until the app restarts.
    /// Instance properties, not constants, so the headless self-test can dial
    /// them down and actually observe the recovery instead of assuming it.
    var firstChunkTimeout: TimeInterval = 45
    var stallTimeout: TimeInterval = 60

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStreaming else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt ?? Date())
                let idle = Date().timeIntervalSince(self.lastChunkAt ?? self.startedAt ?? Date())
                let limit = self.phase == .waiting ? self.firstChunkTimeout : self.stallTimeout
                guard idle > limit else { return }
                self.task?.cancel()
                if let i = self.messages.indices.last, self.messages[i].role == .assistant,
                   self.messages[i].text.isEmpty {
                    self.messages[i].text = String(localized:
                        "No reply after \(Int(idle))s — is Glotty running? Send again to retry.")
                }
                self.finish()
            }
        }
    }

    private func finish() {
        ticker?.invalidate(); ticker = nil
        isStreaming = false
        phase = .idle
        elapsed = 0
        startedAt = nil
        lastChunkAt = nil
        saveThread()
    }

    func stop() { task?.cancel(); finish() }

    func reset() {
        stop()
        messages.removeAll()
        context = nil
        threadID = UUID()
    }

    /// Persist the current thread into the book's saved dialogues.
    private func saveThread() {
        guard let bookID, !messages.isEmpty,
              messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return }
        let title = messages.first(where: { $0.role == .user })?.text ?? context ?? "Conversation"
        let dialogue = SavedDialogue(
            id: threadID,
            title: String(title.prefix(70)),
            date: Date(),
            context: context,
            messages: messages.map { SavedMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) })
        BookLibrary.saveDialogue(bookID: bookID, title: bookTitle, path: bookPath, dialogue)
    }

    private func buildPrompt() -> String {
        var p = "You are a patient reading tutor helping someone understand a document. "
        // Reply in the question's language, not `glotty.targetLang` — that's the
        // translation target (what the user is learning), which is usually the
        // opposite of what they want a question answered in. Asking in Chinese
        // used to get an English reply.
        p += "Answer clearly and concisely, and ALWAYS reply in the same language "
        p += "the user writes their question in.\n"
        // Without this the model treats the page as the only permitted source
        // and refuses anything it doesn't cover ("this material only explains
        // X, you'd need to consult other documentation") — which reads as no
        // answer at all. The page is context, not a fence.
        p += "The page below is context, not a limit on what you may say. When it "
        p += "doesn't cover the question, answer from your own knowledge anyway — "
        p += "note in one short clause that the passage doesn't cover it, then give "
        p += "the answer. Never reply with only a refusal.\n\n"
        // What's on screen right now. The user asks about what they're reading,
        // usually without selecting anything first; without this the model only
        // saw the attached snippet and would answer that it can't see the rest.
        // Capped for token cost, not transport — a dense PDF page's text can run
        // long, and the tail matters less than what's on screen at the top.
        let page = String((pageTextProvider?() ?? "").prefix(4000))
        if !page.isEmpty {
            p += "The page the user is currently reading:\n\"\"\"\n\(page)\n\"\"\"\n\n"
        }
        if let ctx = context, !ctx.isEmpty {
            p += "The user specifically selected this passage from that page:\n\"\"\"\n\(ctx)\n\"\"\"\n\n"
        }
        for m in messages {   // ends with the user's latest question
            p += (m.role == .user ? "User: " : "Assistant: ") + m.text + "\n"
        }
        p += "Assistant:"
        return p
    }
}
