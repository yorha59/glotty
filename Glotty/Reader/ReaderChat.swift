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
        /// The reply failed — rate limit, network, a dropped request. Flagged
        /// so the bubble can offer a retry instead of making the question be
        /// retyped.
        var isError = false
        /// The turn is a passage sent by Ask rather than something typed. The
        /// bubble shows the passage alone — the "explain this" instruction goes
        /// in the prompt, not into the visible text, so the model still sees
        /// the reader's own language and answers in it.
        var isQuoteAsk = false
        /// Where the quoted passage came from, so the bubble can offer a jump
        /// back to it. Set for turns that quote a selection (Ask / Add); nil
        /// for a plain typed question. `page` alone means a PDF.
        var srcChapter: Int?
        var srcPage: Int?
        /// The quoted passage itself, shown as a chip and used to highlight the
        /// spot on jump. Held apart from `text` (which also carries the typed
        /// question and is what the model sees).
        var srcText: String?
        var hasSource: Bool { srcPage != nil }
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
        guard info?.id != bookID else {
            // Same book — just let the title/path fill in if they were nil.
            if bookTitle.isEmpty { bookTitle = info?.title ?? "" }
            if bookPath == nil { bookPath = info?.path }
            return
        }
        // Leaving a book: persist its conversation under ITS id, then drop the
        // messages so the switch can't re-save them under the next book. Saving
        // after bookID had already changed is what filed one book's chat under
        // another and made it show up there.
        stop()                 // saves the outgoing thread under the current (old) id
        messages.removeAll()   // nothing to carry onto — or re-save under — the new book
        context = nil
        attachments.removeAll()

        bookID = info?.id
        bookTitle = info?.title ?? ""
        bookPath = info?.path

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
        attachments.removeAll()
        threadID = session.id
        sessionStartedAt = session.date
        context = session.context
        messages = session.messages.map {
            Msg(role: $0.role == "user" ? .user : .assistant, text: $0.text,
                srcChapter: $0.srcChapter, srcPage: $0.srcPage, srcText: $0.srcText)
        }
    }

    /// Begin a new conversation. The previous one is already on disk — every
    /// reply saves — so nothing is lost by switching away.
    func startNewSession() {
        stop()
        attachments.removeAll()
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
    func attach(_ text: String, chapter: Int? = nil, page: Int? = nil) {
        let quote = ReaderState.cleanSelection(text)
        guard !quote.isEmpty, !isStreaming else { return }
        messages.append(Msg(role: .user, text: "\u{201C}\(quote)\u{201D}",
                            isQuoteAsk: true, srcChapter: chapter, srcPage: page, srcText: quote))
        deliver()
    }

    /// A passage staged for the next question. Held as a reference rather than
    /// pasted into the input: a paragraph of prose buries whatever you're
    /// trying to type, and once it's plain text there's no way to drop just
    /// one of several without editing around it.
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// Where the passage was picked, carried onto the sent message so it
        /// can link back. `page` alone means a PDF.
        var chapter: Int?
        var page: Int?
        /// Enough to recognise which selection this is, not the selection.
        var label: String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.count > 20 ? String(flat.prefix(20)) + "…" : flat
        }
    }
    @Published private(set) var attachments: [Attachment] = []

    /// Stage a passage for the next question. Ask answers "what does this
    /// say?" on its own; this is for when the question is something else and
    /// the passage is only what it's about. Several can be gathered.
    func quote(_ text: String, chapter: Int? = nil, page: Int? = nil) {
        let quote = ReaderState.cleanSelection(text)
        guard !quote.isEmpty else { return }
        attachments.append(Attachment(text: quote, chapter: chapter, page: page))
        focusRequests &+= 1
    }

    func removeAttachment(_ a: Attachment) {
        attachments.removeAll { $0.id == a.id }
    }

    /// Bumped when the composer should take focus — after Add drops a passage
    /// in, typing is the next thing wanted.
    @Published private(set) var focusRequests = 0

    /// Set by the reader view to turn a quote link back into a page turn +
    /// highlight. The panel can't reach the document itself, so it hands off
    /// the spot and the passage and the view navigates and marks it.
    var onJump: ((_ chapter: Int, _ page: Int, _ passage: String) -> Void)?

    /// Take the reader to where a quoted passage was picked and mark it.
    func jump(to m: Msg) {
        guard let page = m.srcPage else { return }
        onJump?(m.srcChapter ?? 0, page, m.srcText ?? "")
    }

    func send() {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty, !isStreaming else { return }
        // The staged passages travel with the question as one turn, so the
        // transcript keeps what was being discussed.
        let quoted = attachments
            .map { "\u{201C}\($0.text)\u{201D}" }
            .joined(separator: "\n\n")
        let full = [quoted, typed].filter { !$0.isEmpty }.joined(separator: "\n\n")
        // ponytail: link to the first passage's spot. Gathering passages from
        // several pages into one turn is rare; per-passage anchors if it isn't.
        let src = attachments.first
        input = ""
        attachments.removeAll()
        messages.append(Msg(role: .user, text: full,
                            srcChapter: src?.chapter, srcPage: src?.page, srcText: src?.text))
        deliver()
    }

    /// Send the last question again after a failure. Drops the failed reply
    /// so the retry replaces it rather than stacking another bubble, and
    /// re-uses the question already in the transcript — a rate limit shouldn't
    /// cost you what you typed.
    func retry() {
        guard !isStreaming else { return }
        while let last = messages.last, last.role == .assistant, last.isError {
            messages.removeLast()
        }
        guard messages.last?.role == .user else { return }
        deliver()
    }

    /// True when the last turn is a question with no reply — a live send whose
    /// error bubble was cleared, or (more often) a thread reopened after a
    /// failed turn, since errors aren't persisted. The panel offers a retry.
    var lastQuestionUnanswered: Bool {
        !isStreaming && messages.last?.role == .user
    }

    /// Stream a reply for whatever the last user turn is. Shared by typing a
    /// question and by Ask, so both behave identically from here on.
    private func deliver() {
        let prompt = buildPrompt()
        ReaderPromptLog.record(prompt)   // debug: see exactly what the model gets
        guard let stream = ReaderCore.services?.chatStream(prompt: prompt) else {
            messages.append(Msg(
                role: .assistant,
                text: String(localized: "No language model is configured. Choose one in Settings → Language Model."),
                isError: true))
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
                var latest = ""
                var lastPaintAt: Date?
                for try await snapshot in stream {
                    guard let self else { return }
                    if self.phase == .waiting { self.phase = .writing }
                    self.lastChunkAt = Date()
                    latest = snapshot
                    let now = Date()
                    if lastPaintAt.map({ now.timeIntervalSince($0) >= 0.05 }) ?? true {
                        if self.messages.indices.contains(idx) { self.messages[idx].text = snapshot }
                        lastPaintAt = now
                    }
                }
                // The last chunk may land inside the 50ms paint window.
                if let self, self.messages.indices.contains(idx), self.messages[idx].text != latest {
                    self.messages[idx].text = latest
                }
                // A stream that ends without ever producing text isn't a reply.
                if let self, self.messages.indices.contains(idx),
                   self.messages[idx].text.isEmpty {
                    self.messages[idx].text = String(localized: "No reply came back.")
                    self.messages[idx].isError = true
                }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                if let self, self.messages.indices.contains(idx), self.messages[idx].text.isEmpty {
                    self.messages[idx].text = String(localized: "Couldn't get a reply: ") + error.localizedDescription
                    self.messages[idx].isError = true
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
                        "No reply after \(Int(idle))s — is Glotty running?")
                    self.messages[i].isError = true
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
            // Errors and the empty in-flight placeholder aren't conversation —
            // saving them reloads a fake reply with no retry and poisons the
            // next prompt. A failed turn leaves its question as the last saved
            // message, which the panel treats as retryable.
            messages: messages.filter { !$0.isError && !$0.text.isEmpty }.map {
                SavedMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text,
                             srcChapter: $0.srcChapter, srcPage: $0.srcPage, srcText: $0.srcText)
            })
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
        // What's around what they're reading — the PDF path sends the current
        // page plus its neighbours (tagged), so a question about a section that
        // spans a page break isn't answered "the page doesn't cover that" when
        // the answer is a paragraph over. Capped for token cost, not transport;
        // wide enough for ~3 dense pages.
        let page = String((pageTextProvider?() ?? "").prefix(9000))
        if !page.isEmpty {
            p += "The page the user is reading (with the pages around it):\n\"\"\"\n\(page)\n\"\"\"\n\n"
        }
        for m in messages where !m.isError {   // ends with the user's latest question
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
