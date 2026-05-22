import AppKit
import SwiftUI

/// AppKit-hosted Settings window. SwiftUI's `Settings` scene doesn't surface reliably
/// when invoked from an `NSStatusItem` menu in a Dock-icon-but-no-main-window app,
/// so we manage the window ourselves — same pattern as `PermissionsWindowController`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    // Sidebar + detail layout needs more room than the old top-tab TabView.
    private let preferredContentWidth: CGFloat = 780
    private let minimumContentSize = NSSize(width: 720, height: 480)

    func show() {
        show(selecting: nil)
    }

    /// Open Settings with a specific tab pre-selected. Used by the
    /// first-launch permissions flow to land the user on the Permissions
    /// pane directly. Passing `nil` preserves whatever tab was last shown
    /// (or `.profile` on first open).
    func show(selecting tab: SettingsTab?) {
        // If a specific tab is requested, rebuild the window so the initial
        // @State of SettingsView picks it up. SwiftUI's @State only honors
        // its default on first construction, so we can't update an already-
        // running view's selection from out here without a binding.
        if let tab, window != nil {
            window?.orderOut(nil)
            window = nil
        }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let initial = tab ?? .profile
        let host = NSHostingController(rootView: SettingsView(initialTab: initial))
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
