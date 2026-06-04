import Foundation

/// Resolves "what day are we in" for chat sessions. Day boundary is
/// 4:00 AM local — chosen because users frequently chat past
/// midnight; a hard midnight rollover would split a single late-
/// night conversation across two days in History. With 4am as the
/// anchor, late-night chats stay grouped with the day they started.
enum ChatDay {
    /// Anchor hour (24h) where one chat day rolls into the next.
    static let dayBoundaryHour = 4

    /// String key in `YYYY-MM-DD` form for the chat day containing
    /// `now`. Anchored to local time so the boundary tracks the
    /// user's calendar, not UTC.
    static func key(for now: Date = Date(),
                    calendar: Calendar = .current) -> String {
        let shifted = now.addingTimeInterval(-Double(dayBoundaryHour) * 3600)
        let comps = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Anchor `Date` of the chat day (the 4 AM local moment when it
    /// began). Used for display formatting and "Today / Yesterday"
    /// labels.
    static func anchor(for dayKey: String,
                       calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = dayBoundaryHour
        return calendar.date(from: comps)
    }

    /// Friendly label for the History list: "Today", "Yesterday",
    /// or a localized full date.
    static func displayLabel(for dayKey: String,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let today = key(for: now, calendar: calendar)
        let yesterday = key(for: now.addingTimeInterval(-86400), calendar: calendar)
        if dayKey == today    { return String(localized: "Today") }
        if dayKey == yesterday { return String(localized: "Yesterday") }
        guard let anchor = anchor(for: dayKey, calendar: calendar) else { return dayKey }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: anchor)
    }
}

/// One persisted turn in a daily chat thread. Mirror of the in-popup
/// `TutorTurn` minus the SwiftUI identity (a fresh UUID is assigned
/// when we hydrate the popup state from disk).
struct TutorTurnSnapshot: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case tutor
        /// App-injected status note (tool-call outcomes etc.). Old
        /// rows on disk only have `user` / `tutor`; the decoder
        /// falls through to nil for unknown raw values, so any
        /// future role added here will fail-soft on legacy data.
        case system
    }
    let role: Role
    let reply: String
    let correctedText: String?
    let correctionNote: String?
    /// Persisted tool-call attached to a tutor turn (e.g. a
    /// `set_setting` that's still pending, or a record of a past
    /// confirmation). Optional + nil-by-default so older threads
    /// without a tool-call field decode cleanly.
    let toolCall: PendingToolCall?
}

/// One day's chat thread. Append-only on the live popup side
/// (`appendToToday`); the History UI rewrites the file when a row
/// is deleted.
struct DailyChatThread: Codable, Identifiable, Sendable {
    let id: UUID
    /// `YYYY-MM-DD` chat-day key (4am-anchored — see `ChatDay`).
    let dayKey: String
    let startedAt: Date
    var updatedAt: Date
    var turns: [TutorTurnSnapshot]
    /// 1–3 short topic tags Glotty extracted from this thread (e.g.
    /// `["polish feature", "Berlin job"]`). Optional + nil-by-default
    /// so old threads on disk decode cleanly. Populated lazily by
    /// `TopicExtractor` once the thread is closed (next day rolls
    /// over) so the next chat can avoid re-pitching the same things.
    var topics: [String]?
}

/// Persistent store for daily chat threads. Mirrors the JSONL +
/// Application Support pattern used by `MemoryStore` and
/// `LearnedMemoryStore` — one JSON object per line, append-only on
/// the live path, full rewrite for deletions.
///
/// Posts `didChangeNotification` after every mutation so the Settings
/// History list auto-refreshes.
@MainActor
final class ChatStore {
    static let shared = ChatStore()

    static let didChangeNotification = Notification.Name("glotty.chatStore.didChange")

