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
    /// Copy-ready phrasings the model surfaced in this turn (optional so old
    /// snapshots without the field decode to nil).
    var phrases: [String]? = nil
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
    /// Discussion thread the user had with Glotty *about* this run.
    /// Originally polish-only — now also used by explain when the user
    /// expands "Discuss with Glotty" under the explanation. Field name
    /// stays `polishChatThread` for JSON compatibility with pre-existing
    /// events on disk. Updated via `MemoryStore.update(_:)` each time a
    /// chat exchange completes, so reopening the event restores the full
    /// back-and-forth. Nil = no chat yet.
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
            let glottyDir = appSupport.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
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

    /// Append one event. No-op when recording is disabled, sourceText is
    /// empty, the event has no meaningful result yet (unfinished run), or
    /// the immediately-preceding event is the same kind+sourceText (back-
    /// to-back duplicate — replaces in place so we keep the freshest copy
    /// without padding History with near-identical rows).
    func record(_ event: MemoryEvent) {
        guard isRecordingEnabled else { return }
        guard !event.sourceText.isEmpty else { return }
        // Skip unfinished queries — empty/whitespace `result` means the
        // popup was dismissed before the stream produced anything (or the
        // provider errored mid-flight and we still hit this code path).
        // Polish has its own structured fields (variants/snapshot); a
        // polish run without variants is also unfinished.
        guard Self.hasContent(event) else { return }
        // Adjacent dedup. If the latest event already in the cache shares
        // kind + sourceText with the incoming one, replace it instead of
        // appending — keeps the chronological order intact while ensuring
        // History only shows one row per "the user asked again about the
        // same thing right after."
        if let last = cache.last,
           last.kind == event.kind,
           last.sourceText == event.sourceText {
            cache[cache.count - 1] = event
            rewriteAll()
            return
        }

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

    /// True when the event carries enough output to be worth surfacing in
    /// History. Polish uses its structured `polishSnapshot.variants`;
    /// translate/explain just need a non-empty `result` string.
    private static func hasContent(_ event: MemoryEvent) -> Bool {
        switch event.kind {
        case .polish:
            if let snap = event.polishSnapshot, !snap.variants.isEmpty { return true }
            // Older entries without polishSnapshot fall back to `result`.
            let trimmed = (event.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
        case .translate, .explain:
            let trimmed = (event.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
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

    /// Wholesale replace every event with the supplied list,
    /// preserving original UUIDs and timestamps. Used by the
    /// Backup import path.
    func replaceAll(with events: [MemoryEvent]) {
        cache = events
        rewriteAll()
    }

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
    func topGrammarIssues(
        limit: Int = 20,
        since: Date? = nil,
        language: String? = nil
    ) -> [MemoryAggregate] {
        var counts: [String: (display: String, count: Int, lastSeen: Date)] = [:]
        for event in cache where event.kind == .polish {
            if let since, event.timestamp < since { continue }
            // Language filter: only count categories from polishes
            // whose target language matches. Without this, English
            // "Word choice" and Chinese "用词不当" would be counted
            // as two separate categories — useless for aggregation.
            if let language, event.targetLang != language { continue }
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

    /// One bucketed data point for the polish "common mistake types"
    /// trend chart. Each `(bucketStart, category)` pair appears once;
    /// `count` is the number of polish issues with that category that
    /// fell inside the bucket. Buckets are filled in for every
    /// `(bucket, category)` combination so the chart's lines don't
    /// drop to nil when a category has zero mistakes in a given day.
    struct GrammarIssueTrendPoint: Identifiable, Sendable {
        let bucketStart: Date
        let category: String
        let count: Int
        var id: String { "\(bucketStart.timeIntervalSinceReferenceDate)|\(category)" }
    }

    /// Time-series of grammar issue counts per category, ready for a
    /// line chart. Restricted to the top `topN` categories within the
    /// window so the chart stays readable (the long tail just adds
    /// visual noise). Bucket size is picked from the range so we get
    /// a useful number of points: hourly for the 24h view, daily for
    /// week / month, weekly for "all time".
    func grammarIssueTrend(
        topN: Int = 5,
        since: Date? = nil,
        language: String? = nil,
        now: Date = Date()
    ) -> (categories: [String], points: [GrammarIssueTrendPoint]) {
        // Pick top categories first — same ranking the list used —
        // so the lines plotted match the legend the user expects.
        let top = topGrammarIssues(limit: topN, since: since, language: language)
        let displayByKey: [String: String] = Dictionary(
            uniqueKeysWithValues: top.map { ($0.key.lowercased(), $0.key) }
        )
        let trackedKeys = Set(displayByKey.keys)
        guard !trackedKeys.isEmpty else { return ([], []) }

        let calendar = Calendar.current
        let component: Calendar.Component = bucketComponent(forSince: since, now: now)

        // Walk events once, bucket the matching issues.
        var counts: [Date: [String: Int]] = [:]
        for event in cache where event.kind == .polish {
            if let since, event.timestamp < since { continue }
            if let language, event.targetLang != language { continue }
            guard let issues = event.issues else { continue }
            let bucket = calendar.dateInterval(of: component, for: event.timestamp)?.start
                ?? event.timestamp
            for issue in issues {
                guard let raw = issue.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                let key = raw.lowercased()
                guard trackedKeys.contains(key) else { continue }
                counts[bucket, default: [:]][key, default: 0] += 1
            }
        }

        // Zero-fill every bucket × category cell so SwiftUI Charts
        // draws continuous lines across the window even when a
        // category has gaps.
        let firstBucket: Date = {
            if let since {
                return calendar.dateInterval(of: component, for: since)?.start ?? since
            }
            // "All time" — anchor on the earliest event we actually have.
            let earliest = cache.first(where: { $0.kind == .polish })?.timestamp ?? now
            return calendar.dateInterval(of: component, for: earliest)?.start ?? earliest
        }()
        let lastBucket = calendar.dateInterval(of: component, for: now)?.start ?? now

        var buckets: [Date] = []
        var cursor = firstBucket
        while cursor <= lastBucket {
            buckets.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
            // Guard against runaway loops (e.g. malformed component).
            if buckets.count > 500 { break }
        }

        var points: [GrammarIssueTrendPoint] = []
        points.reserveCapacity(buckets.count * displayByKey.count)
        for bucket in buckets {
            for (key, display) in displayByKey {
                let count = counts[bucket]?[key] ?? 0
                points.append(GrammarIssueTrendPoint(
                    bucketStart: bucket,
                    category: display,
                    count: count
                ))
            }
        }

        // Return categories in the same top-N order so the chart's
        // legend matches the underlying ranking.
        return (top.map { $0.key }, points)
    }

    /// Bucket size for the trend chart. Short ranges get finer
    /// granularity so the chart isn't reduced to one or two points.
    private func bucketComponent(forSince since: Date?, now: Date) -> Calendar.Component {
        guard let since else { return .weekOfYear }
        let span = now.timeIntervalSince(since)
        let day: TimeInterval = 86_400
        if span <= 2 * day { return .hour }
        if span <= 60 * day { return .day }
        return .weekOfYear
    }

    /// Distinct category strings the LLM has produced for polish
    /// events in this target language. Fed back into the polish
    /// prompt's "prefer existing categories" instruction so the
    /// model doesn't drift (same kind of mistake getting different
    /// labels across runs, which would defeat aggregation).
    func knownCategories(for language: String) -> Set<String> {
        var result: Set<String> = []
        for event in cache where event.kind == .polish && event.targetLang == language {
            guard let issues = event.issues else { continue }
            for issue in issues {
                if let category = issue.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !category.isEmpty {
                    result.insert(category)
                }
            }
        }
        return result
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
        // One-shot cleanup of stale rows on every launch — purges
        // unfinished queries (empty `result`) and back-to-back
        // duplicates that pre-date the matching guards in `record(_:)`.
        // If anything gets dropped, the JSONL is rewritten so the file
        // matches the cache on disk too.
        purgeStaleEntries()
    }

    /// Drop empty/unfinished events and collapse adjacent
    /// kind+sourceText duplicates (keeping the last of each run, which
    /// is normally the most complete copy). Idempotent: a clean cache
    /// passes through untouched. Rewrites the JSONL only when the cache
    /// actually changed so the I/O is free on the common path.
    private func purgeStaleEntries() {
        let before = cache.count
        var cleaned: [MemoryEvent] = []
        cleaned.reserveCapacity(cache.count)
        for event in cache {
            guard Self.hasContent(event) else { continue }
            if let last = cleaned.last,
               last.kind == event.kind,
               last.sourceText == event.sourceText {
                // Adjacent dup — overwrite the earlier slot.
                cleaned[cleaned.count - 1] = event
            } else {
                cleaned.append(event)
            }
        }
        guard cleaned.count != before else { return }
        cache = cleaned
        rewriteAll()
    }
}
