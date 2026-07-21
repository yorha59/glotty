import Foundation

/// Where the reader keeps its state: preferences (reading position, bookmarks,
/// marks, recents, PDF translations) and the on-disk book library.
///
/// Everything in `Reader/` goes through here rather than touching
/// `UserDefaults.standard` and Application Support directly, so a headless
/// self-test can redirect the whole lot into a throwaway sandbox. Tests that
/// share the real store are worse than no tests: exercising "open a book",
/// "bookmark a page" or "delete a record" against live data silently rewrites
/// the user's reading position and can destroy their library.
enum ReaderStore {
    /// Set once, before anything reads state. `nil` means the real store.
    private static var sandbox: (defaults: UserDefaults, library: URL)?

    static var defaults: UserDefaults { sandbox?.defaults ?? .standard }

    static var libraryDirectory: URL {
        let base = sandbox?.library
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()))
                .appendingPathComponent("Glotty/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// True when running against a throwaway store — the self-test asserts this
    /// before it writes anything, so a wiring mistake can't quietly point
    /// destructive checks at the real library.
    static var isSandboxed: Bool { sandbox != nil }

    /// Redirect all reader state into a temp directory + private defaults
    /// suite. Returns the directory so a caller can clean it up.
    @discardableResult
    static func useSandbox() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlottyReaderSelfTest-\(UUID().uuidString)", isDirectory: true)
        let suite = "com.ruojunye.glotty.reader.selftest.\(UUID().uuidString)"
        // A fresh suite name has no persisted contents, so this starts empty
        // and `removeSuite` at teardown leaves nothing behind.
        let d = UserDefaults(suiteName: suite) ?? .standard
        sandbox = (d, root.appendingPathComponent("Library", isDirectory: true))
        return root
    }

    static func tearDownSandbox(_ root: URL, suiteName: String? = nil) {
        try? FileManager.default.removeItem(at: root)
        sandbox = nil
    }
}
