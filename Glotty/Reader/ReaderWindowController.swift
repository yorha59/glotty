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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub, .pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose an EPUB or PDF")
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.state.open(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
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
