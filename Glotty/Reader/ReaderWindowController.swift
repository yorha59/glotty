import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the EPUB reader in a standard resizable window (Glotty is otherwise an
/// agent with only panels). One shared window + state; reopening brings it
/// forward rather than spawning duplicates.
@MainActor
final class ReaderWindowController: NSObject, NSWindowDelegate {
    static let shared = ReaderWindowController()
    let state = ReaderState()
    private var window: NSWindow?

    func show() {
        ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open a specific EPUB (Finder "Open With", a dropped file, etc.).
    func open(url: URL) {
        show()
        state.open(url)
    }

    /// Bring up the reader and prompt for an `.epub` to open.
    func openBook() {
        show()
        chooseBook(over: window)
    }

    /// File picker that opens straight into the reader. Presented from
    /// whichever window asked, so the Library can offer it without the empty
    /// reader flashing up first.
    func chooseBook(over host: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub, .pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose an EPUB or PDF")
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }

    /// Closing the reader (traffic light or ⌘W) returns to the Library instead
    /// of quitting — Books-style: the book you were reading is the thing that
    /// closes, not the app. Bringing the Library window up before the reader
    /// actually closes means it's never the *last* window, so AppKit's
    /// applicationShouldTerminateAfterLastWindowClosed never fires for this.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        LibraryWindowController.shared.show()
        return true
    }

    private func ensureWindow() {
        if window != nil { return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = String(localized: "Glotty Reader")
        w.center()
        // Enable the green button → Full Screen (immersive reading). Without a
        // fullscreen collection behavior an agent app's green button is a no-op;
        // ⌥-click still zooms. Managed so it appears in Mission Control.
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        w.setFrameAutosaveName("GlottyReaderWindow")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: ReaderView(state: state))
        window = w
    }
}
