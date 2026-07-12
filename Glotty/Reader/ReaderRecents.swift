import Foundation

/// Recently-opened books/PDFs for the "Read a book…" menu. Stores standardized
/// file paths, most-recent-first, and drops entries whose file no longer exists.
enum ReaderRecents {
    private static let key = "glotty.reader.recents"
    private static let maxCount = 12

    static func all() -> [URL] {
        let paths = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func record(_ url: URL) {
        let p = url.standardizedFileURL.path
        var paths = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        paths.removeAll { $0 == p }
        paths.insert(p, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
