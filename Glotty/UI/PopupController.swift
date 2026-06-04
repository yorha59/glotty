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
        let marked = Self.responderChainHasMarkedText(from: firstResponder)
        Log.debug(.popup, "cancelOperation — markedText=\(marked) "
                  + "→ \(marked ? "defer to IME" : "onCancel")", op: "close")
        if marked {
            // IME owns this key — defer to the system so the candidate
            // window can close (or the marked text can be cleared) without
            // taking the popup with it.
            super.cancelOperation(sender)
            return
        }
        onCancel?()
    }

    /// Return-while-composing should commit the IME candidate, not
    /// submit the chat message. SwiftUI's `.onSubmit` fires on Return
    /// regardless of marked-text state — so we intercept the keyDown
    /// here, route it only into the field editor's `interpretKeyEvents`
    /// (where the IME consumes it for commit), and skip the rest of
    /// the dispatch chain that would trigger `.onSubmit`.
    override func sendEvent(_ event: NSEvent) {
        // ESC (keyCode 53): close the panel. We handle it here, before
        // responder dispatch, because in chat the composer TextField
        // holds first responder and its field editor swallows ESC
        // (cancelOperation) before it reaches this panel — so the popup
        // wouldn't close. Translate/explain have no focused field, so
        // their ESC reaches `cancelOperation` normally; this just makes
        // chat behave the same. While an IME is composing, ESC instead
        // cancels the composition (defer to the system).
        if event.type == .keyDown, event.keyCode == 53 {
            let marked = Self.responderChainHasMarkedText(from: firstResponder)
            Log.debug(.popup, "ESC keyDown — markedText=\(marked) "
                      + "firstResponder=\(type(of: firstResponder)) "
                      + "→ \(marked ? "defer to IME" : "onCancel")", op: "close")
            if marked {
                super.sendEvent(event)
                return
            }
            onCancel?()
            return
        }
        if event.type == .keyDown,
           (event.keyCode == 36 || event.keyCode == 76),  // Return / numpad Enter
           !event.modifierFlags.contains(.shift) {
            if let tv = firstResponder as? NSTextView, tv.hasMarkedText() {
                tv.interpretKeyEvents([event])
                return
            }
            if let tf = firstResponder as? NSTextField,
               let editor = tf.currentEditor() as? NSTextView,
               editor.hasMarkedText() {
                editor.interpretKeyEvents([event])
                return
            }
        }
        super.sendEvent(event)
    }

    /// Allow the user to drag the panel to any position, including ones
    /// where the title bar is off-screen. AppKit's default
    /// `constrainFrameRect` keeps the title bar visible — fine for
    /// most windows, but answer panels can grow taller than the screen
    /// (long selection → long polished response + chat). When that
    /// happens the user needs to "scroll" the panel by dragging it so
    /// the hidden top or bottom comes into view; the default constraint
    /// snaps it back. Returning the proposed frame unchanged lets the
    /// drag stick.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
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
    /// Per-panel extraction trigger registered by `PopupView`. PopupView
    /// re-registers on every relevant @State change so the closure
    /// captures the latest chat thread / event id. Invoked from
    /// `dismiss(_:)` and the willClose observer so post-dismiss
    /// memory extraction always sees the freshest state — more
    /// reliable than SwiftUI's `.onDisappear`, which doesn't fire
    /// consistently when an NSPanel is dismissed via `orderOut`.
    private var extractionTriggers: [ObjectIdentifier: () -> Void] = [:]

    /// Initial size for any popup before SwiftUI reports its intrinsic height.
    /// The hosting controller's `preferredContentSize` takes over right after
    /// the first layout pass; this is just a placeholder so the panel doesn't
    /// flash at zero-size.
    private static let initialSize = NSSize(width: 460, height: 240)

    /// Distributed-notification name the dev/agent posts to replay
    /// the most-recent stored history event of a given kind into a
    /// fresh popup window. `userInfo["kind"]` ∈ `translate / explain /
    /// polish`; omitted defaults to `polish` (the richest popup to
    /// eyeball for sizing). Used for screen-snapshot debugging of
    /// the popup layout without manually triggering Fn-key flows.
    static let replayLastNotificationName = Notification.Name("com.ruojunye.glotty.replayLast")

    /// One-time install — call from AppDelegate.
    nonisolated static func installReplayObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: replayLastNotificationName,
            object: nil,
            queue: .main,
            using: { note in
                let kindRaw = (note.userInfo?["kind"] as? String) ?? "polish"
                let kind: MemoryEventKind = {
                    switch kindRaw {
                    case "translate": return .translate
                    case "explain":   return .explain
                    default:          return .polish
                    }
                }()
                Task { @MainActor in
                    PopupController.shared.replayLast(kind: kind)
                }
            }
        )
    }

    /// Find the most-recent event of the given kind in MemoryStore
    /// and re-open its popup. No-op if no matching event exists.
    @MainActor
    func replayLast(kind: MemoryEventKind) {
        let all = MemoryStore.shared.allEvents()
        // Walk newest-first to find the latest of the requested kind.
        guard let event = all.reversed().first(where: { $0.kind == kind }) else { return }
        guard let payload = PopupReplayPayload.from(event) else { return }
        let mode: PopupMode = {
            switch kind {
            case .translate: return .translate
            case .explain:   return .explain
            case .polish:    return .polish
            }
        }()
        show(sourceText: event.sourceText, mode: mode, replay: payload)
    }

    func show(sourceText: String,
              mode: PopupMode = .translate,
              replay: PopupReplayPayload? = nil,
              proactive: Bool = false,
              onboarding: Bool = false) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Rescue any existing panels the user dragged off-screen. With
        // `constrainFrameRect` disabled on PopupPanel they can end up
        // entirely outside every screen's frame and unreachable. Each
        // new action is a natural moment to bring lost panels back —
        // the user is asking for the popup anyway.
        rescueOffscreenPanels(targetScreenFrame: screenFrame)

        // All modes use translate's panel config — non-activating overlay
        // at `.floating` level with `.fullScreenAuxiliary` collection
        // behavior. This is the combination macOS needs for the popup to
        // appear alongside a full-screen source app (Chrome, Safari, etc.).
        // Polish/chat only diverge from translate by being resizable; the
        // chat-field IME first-open binding is handled separately when the
        // user actually taps into the field, not at panel creation.
        let panel = createPanel(resizable: mode == .polish || mode == .chat)

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
            proactive: proactive,
            onboarding: onboarding,
            onClose: { [weak self, weak panelRef] in
                guard let panelRef else { return }
                self?.dismiss(panelRef)
            },
            onChatExpand: { [weak panelRef] in
                // Polish panels are user-resizable with a fixed initial
                // size, so the chat region needs a manual nudge to give
                // it room. Explain panels use `sizingOptions = .preferred-
                // ContentSize` and grow on their own as the SwiftUI body
                // demands more height — no manual grow needed.
                guard mode == .polish else { return }
                guard let panelRef, !didGrowForChat else { return }
                didGrowForChat = true
                Self.growPanelForChat(panelRef)
            },
            registerExtractionTrigger: { [weak self, weak panelRef] hook in
                guard let self, let panelRef else { return }
                self.extractionTriggers[ObjectIdentifier(panelRef)] = hook
            }
        )
        // ESC routes through `PopupPanel.cancelOperation`, which checks
        // for IME composition first — see PopupPanel for the rationale.
        panel.onCancel = { [weak self, weak panelRef] in
            guard let panelRef else { return }
            self?.dismiss(panelRef)
        }

        // Auto-fit for ALL modes via sizingOptions = .preferredContentSize.
        // SwiftUI body's outer `.frame(maxHeight: maxPanelHeight)`
        // clamps the reported preferredContentSize at the screen
        // (minus margin), so a long selection caps the panel
        // height and the inner ScrollView takes over for overflow.
        //
        // Previously polish skipped this (so the user's drag-resize
        // wouldn't be fought by auto-sync). The cost was that polish
        // popups always opened at the 560×480 fallback regardless of
        // content — visibly a "fixed window size." We now sync for
        // polish too; the user can still resize via the .resizable
        // styleMask, and the auto-sync just gives them a better
        // starting size.
        let host = NSHostingController(rootView: rootView)
        // Auto-fit (preferredContentSize) for translate / explain /
        // polish. Chat is EXCLUDED: it's user-resizable and its
        // content grows as messages arrive, so auto-sync would fight
        // the manual drag — snapping the window back to the content's
        // ideal size on every new message. We still read
        // `preferredContentSize` once below to pick chat's initial
        // size; we just don't keep tracking it.
        host.sizingOptions = mode == .chat ? [] : [.preferredContentSize]
        panel.contentViewController = host
        hosts[ObjectIdentifier(panel)] = host
        host.view.layoutSubtreeIfNeeded()
        let preferred = host.preferredContentSize
        let initialSize: NSSize
        switch mode {
        case .polish:
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
        case .chat:
            // Chat is user-resizable so the thread area can be dragged
            // bigger. Start at the auto-fit ideal (or a sensible
            // fallback) and set a floor so it can't be dragged uselessly
            // small.
            let base = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : NSSize(width: 560, height: 560)
            initialSize = NSSize(width: max(base.width, 460),
                                 height: max(base.height, 400))
            panel.contentMinSize = NSSize(width: 380, height: 300)
        default:
            initialSize = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : Self.initialSize
        }
        // Cap the panel content area at the available screen height
        // (minus chrome). With `sizingOptions = .preferredContentSize`
        // the panel auto-resizes to whatever SwiftUI reports as its
        // ideal — and a very long source selection's ideal IS huge.
        // `contentMaxSize` clamps the upward growth; SwiftUI gets
        // less space than it asked for and the inner ScrollView
        // takes over.
        let screenCap = max(screenFrame.height - 120, 320)
        if initialSize.height > screenCap {
            panel.setContentSize(NSSize(width: initialSize.width, height: screenCap))
        } else {
            panel.setContentSize(initialSize)
        }
        panel.contentMaxSize = NSSize(
            width: .greatestFiniteMagnitude,
            height: screenCap
        )

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
                Log.debug(.popup, "willClose fired (red-button / system close)", op: "close")
                self?.removeFromTracking(panelRef)
            }
        }

        panel.orderFrontRegardless()
        // Clear any auto-promoted first responder. macOS picks the
        // first focusable text view in the SwiftUI hierarchy when an
        // NSPanel becomes key — that's the polish/explain Discuss
        // chat input, buried at the bottom of the popup. macOS then
        // auto-scrolls the ScrollView to bring the focused field
        // into view, pushing the source text + section labels off
        // the top of the panel. Explicitly setting firstResponder
        // to nil after the panel is on screen prevents this.
        DispatchQueue.main.async {
            panel.makeFirstResponder(nil)
        }
    }

    func dismiss(_ panel: PopupPanel) {
        let mode = hosts[ObjectIdentifier(panel)]?.rootView.mode
        Log.debug(.popup, "dismiss(_) — mode=\(mode.map(String.init(describing:)) ?? "?") "
                  + "panelsBefore=\(panels.count)", op: "close")
        // Fire post-dismiss memory extraction BEFORE we tear down
        // the host. Use removeValue so removeFromTracking below
        // doesn't double-fire — the X-button (willClose) path goes
        // directly through removeFromTracking without dismiss.
        extractionTriggers.removeValue(forKey: ObjectIdentifier(panel))?()
        panel.orderOut(nil)
        removeFromTracking(panel)
    }

    /// True if at least one chat-mode popup is currently visible.
    /// Used by `PracticeScheduler` to skip proactive notifications
    /// while the user is mid-conversation — interrupting a live
    /// chat with a "want to chat?" banner reads as broken.
    func hasOpenChatPopup() -> Bool {
        for panel in panels {
            guard let host = hosts[ObjectIdentifier(panel)] else { continue }
            if host.rootView.mode == .chat { return true }
        }
        return false
    }

    /// Close every popup. Not currently wired to a hotkey but useful as a
    /// "panic" affordance and during tests.
    func dismissAll() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        hosts.removeAll()
    }

    private func removeFromTracking(_ panel: PopupPanel) {
        let id = ObjectIdentifier(panel)
        // Belt-and-suspenders: if dismiss(_:) didn't run (e.g.
        // user clicked the X button — willClose path goes straight
        // here without dismiss), still fire the trigger once before
        // forgetting the closure.
        extractionTriggers.removeValue(forKey: id)?()
        hosts.removeValue(forKey: id)
        panels.removeAll { $0 === panel }
    }

    /// Nudge any panel that ended up entirely outside every screen
    /// back into view. We require a meaningful overlap (not just a
    /// pixel) so a panel intentionally placed at the screen edge isn't
    /// repositioned. Off-screen panels are recentered on the screen
    /// the user is currently working on.
    private func rescueOffscreenPanels(targetScreenFrame: NSRect) {
        let minVisible: CGFloat = 80
        for panel in panels {
            let frame = panel.frame
            let stillReachable = NSScreen.screens.contains { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                return intersection.width >= minVisible && intersection.height >= minVisible
            }
            if stillReachable { continue }
            var newFrame = frame
            newFrame.origin.x = targetScreenFrame.midX - frame.width / 2
            newFrame.origin.y = targetScreenFrame.midY - frame.height / 2
            // Clamp X so the panel doesn't extend past the screen sides
            // when it's wider than expected. Y is left alone — tall
            // panels intentionally extend beyond the screen.
            newFrame.origin.x = min(max(newFrame.origin.x, targetScreenFrame.minX),
                                    max(targetScreenFrame.maxX - frame.width, targetScreenFrame.minX))
            panel.setFrame(newFrame, display: true, animate: true)
        }
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