    private let fileURL: URL
    private var cache: [DailyChatThread] = []
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.chat-store", qos: .utility)

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
            self.fileURL = glottyDir.appendingPathComponent("chat-threads.jsonl")
        }
        loadCache()
    }

    var storageURL: URL { fileURL }

    /// All threads, newest day first. Used by the Settings History
    /// list.
    func allThreads() -> [DailyChatThread] {
        cache.sorted { $0.dayKey > $1.dayKey }
    }

    /// Timestamp of the most recent chat activity across every
    /// stored thread (latest `updatedAt`). Used by the proactive
    /// reminder scheduler to gate notifications on real idle time —
    /// "you haven't chatted in N minutes" rather than "the timer
    /// rolled over". Nil if the user has never chatted.
    func lastActivity() -> Date? {
        cache.map { $0.updatedAt }.max()
    }

    /// Lookup by id — used by the History viewer.
    func thread(id: UUID) -> DailyChatThread? {
        cache.first { $0.id == id }
    }

    /// Today's thread, creating an empty one if none exists yet.
    /// The empty thread is NOT persisted until the first turn is
    /// appended — keeps the file from filling with zero-turn rows
    /// when the user just opens and immediately closes the popup.
    func todayThread() -> DailyChatThread {
        let today = ChatDay.key()
        if let existing = cache.first(where: { $0.dayKey == today }) {
            return existing
        }
        let now = Date()
        return DailyChatThread(
            id: UUID(),
            dayKey: today,
            startedAt: now,
            updatedAt: now,
            turns: []
        )
    }

    /// Append a turn to today's thread. Creates and persists the
    /// thread on disk if this is the first turn of the day.
    /// Returns the id of the thread the turn landed in so callers
    /// (extractor) can tie suggestions to it.
    @discardableResult
    func appendToToday(_ turn: TutorTurnSnapshot) -> UUID {
        let today = ChatDay.key()
        if let idx = cache.firstIndex(where: { $0.dayKey == today }) {
            cache[idx].turns.append(turn)
            cache[idx].updatedAt = Date()
            rewriteAll()
            notifyChange()
            return cache[idx].id
        }
        // First turn of the day — create the thread.
        let now = Date()
        let new = DailyChatThread(
            id: UUID(),
            dayKey: today,
            startedAt: now,
            updatedAt: now,
            turns: [turn]
        )
        cache.append(new)
        rewriteAll()
        notifyChange()
        return new.id
    }

    /// Replace the tool-call payload on a specific turn within a
    /// thread. Used when the user confirms / declines a `set_setting`
    /// card so the resolved state survives a popup close + relaunch.
    /// No-op when the thread or turn isn't found.
    func updateTurn(threadID: UUID,
                    turnIndex: Int,
                    toolCall: PendingToolCall?) {
        guard let ti = cache.firstIndex(where: { $0.id == threadID }) else { return }
        guard turnIndex >= 0, turnIndex < cache[ti].turns.count else { return }
        let old = cache[ti].turns[turnIndex]
        cache[ti].turns[turnIndex] = TutorTurnSnapshot(
            role: old.role,
            reply: old.reply,
            correctedText: old.correctedText,
            correctionNote: old.correctionNote,
            toolCall: toolCall
        )
        cache[ti].updatedAt = Date()
        rewriteAll()
        notifyChange()
    }

    /// Replace the `topics` tag list for one thread. Used by
    /// `TopicExtractor` once the LLM has summarised yesterday's
    /// chat into a short tag list.
    func setTopics(_ topics: [String], for threadID: UUID) {
        guard let idx = cache.firstIndex(where: { $0.id == threadID }) else { return }
        cache[idx].topics = topics
        rewriteAll()
        notifyChange()
    }

    /// Recently-discussed topics across the last `daysBack` chat
    /// days, EXCLUDING the current chat day (we don't want to tell
    /// the LLM "you already pitched X" if X is happening right now).
    /// Deduped case-insensitively while preserving first-seen order.
    func recentTopics(daysBack: Int = 7, now: Date = Date()) -> [String] {
        let todayKey = ChatDay.key(for: now)
        let oldestKey = ChatDay.key(for: now.addingTimeInterval(-Double(daysBack) * 86_400))
        var seen: Set<String> = []
        var result: [String] = []
        // Newest first so the most recent topics anchor the list.
        for thread in cache.sorted(by: { $0.dayKey > $1.dayKey }) {
            guard thread.dayKey != todayKey, thread.dayKey >= oldestKey else { continue }
            guard let topics = thread.topics else { continue }
            for topic in topics {
                let key = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                if seen.insert(key.lowercased()).inserted {
                    result.append(key)
                }
            }
        }
        return result
    }

    /// Closed threads (i.e. not today's) that haven't had their
    /// `topics` extracted yet. Caller awaits `TopicExtractor.run`
    /// on each one in the background; populates `topics` so future
    /// chats avoid re-pitching.
    func threadsNeedingTopicExtraction(now: Date = Date()) -> [DailyChatThread] {
        let todayKey = ChatDay.key(for: now)
        return cache.filter { $0.dayKey != todayKey && $0.topics == nil && !$0.turns.isEmpty }
    }

    /// Delete a thread permanently.
    func delete(id: UUID) {
        let before = cache.count
        cache.removeAll { $0.id == id }
        if cache.count != before {
            rewriteAll()
            notifyChange()
        }
    }

    /// Wholesale replace every thread with the supplied list,
    /// preserving the original UUIDs and dayKeys. Used by the
    /// Backup import path. Posts the change notification so any
    /// open Settings view refreshes.
    func replaceAll(with threads: [DailyChatThread]) {
        cache = threads
        rewriteAll()
        notifyChange()
    }

    /// Wipe every chat thread. Behind "Clear all chat history" in
    /// Settings.
    func clearAll() {
        cache.removeAll()
        let fileURL = self.fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func rewriteAll() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = cache
        let fileURL = self.fileURL
        writeQueue.async {
            var blob = Data()
            for thread in snapshot {
                if let data = try? encoder.encode(thread) {
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
            .split(separator: 0x0A)
            .compactMap { line -> DailyChatThread? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(DailyChatThread.self, from: Data(line))
            }
    }
}
