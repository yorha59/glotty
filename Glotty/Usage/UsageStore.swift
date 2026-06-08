import Foundation

/// Threads the current usage mode down from the call site (PopupView,
/// ReminderScheduler) into the provider's SSE-parsing code, without
/// requiring every protocol method to grow a `mode:` parameter. Callers
/// wrap their provider calls with `UsageContext.$mode.withValue(.polish)`;
/// providers read `UsageContext.mode` when they record a UsageEvent.
enum UsageContext {
    @TaskLocal static var mode: UsageMode? = nil
}

/// Which Glotty feature triggered the LLM call. Tagging at the call site lets
/// the Usage tab break down spend by feature (which is more useful than just
/// "total tokens since install"). Provider-side code just passes whatever
/// label the caller gave it.
enum UsageMode: String, Codable, Sendable, CaseIterable {
    case translate
    case explain
    case polish
    case chat              // ad-hoc / popup-generated question
    case memoryExtract     // post-chat extraction of learned memories

    var displayName: String {
        switch self {
        case .translate:        return String(localized: "Translate")
        case .explain:          return String(localized: "Explain")
        case .polish:           return String(localized: "Polish")
        case .chat:             return String(localized: "Chat (ad-hoc)")
        case .memoryExtract:    return String(localized: "Memory extraction")
        }
    }
}

/// One LLM-call accounting entry. `promptTokens` + `completionTokens` may be
/// 0 when the provider didn't report usage for a particular call — we still
/// persist the event so the count of *calls* per mode is visible even if the
/// token columns are missing.
struct UsageEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let providerID: String      // e.g. "zai", "kimi-coding"
    let mode: UsageMode
    let promptTokens: Int
    let completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }

    init(providerID: String,
         mode: UsageMode,
         promptTokens: Int,
         completionTokens: Int,
         timestamp: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.timestamp = timestamp
        self.providerID = providerID
        self.mode = mode
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Aggregated totals returned by `UsageStore` query methods. Keep this
/// shape stable — the Settings UI binds directly to it.
struct UsageTotals: Sendable {
    let prompt: Int
    let completion: Int
    var total: Int { prompt + completion }
    let calls: Int

    static let zero = UsageTotals(prompt: 0, completion: 0, calls: 0)
}

/// Persistent token-usage log. JSONL at
/// `~/Library/Application Support/Glotty/usage.jsonl`. Append-only — events
/// are never edited. Aggregations are computed in-memory from the cache.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private let fileURL: URL
    @Published private(set) var events: [UsageEvent] = []
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.usage", qos: .utility)

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
            self.fileURL = glottyDir.appendingPathComponent("usage.jsonl")
        }
        load()
    }

    /// Provider-side hook — record a token-usage event from any context
    /// (provider streaming code runs off the main actor). Mode is read from
    /// the surrounding `UsageContext` TaskLocal; falls back to `.chat` if
    /// the caller didn't set one.
    nonisolated static func recordFromProvider(providerID: String,
                                                promptTokens: Int,
                                                completionTokens: Int) {
        let mode = UsageContext.mode ?? .chat
        let event = UsageEvent(
            providerID: providerID,
            mode: mode,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        Task { @MainActor in
            UsageStore.shared.record(event)
        }
    }

    /// Append one event. Persists asynchronously; the in-memory cache is
    /// updated synchronously so the next aggregation reflects the event.
    func record(_ event: UsageEvent) {
        events.append(event)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event) else { return }
        let fileURL = self.fileURL
        writeQueue.async {
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                    try? h.close()
                }
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }

    func clearAll() {
        events.removeAll()
        let fileURL = self.fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Aggregations

    /// Totals since a given cutoff. Pass `nil` for all-time.
    func totals(since: Date?) -> UsageTotals {
        aggregate(events.filter { since == nil || $0.timestamp >= since! })
    }

    /// Totals broken down by mode, since a given cutoff. Returns rows in
    /// `UsageMode.allCases` order with zero-totals filtered out.
    func byMode(since: Date?) -> [(mode: UsageMode, totals: UsageTotals)] {
        let scoped = events.filter { since == nil || $0.timestamp >= since! }
        return UsageMode.allCases.compactMap { mode in
            let bucket = scoped.filter { $0.mode == mode }
            guard !bucket.isEmpty else { return nil }
            return (mode, aggregate(bucket))
        }
    }

    /// Totals broken down by provider id ("zai", "kimi-coding"), since cutoff.
    func byProvider(since: Date?) -> [(provider: String, totals: UsageTotals)] {
        let scoped = events.filter { since == nil || $0.timestamp >= since! }
        let providerIDs = Set(scoped.map(\.providerID)).sorted()
        return providerIDs.compactMap { pid in
            let bucket = scoped.filter { $0.providerID == pid }
            return (pid, aggregate(bucket))
        }
    }

    private func aggregate(_ slice: [UsageEvent]) -> UsageTotals {
        let prompt = slice.reduce(0) { $0 + $1.promptTokens }
        let completion = slice.reduce(0) { $0 + $1.completionTokens }
        return UsageTotals(prompt: prompt, completion: completion, calls: slice.count)
    }

    // MARK: - Time-range helpers

    nonisolated static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    nonisolated static func startOfWeek() -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? Date().addingTimeInterval(-7 * 86_400)
    }

    nonisolated static func startOfMonth() -> Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start
            ?? Date().addingTimeInterval(-30 * 86_400)
    }

    // MARK: - I/O

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = data
            .split(separator: 0x0A)
            .compactMap { line -> UsageEvent? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(UsageEvent.self, from: Data(line))
            }
    }
}
