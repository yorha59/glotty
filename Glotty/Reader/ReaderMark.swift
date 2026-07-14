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
