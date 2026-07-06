import AppKit

/// Tracks mouse hover over the menu-bar status item button and cycles its
/// image between the default and "active" mascot frames while hovered. The
/// effect is a subtle "noticing you" animation — ears perk up, mouth opens —
/// that reads as a tail-wag mood signal at menu-bar size.
///
/// Implementation note: `NSTrackingArea` on `NSStatusBarButton` is unreliable
/// because the button lives in a system-owned `NSStatusBarWindow` that often
/// swallows enter/exit events before they reach a tracking-area owner.
/// Instead we use NSEvent monitors (global + local) on `.mouseMoved`, doing
/// a cheap geometry check against the button's screen frame on each event.
/// Mouse-moved events don't require any permissions.
@MainActor
final class MenuBarMascot: NSObject {
    private weak var button: NSStatusBarButton?
    private let defaultImage: NSImage
    private let activeImage: NSImage
    private var animationTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHovering = false
    /// Period between frame swaps while hovered. 220ms feels lively without
    /// strobing — slower than a real tail wag but readable at 18px where any
    /// faster cycle just looks like flicker.
    private let frameInterval: TimeInterval = 0.22

    init(button: NSStatusBarButton, defaultImage: NSImage, activeImage: NSImage) {
        self.button = button
        self.defaultImage = defaultImage
        self.activeImage = activeImage
        super.init()
        // Both frames render at the standard menu bar icon size — the hover
        // animation is purely a frame swap, no scaling, so the silhouette
        // stays the same dimensions while only the expression changes.
        defaultImage.size = NSSize(width: 18, height: 18)
        activeImage.size = NSSize(width: 18, height: 18)
        button.image = defaultImage
        installMouseMonitors()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        animationTimer?.invalidate()
    }

    private func installMouseMonitors() {
        // Global monitor: mouse-moved events that occur while another app is
        // frontmost (e.g. the user is in Safari and drags up to the menu bar).
        // Returns nothing — global monitors are read-only.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.checkHover() }
        }
        // Local monitor: mouse-moved events when our own app is frontmost
        // (the user is in a Glotty popup and drags up to the menu bar).
        // Must pass the event through so AppKit still dispatches it normally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in self?.checkHover() }
            return event
        }
    }

    private func checkHover() {
        let inside = isMouseOverButton()
        if inside, !isHovering {
            isHovering = true
            startAnimation()
        } else if !inside, isHovering {
            isHovering = false
            stopAnimation()
        }
    }

    /// True when the system cursor is currently inside the button's on-screen
    /// rect. Converted through `button.window` because the button is laid out
    /// inside the status-bar window, not screen coordinates directly.
    private func isMouseOverButton() -> Bool {
        guard let button, let window = button.window else { return false }
        let pt = NSEvent.mouseLocation                          // screen coords
        let inWindow = button.convert(button.bounds, to: nil)   // window coords
        let inScreen = window.convertToScreen(inWindow)         // screen coords
        return inScreen.contains(pt)
    }

    private func startAnimation() {
        stopAnimation()
        // Show the active frame immediately so there's no delay between
        // cursor arrival and visible response; the timer then flips back to
        // default on the next tick, giving the cycle a "lift then settle" feel.
        button?.image = activeImage
        var showingActive = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            showingActive.toggle()
            self.button?.image = showingActive ? self.activeImage : self.defaultImage
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        button?.image = defaultImage
    }
}
