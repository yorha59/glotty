import Foundation

/// Which window the app should land on. Pure decision, separate from the
/// AppKit plumbing, so it can be checked headlessly — the routing is easy to
/// get subtly wrong (a file opened from Finder must not get the start page
/// shoved in front of it) and testing it by launching windows is exactly what
/// the headless mode exists to avoid.
enum ReaderStartPage: Equatable {
    case library
    case reader

    /// Launch. `openedDocument` is true when the launch was "open this file"
    /// — `application(_:open:)` runs *before* `applicationDidFinishLaunching`,
    /// so by the time the start page is decided the book is already loading.
    static func forLaunch(openedDocument: Bool) -> ReaderStartPage {
        openedDocument ? .reader : .library
    }

    /// Dock icon clicked with no windows: back to whatever was being read,
    /// falling back to the shelf.
    static func forReopen(hasOpenBook: Bool) -> ReaderStartPage {
        hasOpenBook ? .reader : .library
    }
}
