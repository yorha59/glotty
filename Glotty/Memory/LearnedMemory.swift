import Foundation

/// What kind of fact this memory represents. Used to drive how it's
/// presented in Settings (Glossary tab vs Profile vs free-form list)
/// and how aggressively it's injected into prompts (glossary entries
/// are gated by term-match in the source text; others always inject).
enum LearnedMemoryKind: String, Codable, CaseIterable, Sendable {
    /// `term: meaning` mapping (e.g. "polish" → "my LLM rewrite
    /// feature, not the country"). Surfaced as a table, injected only
    /// when `term` appears in the source text being processed.
    case glossary
    /// User-stated preference (e.g. "prefer concise replies").
    case preference
    /// Background fact about the user (e.g. "native Chinese speaker").
    case fact
    /// Project / context the user is working on (e.g. "building
    /// Glotty, a macOS translation utility").
    case project

    /// Short label for the UI badge next to a memory.
    var label: String {
        switch self {
        case .glossary:   return "glossary"
        case .preference: return "preference"
        case .fact:       return "fact"
        case .project:    return "project"
        }
    }
}

/// Review status of a proposed memory. Newly extracted memories land
/// as `.pending`; the user accepts/rejects them in the Settings →
/// Memory → Suggestions section. Only `.accepted` memories are
/// injected into LLM prompts. Rejected memories stay in the store
/// (with `.rejected` status) so the extractor can avoid re-proposing
/// the same item next session. There is no expired/archived state —
/// accepted memories are either kept or hard-deleted.
enum LearnedMemoryStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
}

/// One piece of learned context about the user. Proposed by the
/// post-chat extractor; persisted across sessions; injected into
/// future LLM calls once the user accepts it.
/// When a memory is allowed to be injected into LLM prompts.
///   - `.everywhere` (default): every scenario — Translate, Explain, Polish, Chat.
///   - `.chatOnly`: only the Fn+C tutor chat (and proactive practice). NOT
///     Polish or Explain — including the follow-up chat *inside* those dialogs.
enum MemoryInjectionScope: String, Codable, Sendable {
    case everywhere
    case chatOnly
}

/// The calling context passed to `contextBlock(...)` so it can honor each
/// memory's `injection` rule. Not persisted — derived from which feature is
/// building the prompt. `.chat` is the Fn+C tutor (and proactive practice);
/// everything else (Translate / Explain / Polish / their in-dialog follow-up
/// chat / UI localization) is `.general`.
enum MemoryInjectionPurpose: Sendable {
    case general
    case chat
}

struct LearnedMemory: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let kind: LearnedMemoryKind
    /// Term being defined for `.glossary` entries (e.g. "polish").
    /// nil for the other kinds — they're statements, not mappings.
    let term: String?
    /// The fact itself, one sentence. This is what gets injected
    /// into prompts. For glossary entries the convention is
    /// "<term> means <definition>" so the injected line reads
    /// naturally on its own.
    let content: String
    /// Verbatim quote from the source conversation that triggered
    /// the proposal. Shown in the review UI so the user can verify
    /// the extraction matches their intent. nil for manually-added
    /// memories.
    let sourceQuote: String?
    /// Back-pointer to the `MemoryEvent` (polish or explain) the
    /// extraction was run on. nil for manual entries. Lets the UI
    /// link a memory back to the conversation that produced it.
    let sourceEventID: UUID?
    let proposedAt: Date
    var status: LearnedMemoryStatus
    /// Memory scope — `.global` (always inject) or `.context(uuid)`
    /// (inject only when that context is active). Optional so legacy
    /// entries on disk without this field decode cleanly; read via
    /// `effectiveScope` so callers don't have to nil-check.
    var scope: MemoryScope?
    /// BCP-47 language code this memory is *about* (e.g. "en", "zh-Hans").
    /// Drives the language-aware filter in `contextBlock(for:targetLanguage:)`
    /// so a glossary entry like "Polish means the feature, not the country"
    /// — which is a statement about ENGLISH usage — doesn't leak into the
    /// translation prompt that's producing Chinese / Japanese / etc. UI
    /// strings.
    ///
    /// `nil` ⇒ "applies regardless of language" (legacy entries on disk
    /// without this field decode this way, preserving today's behavior).
    /// Set by `MemoryExtractor` from the chat's effective language when
    /// a new memory is recorded.
    var sourceLanguage: String?

    init(
        id: UUID = UUID(),
        kind: LearnedMemoryKind,
        term: String? = nil,
        content: String,
        sourceQuote: String? = nil,
        sourceEventID: UUID? = nil,
        proposedAt: Date = Date(),
        status: LearnedMemoryStatus = .pending,
        scope: MemoryScope? = nil,
        sourceLanguage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.term = term
        self.content = content
        self.sourceQuote = sourceQuote
        self.sourceEventID = sourceEventID
        self.proposedAt = proposedAt
        self.status = status
        self.scope = scope
        self.sourceLanguage = sourceLanguage
    }

    /// Resolved scope — pre-context legacy entries (no `scope` field
    /// on disk) decode as nil and behave as `.global`, so existing
    /// memories keep injecting as they always did.
    var effectiveScope: MemoryScope { scope ?? .global }
}

