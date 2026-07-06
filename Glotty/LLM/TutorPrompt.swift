import Foundation

/// One turn in a tutor session. User turns carry just the user's
/// text. Tutor turns carry the conversational reply plus, when the
/// user's previous message had any awkwardness, the natural rewrite
/// (`correctedText`) and a brief native-language note explaining
/// what was off (`correctionNote`).
struct TutorTurn: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case tutor
        /// A "system" turn injected by the app itself to record
        /// confirmed / declined tool-call outcomes. Rendered with a
        /// subtle background, no avatar; the LLM treats these as
        /// authoritative status notes about what just happened.
        case system
    }
    let id: UUID
    let role: Role
    var reply: String
    /// The most natural / idiomatic way a native speaker would
    /// express what the user just said. Nil when the user's message
    /// was already fluent.
    var correctedText: String?
    /// One short native-language sentence on what was off. Nil when
    /// the user's message was already fluent.
    var correctionNote: String?
    /// Tool-call attached to this tutor turn (e.g. a `set_setting`
    /// request awaiting user confirmation). Only ever non-nil on
    /// `.tutor` turns. After the user confirms / declines, `outcome`
    /// flips and the turn re-renders as a collapsed badge.
    var toolCall: PendingToolCall?
    /// When non-nil, this `.tutor` turn is an app-built practice scenario
    /// and renders as a structured card (not a text bubble). `reply` still
    /// holds the equivalent "You wrote… / You meant…" text for the LLM.
    var practice: PracticeCardInfo?

    init(id: UUID = UUID(),
         role: Role,
         reply: String,
         correctedText: String? = nil,
         correctionNote: String? = nil,
         toolCall: PendingToolCall? = nil,
         practice: PracticeCardInfo? = nil) {
        self.id = id
        self.role = role
        self.reply = reply
        self.correctedText = correctedText
        self.correctionNote = correctionNote
        self.toolCall = toolCall
        self.practice = practice
    }
}

/// What the app needs to render a practice scenario as a card (a `.tutor`
/// turn built with no LLM call): the user's draft and what they meant, plus
/// the queue count. The reference answer is deliberately NOT carried here.
struct PracticeCardInfo: Equatable, Sendable {
    let draft: String
    let meaning: String?
    let remaining: Int
}

/// One pending / resolved tool invocation attached to a tutor turn.
/// MCP-shaped on purpose: `name` is the tool id, `args` is a string-
/// keyed dictionary that serialises trivially to JSON. When we later
/// expose Glotty as an MCP server, this struct maps 1-to-1 onto an
/// MCP `tools/call` payload.
struct PendingToolCall: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Hashable, Sendable {
        case pending
        case confirmed
        case declined
        /// Validator rejected the request (unknown setting, blocked,
        /// invalid value). The card shows the reason and the
        /// outcome is final — user can't retry from the card,
        /// they'd ask in chat again.
        case rejected
    }
    let name: String
    let args: [String: String]
    var outcome: Outcome
    /// Free-form reason when `outcome == .rejected`. Shown on the
    /// collapsed card and replayed into the LLM's history so the
    /// model knows why the call failed.
    var rejectionReason: String?
}

/// Parsed structured response from the tutor LLM. Streams as plain
/// text; we only parse once the full JSON has arrived.
struct TutorResponse: Equatable {
    let reply: String
    let correctedText: String?
    let correctionNote: String?
    /// Optional list of tool calls the LLM wants to issue alongside
    /// its reply. For v1 we honour at most one entry — multi-tool
    /// confirmation UX adds complexity that hasn't proven necessary.
    let toolCalls: [PendingToolCall]
    /// Practice-session verdicts: which agenda item(s) the tutor just judged
    /// and whether the user got them right. Drives spaced-repetition
    /// rescheduling. Empty outside a practice session.
    let practiceOutcomes: [PracticeOutcome]
}

/// One graded practice item the tutor reports in a practice session. `item` is
/// the 1-based index into the session's agenda (`PopupView.practiceItems`).
struct PracticeOutcome: Equatable, Sendable {
    let item: Int
    let correct: Bool
}

