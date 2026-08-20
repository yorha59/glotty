import AppKit
import SwiftUI

/// Hosts the Library in a standard window. Rebuilds its content on every show
/// so the book list + query counts stay current.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = LibraryWindowController()
    /// Readable so sheets (the file picker) can hang off the Library window.
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = String(localized: "Glotty Library")
            w.contentMinSize = NSSize(width: 1050, height: 650)
            w.setFrameAutosaveName("GlottyLibraryWindow")
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: LibraryView())
        if let w = window, let screen = w.screen ?? NSScreen.main,
           !screen.visibleFrame.contains(w.frame) {
            w.setFrame(w.constrainFrameRect(w.frame, to: screen), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
