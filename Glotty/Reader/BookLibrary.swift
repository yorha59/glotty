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

/// One message in a saved reader chat.
struct SavedMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    let role: String        // "user" | "assistant"
    let text: String
    /// Where in the book a quoted passage came from, so the chat can jump back
    /// to it. `chapter`/`page` mirror the reader's position (EPUB chapter+page,
    /// or a PDF page in `page`). Optional so threads saved before this decode.
    var srcChapter: Int?
    var srcPage: Int?
    var srcText: String?
}

/// A saved chat thread about a book (from the reader's chat panel).
struct SavedDialogue: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var context: String?
    var messages: [SavedMessage]
    /// Derived context only; the original transcript remains in `messages`.
    var memory: String?
    var memoryMessageCount: Int?
}

/// A book the user has opened, plus everything recorded about it. `dialogues`
/// is optional so records written before it existed still decode.
struct BookRecord: Codable, Identifiable {
    var id: String { bookID }
    let bookID: String
    var title: String
    var path: String?
    var lastOpened: Date
    var queries: [QueryRecord] = []
    var dialogues: [SavedDialogue]?
    /// Reading position — chapter index for EPUB, page index for PDF (both
    /// 0-based), and the total to measure it against (chapter count / page
    /// count). Optional so records written before this existed still decode.
    var currentPosition: Int?
    var totalPositions: Int?

    var dialogueList: [SavedDialogue] { dialogues ?? [] }
}