/// Prompt builder for the conversational chat tutor. The tutor picks
/// a topic from what it knows about the user (memory context) and holds
/// a natural conversation in the target language, gently correcting
/// errors inline as it goes.
enum TutorPrompt {
    /// Build the system + history prompt. `targetLanguage` is the
    /// language Glotty rewrites into (the user's practice target).
    /// `nativeLanguage` is what the user thinks in — used for
    /// correction explanations so a learner can actually understand
    /// the fix. `userContextBlock` is the same "About the user"
    /// block prepended elsewhere (notes + glossary + memory).
    /// `history` is `[(role, text)]` so we don't import the popup's
    /// `TutorTurn` type into this module.
    static func build(
        history: [(role: String, text: String)],
        targetLanguage: String,
        nativeLanguage: String,
        userContextBlock: String,
        isFirstTurn: Bool,
        proactive: Bool = false,
        recentTopics: [String] = [],
        allowToolCalls: Bool = false,
        onboarding: Bool = false,
        practiceItems: [PracticeItem] = [],
        practiceAwaitingAdvance: Bool = false,
        persona: GlottyPersona = .current()
    ) -> String {
        // Onboarding chat (launched from the Welcome window's final
        // step) follows a scripted setup conversation — collect a few
        // pieces of profile info, emit `set_setting` calls for each,
        // then wrap up. Branches early to avoid threading the
        // onboarding instructions through the regular conversational
        // prompt body.
        if onboarding {
            // Same `MainActor.assumeIsolated` pattern the tool block
            // uses — the caller (runTutorTurn) is on main.
            return MainActor.assumeIsolated {
                onboardingPrompt(history: history, persona: persona)
            }
        }

        // Practice session — a structured drill on past mistakes, not free
        // chat. Branches early so the friend-tone guardrails don't fight it.
        if !practiceItems.isEmpty {
            return practicePrompt(
                history: history,
                items: practiceItems,
                targetLanguage: targetLanguage,
                nativeLanguage: nativeLanguage,
                awaitingAdvance: practiceAwaitingAdvance,
                persona: persona
            )
        }

        let targetName = PolishPrompt.englishName(for: targetLanguage)
        let nativeName = PolishPrompt.englishName(for: nativeLanguage)

        let context = userContextBlock.isEmpty
            ? "(No prior notes about the user yet.)"
            : userContextBlock

        // Recently-discussed topics from prior daily threads. Goes
        // into the prompt as a "don't re-pitch" instruction so the
        // opening turn picks something fresh instead of asking
        // about the polish feature every single day.
        let recentTopicsBlock: String
        if recentTopics.isEmpty {
            recentTopicsBlock = ""
        } else {
            let bullets = recentTopics.map { "        - \($0)" }.joined(separator: "\n")
            recentTopicsBlock = """

            RECENT TOPICS — you brought these up with this user in the last week. \
            Treat them as off-limits for the opening turn unless you have a \
            specific concrete follow-up ("How did the interview go?", \
            "Did that build pass?"). Generic "how's that going?" check-ins on \
            these topics will feel repetitive and surveillance-y — the user \
            already told you the chat felt unnatural last time. Default to \
            small talk or a brand new topic instead.
            \(bullets)
            """
        }

        let historyBlock: String
        if history.isEmpty {
            historyBlock = "(no messages yet)"
        } else {
            historyBlock = history
                .map { "\($0.role.capitalized): \($0.text)" }
                .joined(separator: "\n\n")
        }

        // Tool block: capabilities + every setting the agent can
        // change. Only included when the user has explicitly enabled
        // the Tools toggle in the chat header — that IS the consent
        // signal, so the LLM doesn't have to second-guess whether
        // a "change polish to ja" message is a real request or
        // hypothetical chatter. Toggle off ⇒ block is empty, the
        // LLM has no tool schemas to invoke at all.
        // Tool capability + state blocks both touch main-actor state
        // (SettingsRegistry, UsageStore, MemoryStore). Build() itself
        // is nonisolated; PopupView.runTutorTurn (the only caller) is
        // on main, so `assumeIsolated` is safe — same pattern as
        // `prependedWithUserContext` in PolishPrompt.
        let toolBlock: String
        let stateBlock: String
        if allowToolCalls {
            (toolBlock, stateBlock) = MainActor.assumeIsolated {
                (Self.toolCapabilityBlock(), Self.glottyStateSnapshot())
            }
        } else {
            toolBlock = ""
            stateBlock = ""
        }

        let firstTurnHint: String
        if isFirstTurn && proactive {
            firstTurnHint = """
            This is the FIRST turn of TODAY'S chat, and YOU initiated it (the user clicked a reminder notification). Two short sentences max in \(targetName). Set `corrected_text` and `correction_note` to null.

            How real friends open conversations — pick one of these styles, NOT a "let's check on your project" check-in:
              - A random thought or curiosity ("Random — do you think pineapple on pizza is fine?", "Was just wondering — what's your go-to comfort food?")
              - Something time / weather / day-related ("Long week, huh?", "Whoever invented Monday mornings owes us an apology", "It's that 3pm slump time")
              - Sharing a tiny thing of YOUR own ("Just spilled coffee on my keyboard, again 😅", "Been thinking about how weird it is that we say 'on accident'")
              - A specific, NEW follow-up — ONLY if you have something concrete and recent to follow up on ("How did the Berlin interview go?") AND you haven't asked about that topic in the last week
              - Generic friendly opener if nothing else fits ("Hey, how's it going?")

            STRICT anti-patterns — never do these:
              - "I noticed you've been working on X" / "I see you mentioned Y" → reads as surveillance
              - Asking about the same project / topic two days in a row, or any topic in the recent-topics list below
              - Recapping what's in your saved notes back at the user
              - Pitching a topic from saved notes just because it's there — only pull from notes when there's a NEW thread to extend, not when you just want something to talk about
            """
        } else if isFirstTurn {
            firstTurnHint = """
            This is the FIRST turn of TODAY'S chat. One or two sentences in \(targetName). Set `corrected_text` and `correction_note` to null.

            Open like a friend would, NOT like a tutor checking in. Default to small talk or a random thought; only reference a topic from the saved notes if there's a SPECIFIC concrete follow-up to make (e.g. you remember they had a deadline yesterday and you want to ask how it went). If nothing concrete to follow up on, just open generically — "Hey, how's it going?" / "Late one tonight?" / a random light question.

            STRICT anti-patterns — never do these:
              - "I noticed you mentioned X" / "I see you've been working on Y" — reads as surveillance
              - Asking about the same project / topic you brought up recently (see recent-topics list below)
              - Listing or paraphrasing the saved notes back to the user
              - Pulling out a profile topic just because it's there — pulling from notes is ONLY for genuine follow-ups, not for finding something to talk about
            """
        } else {
            firstTurnHint = "Continue the conversation naturally. Stay on the current topic unless the user shifts it."
        }

        return """
        \(persona.systemDescription) You are chatting with the user in \(targetName).

        Tone guardrails (important):
        - You are a friend, not a tutor or a study buddy. Do NOT turn the `reply` field into a lesson — corrections live in the dedicated fields below, not in the chat reply.
        - The saved notes below are BACKGROUND about the user, not a topic queue. Real friends don't open every chat with "how's that project going" — they react to right now (weather, day-of-week, random thoughts), and only bring up a known topic when there's something specific and fresh to follow up on. Default to NOT pulling from the notes.
        - If you do reference something from the notes, do it implicitly — like you remembered from chatting before, not from a profile. NEVER say "I see you've been working on X" or "I noticed you mentioned Y". And never lead with the same topic two chats in a row.

        Output STRICT JSON only — no markdown fences, no preamble:

        \(jsonSchemaSnippet(targetName: targetName,
                            nativeName: nativeName,
                            allowToolCalls: allowToolCalls))

        Correction policy — be conservative; Discuss is a conversation, NOT a polish/expression tool:
        - ONLY populate a correction when the user is genuinely ATTEMPTING to say their OWN idea in \(targetName) and that attempt has a real grammar / word-choice / idiom problem. Then populate BOTH:
          - `corrected_text`: rewrite their sentence the way a native speaker would naturally say the same thing. Preserve their meaning and tone. Keep changes minimal — don't restructure if you don't need to.
          - `correction_note`: one short \(nativeName) sentence explaining what was off (e.g. "should be 'have been', not 'have being'").
        - Set BOTH fields to null — do NOT correct — when ANY of these hold:
          - the message is wholly or mostly in \(nativeName) (they're asking or discussing, not practicing \(targetName));
          - the user is asking a question — about grammar, usage, meaning, a word, or anything else;
          - the user is quoting, pasting, or discussing existing text rather than offering their own sentence to practice;
          - the message is already fluent and idiomatic.
          NEVER translate or rewrite the user's question into \(targetName) and present it as a correction — that is not a correction.
        - Match the user's level. If they write simple sentences, stay simple in both `reply` and `corrected_text`.
        - The `reply` field is your in-character chat message responding to what the user said. Do not include any correction in the reply itself.

        \(firstTurnHint)

        \(toolBlock)

        \(stateBlock)

        \(context)
        \(recentTopicsBlock)

        Conversation so far:
        \(historyBlock)
        """
    }

