import SwiftUI
import AppKit

/// Standalone Glotty Reader — a regular windowed app that reuses `Reader/` from
/// the Glotty menu-bar app. Reading, TOC, marks, recents and the chat panel are
/// all local; the AI actions (look-up, translate, chat) are served by a running
/// Glotty over IPC via `IPCReaderServices`.
@main
struct GlottyReaderApp: App {
    @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var delegate
    var body: some Scene {
        // The reader lives in an AppKit NSWindow (ReaderWindowController); this
        // Settings scene just satisfies the App protocol.
        Settings { EmptyView() }
    }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless: run the state-layer checks with no window, no Dock icon and
        // no activation, against a throwaway store, then exit. Lets the reader
        // be tested without windows appearing over whatever the user is doing.
        //   .../Glotty Reader --headless [file.pdf …]
        let args = CommandLine.arguments
        if args.contains("--headless") {
            NSApp.setActivationPolicy(.prohibited)   // nothing on screen, no Dock tile
            ReaderCore.services = nil                // never reach out to Glotty over IPC
            let paths = args.dropFirst()
                .filter { !$0.hasPrefix("--") }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            exit(ReaderSelfTest.run(paths: paths))
        }
        ReaderCore.services = IPCReaderServices()
        NSApp.setActivationPolicy(.regular)
        // Start on the shelf, not an empty reader.
        switch ReaderStartPage.forLaunch(openedDocument: openedDocumentAtLaunch) {
        case .reader:  break   // application(_:open:) already opened the book
        case .library: LibraryWindowController.shared.show()
        }
    }

    /// Set when launch was "open this file", so the start page is skipped.
    private var openedDocumentAtLaunch = false

    /// Finder "Open With → Glotty Reader" / double-click / drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let doc = urls.first(where: { ["epub", "pdf"].contains($0.pathExtension.lowercased()) })
        else { return }
        openedDocumentAtLaunch = true
        ReaderWindowController.shared.open(url: doc)
    }

    /// Closing the reader shows the Library, so the reader is never the last
    /// window and this doesn't fire for it. Closing the *Library* is the user
    /// saying they're done — quit then.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Re-open the reader window when the Dock icon is clicked with no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        let s = ReaderWindowController.shared.state
        switch ReaderStartPage.forReopen(hasOpenBook: s.book != nil || s.pdf != nil) {
        case .reader:  ReaderWindowController.shared.show()
        case .library: LibraryWindowController.shared.show()
        }
        return true
    }
}
