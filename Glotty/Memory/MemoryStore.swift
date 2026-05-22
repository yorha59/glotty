import Foundation

/// Which Fn-leader command produced this memory event.
enum MemoryEventKind: String, Codable, Sendable {
    case translate
    case explain
    case polish
}

/// One issue extracted from a polish run, persisted so the Memory tab can
/// surface recurring patterns ("you keep dropping articles", etc.). We
/// deliberately record only the **category** (e.g. "Article usage",
/// "Subject-verb agreement") and not the user's literal phrase — that's the
/// minimum we need to aggregate by type, and it keeps memory data privacy-safe.
/// Old on-disk entries that used `original`/`explanation` instead of category
/// decode with `category = nil` and contribute nothing to the aggregation.
struct PolishIssueSnapshot: Codable, Hashable, Sendable {
    let category: String?
}

/// Captures everything the popup needs to redraw a polish run exactly: the
/// full variant list (text + back-translation) and the issues the LLM
/// flagged (category + original snippet + fix explanation). Persisted
/// alongside the regular aggregate `issues` field on `MemoryEvent`. Memory's
/// click-through path uses this to rehydrate the popup without re-running
/// the LLM.
struct PolishResultSnapshot: Codable, Hashable, Sendable {
    struct Variant: Codable, Hashable, Sendable {
        let text: String
        let backTranslation: String?
    }
    struct Issue: Codable, Hashable, Sendable {
        let category: String?
        let original: String?
        let explanation: String
    }
    let variants: [Variant]
    let issues: [Issue]
}

/// One turn in a saved polish-discussion thread. Mirror of `PolishChatTurn`
/// in the popup but without identity (a fresh UUID is assigned on load).
struct PolishChatTurnSnapshot: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

/// One row in the user's history. Append-only — we never rewrite events, only
/// add new ones. UI aggregates by reading the full cache (small enough that
/// loading into memory is fine for the foreseeable future).
struct MemoryEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: MemoryEventKind
    /// The selection the user picked. For translate/explain this is the word
    /// or phrase being looked up; for polish it's the draft being rewritten.
    let sourceText: String
    let sourceLang: String?
    let targetLang: String?
    /// For translate: the translation result. For explain: the full streamed
    /// explanation prose. For polish: the top-ranked variant (nil if the run
    /// failed). Stored so the user can review without re-running the LLM.
    let result: String?
    /// Grammar issues from polish. Always nil for translate/explain.
    let issues: [PolishIssueSnapshot]?
    /// Translate-only: back-translation (target → source round-trip). Stored
    /// so the Memory click-through can rebuild the full translate popup,
    /// which always shows both the translation and the round-trip. Old
    /// entries without this field decode as nil — the replay path falls back
    /// to running the back-translation live in that case.
    let backTranslation: String?
    /// Polish-only: the full structured output (every variant + every issue's
    /// category/original/explanation). Aggregate-only `issues` above is kept
    /// for backwards compatibility with old entries. Old entries without
    /// this field decode as nil and force a live re-run on replay.
    let polishSnapshot: PolishResultSnapshot?
    /// Polish-only: the discussion thread the user had with Glotty *about*
    /// this polish run. Updated via `MemoryStore.update(_:)` each time a
    /// chat exchange completes, so reopening the event restores the full
    /// back-and-forth, not just the original variants. Nil = no chat yet.
    let polishChatThread: [PolishChatTurnSnapshot]?

    init(
        kind: MemoryEventKind,
        sourceText: String,
        sourceLang: String?,
        targetLang: String?,
        result: String?,
        issues: [PolishIssueSnapshot]? = nil,
        backTranslation: String? = nil,
        polishSnapshot: PolishResultSnapshot? = nil,
        polishChatThread: [PolishChatTurnSnapshot]? = nil,
        timestamp: Date = Date(),
        id: UUID = UUID()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.result = result
        self.issues = issues
        self.backTranslation = backTranslation
        self.polishSnapshot = polishSnapshot
        self.polishChatThread = polishChatThread
    }
}

/// One row in the "Frequently looked up" or "Common grammar issues" aggregates.
struct MemoryAggregate: Identifiable, Sendable {
    let id: String      // the key (lookup text or issue snippet)
    let key: String
    let count: Int
    let lastSeen: Date
}

