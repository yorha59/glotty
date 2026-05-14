import AppKit
import SwiftUI

/// AppKit-hosted Settings window. SwiftUI's `Settings` scene doesn't surface reliably
/// when invoked from an `NSStatusItem` menu in a Dock-icon-but-no-main-window app,
/// so we manage the window ourselves — same pattern as `PermissionsWindowController`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferredContentWidth: CGFloat = 560
    private let minimumContentSize = NSSize(width: 520, height: 420)

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
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(initialContentSize(for: host))
        w.minSize = minimumWindowSize(for: w)
        w.center()
        w.collectionBehavior = [.moveToActiveSpace]

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func initialContentSize(for host: NSHostingController<SettingsView>) -> NSSize {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxContentHeight = max(minimumContentSize.height, screenHeight - 96)
        let proposed = NSSize(width: preferredContentWidth, height: maxContentHeight)
        let fitting = host.sizeThatFits(in: proposed)

        return NSSize(
            width: max(minimumContentSize.width, preferredContentWidth),
            height: min(max(fitting.height, minimumContentSize.height), maxContentHeight)
        )
    }

    private func minimumWindowSize(for window: NSWindow) -> NSSize {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize))
        return frame.size
    }
}
