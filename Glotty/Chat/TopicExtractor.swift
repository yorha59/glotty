import Foundation

/// Generates the 1–3 short "topic tags" for a closed chat thread.
/// Glotty's tutor chat is one fresh thread per chat-day; without
/// cross-day memory the LLM keeps re-pitching the same topics in
/// every opening turn. This extractor tags each closed thread with
/// the things the user actually engaged with so the next thread's
/// prompt can include a "recently discussed, don't re-pitch these"
/// list (see `TutorPrompt.build`).
///
/// One LLM call per thread, ever. Results are written back into
/// `DailyChatThread.topics` via `ChatStore.setTopics(_:for:)`;
/// re-extraction is skipped on subsequent launches because that
/// field is no longer nil.
@MainActor
enum TopicExtractor {
    /// Extract topics for one thread and persist them. No-op when
    /// the thread is empty, the LLM provider is unavailable, or the
    /// response fails to parse. Silent on failure — extractor is
    /// background polish, not user-blocking.
    static func run(for thread: DailyChatThread) async {
        guard thread.topics == nil else { return }
        guard !thread.turns.isEmpty else { return }
        guard let provider = LLMRegistry.current() else { return }

        let transcript = thread.turns
            .map { turn -> String in
                let role = turn.role == .user ? "User" : "Tutor"
                return "\(role): \(turn.reply)"
            }
            .joined(separator: "\n\n")

        let prompt = """
        You are helping Glotty, a language-tutor chat app, remember what \
        topics it has already discussed with a user so it doesn't keep \
        pitching the same things on subsequent days.

        Read this completed daily chat transcript and extract 1 to 3 short \
        topic tags that capture the substantive things the user engaged \
        with (a project they're working on, a question they raised, an \
        experience they shared). Each tag should be:

        - 2 to 5 words
        - Specific (e.g. "Berlin job application" not "work"; \
        "polish feature implementation" not "coding")
        - In English so they're a stable key across UI locales
        - NOT a description of Glotty's behaviour ("greeted user", \
        "asked a question") — only the user's actual subject matter

        If the transcript is too thin to extract real topics (small talk \
        only, user barely engaged), return an empty array.

        Output STRICT JSON only — no markdown fences, no preamble:

        {"topics": ["<short topic 1>", "<short topic 2>", ...]}

        Transcript:
        \(transcript)
        """

        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.chat) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return
        }

        let topics = parse(raw)
        // Empty topics is still a valid answer (small-talk threads),
        // and we persist that so we don't re-attempt every launch.
        ChatStore.shared.setTopics(topics, for: thread.id)
    }

    /// Run extraction for every closed thread that doesn't have
    /// topics yet. Backgrounded — fires from the popup opening hook
    /// in `runTutor` so the user doesn't wait on the LLM calls.
    static func extractPendingInBackground() {
        let pending = ChatStore.shared.threadsNeedingTopicExtraction()
        guard !pending.isEmpty else { return }
        Task.detached(priority: .background) {
            for thread in pending {
                await TopicExtractor.run(for: thread)
            }
        }
    }

    private static func parse(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first < last else { return [] }
        let body = String(trimmed[first...last])
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = dict["topics"] as? [String] else {
            return []
        }
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
