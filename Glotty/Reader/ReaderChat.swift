import SwiftUI

/// A lightweight tutor chat for the reader's side panel. "Ask" quotes the
/// selected passage into the message being written, so the question and the
/// text it's about are one turn; replies stream from the configured provider
/// and every conversation is saved against the book.
@MainActor
final class ReaderChat: ObservableObject {
    struct Msg: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// The turn is a passage sent by Ask rather than something typed. The
        /// bubble shows the passage alone — the "explain this" instruction goes
        /// in the prompt, not into the visible text, so the model still sees
        /// the reader's own language and answers in it.
        var isQuoteAsk = false
    }

    @Published var messages: [Msg] = []
    /// Only still here so conversations saved before Ask started quoting into
    /// the message still decode; nothing sets it now.
    @Published var context: String?
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

    /// Conversations saved for this book, newest first.
    @Published private(set) var sessions: [SavedDialogue] = []
    /// Which saved conversation is on screen, so the picker can mark it.
    var currentSessionID: UUID { threadID }

    /// When the open conversation was started, for the placeholder row. Named
    /// apart from `startedAt`, which times the in-flight reply.
    private var sessionStartedAt = Date()

    /// The open conversation has nothing worth keeping yet — no reply has
    /// landed, so it was never written to disk.
    private var currentIsUnsaved: Bool { !sessions.contains { $0.id == threadID } }

    /// Rows for the rail: the saved conversations, plus the one just started.
    /// A brand-new conversation has nothing to save, so it wouldn't appear at
    /// all — clicking "new" looked like nothing happened. It's listed as a
    /// placeholder and takes a real title once there's something in it; leave
    /// without saying anything and it's simply never written.
    var listedSessions: [SavedDialogue] {
        guard currentIsUnsaved else { return sessions }
        let placeholder = SavedDialogue(
            id: threadID,
            title: String(localized: "New conversation"),
            date: sessionStartedAt,
            context: context,
            messages: [])
        return [placeholder] + sessions
    }

    /// Bind the chat to the open book and pick up where it left off. Opening a
    /// book used to hand back an empty panel even though the conversation was
    /// on disk — the thread was saved but never read back.
    func setBook(_ info: ReaderState.BookInfo?) {
        let changed = info?.id != bookID
        bookID = info?.id
        bookTitle = info?.title ?? ""
        bookPath = info?.path
        guard changed else { return }
        stop()
        context = nil
        refreshSessions()
        if let latest = sessions.first { load(latest) } else { startNewSession() }
    }

    func refreshSessions() {
        sessions = bookID.map { BookLibrary.dialogues(bookID: $0) } ?? []
    }

    /// Show a saved conversation. The in-flight reply (if any) belongs to the
    /// thread being left, so it's cancelled rather than landing in this one.
    func load(_ session: SavedDialogue) {
        stop()
        threadID = session.id
        sessionStartedAt = session.date
        context = session.context
        messages = session.messages.map {
            Msg(role: $0.role == "user" ? .user : .assistant, text: $0.text)
        }
    }

    /// Begin a new conversation. The previous one is already on disk — every
    /// reply saves — so nothing is lost by switching away.
    func startNewSession() {
        stop()
        messages.removeAll()
        context = nil
        threadID = UUID()
        sessionStartedAt = Date()
        refreshSessions()
    }

    func delete(_ session: SavedDialogue) {
        guard let bookID else { return }
        let deletingOpenOne = session.id == threadID
        if deletingOpenOne {
            // Let go of the in-memory thread *before* deleting. Switching away
            // saves whatever is on screen, so leaving these messages under the
            // same id would write the record straight back after the delete.
            stop()
            messages.removeAll()
            context = nil
            threadID = UUID()
        }
        BookLibrary.deleteDialogue(bookID: bookID, id: session.id)
        refreshSessions()
        // Deleting the open conversation leaves nothing on screen — show the
        // next most recent, or stay on the fresh empty one.
        if deletingOpenOne, let next = sessions.first { load(next) }
    }

    func rename(_ session: SavedDialogue, to title: String) {
        guard let bookID else { return }
        BookLibrary.renameDialogue(bookID: bookID, id: session.id, title: title)
        refreshSessions()
    }

    /// Bring a selected passage into the message being written, rather than
    /// pinning it above the composer as a separate thing to keep track of. It
    /// goes into the transcript with the question, so the conversation reads
    /// as a whole and follow-ups don't have to re-state what was quoted.
    /// Ask about a selected passage — sent straight away rather than parked in
    /// the composer. The visible turn is the passage itself; asking for the
    /// explanation is the prompt's job, so the request carries the reader's own
    /// language and comes back in it.
    func attach(_ text: String) {
        let quote = ReaderState.cleanSelection(text)
        guard !quote.isEmpty, !isStreaming else { return }
        messages.append(Msg(role: .user, text: "\u{201C}\(quote)\u{201D}", isQuoteAsk: true))
        deliver()
    }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(Msg(role: .user, text: q))
        deliver()
    }

    /// Stream a reply for whatever the last user turn is. Shared by typing a
    /// question and by Ask, so both behave identically from here on.
    private func deliver() {
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

    /// Kept as the name the panel's "new conversation" control uses.
    func reset() { startNewSession() }

    /// Persist without going through a live reply — lets the headless suite
    /// exercise saving/restoring without an LLM.
    func saveThreadForTesting() { saveThread() }

    /// Persist the current thread into the book's saved dialogues.
    private func saveThread() {
        guard let bookID, !messages.isEmpty,
              messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return }
        // Keep a title the user set: it's derived from the first question only
        // as a default, and re-deriving on every save would undo a rename.
        let existing = sessions.first { $0.id == threadID }?.title
        let derived = messages.first(where: { $0.role == .user })?.text ?? context ?? "Conversation"
        let dialogue = SavedDialogue(
            id: threadID,
            title: existing ?? String(derived.prefix(70)),
            date: Date(),
            context: context,
            messages: messages.map { SavedMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) })
        BookLibrary.saveDialogue(bookID: bookID, title: bookTitle, path: bookPath, dialogue)
        refreshSessions()
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
        for m in messages {   // ends with the user's latest question
            p += (m.role == .user ? "User: " : "Assistant: ") + m.text + "\n"
        }
        // Ask sends the passage with no question attached, so say what's wanted
        // here rather than wrapping the visible turn in English — that would
        // make a Chinese reader's selection read as an English question and
        // come back answered in English.
        if messages.last(where: { $0.role == .user })?.isQuoteAsk == true {
            p += """

                The user selected that passage while reading and wants it explained: \
                what it means, and what it refers to in the surrounding text. Answer \
                in the language of the passage.

                """
        }
        p += "Assistant:"
        return p
    }
}
