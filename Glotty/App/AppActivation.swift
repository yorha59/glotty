import AppKit

/// Glotty ships as `LSUIElement = YES` (agent app, no Dock icon) so that
/// popup panels behave correctly when overlaid on another regular app's
/// full-screen Mission Control space — most importantly, the system IME
/// candidate window appears for CJK input. Regular apps activating over
/// a full-screen app trip a different code path in the input-method
/// server that suppresses the candidate window for our auxiliary panels.
///
/// Some surfaces still need full-app treatment though: the Settings
/// window, the standalone Mistake-type drill-in, etc. — they want a Dock
/// icon and ⌘-Tab presence while open. `AppActivation` is a refcount that
/// flips `NSApp.setActivationPolicy(...)` to `.regular` while any such
/// window is showing and back to `.accessory` once the last one closes.
@MainActor
enum AppActivation {
    private static var count: Int = 0

    /// Bump the refcount and switch to `.regular` (Dock icon, app menu,
    /// ⌘-Tab). Also activates the app so the just-shown window comes to
    /// the front — `setActivationPolicy(.regular)` on its own doesn't
    /// move us forward if another app is currently key.
    static func register() {
        count += 1
        if count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drop the refcount. If no regular-mode windows remain, return to
    /// `.accessory` so popups over full-screen apps continue to behave
    /// well for IME input.
    static func unregister() {
        count = max(0, count - 1)
        if count == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
