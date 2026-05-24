import AppKit
import SwiftUI

/// NSPanel subclass that routes ESC through `cancelOperation` instead of
/// SwiftUI's `.onKeyPress(.escape)`. The SwiftUI hook runs before the
/// system input method gets a chance to handle the key, so ESC during a
/// CJK IME composition (e.g. dismissing the pinyin candidate list) was
/// closing the popup instead of just hiding the candidates. By overriding
/// `cancelOperation` we can ask the first responder whether it currently
/// has marked text — if it does, the IME owns this ESC and the panel
/// should stay open.
final class PopupPanel: NSPanel {
    /// Closure invoked when ESC fires on this panel AND no IME composition
    /// is active. Set by `PopupController.show(...)` to dismiss the panel.
    var onCancel: (() -> Void)?

    /// `.nonactivatingPanel` defaults this to false, which prevents the
    /// panel from becoming key — and without a key window, the input method
    /// server can't bind its candidate window to the field editor (e.g.
    /// Chinese pinyin candidates never appear). Override to true so the
    /// panel can hold keyboard focus while still leaving the underlying
    /// app's activation state alone.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if Self.responderChainHasMarkedText(from: firstResponder) {
            // IME owns this key — defer to the system so the candidate
            // window can close (or the marked text can be cleared) without
            // taking the popup with it.
            super.cancelOperation(sender)
            return
        }
        onCancel?()
    }

    /// True if any responder up the chain from `start` reports a non-zero
    /// marked text range. `NSTextField`s host their editor lazily as the
    /// field editor (an `NSTextView`), so we check both the responder
    /// itself and any `currentEditor()` it exposes.
    private static func responderChainHasMarkedText(from start: NSResponder?) -> Bool {
        var node: NSResponder? = start
        while let cur = node {
            if let tv = cur as? NSTextView, tv.hasMarkedText() { return true }
            if let tf = cur as? NSTextField,
               let editor = tf.currentEditor() as? NSTextView,
               editor.hasMarkedText() { return true }
            node = cur.nextResponder
        }
        return false
    }
}

@MainActor
final class PopupController {
    /// Shared instance. `@NSApplicationDelegateAdaptor` proxies our
    /// AppDelegate, so `NSApp.delegate as? AppDelegate` fails through the
    /// wrapper — other module code (Settings, hotkey wiring) reaches the
    /// popup through this singleton instead.
    static let shared = PopupController()

    /// All currently open popups. Each `show` call creates a fresh panel and
    /// appends it here; clicking the close button (or pressing Esc) removes
    /// that one panel from the list. Allowing multiple windows lets the user
    /// keep a Polish output open while looking up a translation, etc.
    private var panels: [PopupPanel] = []
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

    func show(sourceText: String, mode: PopupMode = .translate, replay: PopupReplayPayload? = nil) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // All modes use translate's panel config — non-activating overlay
        // at `.floating` level with `.fullScreenAuxiliary` collection
        // behavior. This is the combination macOS needs for the popup to
        // appear alongside a full-screen source app (Chrome, Safari, etc.).
        // Polish/chat only diverge from translate by being resizable; the
        // chat-field IME first-open binding is handled separately when the
        // user actually taps into the field, not at panel creation.
        let panel = createPanel(resizable: mode == .polish)

        // Per-panel dismiss closure — each PopupView's onClose targets its own
        // panel, not the controller's notion of "the current one". This is
        // what lets Esc on one window leave the others standing.
        let panelRef = panel
        // One-shot guard so collapse + re-expand doesn't keep growing
        // the panel each time. The first expansion buys the chat room;
        // subsequent ones reuse that space.
        var didGrowForChat = false
        let rootView = PopupView(
            sourceText: sourceText,
            mode: mode,
            replay: replay,
            onClose: { [weak self, weak panelRef] in
                guard let panelRef else { return }
                self?.dismiss(panelRef)
            },
            onChatExpand: { [weak panelRef] in
                guard let panelRef, !didGrowForChat else { return }
                didGrowForChat = true
                Self.growPanelForChat(panelRef)
            }
        )
        // ESC routes through `PopupPanel.cancelOperation`, which checks
        // for IME composition first — see PopupPanel for the rationale.
        panel.onCancel = { [weak self, weak panelRef] in
            guard let panelRef else { return }
            self?.dismiss(panelRef)
        }

        // Auto-fit for translate/explain via sizingOptions = .preferredContentSize.
        // For polish we skip that — the user controls the size via the
        // resize handle — and instead pick a sensible starting size from
        // the first layout pass.
        let host = NSHostingController(rootView: rootView)
        if mode != .polish {
            host.sizingOptions = [.preferredContentSize]
        }
        panel.contentViewController = host
        hosts[ObjectIdentifier(panel)] = host
        host.view.layoutSubtreeIfNeeded()
        let preferred = host.preferredContentSize
        let initialSize: NSSize
        if mode == .polish {
            // Polish starts at a comfortable working size — wide enough for
            // variant cards, tall enough to show variants + issues without
            // requiring an immediate drag. Bigger than the SwiftUI ideal so
            // the user has visible drag handles right away.
            let base = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : NSSize(width: 560, height: 520)
            initialSize = NSSize(width: max(base.width, 560),
                                 height: max(base.height, 480))
            panel.contentMinSize = NSSize(width: 380, height: 240)
        } else {
            initialSize = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : Self.initialSize
        }
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

    func dismiss(_ panel: PopupPanel) {
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

    private func removeFromTracking(_ panel: PopupPanel) {
        hosts.removeValue(forKey: ObjectIdentifier(panel))
        panels.removeAll { $0 === panel }
    }

    /// Add ~220pt of vertical room when the user expands the polish chat
    /// for the first time. The chat region inside `PopupView` reserves a
    /// 180pt min-height; without growing the panel, that space would come
    /// out of the polish content above. We anchor the top of the window
    /// so the polish content stays put and the chat appears below — and
    /// we clamp to the screen so we don't shove the window off-edge on
    /// small displays.
    private static func growPanelForChat(_ panel: NSPanel) {
        let delta: CGFloat = 220
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var frame = panel.frame
        let topY = frame.origin.y + frame.size.height
        let maxHeight = max(frame.size.height, screen.height - 40)
        let newHeight = min(frame.size.height + delta, maxHeight)
        frame.size.height = newHeight
        // Anchor the top edge so existing polish content doesn't appear
        // to "jump" — the new room opens downward.
        frame.origin.y = max(topY - newHeight, screen.minY)
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Build a fresh panel. We always create a new one — supporting multiple
    /// windows means there's no "current" panel to reuse anymore. Translate
    /// and explain auto-fit (non-resizable); polish includes `.resizable`
    /// so the user can drag the corners as the chat thread grows.
    private func createPanel(resizable: Bool = false) -> PopupPanel {
        var mask: NSWindow.StyleMask = [
            .nonactivatingPanel, .titled, .closable, .fullSizeContentView,
        ]
        if resizable { mask.insert(.resizable) }
        let p = PopupPanel(
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
        // `.fullScreenAuxiliary` lets the popup overlay a full-screen
        // source app (Chrome, Safari, etc.) without forcing macOS to
        // switch out of that app's space.
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }
}
