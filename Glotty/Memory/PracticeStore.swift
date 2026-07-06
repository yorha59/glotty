import Foundation

/// A single practice card built from a due polish event — the scenario the
/// chat drill replays. Value type so it threads into the popup/prompt cleanly.
struct PracticeItem: Identifiable, Equatable, Sendable {
    /// Back-reference to the polish `MemoryEvent`, used to reschedule.
    let eventID: UUID
    /// The user's original phrasing (what they hit Polish on).
    let draft: String
    /// Native-language meaning (back-translation of the polished answer), the
    /// "you meant…" half of the scenario. Nil if it wasn't captured.
    let meaning: String?
    /// The polished rewrite they originally got — the reference answer.
    let answer: String
    /// Short "category — explanation" lines for what was off.
    let issues: [String]

    var id: UUID { eventID }
}

/// Spaced-repetition scheduling for "practice your past mistakes".
///
/// Every Polish run that flagged grammar mistakes becomes a reviewable item,
/// anchored on its `MemoryEvent.id`. The actual practice happens in the chat
/// (the tutor re-presents the original scenario — your draft + the meaning —
/// and checks your new attempt); this store only tracks WHEN each item is due
/// and reschedules it from the outcome the tutor reports.
///
/// State persists as a small JSON map (eventID → review state) in Application
/// Support, alongside `MemoryStore`'s history file.
@MainActor
final class PracticeStore {
    static let shared = PracticeStore()

    /// Opt-in toggle for the "items are due" reminder (Settings → Memory).
    static let reminderEnabledKey = "glotty.practice.reminder.enabled"

    /// Per-item spaced-repetition state.
    struct ReviewState: Codable, Sendable {
        var dueDate: Date
        var intervalDays: Double
        /// Consecutive correct attempts — drives the growing interval.
        var streak: Int
        var lastReviewed: Date?
        /// Graduated out once the interval is long enough; stops surfacing.
        var retired: Bool
    }

    // First review lands ~1 day after the polish (the user's "a day or two"),
    // then grows on each correct attempt and resets on a miss. Retires once it
    // reaches the long tail so well-learned items stop coming back.
    private let firstIntervalDays = 1.0
    private let retireIntervalDays = 60.0
    /// Cap on how many due items a single practice session pulls in.
    nonisolated static let sessionCap = 10
    /// Keep the active queue focused on fresh mistakes: only the most-recently
    /// polished due items count toward the badge / are eligible for a session,
    /// so an old backlog never piles up into a discouraging number.
    nonisolated static let recentCap = 20

    private let fileURL: URL
    /// eventID → review state. Source of truth in memory; persisted as a
    /// `[uuidString: ReviewState]` map for readability.
    private var states: [UUID: ReviewState] = [:]
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.practice", qos: .utility)

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            let dir = appSupport.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("practice.json")
        }
        load()
    }

    var storageURL: URL { fileURL }

    /// True for polish events worth practicing: a polish run that flagged at
    /// least one mistake and still carries the snapshot we replay from.
    static func isPracticable(_ event: MemoryEvent) -> Bool {
        event.kind == .polish
            && (event.issues?.isEmpty == false)
            && event.polishSnapshot != nil
    }

    /// Ensure every practicable polish event has a review state. New items are
    /// scheduled ~1 day after the polish so they don't surface the same day,
    /// and states for events that no longer exist are pruned.
    func sync(with events: [MemoryEvent]) {
        var changed = false
        let liveIDs = Set(events.map(\.id))

        for event in events where Self.isPracticable(event) {
            if states[event.id] == nil {
                states[event.id] = ReviewState(
                    dueDate: event.timestamp.addingTimeInterval(firstIntervalDays * 86_400),
                    intervalDays: firstIntervalDays,
                    streak: 0,
                    lastReviewed: nil,
                    retired: false
                )
                changed = true
            }
        }
        // Prune orphans (event deleted / history cleared).
        for id in states.keys where !liveIDs.contains(id) {
            states.removeValue(forKey: id)
            changed = true
        }
        if changed { persist() }
    }

    /// The active due pool: events whose review is due, **most-recently polished
    /// first**, limited to `recentCap` so practice stays on fresh mistakes
    /// rather than a stale backlog.
    private func dueEvents(now: Date = Date()) -> [MemoryEvent] {
        let events = MemoryStore.shared.allEvents()
        sync(with: events)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let dueIDs = states
            .filter { !$0.value.retired && $0.value.dueDate <= now }
            .map(\.key)
        return dueIDs
            .compactMap { byID[$0] }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(Self.recentCap)
            .map { $0 }
    }

    /// Polish events to drill this session — the most recent due items, capped.
    func dueItems(now: Date = Date(), limit: Int = sessionCap) -> [MemoryEvent] {
        Array(dueEvents(now: now).prefix(limit))
    }

    /// Due items as ready-to-drill practice cards (the chat session's agenda).
    func dueSession(now: Date = Date(), limit: Int = sessionCap) -> [PracticeItem] {
        dueItems(now: now, limit: limit).compactMap { Self.makeItem(from: $0) }
    }

    /// Build a practice card from a polish event's stored snapshot.
    static func makeItem(from event: MemoryEvent) -> PracticeItem? {
        guard let snap = event.polishSnapshot, let top = snap.variants.first else { return nil }
        let issues = snap.issues.map { issue in
            [issue.category, issue.explanation].compactMap { $0 }.joined(separator: " — ")
        }
        return PracticeItem(
            eventID: event.id,
            draft: event.sourceText,
            meaning: top.backTranslation,
            answer: top.text,
            issues: issues
        )
    }

    /// How many items are in the active due pool (≤ `recentCap`) — the menu-bar
    /// count / reminder gate.
    func dueCount(now: Date = Date()) -> Int {
        dueEvents(now: now).count
    }

    /// Record a practice outcome the tutor reported and reschedule the item.
    /// Correct → interval grows (and eventually retires); incorrect → back to
    /// the first interval.
    func recordOutcome(eventID: UUID, correct: Bool, now: Date = Date()) {
        guard var state = states[eventID] else { return }
        state.lastReviewed = now
        if correct {
            state.streak += 1
            state.intervalDays = nextInterval(after: state.intervalDays)
            if state.intervalDays >= retireIntervalDays { state.retired = true }
        } else {
            state.streak = 0
            state.intervalDays = firstIntervalDays
        }
        state.dueDate = now.addingTimeInterval(state.intervalDays * 86_400)
        states[eventID] = state
        persist()
    }

    /// Anki-flavored growth: 1 → 3 → 7 → 16 → 35 → 60 days.
    private func nextInterval(after current: Double) -> Double {
        switch current {
        case ..<1.5:  return 3
        case ..<3.5:  return 7
        case ..<8:    return 16
        case ..<20:   return 35
        default:      return retireIntervalDays
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder.practice.decode([String: ReviewState].self, from: data)
        else { return }
        states = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
        let url = fileURL
        writeQueue.async {
            guard let data = try? JSONEncoder.practice.encode(raw) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension JSONEncoder {
    static let practice: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let practice: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
