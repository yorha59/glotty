import AppKit
import SwiftUI

/// AppKit-hosted Settings window. SwiftUI's `Settings` scene doesn't surface reliably
/// when invoked from an `NSStatusItem` menu in a Dock-icon-but-no-main-window app,
/// so we manage the window ourselves — same pattern as `PermissionsWindowController`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferredContentWidth: CGFloat = 600
    private let minimumContentSize = NSSize(width: 520, height: 460)

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: SettingsView())
        // NOTE: `host.sizingOptions = .preferredContentSize` crashes when SwiftUI
        // content has unbounded intrinsic size (Forms with TextEditors, long
        // scrolling lists). We pick a sensible initial content size instead and
        // keep the window resizable so the user can adjust.
        let w = NSWindow(contentViewController: host)
        w.title = "Glotty Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(initialContentSize())
        w.contentMinSize = minimumContentSize
        w.center()
        w.collectionBehavior = [.moveToActiveSpace]

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func initialContentSize() -> NSSize {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = min(720, max(minimumContentSize.height, screenHeight - 120))
        return NSSize(width: preferredContentWidth, height: height)
    }
}
