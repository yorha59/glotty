import AppKit
import SwiftUI

/// AppKit-hosted Settings window. SwiftUI's `Settings` scene doesn't surface reliably
/// when invoked from an `NSStatusItem` menu in a Dock-icon-but-no-main-window app,
/// so we manage the window ourselves — same pattern as `PermissionsWindowController`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: SettingsView())
        let w = NSWindow(contentViewController: host)
        w.title = "Glotty Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 460, height: 320))
        w.center()
        w.collectionBehavior = [.moveToActiveSpace]

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}
