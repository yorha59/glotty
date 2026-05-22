import Foundation

/// One multiple-choice practice question produced by the LLM. Designed for
/// the Fn → C chat popup: the user reads the prompt, picks one of four
/// options, and sees feedback + an explanation.
struct QuizQuestion: Sendable, Equatable, Codable {
    /// Mistake category this question targets — surfaces in the popup header
    /// so the user knows what they're practicing.
    let category: String
    /// The full question prompt (single sentence, may include a `___` blank).
    let question: String
    /// Exactly four candidate answers — order matters because `correctIndex`
    /// points into this array.
    let options: [String]
    /// 0-based index into `options` of the correct answer.
    let correctIndex: Int
    /// One-sentence reason the correct answer is right. Shown after the user
    /// picks an option.
    let explanation: String
}

/// Prompt builder for Fn → C chat questions. The LLM is given a short list of
/// the user's most-frequent mistake categories (from `MemoryStore`) and asked
/// to produce one multiple-choice question on that topic, in strict JSON.
enum QuizPrompt {
    static let templateKey = "glotty.quizPrompt"

    static let defaultTemplate = """
    You are a language tutor for a user practicing ${language}. Generate ONE \
    multiple-choice practice question that targets one of these mistake \
    categories the user has been making: ${categories}.

    Pick whichever single category from that list makes the most useful \
    question right now. Use everyday vocabulary the user would actually \
    encounter; difficulty should match an intermediate learner.

    Output STRICT JSON only — no markdown fences, no preamble, no trailing \
    prose:

    {
      "category": "<the mistake category you targeted>",
      "question": "<one sentence; may include ___ as a blank to fill>",
      "options": ["<a>", "<b>", "<c>", "<d>"],
      "correctIndex": <0-3>,
      "explanation": "<one sentence on why the correct option is right>"
    }

    Rules:
    - Exactly four options. Exactly one correct.
    - Options should be plausible (distractors that share part of the answer's \
    surface form work well — same root word with wrong tense, similar-looking \
    spelling, etc.).
    - Question must be self-contained — no follow-up needed.
    - All output in ${language}.
    """

    static func currentTemplate() -> String {
        let saved = UserDefaults.standard.string(forKey: templateKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : defaultTemplate
    }

    /// Build the prompt. `categories` is the top-N mistake category list from
    /// MemoryStore; we join them as a comma-separated string for the LLM.
    /// Empty list collapses to a generic prompt with no specific focus.
    static func build(categories: [String], targetLanguage: String) -> String {
        let lang = PolishPrompt.englishName(for: targetLanguage)
        let categoryList = categories.isEmpty
            ? "general grammar and word choice"
            : categories.joined(separator: ", ")
        return currentTemplate()
            .replacingOccurrences(of: "${language}", with: lang)
            .replacingOccurrences(of: "${categories}", with: categoryList)
    }

    /// Parse a raw LLM response into a `QuizQuestion`. Tolerant of code fences
    /// (rewrites the same `stripCodeFences`-style preamble that polish/explain
    /// use). Returns nil if the JSON is malformed or fails the shape check
    /// (4 options, correctIndex in range).
    static func parse(_ raw: String) -> QuizQuestion? {
        let stripped = stripCodeFences(raw)
        guard let data = stripped.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let q = try? decoder.decode(QuizQuestion.self, from: data) else {
            return nil
        }
        guard q.options.count == 4,
              q.correctIndex >= 0,
              q.correctIndex < q.options.count,
              !q.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return q
    }

    private static func stripCodeFences(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
