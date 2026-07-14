import Foundation
import CryptoKit

/// One recorded look-up in a book: the term, what kind of query, and the answer
/// we got back, so the click-preview can show the saved content.
struct QueryRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let term: String
    let kind: String        // "explain" | "translate"
    var result: String
    var chapter: Int?
    var date: Date
}

/// A book the user has opened, plus everything recorded about it. Saved
/// dialogues are added in a later phase.
struct BookRecord: Codable, Identifiable {
    var id: String { bookID }
    let bookID: String
    var title: String
    var path: String?
    var lastOpened: Date
    var queries: [QueryRecord] = []
}

/// On-disk library: one JSON file per book under Application Support, so both
/// the menu-bar Glotty and the standalone Reader can share it. Keyed by a hash
/// of the book id (ids can contain path-unsafe characters).
@MainActor
enum BookLibrary {
    private static var dir: URL {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("Glotty/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fileURL(_ bookID: String) -> URL {
        let hash = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hash + ".json")
    }

    static func load(_ bookID: String) -> BookRecord? {
        guard let data = try? Data(contentsOf: fileURL(bookID)) else { return nil }
        return try? JSONDecoder().decode(BookRecord.self, from: data)
    }

    static func save(_ rec: BookRecord) {
        guard let data = try? JSONEncoder().encode(rec) else { return }
        try? data.write(to: fileURL(rec.bookID))
    }

    /// All books, most-recently-opened first — for the Library view.
    static func all() -> [BookRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(BookRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Register / refresh a book when it's opened.
    static func touch(bookID: String, title: String, path: String?) {
        var rec = load(bookID) ?? BookRecord(bookID: bookID, title: title, path: path, lastOpened: Date())
        rec.title = title
        rec.path = path
        rec.lastOpened = Date()
        save(rec)
    }

    /// Record a look-up + its result. Re-querying the same term/kind updates the
    /// stored result instead of duplicating.
    static func addQuery(bookID: String, title: String, path: String?,
                         term: String, kind: String, result: String, chapter: Int?) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !result.isEmpty else { return }
        var rec = load(bookID) ?? BookRecord(bookID: bookID, title: title, path: path, lastOpened: Date())
        rec.title = title
        rec.path = path
        rec.lastOpened = Date()
        if let i = rec.queries.firstIndex(where: { $0.term == term && $0.kind == kind }) {
            rec.queries[i].result = result
            rec.queries[i].date = Date()
            rec.queries[i].chapter = chapter
        } else {
            rec.queries.append(QueryRecord(term: term, kind: kind, result: result, chapter: chapter, date: Date()))
        }
        save(rec)
    }

    /// The most recent record for a term (for the click-preview).
    static func record(bookID: String, term: String) -> QueryRecord? {
        load(bookID)?.queries
            .filter { $0.term == term }
            .max(by: { $0.date < $1.date })
    }
}
