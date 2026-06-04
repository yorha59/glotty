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

    /// No-op by design. Glotty does NOT auto-translate the UI in the
    /// background — that behavior caused two problems:
    ///
    ///   1. It fired LLM calls before the user had even finished LLM
    ///      setup. With no provider configured the calls just failed,
    ///      over and over.
    ///   2. Worse, each (failed) attempt posted `didUpdateNotification`,
    ///      which rebuilds every `.localizationAware()` view — and a
    ///      SwiftUI rebuild destroys + recreates the focused TextField.
    ///      With no API key the retry loop ran ~every 0.7s, so the
    ///      field was wiped mid-keystroke and the user couldn't type
    ///      ANYTHING — including the API key that would have stopped
    ///      the loop. A catch-22. (Diagnosed from a user's logs,
    ///      2026-06-04: filler failing every ~0.7s, displayName focus
    ///      flapping, no keystrokes landing.)
    ///
    /// LLM-backed UI translation is now exclusively user-triggered via
    /// Settings → System → Refresh translations (and the language
    /// switch flow), both of which call `LocalizationFiller.fill`
    /// directly and post the update notification themselves. Bundled
    /// `.lproj` translations still apply automatically with zero LLM
    /// work — Foundation resolves e.g. `zh-Hans-CN` to the shipped
    /// `zh-Hans` catalog. Strings the bundle doesn't cover stay in the
    /// source language until the user runs a refresh.
    ///
    /// The signature is kept (rather than deleting call sites) so the
    /// swizzle / OSLocalizer can keep calling it harmlessly; the
    /// `recordEncountered` call they make separately is what feeds the
    /// Refresh button's source list.
    func queueMissingForTranslation(_ source: String, language: String) {
        // Intentionally empty — see doc comment. No automatic fills.
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
