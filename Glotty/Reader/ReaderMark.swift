import Foundation

/// Bridges a reader word-tap to the lookup popup's optional "Mark" button.
///
/// Tapping a word in the EPUB reader opens the shared popup for meaning only — it
/// no longer auto-underlines (that flooded the page). The reader sets `pending`
/// to the tapped word before opening the popup; the popup shows a Mark button
/// only when its source text matches, and pressing it underlines the word in the
/// reader. So a word is marked only when the user deliberately chooses to.
@MainActor
enum ReaderMark {
    static var pending: String?

    /// Context for capturing a reader look-up into the library and underlining
    /// it. The reader sets this before firing the popup; the popup consumes it
    /// when the result finalizes (`term` must match the popup's source text).
    struct Capture {
        let bookID: String
        let title: String
        let path: String?
        let term: String
        let kind: String        // "explain" | "translate"
        let chapter: Int?
    }
    static var capture: Capture?
}

extension ReaderMark.Capture {
    /// Encode for a distributed-notification userInfo (all string values).
    var userInfo: [String: String] {
        var d = ["bookID": bookID, "title": title, "term": term, "kind": kind]
        if let path { d["path"] = path }
        if let chapter { d["chapter"] = String(chapter) }
        return d
    }
    init?(userInfo d: [AnyHashable: Any]) {
        guard let bookID = d["bookID"] as? String, let title = d["title"] as? String,
              let term = d["term"] as? String, let kind = d["kind"] as? String else { return nil }
        self.init(bookID: bookID, title: title, path: d["path"] as? String,
                  term: term, kind: kind, chapter: (d["chapter"] as? String).flatMap { Int($0) })
    }
}
