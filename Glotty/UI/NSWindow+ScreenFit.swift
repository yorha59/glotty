import AppKit

extension NSWindow {
    /// Apply a desired content size, but never larger than the active
    /// screen's visible frame (minus a margin). Width and height are
    /// capped independently.
    ///
    /// Why this exists: several windows size themselves from a fixed
    /// constant (Welcome, the Translate/Permissions gates) or from
    /// `host.preferredContentSize`, which grows with content (a long
    /// chat history / many memory rows can be thousands of points
    /// tall). On a smaller display — older 13"/11" Intel laptops, a
    /// tall Dock, or no "More Space" scaling — an unclamped size makes
    /// the window taller (or wider) than the screen, pushing controls
    /// off the edge with no way to reach them. The original report was
    /// the Welcome window's Next button falling below the screen.
    ///
    /// `screen` defaults to the window's own screen, falling back to the
    /// main screen (the one `center()` places the window on). Call this
    /// before `center()`. Windows whose content can exceed the clamped
    /// size should keep that content scrollable so nothing is lost.
    func setContentSizeClampedToScreen(_ desired: NSSize, margin: CGFloat = 40) {
        guard let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?
            .visibleFrame.size else {
            setContentSize(desired)
            return
        }
        setContentSize(NSSize(
            width: min(desired.width, visible.width - margin),
            height: min(desired.height, visible.height - margin)
        ))
    }
}