    /// Compact "what's going on inside Glotty right now" snapshot
    /// the LLM can answer questions from without round-tripping a
    /// `get_*` tool call. Numbers come straight from the on-device
    /// stores — UsageStore, ChatStore, MemoryStore — so they reflect
    /// the actual session state at prompt build time.
    @MainActor
    private static func glottyStateSnapshot() -> String {
        let usage = UsageStore.shared
        let today = usage.totals(since: UsageStore.startOfToday())
        let week = usage.totals(since: UsageStore.startOfWeek())
        let byMode = usage.byMode(since: UsageStore.startOfWeek())

        let modeBreakdown = byMode
            .sorted { $0.totals.total > $1.totals.total }
            .prefix(4)
            .map { "\($0.mode.displayName) \($0.totals.total)" }
            .joined(separator: ", ")

        let threads = ChatStore.shared.allThreads()
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let recentThreadCount = threads.filter { $0.updatedAt >= weekAgo }.count
        let lastActivityLine: String
        if let last = ChatStore.shared.lastActivity() {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            lastActivityLine = "last chat \(f.localizedString(for: last, relativeTo: Date()))"
        } else {
            lastActivityLine = "no chats yet"
        }

        let polishLang = UserDefaults.standard.string(forKey: "glotty.polishLang") ?? "en"
        let topMistakes = MemoryStore.shared
            .topGrammarIssues(limit: 3, since: weekAgo, language: polishLang)
            .map { "\($0.key) (\($0.count))" }
            .joined(separator: ", ")
        let mistakesLine = topMistakes.isEmpty
            ? "no polish mistakes recorded for \(polishLang) this week"
            : "top mistake types in \(polishLang) this week: \(topMistakes)"

        return """
        GLOTTY STATE (for answering quick info questions — token usage, chat history, common mistakes):
          - Tokens today: \(today.total) (prompt \(today.prompt) / completion \(today.completion))
          - Tokens this week: \(week.total)
          - This week by feature: \(modeBreakdown.isEmpty ? "(no usage yet)" : modeBreakdown)
          - Chat threads in the last 7 days: \(recentThreadCount); \(lastActivityLine)
          - \(mistakesLine)

        Use these numbers directly when the user asks a usage / history / mistakes question — don't pretend you can't see them. Keep the answer brief (1-3 sentences). For deeper drill-down, suggest the relevant Settings tab (Usage, History, Polish) and emit `open_settings_tab` if they want to look at it.
        """
    }