/// Time-range filter applied when the Memory tab aggregates events. The
/// underlying history is never pruned — this is purely a display filter, so
/// the user can switch back to "All time" without losing anything.
enum MemoryTimeRange: String, CaseIterable, Identifiable, Sendable {
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:   return "Last 24 hours"
        case .week:  return "Last 7 days"
        case .month: return "Last 30 days"
        case .all:   return "All time"
        }
    }

    /// Cutoff date for events to include. `nil` means no filter (all time).
    /// Evaluated lazily — `Date()` is captured each call, not at enum creation.
    func since(now: Date = Date()) -> Date? {
        let day: TimeInterval = 86_400
        switch self {
        case .day:   return now.addingTimeInterval(-day)
        case .week:  return now.addingTimeInterval(-7 * day)
        case .month: return now.addingTimeInterval(-30 * day)
        case .all:   return nil
        }
    }
}

/// Persistent record of what the user has searched / had polished. Stored as
/// newline-delimited JSON in Application Support so the file is human-readable
/// and easy to back up / inspect. Aggregations (top-N lookups, top-N grammar
/// issues) are computed in-memory from the cache.
@MainActor
final class MemoryStore {
    static let shared = MemoryStore()

    /// UserDefaults key for the opt-out toggle. Memory is on by default; the
    /// Settings → Memory tab exposes a "Record history" switch.
    static let recordingEnabledKey = "glotty.memory.enabled"

    private let fileURL: URL
    private var cache: [MemoryEvent] = []
    /// Serial queue for disk writes so concurrent `record` calls can't
    /// interleave bytes in the JSONL file. Reads come from the in-memory cache.
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.memory", qos: .utility)

