import Foundation

/// A named scope the user can switch between. While context X is
/// active, accepted memories scoped to X (plus all globals) get
/// injected into LLM prompts; memories scoped to *other* contexts
/// are dormant. Lets the user keep parallel sets of terminology /
/// preferences (e.g. "Glotty work" vs "Travel writing") without
/// having to expire entries when their relevance shifts.
struct MemoryContext: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// Injection rule for the whole set — `.everywhere` (default) or
    /// `.chatOnly`. Optional so contexts saved before this field existed
    /// decode cleanly; read via `effectiveInjection`.
    var injection: MemoryInjectionScope?
    /// Optional user-written description of what this context is for (shown
    /// under its name in Settings). Optional so contexts saved before this
    /// field existed decode cleanly. Empty/whitespace is normalized to nil.
    var note: String?

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         injection: MemoryInjectionScope? = nil,
         note: String? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.injection = injection
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
    }

    /// Resolved injection rule — legacy contexts (no `injection` field)
    /// decode as nil and behave as `.everywhere`.
    var effectiveInjection: MemoryInjectionScope { injection ?? .everywhere }
}

/// Which memory scope a `LearnedMemory` belongs to. `.global`
/// memories always inject; `.context(id)` only inject when that
/// context is the currently active one (see
/// `MemoryContextStore.activeContextID`). Legacy entries on disk
/// without a `scope` field decode as nil and `LearnedMemory.effectiveScope`
/// treats them as `.global` for backwards compatibility.
enum MemoryScope: Equatable, Sendable, Hashable {
    case global
    case context(UUID)

    /// Convenience used by UI badges and store filtering.
    var contextID: UUID? {
        if case .context(let id) = self { return id }
        return nil
    }
}

extension MemoryScope: Codable {
    private enum CodingKeys: String, CodingKey { case type, contextID }
    private enum ScopeType: String, Codable { case global, context }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try c.encode(ScopeType.global, forKey: .type)
        case .context(let id):
            try c.encode(ScopeType.context, forKey: .type)
            try c.encode(id, forKey: .contextID)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ScopeType.self, forKey: .type)
        switch type {
        case .global:
            self = .global
        case .context:
            let id = try c.decode(UUID.self, forKey: .contextID)
            self = .context(id)
        }
    }
}

/// Persistent store for the user's named contexts. Mirrors the
/// JSONL-in-Application-Support pattern used by `MemoryStore` and
/// `LearnedMemoryStore` so the file is human-readable and easy to
/// back up. Contexts are few (handful per user), so we hold the
/// full list in memory and rewrite the file on every mutation.
@MainActor
final class MemoryContextStore {
    static let shared = MemoryContextStore()

    /// UserDefaults key for the currently-active context. nil = no
    /// context active (global memories only). The mascot menu and
    /// the Memory settings tab both read/write this.
    static let activeContextKey = "glotty.memory.activeContextID"

    /// UserDefaults key for the **Global** set's injection rule (Global isn't a
    /// `MemoryContext`, so its rule lives here rather than on a struct).
    static let globalInjectionKey = "glotty.memory.global.injection"

    /// Injection rule for the Global memory set. Defaults to `.everywhere`.
    var globalInjection: MemoryInjectionScope {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.globalInjectionKey) ?? ""
            return MemoryInjectionScope(rawValue: raw) ?? .everywhere
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.globalInjectionKey) }
    }

    private let fileURL: URL
    private var cache: [MemoryContext] = []
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.memory-contexts", qos: .utility)

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
            self.fileURL = glottyDir.appendingPathComponent("memory-contexts.jsonl")
        }
        loadCache()
    }

    /// All contexts, oldest-first (creation order). UI may re-sort.
    func all() -> [MemoryContext] { cache }

    /// Look up by id — used by UI badges that need a context's name.
    func context(id: UUID) -> MemoryContext? {
        cache.first { $0.id == id }
    }

    /// Currently-active context id, or nil for "no active context".
    /// Reading is a UserDefaults round-trip so external code (menu
    /// bar, popup) sees the up-to-date value even across processes.
    var activeContextID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.activeContextKey),
                  let id = UUID(uuidString: raw) else { return nil }
            // Guard against orphaned ids — context was deleted but
            // the active pointer still references it.
            return cache.contains(where: { $0.id == id }) ? id : nil
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeContextKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeContextKey)
            }
        }
    }

    /// Active context resolved to a value, or nil.
    var active: MemoryContext? {
        activeContextID.flatMap { id in cache.first { $0.id == id } }
    }

    @discardableResult
    func add(name: String) -> MemoryContext? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let context = MemoryContext(name: trimmed)
        cache.append(context)
        rewriteAll()
        return context
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].name = trimmed
        rewriteAll()
    }

    /// Set a context's injection rule (Every scenario vs Chat-only).
    func setInjection(id: UUID, _ injection: MemoryInjectionScope) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].injection = injection
        rewriteAll()
    }

    /// Set (or clear) a context's user-written description. Empty/whitespace
    /// clears it back to nil.
    func setNote(id: UUID, _ note: String) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[idx].note = trimmed.isEmpty ? nil : trimmed
        rewriteAll()
    }

    /// Wholesale replace every context with the supplied list,
    /// preserving the original UUIDs. Used by the Backup import
    /// path; ID preservation matters because learned memories
    /// reference contexts by UUID. Without this, restoring a
    /// backup would orphan every context-scoped memory.
    func replaceAll(with contexts: [MemoryContext]) {
        cache = contexts
        rewriteAll()
    }

    /// Remove a context. Does not touch the memories that pointed at
    /// it — they remain in the store with their scope intact, which
    /// effectively orphans them (`contextBlock` skips memories whose
    /// context no longer exists). Callers may opt to reassign or
    /// delete those memories separately if they want a clean break.
    func delete(id: UUID) {
        let before = cache.count
        cache.removeAll { $0.id == id }
        if cache.count != before { rewriteAll() }
        // Clear active pointer if it referenced the deleted context.
        if activeContextID == id { activeContextID = nil }
    }

    private func rewriteAll() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = cache
        let fileURL = self.fileURL
        writeQueue.async {
            var blob = Data()
            for ctx in snapshot {
                if let data = try? encoder.encode(ctx) {
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
            .compactMap { line -> MemoryContext? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(MemoryContext.self, from: Data(line))
            }
    }
}