    /// JSON output schema shown to the LLM. The `tool_calls` field
    /// only appears when the user has the Tools toggle on — keeps
    /// the prompt clean and removes any temptation for the model
    /// to invent tool calls in chat-only mode.
    private static func jsonSchemaSnippet(targetName: String,
                                          nativeName: String,
                                          allowToolCalls: Bool) -> String {
        if allowToolCalls {
            return """
            {
              "reply": "<your conversational message in \(targetName)>",
              "corrected_text": "<the most natural way to say what the user just said, in \(targetName), or null>",
              "correction_note": "<one short \(nativeName) sentence on what was off, or null>",
              "tool_calls": [
                {"name": "<tool id>", "args": {"<arg>": "<value>"}}
              ]
            }
            """
        } else {
            return """
            {
              "reply": "<your conversational message in \(targetName)>",
              "corrected_text": "<the most natural way to say what the user just said, in \(targetName), or null>",
              "correction_note": "<one short \(nativeName) sentence on what was off, or null>"
            }
            """
        }
    }

    /// Compact tool capability block. One line per setting plus a
    /// worked example — LLMs comply with tool-call formats far more
    /// reliably when shown an example rather than just told the
    /// schema in prose. `@MainActor` because it reads
    /// `SettingsRegistry`, which touches main-isolated stores.
    @MainActor
    private static func toolCapabilityBlock() -> String {
        let snapshot = SettingsRegistry.snapshotForPrompt()
        let lines = snapshot.map { entry, current in
            let now = current.flatMap { $0.isEmpty ? nil : $0 } ?? "unset"
            let schema = SettingsRegistry.describe(kind: entry.kind)
            return "  \(entry.id) (\(schema)) = \(now)"
        }
        let settingsList = lines.joined(separator: "\n")

        return """
        TOOLS MODE IS ON. The user has explicitly enabled the Modify Settings toggle, which means messages that look like requests to change something in Glotty ARE requests. Don't second-guess — emit the appropriate tool call.

        Two tools are available. Pick exactly one per turn:

        1. set_setting(key, value) — change one of the settings below directly.

        SETTINGS YOU CAN CHANGE (id (accepts) = current value):
        \(settingsList)

        2. open_settings_tab(tab) — open one Settings tab for the user when they're asking about something you can't change with `set_setting`. Use this for: dictionaries, API key, LLM provider, hotkeys, backup, permissions, anything else not in the list above.

        Available tab ids: profile, translation, dictionaries, languageModel, polish, hotkey, history, memory, chat, usage, backup, system, permissions.

        Rules:
          - Emit at most one `tool_calls` entry per turn.
          - The reply must describe what you're about to change / open in plain language; do NOT claim it's done — the app shows a Confirm card and tells you the outcome next turn via a `[bracketed system note]`.
          - Use BCP-47 codes for language ids (`en`, `zh-Hans`, `ja`, ...).

        Examples:

        User says "Switch polish to Japanese":
        {
          "reply": "Switching polish target to Japanese. Confirm to apply?",
          "tool_calls": [{"name": "set_setting", "args": {"key": "polish_output_language", "value": "ja"}}]
        }

        User says "I want to change my dictionaries":
        {
          "reply": "I can't reorder dictionaries directly, but I can open the Dictionaries tab for you. Confirm?",
          "tool_calls": [{"name": "open_settings_tab", "args": {"tab": "dictionaries"}}]
        }

        For ordinary chat turns where the user isn't asking to change anything, OMIT `tool_calls` (or set it to []).
        """
    }