/// On-disk library: one JSON file per book under Application Support, so both
/// the menu-bar Glotty and the standalone Reader can share it. Keyed by a hash
/// of the book id (ids can contain path-unsafe characters).
@MainActor
enum BookLibrary {
    /// Redirected wholesale by ReaderStore so a self-test never writes into
    /// the real library.
    private static var dir: URL { ReaderStore.libraryDirectory }

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
        try? data.write(to: fileURL(rec.bookID), options: .atomic)
    }

    /// Own a copy before registering a PDF. Never overwrite a different book
    /// with the same filename, and keep existing filename-based identities.
    static func importPDF(_ source: URL) throws -> URL {
        let folder = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = source.standardizedFileURL
        if source.deletingLastPathComponent() == folder.standardizedFileURL { return source }
        var target = folder.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            if FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) { return target }
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent
                + "-" + hash + ".pdf")
        }
        if !FileManager.default.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            try data.write(to: target, options: .atomic)
        } else if !FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        return target
    }

    /// Reject late extraction results after a thread was edited or deleted.
    static func saveMemory(bookID: String, dialogue: SavedDialogue, memory: String) {
        guard var rec = load(bookID),
              let i = rec.dialogues?.firstIndex(where: { $0.id == dialogue.id }),
              rec.dialogues?[i].messages == dialogue.messages else { return }
        rec.dialogues?[i].memory = String(memory.prefix(2400))
        rec.dialogues?[i].memoryMessageCount = dialogue.messages.count
        save(rec)
    }

    /// Same-document context first, then recent conversations in other books.
    /// Unsummarized/failed extractions still contribute a bounded transcript.
    static func memoryContext(bookID: String?, excluding threadID: UUID) -> String {
        let records = all().sorted {
            if ($0.bookID == bookID) != ($1.bookID == bookID) { return $0.bookID == bookID }
            return $0.lastOpened > $1.lastOpened
        }
        var result = ""
        for record in records {
            for dialogue in record.dialogueList.sorted(by: { $0.date > $1.date }) where dialogue.id != threadID {
                let recent = dialogue.messages.dropFirst(dialogue.memoryMessageCount ?? 0).suffix(6)
                    .map { $0.role + ": " + String($0.text.prefix(800)) }.joined(separator: "\n")
                let text = [dialogue.memory, recent].compactMap { $0 }.joined(separator: "\n")
                let entry = "Document: \(record.title)\nSession: \(dialogue.title)\n\(text)\n\n"
                result += String(entry.prefix(min(2800, 12000 - result.count)))
                if result.count >= 12000 { return result }
            }
        }
        return result
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

    /// Upsert a chat thread into a book's saved dialogues (by dialogue id).
    static func saveDialogue(bookID: String, title: String, path: String?, _ dialogue: SavedDialogue) {
        guard !dialogue.messages.isEmpty else { return }
        var rec = load(bookID) ?? BookRecord(bookID: bookID, title: title, path: path, lastOpened: Date())
        rec.title = title
        rec.path = path
        var list = rec.dialogues ?? []
        if let i = list.firstIndex(where: { $0.id == dialogue.id }) {
            var updated = dialogue
            updated.memory = list[i].memory
            updated.memoryMessageCount = list[i].memoryMessageCount
            list[i] = updated
        }
        else { list.append(dialogue) }
        rec.dialogues = list
        save(rec)
    }

    /// Every saved conversation for a book, newest first.
    static func dialogues(bookID: String) -> [SavedDialogue] {
        (load(bookID)?.dialogues ?? []).sorted { $0.date > $1.date }
    }

    static func deleteDialogue(bookID: String, id: UUID) {
        guard var rec = load(bookID) else { return }
        rec.dialogues = (rec.dialogues ?? []).filter { $0.id != id }
        save(rec)
    }

    /// Rename a conversation. Titles are auto-derived from the first question,
    /// which is often a poor label for a thread that wandered.
    static func renameDialogue(bookID: String, id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var rec = load(bookID) else { return }
        var list = rec.dialogues ?? []
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].title = title
        rec.dialogues = list
        save(rec)
    }

    /// The most recent record for a term (for the click-preview).
    static func record(bookID: String, term: String) -> QueryRecord? {
        load(bookID)?.queries
            .filter { $0.term == term }
            .max(by: { $0.date < $1.date })
    }

    /// Keep the Library's stored reading position current. Fired on open and
    /// on every page/chapter turn — does not touch `lastOpened`, which is
    /// `touch()`'s job (once per open, not once per page).
    static func updateProgress(bookID: String, current: Int, total: Int) {
        guard var rec = load(bookID) else { return }
        // Clamp rather than trust the caller: a position past the end is
        // nonsense to show ("Page 194 of 41") and has happened for real when a
        // stale page index outlived a document swap. Clamping here also
        // repairs an already-corrupted record on the next write.
        rec.currentPosition = max(0, min(current, max(0, total - 1)))
        rec.totalPositions = max(0, total)
        save(rec)
    }

    /// Remove a book's record entirely — its look-ups, saved dialogues, and
    /// reading position. Does not touch the book file itself.
    static func delete(bookID: String) {
        try? FileManager.default.removeItem(at: fileURL(bookID))
    }

    /// PDFs were briefly registered under their bare filename while look-ups
    /// and chat threads used the `pdf:` namespace, so a single file could show
    /// up as two rows in the Library — one holding the reading position, the
    /// other the look-ups. Fold the stray record into the namespaced one and
    /// delete it. No-op once a file has been migrated.
    static func mergeLegacyPDFRecord(filename: String, into canonicalID: String) {
        guard filename != canonicalID, let legacy = load(filename) else { return }
        var target = load(canonicalID)
            ?? BookRecord(bookID: canonicalID, title: legacy.title,
                          path: legacy.path, lastOpened: legacy.lastOpened)
        // Prefer whichever record actually has each piece: the split meant one
        // side got the progress and the other the queries.
        if target.path == nil { target.path = legacy.path }
        target.lastOpened = max(target.lastOpened, legacy.lastOpened)
        if target.currentPosition == nil {
            target.currentPosition = legacy.currentPosition
            target.totalPositions = legacy.totalPositions
        }
        for q in legacy.queries where !target.queries.contains(where: { $0.term == q.term && $0.kind == q.kind }) {
            target.queries.append(q)
        }
        var dialogues = target.dialogues ?? []
        for d in legacy.dialogueList where !dialogues.contains(where: { $0.id == d.id }) {
            dialogues.append(d)
        }
        if !dialogues.isEmpty { target.dialogues = dialogues }
        save(target)
        delete(bookID: filename)
    }
}
