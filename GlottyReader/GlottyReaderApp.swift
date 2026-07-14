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
        ReaderCore.services = IPCReaderServices()
        NSApp.setActivationPolicy(.regular)
        ReaderWindowController.shared.show()
    }

    /// Finder "Open With → Glotty Reader" / double-click / drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let doc = urls.first(where: { ["epub", "pdf"].contains($0.pathExtension.lowercased()) })
        else { return }
        ReaderWindowController.shared.open(url: doc)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Re-open the reader window when the Dock icon is clicked with no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ReaderWindowController.shared.show() }
        return true
    }
}
