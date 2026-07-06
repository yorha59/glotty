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
}
