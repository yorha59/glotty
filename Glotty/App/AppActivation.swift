import AppKit

/// Glotty ships as `LSUIElement = YES` (agent app, no Dock icon) so that
/// popup panels behave correctly when overlaid on another regular app's
/// full-screen Mission Control space — most importantly, the system IME
/// candidate window appears for CJK input. Regular apps activating over
/// a full-screen app trip a different code path in the input-method
/// server that suppresses the candidate window for our auxiliary panels.
///
/// Some surfaces still want full-app treatment (Settings, Mistake-type
/// drill-in): a Dock icon while open, presence in ⌘-Tab, an app menu.
/// `AppActivation` is a refcounted helper that flips
/// `NSApp.setActivationPolicy(...)` to `.regular` while any such window
/// is registered and back to `.accessory` once the last one closes.
///
/// To avoid the bug-shaped UX where opening Settings silently breaks
/// IME in subsequently-triggered popups, hotkey paths (Fn → T/E/P) call
/// `dismissAllRegistered()` before showing a popup. Same idea Raycast
/// uses: if Settings is open and the user hits the hotkey, close
/// Settings first, then show the popup in clean agent mode.
@MainActor
enum AppActivation {
    private static var count: Int = 0
    /// Closures that perform the actual window dismissal for each
    /// registered surface. Keyed by the token returned from `register`
    /// so a window can both unregister itself on close and be force-
    /// closed from elsewhere via `dismissAllRegistered`.
    private static var closers: [UUID: () -> Void] = [:]

    /// Bump the refcount, switch to `.regular`, and remember how to
    /// dismiss the registered window when a hotkey forces a popup
    /// open. Caller stores the returned token and passes it back to
    /// `unregister` on the window's `willClose` notification.
    static func register(closer: @escaping () -> Void) -> UUID {
        count += 1
        if count == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Pump the main runloop so Input Method Kit can finish
            // binding its mach port for the freshly-promoted .regular
            // process. Without this, SwiftUI TextFields in the first
            // managed window of the session silently drop keystrokes
            // ("error messaging the mach port for
            // IMKCFRunLoopWakeUpReliable"). The caller invokes
            // makeKeyAndOrderFront right after we return, so IMK has
            // to be ready by then.
            let deadline = Date(timeIntervalSinceNow: 0.25)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let token = UUID()
        closers[token] = closer
        return token
    }

    /// Drop the refcount. If no regular-mode windows remain, return to
    /// `.accessory` so popups continue to receive IME candidates over
    /// full-screen overlays. Idempotent — safe to call twice for the
    /// same token (the `dismissAllRegistered` path already cleared
    /// state before the willClose observer fires).
    static func unregister(_ token: UUID) {
        guard closers.removeValue(forKey: token) != nil else { return }
        count = max(0, count - 1)
        if count == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Synchronously close every registered window and reset the
    /// activation policy to `.accessory`. Called from hotkey paths so
    /// the popup that's about to open inherits agent-mode behavior
    /// (which is what makes IME candidates render over full-screen
    /// apps). We force the count/policy back now rather than waiting
    /// for each `willClose` observer to call `unregister` on the next
    /// runloop tick — the popup needs agent mode immediately, not one
    /// tick later. Returns true if any window was actually dismissed.
    @discardableResult
    static func dismissAllRegistered() -> Bool {
        let snapshot = Array(closers.values)
        guard !snapshot.isEmpty else { return false }
        for close in snapshot { close() }
        closers.removeAll()
        count = 0
        NSApp.setActivationPolicy(.accessory)
        return true
    }
}
