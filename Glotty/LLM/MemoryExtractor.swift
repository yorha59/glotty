import Foundation

/// Post-chat memory extraction. After a polish or explain popup is
/// dismissed with a non-empty discussion thread, `extract(...)` runs
/// one LLM call asking the model to propose facts about the user
/// worth remembering for future personalization. Proposals land in
/// `LearnedMemoryStore` as `.pending` for the user to review in
/// Settings → Memory → Suggestions.
///
/// The extractor is best-effort and tolerant: an LLM error, a parse
/// failure, or a cooldown hit all silently no-op. Memory extraction
/// is an enhancement, not a hard requirement of the chat flow — it
/// must never block UX.
@MainActor
enum MemoryExtractor {
    /// How aggressively to extract memories from chat sessions.
    /// Picker in Settings → Memory writes the raw value.
    enum Mode: String, CaseIterable, Identifiable {
        /// Run after every chat reply (cards appear in real time
        /// during a conversation). Highest token cost.
        case auto
        /// Only run when the user clicks the in-chat "Extract
        /// memories" button. Zero cost while just chatting.
        case manual
        /// Never run. Hides the button too.
        case off

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto:   return String(localized: "Automatic")
            case .manual: return String(localized: "Manual")
            case .off:    return String(localized: "Off")
            }
        }

        var description: String {
            switch self {
            case .auto:
                return String(localized: "Glotty proposes new memories after every chat reply. Highest token usage.")
            case .manual:
                return String(localized: "Memories are only extracted when you click 'Extract memories' in the chat. Lower cost.")
            case .off:
                return String(localized: "No memory extraction at all. Existing accepted memories still inject into prompts.")
            }
        }
    }

    /// UserDefaults key for the extraction mode picker. Reads
    /// fall back to `.auto` for installs that never wrote a value;
    /// the legacy on/off toggle key is no longer read.
    static let modeKey = "glotty.memory.extractionMode"

    /// Current extraction mode resolved from UserDefaults.
    static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let mode = Mode(rawValue: raw) else { return .auto }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    /// Minimum interval between extraction runs across the entire
    /// app. Prevents the LLM bill exploding if the user power-uses
    /// polish. 10s is short enough that consecutive chat replies
    /// each get an extraction pass (cards appear in near-real-time
    /// during a conversation), long enough that rapid open-close
    /// flurries don't all fire.
    static let cooldownInterval: TimeInterval = 10

    /// Posted when extraction begins for a given source event so the
    /// in-chat UI can show a "Glotty is reviewing…" indicator.
    /// `userInfo["eventID"]` carries the UUID.
    static let didStartNotification = Notification.Name("glotty.memoryExtractor.didStart")

    /// Posted when extraction finishes (success OR failure) so the
    /// indicator can be dismissed. `userInfo["eventID"]` carries the
    /// UUID; `userInfo["count"]` carries the number of new proposals
    /// added (zero on failure or when nothing was worth extracting).
    static let didFinishNotification = Notification.Name("glotty.memoryExtractor.didFinish")

    /// Cap on proposals per extraction. The prompt also enforces this,
    /// but we trim defensively in case the LLM ignores the instruction.
    static let maxProposals = 5

    /// Last time `extract` actually fired an LLM call. nil = never.
    private static var lastExtractionAt: Date?


    /// Mode the extraction is being run for — drives wording of the
    /// context block in the prompt. Maps 1:1 to the popup modes that
    /// actually offer a chat.
    enum Source {
        case polish(sourceText: String, topVariant: String?)
        case explain(sourceText: String, explanation: String)
        /// Conversational practice session — no source text or
        /// Glotty-produced output, just the tutor/user dialogue.
        /// The extractor still mines the conversation for memories
        /// about the user (preferences, projects, vocabulary they
        /// volunteered).
        case tutor
    }

    /// Try to extract memories from the given chat thread. No-ops if:
    /// - extraction is disabled via the Settings toggle
    /// - the cooldown window hasn't elapsed since the previous run
    /// - the thread has no user messages (assistant-only doesn't
    ///   carry user signal worth remembering)
    /// - the LLM call fails or returns malformed JSON
    ///
    /// Successfully extracted proposals are added to
    /// `LearnedMemoryStore.shared` as `.pending` — dedup is handled
    /// inside the store, so re-running on the same thread is safe.
    /// Why this extraction was triggered. Auto-triggers respect the
    /// mode toggle and the cooldown; manual triggers bypass both
    /// gates so the user always gets an immediate response when
    /// they click the in-chat button.
    enum Trigger {
        case auto
        case manual
    }

    static func extract(
        thread: [PolishChatTurnSnapshot],
        source: Source,
        sourceEventID: UUID?,
        trigger: Trigger = .auto
    ) async {
        dbg("extract ENTER — thread=\(thread.count) turns, eventID=\(sourceEventID?.uuidString ?? "nil"), trigger=\(trigger)")
        // Mode gates auto only — manual always runs (subject to
        // the basic preconditions below).
        if trigger == .auto, mode != .auto {
            dbg("extract SKIP — mode is \(mode.rawValue)")
            return
        }
        if mode == .off {
            dbg("extract SKIP — mode is off")
            return
        }
        guard thread.contains(where: { $0.role == .user }) else {
            dbg("extract SKIP — no user turns")
            return
        }
        if trigger == .auto,
           let last = lastExtractionAt,
           Date().timeIntervalSince(last) < cooldownInterval {
            dbg("extract SKIP — cooldown (last=\(last))")
            return
        }
        guard let provider = LLMRegistry.current() else {
            dbg("extract SKIP — no LLM provider configured")
            return
        }

        // Mark immediately so concurrent dismissals don't both fire.
        lastExtractionAt = Date()

        let existing = LearnedMemoryStore.shared.allMemories()
        let prompt = buildPrompt(thread: thread, source: source, existing: existing)
        dbg("extract CALL — provider=\(provider.id), prompt=\(prompt.count) chars, existing=\(existing.count)")

        // Tell the UI an extraction has begun for this event so the
        // in-chat suggestion area can show a "Reviewing…" indicator.
        postStart(sourceEventID: sourceEventID)
        defer { postFinish(sourceEventID: sourceEventID, count: lastAddedCount) }

        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.memoryExtract) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            dbg("extract FAIL — \(error.localizedDescription)")
            return
        }

        dbg("extract RESPONSE — \(raw.count) chars")
        // Tag every new memory with the language the conversation was
        // in. Drives the strict-equality language filter in
        // `LearnedMemoryStore.contextBlock(for:targetLanguage:)`, so a
        // memory extracted from an English chat doesn't leak into a
        // later Chinese-target prompt and vice versa. Use the polish
        // target language as the proxy — that's the language of the
        // LLM's output across polish, explain, and tutor chats; the
        // conversation predominantly happens in that language.
        let extractionLang: String? = {
            let raw = UserDefaults.standard.string(forKey: "glotty.polishLang")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : "en"
        }()
        let proposals = parse(raw,
                              sourceEventID: sourceEventID,
                              sourceLanguage: extractionLang)
        dbg("extract PARSED — \(proposals.count) proposals (lang=\(extractionLang ?? "nil"))")
        guard !proposals.isEmpty else { return }
        let toAdd = Array(proposals.prefix(maxProposals))
        LearnedMemoryStore.shared.add(toAdd)
        lastAddedCount = toAdd.count
        dbg("extract STORED — added \(toAdd.count) to LearnedMemoryStore")
    }

    /// Carried out of `extract` into the `defer` block so the
    /// finish notification reports the correct count without
    /// duplicating the dispatch logic at every return site.
    private static var lastAddedCount = 0

    private static func postStart(sourceEventID: UUID?) {
        var info: [String: Any] = [:]
        if let id = sourceEventID { info["eventID"] = id }
        NotificationCenter.default.post(name: didStartNotification, object: nil, userInfo: info)
    }

    private static func postFinish(sourceEventID: UUID?, count: Int) {
        var info: [String: Any] = ["count": count]
        if let id = sourceEventID { info["eventID"] = id }
        NotificationCenter.default.post(name: didFinishNotification, object: nil, userInfo: info)
        lastAddedCount = 0
    }

    private static func dbg(_ message: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.memory, message, file: file, line: line)
    }

    // MARK: - Prompt

    private static func buildPrompt(
        thread: [PolishChatTurnSnapshot],
        source: Source,
        existing: [LearnedMemory]
    ) -> String {
        let conversation = thread
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")

        let context: String
        switch source {
        case .polish(let sourceText, let topVariant):
            context = """
            The conversation is about polishing this draft:
            \(sourceText)

            Glotty's top suggested rewrite was:
            \(topVariant ?? "(none)")
            """
        case .explain(let sourceText, let explanation):
            context = """
            The conversation is about Glotty's explanation of this text:
            \(sourceText)

            The explanation Glotty gave was:
            \(explanation)
            """
        case .tutor:
            context = "This is a free-form conversational language-practice session. Focus on what the user volunteered about themselves, their projects, their preferences, or terminology they used."
        }

        let dontPropose = existing.isEmpty
            ? "(none yet)"
            : existing.map { entry -> String in
                let prefix = entry.kind.label
                let term = entry.term.map { "\($0): " } ?? ""
                return "- [\(prefix)] \(term)\(entry.content)"
            }.joined(separator: "\n")

        return """
        You analyze a short conversation between a user and Glotty (a
        translation / writing assistant) and propose new memories about
        the user worth persisting for future LLM calls.

        Apply a strict durability test before proposing anything: would
        injecting this memory into a DIFFERENT conversation weeks from now
        make Glotty meaningfully more helpful? If the statement only
        describes what happened in THIS conversation, it fails — skip it.

        Do NOT propose:
        - One-off events, errors, or slips: "user confused X with Y",
          "user misspelled Z", "user forgot a word", "user didn't know how
          to say W". A single mistake is not a durable trait — the user
          fixing it here does not need to be remembered forever.
        - Generic or trivial observations: "user asked a question", "user
          wanted help", "user is learning English".
        - Anything already obvious from the user's profile or the target
          language.

        ONLY propose when the user VOLUNTEERED something durable and
        reusable: domain terminology with a non-obvious meaning, a stable
        preference for how Glotty should respond, a project whose
        vocabulary will recur, or a lasting background fact (profession,
        native language, a concrete long-term goal).

        Each memory has a `kind`:
        - "glossary": term used by the user with a non-obvious meaning.
          Must include `term`. Content reads "<term> means <meaning>".
        - "preference": a stable preference about how Glotty should
          behave (tone, brevity, formality, etc.).
        - "fact": durable background fact about the user (native
          language, profession, long-term goals). NOT a record of a
          one-off mistake, question, or momentary state.
        - "project": something the user is actively working on whose
          terminology may recur.

        Each memory also has:
        - `content`: one short sentence, what to remember.
        - `source_quote`: exact quote from the conversation that
          triggered the proposal.

        Output STRICT JSON only — no markdown fences, no preamble:

        {"proposed": [
          {"kind": "glossary|preference|fact|project",
           "term": "<term or null>",
           "content": "<one sentence>",
           "source_quote": "<verbatim quote>"}
        ]}

        Propose at most \(maxProposals). If nothing is worth remembering,
        return {"proposed": []}.

        DO NOT propose anything already in this list:
        \(dontPropose)

        Context:
        \(context)

        Conversation:
        \(conversation)
        """
    }

    // MARK: - Parse

    /// Parse the raw LLM response into LearnedMemory proposals.
    /// Lenient: strips markdown code fences in case the model
    /// ignored the "no fences" instruction; tolerates missing
    /// fields by skipping the malformed entry rather than failing
    /// the whole batch. Returns an empty array on total failure.
    static func parse(_ raw: String,
                      sourceEventID: UUID?,
                      sourceLanguage: String? = nil) -> [LearnedMemory] {
        let cleaned = stripCodeFences(raw)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let items = root["proposed"] as? [[String: Any]] else { return [] }

        return items.compactMap { item -> LearnedMemory? in
            guard let kindRaw = item["kind"] as? String,
                  let kind = LearnedMemoryKind(rawValue: kindRaw) else { return nil }
            let content = (item["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { return nil }

            let rawTerm = (item["term"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let term: String? = (rawTerm?.isEmpty == false) ? rawTerm : nil
            // Glossary entries without a term are unusable downstream
            // (the contextBlock matcher needs a term to gate on), so
            // skip them rather than persist garbage.
            if kind == .glossary, term == nil { return nil }

            let quote = (item["source_quote"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LearnedMemory(
                kind: kind,
                term: term,
                content: content,
                sourceQuote: (quote?.isEmpty == false) ? quote : nil,
                sourceEventID: sourceEventID,
                sourceLanguage: sourceLanguage
            )
        }
    }

    /// Trim ```json … ``` (or plain ```) fences if the model emitted
    /// them despite our instruction. Looks for the first `{` and
    /// last `}` and uses that slice as the JSON payload.
    private static func stripCodeFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace < lastBrace else {
            return trimmed
        }
        return String(trimmed[firstBrace...lastBrace])
    }
}
