import AppKit
import SwiftUI

/// AppKit-hosted Settings window. SwiftUI's `Settings` scene doesn't surface reliably
/// when invoked from an `NSStatusItem` menu in a Dock-icon-but-no-main-window app,
/// so we manage the window ourselves — same pattern as `PermissionsWindowController`.
@MainActor
final class SettingsWindowController {
    /// Process-wide instance. The Settings window is a singleton —
    /// re-opening just brings the existing one forward — so a
    /// shared accessor keeps consumers (menu bar, snapshotter,
    /// debug tools) on the same controller.
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// Exposed for the debug snapshotter — it needs the live
    /// NSWindow to capture pixels from. Read-only.
    var currentWindow: NSWindow? { window }
    /// Token from `AppActivation.register` for the currently-open
    /// window. nil when no window is shown. Released on willClose so
    /// closing Settings drops the app back to `.accessory`.
    private var activationToken: UUID?
    private var closeObserver: NSObjectProtocol?
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
    ///
    /// While Settings is open we hold an `AppActivation` slot, which
    /// promotes the app to `.regular` (Dock icon, ⌘-Tab presence, app
    /// menu). The hotkey paths in `AppDelegate.handleFire` call
    /// `AppActivation.dismissAllRegistered()` before opening a popup, so
    /// the popup always launches in clean agent mode — see
    /// `AppActivation` for the why.
    func show(selecting tab: SettingsTab?) {
        // Tab-rebuild path: tear down the current window cleanly first
        // (releases the activation slot) before creating a new one.
        if let tab, window != nil {
            tearDownWindow()
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
        // `.t` routes through Bundle.main.localizedString(forKey:value:table:)
        // which our swizzle intercepts; `String(localized:)` uses the
        // LocalizedStringResource path on macOS 26 and bypasses it.
        w.title = "Glotty Settings".t
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(initialContentSize())
        w.contentMinSize = minimumContentSize
        w.center()
        // Deliberately NO `.moveToActiveSpace`. Settings is a regular
        // full-app window, not an overlay — when invoked from a
        // full-screen source app's space, the right macOS behavior is
        // to slide the user out of that space onto Settings's own
        // space where it has exclusive focus and IME. Setting
        // `.moveToActiveSpace` instead drags Settings into the
        // foreign space and inherits its locked input context: the
        // window appears, the cursor blinks, but key events go to the
        // full-screen-owning app. `.moveToActiveSpace` is correct for
        // popups (which DO need to overlay on the source space) and
        // wrong here. Same reasoning applies to the other managed
        // windows below.

        window = w
        // Register with AppActivation, passing a closer the hotkey
        // path can fire to dismiss this window when a popup is about
        // to open.
        activationToken = AppActivation.register { [weak w] in
            w?.performClose(nil)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tearDownWindow() }
        }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        Log.activationSnapshot(window: w, name: "Settings", op: "open-settings")
    }

    /// Idempotent cleanup. Called from both the willClose observer
    /// (user-driven close) and the tab-rebuild path (which closes the
    /// old window before re-show). `unregister` is a no-op for an
    /// already-released token, so `AppActivation.dismissAllRegistered`
    /// running first is also safe.
    private func tearDownWindow() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window?.orderOut(nil)
        window = nil
        if let token = activationToken {
            activationToken = nil
            AppActivation.unregister(token)
        }
    }

    private func initialContentSize() -> NSSize {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = min(720, max(minimumContentSize.height, screenHeight - 120))
        return NSSize(width: preferredContentWidth, height: height)
    }
}