    /// Parse the LLM's JSON response into a `TutorResponse`. Lenient:
    /// trims code fences if the model emitted them, treats missing /
    /// "null" / empty correction fields as nil. Returns nil only if
    /// the JSON is unrecoverable or `reply` is empty.
    static func parse(_ raw: String) -> TutorResponse? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace < lastBrace else { return nil }
        let body = String(trimmed[firstBrace...lastBrace])
        guard let data = body.data(using: .utf8) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let reply = (dict["reply"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reply.isEmpty else { return nil }
        // Accept both the new pair (`corrected_text` + `correction_note`)
        // and the legacy single `correction` key — older builds emitted
        // the latter, and we don't want one stale prompt cache to break
        // parsing for in-flight replies.
        let correctedText = optionalString(dict["corrected_text"])
        let correctionNote = optionalString(dict["correction_note"])
            ?? optionalString(dict["correction"])
        // Parse optional `tool_calls`. Only `set_setting` is honoured
        // today; anything else gets dropped at the validation layer
        // (PopupView.handleTutorResponse) which posts a system turn
        // back. Cap at one call per turn — multi-tool UX would need
        // a more elaborate confirmation card.
        var toolCalls: [PendingToolCall] = []
        if let rawCalls = dict["tool_calls"] as? [[String: Any]] {
            for entry in rawCalls.prefix(1) {
                guard let name = (entry["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                let rawArgs = (entry["args"] as? [String: Any]) ?? [:]
                var args: [String: String] = [:]
                for (k, v) in rawArgs {
                    if let s = v as? String { args[k] = s }
                    else if let n = v as? NSNumber { args[k] = n.stringValue }
                }
                toolCalls.append(PendingToolCall(
                    name: name,
                    args: args,
                    outcome: .pending,
                    rejectionReason: nil
                ))
            }
        }
        // Practice-session verdicts (silent — no confirm card). Each entry is
        // `{item: <1-based number>, correct: <bool>}`.
        var practiceOutcomes: [PracticeOutcome] = []
        if let rawOutcomes = dict["practice_outcomes"] as? [[String: Any]] {
            for entry in rawOutcomes {
                guard let item = (entry["item"] as? NSNumber)?.intValue
                        ?? (entry["item"] as? Int) else { continue }
                let correct = (entry["correct"] as? Bool)
                    ?? ((entry["correct"] as? NSNumber)?.boolValue ?? false)
                practiceOutcomes.append(PracticeOutcome(item: item, correct: correct))
            }
        }
        return TutorResponse(
            reply: reply,
            correctedText: correctedText,
            correctionNote: correctionNote,
            toolCalls: toolCalls,
            practiceOutcomes: practiceOutcomes
        )
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    /// Scripted onboarding prompt — used when the chat was launched
    /// from the Welcome window's final step. Glotty asks seven
    /// setup questions in sequence (emitting a `set_setting` tool
    /// call after each), then runs one guided action (open Settings
    /// → Dictionaries via `open_settings_tab` so the user can
    /// activate macOS dictionaries that Translate depends on).
    /// After the action it wraps up and tells the user they're done.
    ///
    /// We deliberately don't loop in the general conversational
    /// prompt's tone guardrails / recent-topics block — this chat
    /// is task-focused (collect 4 answers, exit), not free
    /// Structured practice drill: re-present the user's past polish mistakes
    /// one at a time (their draft + the meaning), have them re-attempt, judge
    /// each attempt, and report verdicts via `practice_outcomes` so the app
    /// reschedules them. The coach speaks in the user's native language for
    /// clear feedback; the practiced phrases stay in their original language.
    private static func practicePrompt(
        history: [(role: String, text: String)],
        items: [PracticeItem],
        targetLanguage: String,
        nativeLanguage: String,
        awaitingAdvance: Bool,
        persona: GlottyPersona
    ) -> String {
        let nativeName = PolishPrompt.englishName(for: nativeLanguage)
        let agenda = items.enumerated().map { idx, item -> String in
            let issues = item.issues.isEmpty ? "—" : item.issues.joined(separator: "; ")
            let meaning = (item.meaning?.isEmpty == false) ? item.meaning! : "(not recorded)"
            return """
              \(idx + 1). They wrote: "\(item.draft)"
                 They meant: \(meaning)
                 Natural answer: "\(item.answer)"
                 What was off: \(issues)
            """
        }.joined(separator: "\n")

        let historyBlock = history.isEmpty
            ? "(no messages yet)"
            : history.map { "\($0.role.capitalized): \($0.text)" }.joined(separator: "\n\n")

        // Two modes within a session: AWAITING the user's attempt (judge it),
        // or BETWEEN items after a verdict (the app paused on a "Next" button —
        // just field follow-up questions, never judge).
        let modeBlock = awaitingAdvance ? """
        - The user already answered the previous item and you gave your verdict. They have NOT started the next one — a "Next" button is waiting for their tap. You are BETWEEN items: treat every message as a follow-up question about what they just practiced (or small talk), answer it helpfully, and ALWAYS set practice_outcomes to []. Do NOT judge, do NOT present or restate any scenario, do NOT tell them to move on — they tap Next when ready.
        """ : """
        - When the user replies with their attempt, judge whether it correctly and naturally expresses the intended meaning. An equally natural phrasing that differs from the reference still counts as correct — judge meaning + naturalness, not an exact match; be lenient on typos/tiny slips.
        - Give a brief verdict (1-2 sentences). If they were off, show the natural answer and the key fix. After a CORRECT attempt you may add one short, warm line inviting a follow-up question or moving on — a "Next" button takes them onward, so never present the next scenario, restate the next draft/meaning, or say which item is next.
        """

        return """
        \(persona.systemDescription) Right now you are running a short PRACTICE SESSION — not free chat. The user previously polished some phrases that needed fixing; now they re-attempt them so the corrections stick. Speak in \(nativeName) so your feedback is clear, but the phrases they practice stay in the language of the "Natural answer".

        How the drill works:
        - The app ITSELF presents each scenario card (what they wrote + what they meant) — that is NOT your job. Do NOT present, re-present, or repeat a scenario's draft/meaning back.
        \(modeBlock)
        - A missed item comes back around later in the session, so don't treat any item as the last, and never congratulate them on "finishing" — the app handles the wrap-up.

        AGENDA (\(items.count) item\(items.count == 1 ? "" : "s")):
        \(agenda)

        Conversation so far:
        \(historyBlock)

        Output ONLY a JSON object, nothing outside it:
        {
          "reply": "<your message in \(nativeName): present the next item, or give a verdict>",
          "practice_outcomes": [{"item": <1-based item number>, "correct": <true|false>}]
        }

        Rules for `practice_outcomes`:
        - Each user message is an attempt at the scenario the app just showed (the most recent "You wrote… / You meant…" card above). Judge it and add exactly ONE entry: the agenda item number it matches (by its draft/meaning) plus whether it was correct.
        - If the user's message is NOT an attempt (e.g. they ask a question), answer it and set `practice_outcomes` to [] — the app keeps the same card up.
        - Report each item at most once.

        You NEVER present or re-present a scenario — the app shows every card itself. Every turn of yours reacts to the user's latest attempt: a short verdict plus the `practice_outcomes` entry. Don't restate the draft or meaning; don't number the next item.
        """
    }

    /// conversation. Keep the prompt short so the model stays on
    /// script.
    @MainActor
    private static func onboardingPrompt(
        history: [(role: String, text: String)],
        persona: GlottyPersona
    ) -> String {
        let historyBlock: String
        if history.isEmpty {
            historyBlock = "(no messages yet — this is the very first turn)"
        } else {
            historyBlock = history
                .map { "\($0.role.capitalized): \($0.text)" }
                .joined(separator: "\n\n")
        }

        // Read current values so the prompt can show defaults and
        // the model can keep them when the user says "looks good".
        let displayName = UserDefaults.standard.string(forKey: "glotty.user.displayName") ?? ""
        let pronouns = UserDefaults.standard.string(forKey: "glotty.user.pronouns") ?? ""
        let nativeLang = UserDefaults.standard.string(forKey: "glotty.user.nativeLanguage") ?? ""
        let polishLang = UserDefaults.standard.string(forKey: "glotty.polishLang") ?? ""
        // Empty string on disk for source/target means "auto-detect" —
        // the picker uses the `auto` sentinel; same convention is used
        // throughout the registry (see SettingsRegistry+Factories.swift).
        let sourceLang = UserDefaults.standard.string(forKey: "glotty.sourceLang") ?? ""
        let targetLang = UserDefaults.standard.string(forKey: "glotty.targetLang") ?? ""
        // showAllDicts is a bool; UserDefaults returns false for missing
        // keys, so default to the registry's default (false = clean view).
        let showAllDicts = UserDefaults.standard.bool(forKey: "glotty.dictionary.showAllMatches")

        // Use the user's macOS system language for replies during
        // onboarding — they haven't configured Glotty's own
        // languages yet, and English-only replies would feel cold
        // to non-English users. `CFPreferencesCopyAppValue` with
        // `kCFPreferencesAnyApplication` reads the global OS pref
        // (not the per-app override). The English name is what the
        // LLM understands ("Chinese (Simplified)" / "Japanese").
        let osLangCode: String = {
            let val = CFPreferencesCopyAppValue("AppleLanguages" as CFString,
                                                kCFPreferencesAnyApplication)
            if let arr = val as? [String], let first = arr.first {
                return first.split(separator: "-").prefix(2).joined(separator: "-")
            }
            return "en"
        }()
        let osLangName = PolishPrompt.englishName(for: osLangCode)

        // Pre-render any saved values into natural language so the
        // prompt can show them to the model WITHOUT leaking the raw
        // settings strings (`he/him`, `zh-Hans`) into the user-facing
        // reply. The model is told these are "for your reference
        // only", which it consistently obeys when paired with the
        // explicit "never read setting keys/values out loud" rule.
        let pronounsHuman: String = {
            switch pronouns {
            case "he/him": return "male"
            case "she/her": return "female"
            case "":       return "(not set — they preferred neutral)"
            default:       return "\"\(pronouns)\""
            }
        }()
        let nativeLangHuman = nativeLang.isEmpty
            ? "(not set)"
            : PolishPrompt.englishName(for: nativeLang)
        let polishLangHuman = polishLang.isEmpty
            ? "(not set)"
            : PolishPrompt.englishName(for: polishLang)
        let sourceLangHuman = sourceLang.isEmpty
            ? "(auto-detect — Glotty figures it out per selection)"
            : PolishPrompt.englishName(for: sourceLang)
        let targetLangHuman = targetLang.isEmpty
            ? "(auto — paired against the detected source)"
            : PolishPrompt.englishName(for: targetLang)
        let showAllDictsHuman = showAllDicts
            ? "show every matching dictionary (detailed view)"
            : "show only the top monolingual + bilingual dictionary (clean view)"

        return """
        You are \(persona.name) running a one-time onboarding chat with a new user. Tone: warm, polite, conversational — like an attentive friend helping them set up, never like a form. You speak in \(osLangName).

        Collect seven pieces of profile + translation/dictionary information by asking the questions below in order, then run one guided dictionary-activation step before the wrap-up. After each setting answer, emit a `set_setting` tool call so the app can record it; for the dictionary-activation step, emit a single `open_settings_tab` tool call (no answer to collect — it's a guided action, not a setting value).

        Questions to ask, one per turn — WAIT for the user's reply before moving on:

          1. Their preferred name. → set_setting key=`display_name`, value=their answer (plain name string)
          2. How they'd like to be addressed (their gender / honorific). Ask gently and naturally — e.g. "I'd love to refer to you in a way that feels right — would you like me to address you in a male, female, or gender-neutral way?" → set_setting key=`pronouns`, value=`he/him` (if they pick male), `she/her` (if female), or "" (empty string, if they prefer neutral / no preference)
          3. Their native language (the language they're most comfortable in and want translations into). Mention warmly that this'll also be the language Glotty's own menus and settings show in — phrase it conversationally, e.g. "What's your native language? I'll use it for translations and for my own menus too." Do NOT read the BCP-47 code or any technical setting key out loud. → set_setting key=`native_language`, value=BCP-47 code (`en`, `zh-Hans`, `ja`, `es`, `fr`, `de`, `ko`, `it`, `pt`, `ru`, `ar`, `hi`, `vi`, `th`, `zh-Hant`)
          4. The language they want to practice writing in (the language they're learning). → set_setting key=`polish_output_language`, value=BCP-47 code from the same list
          5. The default source language for translations — the language the text they highlight is usually in. Frame it warmly: "When you highlight text and press Fn-T, what language is it usually in? If it varies a lot, I can just auto-detect it each time." → set_setting key=`default_translation_source`, value=`auto` (if they want auto-detect / their answer is unclear) OR a BCP-47 code from the same language list
          6. The default target language for translations — what they want translations rendered INTO. Suggest their native language as the natural default: "Should I translate INTO <their native language> by default, or did you have a different language in mind?" → set_setting key=`default_translation_target`, value=`auto` (if they want it auto-paired) OR a BCP-47 code
          7. Dictionary display preference. Phrase it as a choice: "When I show translations, would you prefer a clean view with just the top dictionary result, or a detailed view that includes every matching dictionary I can find?" → set_setting key=`show_all_dictionaries`, value=`true` (detailed view) or `false` (clean view)
          8. **Guided action — activate macOS dictionaries.** No question to answer; offer to open Settings → Dictionaries so they can enable dictionaries macOS ships with. Frame it warmly and briefly explain WHY: "One last thing — Translate looks up definitions in the dictionaries macOS has activated. By default that's not many. Want me to open the Dictionaries setup so you can enable the ones you need (English, Chinese, Japanese, and more are bundled with macOS)?" → `open_settings_tab`, args=`{"tab": "dictionaries"}`. This is the only `open_settings_tab` call in the script. If they decline, advance straight to the wrap-up — don't re-offer.

        Current saved profile (FOR YOUR REFERENCE ONLY — do not read these strings out loud verbatim):
          - name: \(displayName.isEmpty ? "(not set)" : "\"\(displayName)\"")
          - addressed as: \(pronounsHuman)
          - native language: \(nativeLangHuman)
          - practicing: \(polishLangHuman)
          - default translation source: \(sourceLangHuman)
          - default translation target: \(targetLangHuman)
          - dictionary display: \(showAllDictsHuman)

        Tone & wording rules — these matter as much as the questions:
          - NEVER read internal setting keys or technical values to the user. Do not say things like "your pronoun is set to `he/him`" or "your native_language is `zh-Hans`". Translate everything into natural language they'd actually use.
          - When a value is already saved, paraphrase warmly. For pronouns specifically, never echo "he/him" / "she/her" — phrase it as "Last time you mentioned you'd prefer I address you as <male/female/in a neutral way> — does that still feel right?" or similar.
          - For languages, use their natural names ("English", "中文", "日本語") not BCP-47 codes.
          - One question per turn — don't bundle several. Two sentences max.
          - Stay warm and curious. Soften with phrases like "if you don't mind me asking", "out of curiosity", "happy to skip if you'd rather". Never make the user feel interrogated.
          - On the very first turn: a brief friendly greeting (one short sentence), then question 1. No long preambles.

        Tool-call emission — **CRITICAL TURN STRUCTURE**:
          - **YOU drive the conversation** — every assistant turn (except the first greeting and the final wrap-up) must END with an explicit question or next-step prompt. If you only acknowledge and stop, the chat dead-ends because the user has nothing to answer.
          - **Standard bundle** (questions 1-7): `reply` contains BOTH (a) a brief warm acknowledgement of the user's previous answer AND (b) the NEXT question. `tool_calls` carries ONE `set_setting` for the answer you're acknowledging.
            Example after the user said "Alice" for Q1: `reply: "Lovely to meet you, Alice! Out of curiosity, would you like me to address you in a male, female, or gender-neutral way?"` + `tool_calls: [set_setting display_name=Alice]`. The acknowledgement and the next question are in the SAME reply, in the SAME turn as the tool_call for the just-answered question.
          - The app does NOT auto-fire a follow-up turn after the user confirms a `set_setting` tool_call. The user reads your reply (ack + next question), confirms the card, and types their answer to the question you ALREADY asked. So if you forget the next question, the chat hangs.
          - **First turn** (greeting + Q1): a one-sentence warm greeting plus question 1. No `tool_calls` — there's nothing to acknowledge yet.
          - **Step 8 — dictionary activation** is the ONE exception to the bundle rule. Frame it warmly as: `reply: "<ack of Q7 answer>. One last thing — Translate looks up definitions in macOS's dictionaries. Want me to open the Dictionaries setup so you can enable the ones you need?"` + `tool_calls: [open_settings_tab tab=dictionaries]`. After the user accepts (or declines) opening Dictionaries, the app DOES auto-fire — the next turn is the wrap-up (no tool_call).
          - **On decline of `set_setting`:** the user's answer didn't match your interpretation. The app auto-fires the next turn after a decline. Re-ask the SAME question with a fresh, gentler phrasing and a clarifying angle ("sorry, I might have misunderstood — did you mean..."). Do NOT bundle the next question. Do NOT emit a `set_setting` tool_call — wait for the clarified answer first.
          - **On decline of `open_settings_tab` (step 8):** the user is skipping dictionary setup. The auto-fired turn is the wrap-up — do NOT re-offer to open Dictionaries, and do not lecture them about activating dictionaries later.
          - **Wrap-up** is the final turn, fires automatically after step 8. No `tool_calls`. Warm congrats, briefly remind them Fn-T translates, Fn-P polishes, Fn-E explains, Fn-C opens chat, and any setting can be changed later from the menu bar.

        Output STRICT JSON only — no markdown fences, no preamble:

        {
          "reply": "<short message in \(osLangName)>",
          "corrected_text": null,
          "correction_note": null,
          "tool_calls": [
            {"name": "set_setting", "args": {"key": "...", "value": "..."}}
          ]
        }

        Conversation so far:
        \(historyBlock)
        """
    }
}