/// Persistent store for learned memories. Mirrors `MemoryStore`'s
/// JSONL-in-Application-Support pattern so the file is human-readable
/// and easy to back up / inspect / hand-edit during dev.
///
/// New memories append; status changes (accept/reject/edit) rewrite
/// the full file. At Glotty's expected scale (dozens to a few hundred
/// memories), full rewrites are cheap.
@MainActor
final class LearnedMemoryStore {
    static let shared = LearnedMemoryStore()

    /// Posted after any mutation (add / accept / reject / delete /
    /// clearAll / edit). Settings UI and in-chat suggestion cards
    /// subscribe so they refresh automatically when the background
    /// extractor writes new proposals — no manual interaction
    /// required.
    static let didChangeNotification = Notification.Name("glotty.learnedMemory.didChange")

    private let fileURL: URL
    private var cache: [LearnedMemory] = []
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.learned-memory", qos: .utility)

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
            self.fileURL = glottyDir.appendingPathComponent("learned-memory.jsonl")
        }
        loadCache()
    }

    var storageURL: URL { fileURL }

    /// Every memory regardless of status, oldest-proposed first.
    func allMemories() -> [LearnedMemory] { cache }

    /// Pending review queue. Newest proposals first so they're easy
    /// to act on in the UI.
    func pending() -> [LearnedMemory] {
        cache.filter { $0.status == .pending }.sorted { $0.proposedAt > $1.proposedAt }
    }

    /// Accepted memories — these get injected into LLM prompts via
    /// `contextBlock(for:)`. Order matches acceptance for now; if it
    /// becomes useful later we can sort by kind / freshness.
    func accepted() -> [LearnedMemory] {
        cache.filter { $0.status == .accepted }
    }

    /// Rejected memories. Kept so the extractor can avoid re-proposing
    /// the same item — passed to the extraction prompt as the
    /// "do-not-suggest" list alongside accepted ones.
    func rejected() -> [LearnedMemory] {
        cache.filter { $0.status == .rejected }
    }

    /// Add one or more freshly-extracted proposals. Filters out
    /// duplicates of anything already in the store (same kind +
    /// case-insensitive content match) so re-running the extractor
    /// on a chat we've already processed is a no-op.
    func add(_ proposals: [LearnedMemory]) {
        guard !proposals.isEmpty else { return }
        let existing = Set(cache.map { canonical($0) })
        let fresh = proposals.filter { !existing.contains(canonical($0)) }
        guard !fresh.isEmpty else { return }
        cache.append(contentsOf: fresh)
        appendToFile(fresh)
        notifyChange()
    }

    /// Accept a pending memory with the given scope. Same call also
    /// re-scopes an already-accepted memory, so the Settings UI can
    /// move a memory between Global and contexts after the fact via
    /// a single API.
    func accept(id: UUID, scope: MemoryScope = .global) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].status = .accepted
        cache[idx].scope = scope
        rewriteAll()
        notifyChange()
    }

    /// Flip a pending memory to rejected. The memory stays in the
    /// store so the extractor avoids re-proposing it.
    func reject(id: UUID) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        guard cache[idx].status != .rejected else { return }
        cache[idx].status = .rejected
        rewriteAll()
        notifyChange()
    }

    /// Clear every pending memory at once. Backs the "Dismiss all"
    /// button on the Settings Suggestions list — useful when the
    /// queue has piled up with proposals the user doesn't want to
    /// page through. Unlike individual `reject(id:)`, this *hard
    /// deletes* the memories rather than marking them rejected, so
    /// the extractor can re-propose similar items from future chats.
    /// (Bulk-rejecting and then never seeing related suggestions
    /// again was unintuitive — "dismiss this batch" is not the same
    /// signal as "never show me this exact thing again".)
    func dismissAllPending() {
        let before = cache.count
        cache.removeAll { $0.status == .pending }
        if cache.count != before {
            rewriteAll()
            notifyChange()
        }
    }

    /// Pending suggestions tied to a specific source event (the
    /// polish or explain run that produced them). Used by the popup
    /// chat to render suggestion cards inline when the user reopens
    /// the conversation that triggered them.
    func pending(forEventID eventID: UUID?) -> [LearnedMemory] {
        guard let eventID else { return [] }
        return cache.filter { $0.status == .pending && $0.sourceEventID == eventID }
    }

    /// Permanently remove a memory. Used by the Settings UI's
    /// trash button for accepted entries the user no longer wants.
    func delete(id: UUID) {
        let before = cache.count
        cache.removeAll { $0.id == id }
        if cache.count != before {
            rewriteAll()
            notifyChange()
        }
    }

    /// Update the term/content of an existing memory in place. Lets
    /// the user refine a proposed memory before accepting it without
    /// having to reject + re-add.
    func edit(id: UUID, term: String?, content: String) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        let old = cache[idx]
        cache[idx] = LearnedMemory(
            id: old.id,
            kind: old.kind,
            term: term?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceQuote: old.sourceQuote,
            sourceEventID: old.sourceEventID,
            proposedAt: old.proposedAt,
            status: old.status,
            scope: old.scope,
            sourceLanguage: old.sourceLanguage
        )
        rewriteAll()
        notifyChange()
    }

    /// Wholesale replace every memory with the supplied list,
    /// preserving original UUIDs, statuses, and scopes. Used by
    /// the Backup import path so accept/reject history and
    /// context bindings survive a round-trip.
    func replaceAll(with memories: [LearnedMemory]) {
        cache = memories
        rewriteAll()
        notifyChange()
    }

    /// Wipe everything. Behind a "Clear all memories" button in
    /// Settings; mirrors `MemoryStore.clearAll` for symmetry.
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

    /// UserDefaults key for the freeform "Notes for Glotty" field in
    /// Settings → Profile. Combined into the context block alongside
    /// learned memories so prompt builders have one source of truth.
    static let userNotesKey = "glotty.user.about"

    /// Build the context block prepended to LLM prompts. Combines:
    ///   - The user's freeform "Notes for Glotty" (always included).
    ///   - Accepted global memories (preference/fact/project always
    ///     inject; glossary entries inject only when their `term`
    ///     appears in `sourceText`, case-insensitive substring).
    ///   - Accepted memories scoped to the currently-active context
    ///     (same kind-based gating). Memories scoped to *other*
    ///     contexts are dormant.
    /// Returns an empty string when there's nothing to inject — the
    /// caller can prepend it unconditionally.
    func contextBlock(for sourceText: String,
                      targetLanguage: String? = nil,
                      purpose: MemoryInjectionPurpose = .general) -> String {
        let haystack = sourceText.lowercased()
        let activeID = MemoryContextStore.shared.activeContextID
        let globalRule = MemoryContextStore.shared.globalInjection

        let relevant = accepted().filter { memory in
            // 1. Active-context scoping + the set's injection rule. A set
            //    (Global or a context) marked `.chatOnly` keeps its memories
            //    out of everything except the Fn+C tutor chat (and proactive
            //    practice). Translate / Explain / Polish — including the
            //    follow-up chat inside those dialogs — stay `.general`.
            switch memory.effectiveScope {
            case .global:
                if globalRule == .chatOnly, purpose != .chat { return false }
            case .context(let id):
                if id != activeID { return false }
                let rule = MemoryContextStore.shared.context(id: id)?.effectiveInjection ?? .everywhere
                if rule == .chatOnly, purpose != .chat { return false }
            }
            // 2. Strict language match. Per the user's directive:
            //    "only inject memory when the memory language is the
            //    same as target language." A memory about English
            //    usage doesn't influence Chinese UI translation; a
            //    Chinese-context preference doesn't influence a
            //    Polish-on-English session.
            //
            //    When the caller doesn't pass a `targetLanguage`
            //    (older code paths) we keep the legacy behavior of
            //    including everything — so existing call sites that
            //    haven't been updated yet keep working.
            guard let target = targetLanguage else { return true }
            guard let memLang = memory.sourceLanguage else { return false }
            return Self.languagesMatch(memLang, target)
        }

        var lines: [String] = []
        for memory in relevant {
            switch memory.kind {
            case .glossary:
                guard let term = memory.term?.lowercased(), !term.isEmpty else { continue }
                if haystack.contains(term) {
                    lines.append("- " + memory.content)
                }
            case .preference, .fact, .project:
                lines.append("- " + memory.content)
            }
        }

        let userNotes = (UserDefaults.standard.string(forKey: Self.userNotesKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Active-context header: the context's name (+ short intro) so the LLM
        // knows the domain this exchange is in — even when the context has no
        // memories yet. Respects the context's chat-only rule the same way its
        // memories do (no header in Translate/Explain/Polish for a chat-only set).
        var contextHeader = ""
        if let ctx = activeID.flatMap({ MemoryContextStore.shared.context(id: $0) }) {
            if !(ctx.effectiveInjection == .chatOnly && purpose != .chat) {
                contextHeader = "Active context: \(ctx.name)"
                if let note = ctx.note, !note.isEmpty {
                    contextHeader += " — \(note)"
                }
            }
        }

        if contextHeader.isEmpty && userNotes.isEmpty && lines.isEmpty { return "" }

        var block = ""
        if !contextHeader.isEmpty { block += contextHeader + "\n\n" }
        if !userNotes.isEmpty || !lines.isEmpty {
            block += "About the user:\n"
            if !userNotes.isEmpty { block += userNotes + "\n" }
            if !lines.isEmpty { block += lines.joined(separator: "\n") }
        }
        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    /// True when two BCP-47 codes refer to the same language family
    /// (compares the primary subtag, so `zh-Hans` matches `zh-Hans-CN`
    /// and the bare `zh`, while `en` won't match `zh`). Used by the
    /// memory language filter to be lenient about region/script
    /// suffixes the caller may pass.
    private static func languagesMatch(_ a: String, _ b: String) -> Bool {
        // Compare the first two subtags (`zh-Hans`, `en-US`) so that
        // a script-bearing memory ("zh-Hans") matches a region-extended
        // request ("zh-Hans-CN") but not a different script ("zh-Hant").
        func key(_ s: String) -> String {
            s.lowercased().split(separator: "-").prefix(2).joined(separator: "-")
        }
        return key(a) == key(b)
    }

    /// Canonical key for dedup — same kind + same content (case- and
    /// whitespace-insensitive) collapses into one memory. We also
    /// normalize the term so "Polish" and "polish" don't both land.
    private func canonical(_ memory: LearnedMemory) -> String {
        let term = (memory.term ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let content = memory.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(memory.kind.rawValue)|\(term)|\(content)"
    }

    private func appendToFile(_ newMemories: [LearnedMemory]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileURL = self.fileURL
        writeQueue.async {
            var blob = Data()
            for memory in newMemories {
                if let data = try? encoder.encode(memory) {
                    blob.append(data)
                    blob.append(0x0A)  // '\n'
                }
            }
            guard !blob.isEmpty else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    try? h.seekToEnd()
                    try? h.write(contentsOf: blob)
                    try? h.close()
                }
            } else {
                try? blob.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func rewriteAll() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = cache
        let fileURL = self.fileURL
        writeQueue.async {
            var blob = Data()
            for memory in snapshot {
                if let data = try? encoder.encode(memory) {
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
            .compactMap { line -> LearnedMemory? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(LearnedMemory.self, from: Data(line))
            }
        backfillSourceLanguageIfNeeded()
    }

    /// One-shot migration: every memory persisted before the
    /// `sourceLanguage` field existed was extracted from an
    /// English-language chat — Glotty's first UI language was
    /// English-only. Tag them "en" so the new strict
    /// language-equality filter in `contextBlock(for:targetLanguage:)`
    /// doesn't leak English glossary into Chinese / Japanese / etc.
    /// translation prompts. Idempotent: only runs while at least one
    /// entry still has `sourceLanguage == nil`.
    private func backfillSourceLanguageIfNeeded() {
        guard cache.contains(where: { $0.sourceLanguage == nil }) else { return }
        var changed = false
        cache = cache.map { memory in
            guard memory.sourceLanguage == nil else { return memory }
            var copy = memory
            copy.sourceLanguage = "en"
            changed = true
            return copy
        }
        if changed { rewriteAll() }
    }
}

private extension String {
    /// Returns nil if the string is empty after trimming. Lets call
    /// sites collapse `Optional<String>` and `""` into a single
    /// empty case so glossary entries with blank terms don't get
    /// stored (they'd never match anything anyway).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