    /// Internal initializer — production code uses `MemoryStore.shared`. Tests
    /// can construct a transient instance pointing at a temp file via
    /// `MemoryStore(fileURL:)`.
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
            self.fileURL = glottyDir.appendingPathComponent("history.jsonl")
        }
        loadCache()
    }

    /// Where the JSONL file lives on disk. Exposed for the Memory settings tab
    /// in case we want to add "Show in Finder…" later.
    var storageURL: URL { fileURL }

    /// Whether recording is currently enabled. UI toggle writes the inverse.
    var isRecordingEnabled: Bool {
        get {
            // Default true if no key is set — first-run users get history.
            UserDefaults.standard.object(forKey: Self.recordingEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.recordingEnabledKey)
        }
    }

    /// Append one event. No-op when recording is disabled or sourceText is
    /// empty. Disk write happens on the serial write queue; the in-memory
    /// cache update is synchronous so the next aggregation reflects the new
    /// event immediately.
    func record(_ event: MemoryEvent) {
        guard isRecordingEnabled else { return }
        guard !event.sourceText.isEmpty else { return }

        cache.append(event)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event) else { return }
        let fileURL = self.fileURL
        writeQueue.async {
            var line = data
            line.append(0x0A)  // '\n'
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                    try? h.close()
                }
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Replace an existing event (matched by id). Used by the polish-chat
    /// flow to attach the conversation thread to its parent polish event
    /// after each new exchange. Rewrites the whole JSONL file rather than
    /// appending — keeps the file size bounded; for normal use the file is
    /// small enough that a full rewrite is cheap.
    func update(_ event: MemoryEvent) {
        guard let idx = cache.firstIndex(where: { $0.id == event.id }) else { return }
        cache[idx] = event
        rewriteAll()
    }

    /// All events in chronological order (oldest first).
    func allEvents() -> [MemoryEvent] { cache }

    /// Total event count (cheap UI signal for "no history yet" states).
    var count: Int { cache.count }

    /// Wipe everything — in-memory and on disk. Called from the Clear button.
    func clearAll() {
        cache.removeAll()
        let fileURL = self.fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Events that contributed to a "Frequently looked up" row. Match is on
    /// the same key the aggregator uses (case-insensitive trimmed source
    /// text), so clicking a row shows exactly the events behind its count.
    /// Newest first. Pass `since` for the same time-range filter that the
    /// aggregate uses.
    func eventsForLookup(key: String, since: Date? = nil) -> [MemoryEvent] {
        let needle = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cache
            .filter { ($0.kind == .translate || $0.kind == .explain) }
            .filter { since == nil || $0.timestamp >= since! }
            .filter { $0.sourceText.lowercased() == needle }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Polish events whose flagged issues include the given category. Used by
    /// the Memory tab's "Common mistake types" drill-in. Newest first.
    func eventsForGrammarCategory(_ category: String, since: Date? = nil) -> [MemoryEvent] {
        let needle = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cache
            .filter { $0.kind == .polish }
            .filter { since == nil || $0.timestamp >= since! }
            .filter {
                guard let issues = $0.issues else { return false }
                return issues.contains { ($0.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Top-N most-searched terms across translate + explain events. Sorted by
    /// count desc, then last-seen desc as a tie-breaker (so recent searches
    /// surface above forgotten ones at the same count). `since` filters out
    /// events older than the cutoff — pass `nil` for "all time".
    func topLookups(limit: Int = 20, since: Date? = nil) -> [MemoryAggregate] {
        Self.aggregate(
            from: cache.filter {
                ($0.kind == .translate || $0.kind == .explain)
                    && (since == nil || $0.timestamp >= since!)
            },
            keyFor: { $0.sourceText },
            limit: limit
        )
    }

    /// Top-N grammar mistake **categories** across polish events. Aggregates
    /// by the LLM-supplied category label ("Verb tense", "Article usage",
    /// etc.) — the user's literal text is never recorded, so this is the only
    /// signal we have. Issues without a category are skipped (the LLM either
    /// failed to label them or these are legacy entries from before the
    /// schema change). The display key is title-cased so "verb tense" and
    /// "Verb tense" both display as "Verb tense".
    func topGrammarIssues(limit: Int = 20, since: Date? = nil) -> [MemoryAggregate] {
        var counts: [String: (display: String, count: Int, lastSeen: Date)] = [:]
        for event in cache where event.kind == .polish {
            if let since, event.timestamp < since { continue }
            guard let issues = event.issues else { continue }
            for issue in issues {
                guard let category = issue.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !category.isEmpty else { continue }
                let key = category.lowercased()
                let display = counts[key]?.display ?? category
                let existing = counts[key] ?? (display, 0, .distantPast)
                counts[key] = (existing.display, existing.count + 1, max(existing.lastSeen, event.timestamp))
            }
        }
        return counts
            .map { MemoryAggregate(id: $0.key, key: $0.value.display, count: $0.value.count, lastSeen: $0.value.lastSeen) }
            .sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
            .prefix(limit)
            .map { $0 }
    }

    /// Internal helper for count/last-seen aggregations. Lowercases keys so
    /// "Hello" and "hello" merge into one row.
    private static func aggregate(
        from events: [MemoryEvent],
        keyFor: (MemoryEvent) -> String,
        limit: Int
    ) -> [MemoryAggregate] {
        var counts: [String: (count: Int, lastSeen: Date)] = [:]
        for event in events {
            let raw = keyFor(event).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let key = raw.lowercased()
            let existing = counts[key] ?? (0, .distantPast)
            counts[key] = (existing.count + 1, max(existing.lastSeen, event.timestamp))
        }
        return counts
            .map { MemoryAggregate(id: $0.key, key: $0.key, count: $0.value.count, lastSeen: $0.value.lastSeen) }
            .sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
            .prefix(limit)
            .map { $0 }
    }

    /// Encode every cached event back to disk as a fresh JSONL file.
    /// Triggered by `update(_:)` since the append-only path can't replace an
    /// existing line in place.
    private func rewriteAll() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = cache
        let fileURL = self.fileURL
        writeQueue.async {
            var blob = Data()
            for event in snapshot {
                if let data = try? encoder.encode(event) {
                    blob.append(data)
                    blob.append(0x0A)
                }
            }
            try? blob.write(to: fileURL, options: .atomic)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cache = data
            .split(separator: 0x0A)            // newline
            .compactMap { line -> MemoryEvent? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(MemoryEvent.self, from: Data(line))
            }
    }
}
