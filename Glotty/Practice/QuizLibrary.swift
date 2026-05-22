import Foundation

/// Persistent library of LLM-generated practice questions. The proactive
/// flow separates *generation* (slow, LLM-backed, runs in the background)
/// from *delivery* (instant, picks at random from this store) — so when a
/// notification fires there's no LLM wait.
///
/// Storage is a single JSON file at
/// `~/Library/Application Support/Glotty/quiz-library.json`. The whole
/// library is loaded into memory on init; reads are O(n) shuffles, writes
/// are full-file rewrites (small enough that overhead doesn't matter).
@MainActor
final class QuizLibrary: ObservableObject {
    static let shared = QuizLibrary()

    /// Target library size — the background generator stops adding once we
    /// hit this. Picked to be enough for ~3-10 practice sessions before a
    /// refill is needed.
    static let targetSize = 30

    /// One entry in the library — wraps a `QuizQuestion` with provenance so
    /// we can later inspect "when was this generated" or "drop questions
    /// older than X" if needed.
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let createdAt: Date
        let question: QuizQuestion
    }

    private let fileURL: URL
    /// Published so any SwiftUI view that observes `QuizLibrary.shared`
    /// stays in sync — Settings shows the queued-questions list, the count,
    /// and any progress UI off this single source of truth. Mutators only
    /// touch this property (no parallel `count` int to keep in sync).
    @Published private(set) var entries: [Entry] = []
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.quizlibrary", qos: .utility)

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            let glottyDir = appSupport.appendingPathComponent("Glotty", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: glottyDir, withIntermediateDirectories: true
            )
            self.fileURL = glottyDir.appendingPathComponent("quiz-library.json")
        }
        load()
    }

    var count: Int { entries.count }

    /// Snapshot of every entry, newest first. Used by Settings → Practice
    /// to show the user what's queued.
    func allEntries() -> [Entry] {
        entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Drop a single entry by id. Used by the per-row delete button in
    /// Settings → Practice's library list.
    func remove(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { persist() }
    }

    /// Add a question. Duplicates (by exact question text) are ignored so the
    /// LLM occasionally producing the same prompt doesn't bloat the library.
    func add(_ question: QuizQuestion) {
        let trimmed = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !entries.contains(where: { $0.question.question == trimmed }) else { return }
        entries.append(Entry(id: UUID(), createdAt: Date(), question: question))
        persist()
    }

    /// Pick `n` questions uniformly at random. Returns fewer than `n` if the
    /// library is smaller. Caller can detect the shortfall via the return
    /// count.
    func pickRandom(count n: Int) -> [QuizQuestion] {
        Array(entries.shuffled().prefix(n)).map(\.question)
    }

    /// Drop a question after the user answers it. Matched by exact question
    /// text (the same key dedup uses). Persists synchronously after the
    /// remove so subsequent picks won't re-include it even on a crash.
    func remove(_ question: QuizQuestion) {
        let key = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = entries.count
        entries.removeAll { $0.question.question == key }
        if entries.count != before { persist() }
    }

    /// Wipe the whole library. Exposed for the Settings UI (regenerate from
    /// scratch when the user changes language preferences, etc.).
    func clear() {
        entries.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Entry].self, from: data) {
            entries = loaded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        let fileURL = self.fileURL
        writeQueue.async {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
