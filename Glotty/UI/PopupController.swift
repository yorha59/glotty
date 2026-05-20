import AppKit
import SwiftUI

@MainActor
final class PopupController {
    /// All currently open popups. Each `show` call creates a fresh panel and
    /// appends it here; clicking the close button (or pressing Esc) removes
    /// that one panel from the list. Allowing multiple windows lets the user
    /// keep a Polish output open while looking up a translation, etc.
    private var panels: [NSPanel] = []
    /// Strong references to each panel's NSHostingController. NSPanel only
    /// weakly retains its contentViewController on macOS, so we hold them
    /// alongside the panel to keep the SwiftUI view alive for streaming
    /// updates. Removed in lockstep with `panels`.
    private var hosts: [ObjectIdentifier: NSHostingController<PopupView>] = [:]

    /// Initial size for any popup before SwiftUI reports its intrinsic height.
    /// The hosting controller's `preferredContentSize` takes over right after
    /// the first layout pass; this is just a placeholder so the panel doesn't
    /// flash at zero-size.
    private static let initialSize = NSSize(width: 460, height: 240)

    func show(sourceText: String, mode: PopupMode = .translate) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // All three modes now auto-fit, so the panel itself is non-resizable.
        // The SwiftUI content's intrinsic size drives the panel.
        let panel = createPanel()

        // Per-panel dismiss closure — each PopupView's onClose targets its own
        // panel, not the controller's notion of "the current one". This is
        // what lets Esc on one window leave the others standing.
        let panelRef = panel
        let rootView = PopupView(
            sourceText: sourceText,
            mode: mode,
            onClose: { [weak self, weak panelRef] in
                guard let panelRef else { return }
                self?.dismiss(panelRef)
            }
        )

        // Auto-fit via NSHostingController.sizingOptions = .preferredContentSize.
        // The panel resizes whenever the SwiftUI content's intrinsic size
        // changes — first layout, async translation arriving, dict result
        // appearing, streamed polish variants becoming variant cards, etc.
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        hosts[ObjectIdentifier(panel)] = host
        host.view.layoutSubtreeIfNeeded()
        let preferred = host.preferredContentSize
        let initialSize = (preferred.width > 0 && preferred.height > 0)
            ? preferred
            : Self.initialSize
        panel.setContentSize(initialSize)

        // Cascade subsequent windows so they don't perfectly stack on the
        // first. AppKit's window-cascading convention is 20pt × 20pt; we use
        // 24pt to match macOS's slightly larger system step.
        let cascadeStep: CGFloat = 24
        let cascade = CGFloat(panels.count) * cascadeStep
        let originX = min(max(mouse.x + cascade, screenFrame.minX),
                          screenFrame.maxX - initialSize.width)
        let originY = max(mouse.y - initialSize.height - 8 - cascade, screenFrame.minY)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        // Track the panel and listen for user-initiated close (the X button).
        // `willClose` fires for AppKit-driven closes; our `dismiss(_)` cleans
        // up the same state up front, so this observer only matters for the
        // close-button path.
        panels.append(panel)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panelRef] _ in
            guard let panelRef else { return }
            Task { @MainActor in
                self?.removeFromTracking(panelRef)
            }
        }

        panel.orderFrontRegardless()
    }

    func dismiss(_ panel: NSPanel) {
        panel.orderOut(nil)
        removeFromTracking(panel)
    }

    /// Close every popup. Not currently wired to a hotkey but useful as a
    /// "panic" affordance and during tests.
    func dismissAll() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        hosts.removeAll()
    }

    private func removeFromTracking(_ panel: NSPanel) {
        hosts.removeValue(forKey: ObjectIdentifier(panel))
        panels.removeAll { $0 === panel }
    }

    /// Build a fresh panel. We always create a new one — supporting multiple
    /// windows means there's no "current" panel to reuse anymore. All three
    /// modes auto-fit now, so the panel is non-resizable; the SwiftUI content
    /// drives the size via the hosting controller.
    private func createPanel() -> NSPanel {
        let mask: NSWindow.StyleMask = [
            .nonactivatingPanel, .titled, .closable, .fullSizeContentView,
        ]
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: 520)),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        // Don't release on close — we control the lifetime via `panels`.
        p.isReleasedWhenClosed = false
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive — pick one.
        p.collectionBehavior = [.moveToActiveSpace, .transient]
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }
}
