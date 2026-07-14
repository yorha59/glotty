import AppKit
import SwiftUI

/// Hosts the Library in a standard window. Rebuilds its content on every show
/// so the book list + query counts stay current.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = LibraryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = String(localized: "Glotty Library")
            w.center()
            w.setFrameAutosaveName("GlottyLibraryWindow")
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: LibraryView())
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
