import Foundation

/// Shadow translation cache. Persists every LLM-produced UI
/// translation to a JSON file in Application Support so we don't
/// re-translate on every launch and can ship them across machines
/// via Backup. Lookup is keyed by `(language, sourceString)`.
///
/// The cache layers OVER the bundled `.xcstrings` catalog — at
/// runtime we check the cache first (in the `Bundle.localizedString`
/// swizzle below); the bundled catalog only handles strings the LLM
/// hasn't filled yet.
@MainActor
final class LocalizationCache {
    static let shared = LocalizationCache()

    /// Posted after a batch of on-demand translations lands in the
    /// cache. UI roots observe this to bump a refresh counter so
    /// views rendering English-fallback text re-resolve through
    /// the now-populated cache.
    static let didUpdateNotification = Notification.Name("glotty.localizationCache.didUpdate")

    /// JSON file shape: `[ language: [ source: translation ] ]`.
    /// `language` is a BCP-47 locale identifier ("zh-Hans" etc.).
    private var store: [String: [String: String]] = [:]
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.ruojunye.glotty.localization-cache", qos: .utility)

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
            self.fileURL = glottyDir.appendingPathComponent("ui-translations.json")
        }
        load()
        loadEncountered()
    }

    /// Synchronous lookup. Returns nil when the cache has no
    /// translation for this key in this language — caller falls
    /// back to the bundled catalog (or the literal English source).
    func translation(for source: String, language: String) -> String? {
        store[language]?[source]
    }

    /// Write one translation. Persists to disk asynchronously so
    /// the LLM filler can churn through hundreds of strings without
    /// blocking.
    func set(translation: String, for source: String, language: String) {
        store[language, default: [:]][source] = translation
        scheduleWrite()
    }

    /// Bulk set used by the LLM filler — fewer disk writes than
    /// looping over `set(translation:for:language:)`.
    func merge(_ translations: [String: String], language: String) {
        var lang = store[language] ?? [:]
        for (k, v) in translations { lang[k] = v }
        store[language] = lang
        scheduleWrite()
    }

    /// All cached source strings the LLM has already translated to
    /// this language. Used by the filler to skip work — and by the
    /// pre-warmer to know what's already covered.
    func translatedSources(for language: String) -> Set<String> {
        Set(store[language]?.keys ?? [:].keys)
    }

    /// Every English source string the running app has ever asked
    /// `Bundle.localizedString` for — recorded by the swizzle. Used
    /// by the LLM filler as the "what does this app need translated"
    /// set so dynamic strings (and strings missing from the bundled
    /// catalog) get covered automatically once they've been seen
    /// at least once.
    private(set) var encounteredSources: Set<String> = []
    private let encounteredFile: URL? = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("Glotty/ui-encountered-strings.json", isDirectory: false)
    }()

    /// Note that a source string was just requested. Called from
    /// the Bundle.localizedString swizzle on every lookup. Cheap
    /// (Set.insert is O(1) on average); persisted lazily via
    /// `scheduleEncounteredWrite`.
    func recordEncountered(_ source: String) {
        guard !source.isEmpty else { return }
        let (inserted, _) = encounteredSources.insert(source)
        if inserted { scheduleEncounteredWrite() }
    }

    // MARK: - On-demand translation

    /// Source strings the swizzle has hit a cache miss on and
    /// queued for LLM translation. Drained by `runPendingFillSoon`.
    private var pendingForFill: Set<String> = []
    private var pendingFillTask: Task<Void, Never>?

    /// Queue a missing source string for on-demand LLM translation
    /// in the given language. Debounced — multiple cache misses in
    /// the same render pass (common when a new view appears) are
    /// collected and sent in one LLM batch, then the cache update
    /// notification fires and views re-render.
    func queueMissingForTranslation(_ source: String, language: String) {
        guard !source.isEmpty else { return }
        guard language != "en", !language.hasPrefix("en-") else { return }
        // Already cached — nothing to do.
        if store[language]?[source] != nil { return }
        // Already queued — don't re-add.
        if pendingForFill.contains(source) { return }
        pendingForFill.insert(source)
        scheduleFillRun(for: language)
    }

    private func scheduleFillRun(for language: String) {
        if pendingFillTask != nil { return }
        pendingFillTask = Task { @MainActor in
            // Debounce so a render pass that touches dozens of new
            // strings ends up in a single LLM call.
            try? await Task.sleep(nanoseconds: 600_000_000)
            let batch = Array(self.pendingForFill)
            self.pendingForFill.removeAll()
            self.pendingFillTask = nil
            guard !batch.isEmpty else { return }
            _ = await LocalizationFiller.fill(
                sources: batch,
                targetLanguage: language
            )
            // Tell observers (root views) that fresh translations
            // are available so they can force a re-render and the
            // English-fallback strings flip to the new language.
            NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
        }
    }

    private var pendingEncounteredWrite = false
    private func scheduleEncounteredWrite() {
        guard !pendingEncounteredWrite else { return }
        pendingEncounteredWrite = true
        // Debounce — strings stream in quickly during view rendering;
        // one batched write per 2 seconds is fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.pendingEncounteredWrite = false
            self.writeEncountered()
        }
    }

    private func writeEncountered() {
        guard let url = encounteredFile else { return }
        let snapshot = encounteredSources
        writeQueue.async {
            let data = try? JSONEncoder().encode(Array(snapshot).sorted())
            try? data?.write(to: url, options: .atomic)
        }
    }

    private func loadEncountered() {
        guard let url = encounteredFile,
              let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return }
        encounteredSources = Set(arr)
    }

    /// Clear cached translations for one language (e.g. user wants
    /// fresh LLM output). Other languages untouched.
    func clear(language: String) {
        store[language] = nil
        scheduleWrite()
    }

    private func scheduleWrite() {
        let snapshot = store
        let url = fileURL
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        store = (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    var storageURL: URL { fileURL }
}
