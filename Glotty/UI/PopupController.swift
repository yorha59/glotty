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
    /// Panels still auto-fitting their height to content. A panel leaves the
    /// set the moment the user drags an edge (see the didResize observer in
    /// `show`). Chat never joins (it manages its own height).
    private var autoFitPanels: Set<ObjectIdentifier> = []
    /// The content size we last set programmatically for each panel. The
    /// didResize observer compares against this to tell our own re-fits apart
    /// from a user drag.
    private var lastAutoFitSize: [ObjectIdentifier: NSSize] = [:]
    /// The usable content-height cap for each panel, captured at open from the
    /// exact screen the popup launched on. Reused by `autoFitIfNeeded` so a
    /// streaming re-fit clamps to the same screen the window was built for.
    private var panelScreenCap: [ObjectIdentifier: CGFloat] = [:]

    /// Bubbles standing in for hidden popups. Keyed by the hidden
    /// popup's ObjectIdentifier; the value is the small floating panel
    /// that sits at the right screen edge while the popup is hidden.
    /// Clicking it restores the popup. This is Glotty's "minimize" —
    /// a privacy gesture (tuck the translation out of sight, bring it
    /// back with one click) implemented as `orderOut`/`orderFront`
    /// rather than native miniaturize, which would break the IME
    /// candidate binding. See `hideToBubble`.
    private var bubbleForPopup: [ObjectIdentifier: NSPanel] = [:]

    /// Initial size for any popup before SwiftUI reports its intrinsic height.
    /// The hosting controller's `preferredContentSize` takes over right after
    /// the first layout pass; this is just a placeholder so the panel doesn't
    /// flash at zero-size.
    private static let initialSize = NSSize(width: 460, height: 240)
    /// Margin kept between an auto-fitted popup and the screen edges.
    /// `visibleFrame` already excludes the menu bar and Dock, so this only
    /// needs to be a small breathing gap — not the old 120pt, which wasted
    /// over a hundred points of usable height and forced tall content to
    /// scroll even when the screen had room.
    private static let screenEdgeMargin: CGFloat = 16

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
              onboarding: Bool = false,
              practiceItems: [PracticeItem] = []) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // We already know the exact screen the popup will open on (the one
        // under the cursor). Compute its usable content height up front and
        // hand it to PopupView, so the content's height cap and the window's
        // height cap come from the SAME screen — no `NSScreen.main` guesswork.
        let screenCap = max(screenFrame.height - Self.screenEdgeMargin, 320)

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
        // All popups are resizable — the user can stretch any of them from
        // any edge/corner. Translate/explain additionally auto-fit their
        // height on open (and while streaming) via
        // `sizingOptions = .preferredContentSize`; a `didResize` observer
        // below releases that auto-fit the moment the user drags an edge,
        // so a manual stretch sticks instead of snapping back.
        let panel = createPanel(resizable: true)

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
            practiceItems: practiceItems,
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
            onHide: { [weak self, weak panelRef] in
                guard let panelRef else { return }
                self?.hideToBubble(panelRef)
            },
            registerExtractionTrigger: { [weak self, weak panelRef] hook in
                guard let self, let panelRef else { return }
                self.extractionTriggers[ObjectIdentifier(panelRef)] = hook
            },
            onContentResize: { [weak self, weak panelRef] desiredHeight in
                guard let self, let panelRef else { return }
                self.autoFitIfNeeded(panelRef, desiredContentHeight: desiredHeight)
            },
            maxContentHeight: screenCap
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
        // MANUAL sizing for every mode. We deliberately do NOT use
        // `sizingOptions = .preferredContentSize`: that drives the window
        // size from a contentViewController's preferredContentSize, which
        // AppKit treats as a fixed size (contentMinSize == contentMaxSize) —
        // the window then looks fixed AND can't be dragged to resize. Instead
        // we read the SwiftUI content's intrinsic `fittingSize` ourselves to
        // pick the opening size, keep the panel freely resizable (min < max),
        // and re-fit on content changes via `autoFitIfNeeded(_:)` until the
        // user drags an edge (see the didResize observer below).
        host.sizingOptions = []
        panel.contentViewController = host
        hosts[ObjectIdentifier(panel)] = host
        host.view.layoutSubtreeIfNeeded()
        // Intrinsic content size (includes all chrome: paddings, footer,
        // traffic-light inset). With the content column's
        // `.fixedSize(vertical: true)`, `fittingSize.height` is the natural
        // unscrolled height regardless of the current window size.
        let preferred = host.view.fittingSize
        let initialSize: NSSize
        switch mode {
        case .polish:
            // Polish starts at a comfortable working size — wide enough for
            // variant cards, tall enough to show variants + issues without
            // requiring an immediate drag.
            let base = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : NSSize(width: 560, height: 520)
            initialSize = NSSize(width: max(base.width, 560),
                                 height: max(base.height, 480))
            panel.contentMinSize = NSSize(width: 380, height: 240)
        case .chat:
            // Chat is user-resizable so the thread area can be dragged
            // bigger. Start at the fitted size (or a sensible fallback) and
            // set a floor so it can't be dragged uselessly small.
            let base = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : NSSize(width: 560, height: 560)
            initialSize = NSSize(width: max(base.width, 460),
                                 height: max(base.height, 400))
            panel.contentMinSize = NSSize(width: 380, height: 300)
        default:
            // Translate / explain: open fitted to content with an explicit
            // floor so there's always a real resize range (min < max).
            initialSize = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : Self.initialSize
            panel.contentMinSize = NSSize(width: 320, height: 200)
        }
        // Cap the panel content height at the available screen height (minus
        // chrome); a very long selection's intrinsic height can exceed the
        // screen, and the inner ScrollView takes over past the cap.
        // `screenCap` was computed up top from the popup's exact screen.
        let openSize = NSSize(width: initialSize.width,
                              height: min(initialSize.height, screenCap))
        panel.setContentSize(openSize)
        panel.contentMaxSize = NSSize(
            width: .greatestFiniteMagnitude,
            height: screenCap
        )
        // Chat manages its own height (messages accrue unboundedly, so we
        // don't auto-grow it); every other mode auto-fits until the user
        // resizes. Seed the "last programmatic size" so the first user drag
        // is correctly distinguished from our own re-fits.
        if mode != .chat {
            autoFitPanels.insert(ObjectIdentifier(panel))
            // Re-fit a few times shortly after open. Translate/explain content
            // arrives async (the translation result ~250ms in, the LLM
            // explanation over a second or more), and SwiftUI's in-ScrollView
            // geometry reporting doesn't reliably re-fire for those late
            // changes. These ticks re-measure (via autoFitIfNeeded's
            // preferredContentSize probe) and grow the window to the final
            // content. Each is a no-op once the user has resized (the panel
            // has left autoFitPanels) or once the size already matches.
            for delay in [0.3, 0.7, 1.3, 2.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    self.autoFitIfNeeded(panel, desiredContentHeight: 0)
                }
            }
        }
        lastAutoFitSize[ObjectIdentifier(panel)] = openSize
        panelScreenCap[ObjectIdentifier(panel)] = screenCap

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

        // User-resize ends auto-fit. While a panel is in `autoFitPanels` we
        // re-fit its height to the content (on open + as a response streams
        // in) via `autoFitIfNeeded`. The moment the window's size diverges
        // from the size WE last set programmatically, the user has dragged an
        // edge — so we drop the panel from `autoFitPanels` and never touch its
        // size again. Comparing against our own last set (rather than the
        // content ideal) makes this timing-independent: our re-fits always
        // match, a user drag never does.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panelRef] _ in
            guard let self, let panelRef else { return }
            let id = ObjectIdentifier(panelRef)
            guard self.autoFitPanels.contains(id) else { return }
            let actual = panelRef.contentRect(forFrameRect: panelRef.frame).size
            let mine = self.lastAutoFitSize[id] ?? actual
            if abs(actual.height - mine.height) > 4
                || abs(actual.width - mine.width) > 4 {
                self.autoFitPanels.remove(id)
                Log.debug(.popup, "user resized — auto-fit ended "
                          + "(actual=\(actual) lastAutoFit=\(mine))", op: "resize")
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
    /// Used by `ReminderScheduler` to skip proactive notifications
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
        for b in bubbleForPopup.values { b.orderOut(nil) }
        bubbleForPopup.removeAll()
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
        autoFitPanels.remove(id)
        lastAutoFitSize.removeValue(forKey: id)
        panelScreenCap.removeValue(forKey: id)
        panels.removeAll { $0 === panel }
        // If this popup was hidden behind a bubble, tear the bubble
        // down too so a closed-while-hidden popup doesn't leave an
        // orphaned bubble pointing at a dead window.
        if let bubble = bubbleForPopup.removeValue(forKey: id) {
            bubble.orderOut(nil)
            layoutBubbles()
        }
    }

    /// Re-fit a still-auto-fitting panel's height to its content. Called from
    /// `PopupView` whenever the content's measured height changes — on open
    /// and as a response streams in — so the window grows to keep all content
    /// visible "by default". No-op once the user has dragged an edge (the
    /// panel has left `autoFitPanels`). Width is left alone; only the height
    /// tracks the content, capped at the screen.
    func autoFitIfNeeded(_ panel: PopupPanel, desiredContentHeight: CGFloat) {
        let id = ObjectIdentifier(panel)
        guard autoFitPanels.contains(id), let host = hosts[id] else { return }
        // MEASURE accurately without permanently locking the window. SwiftUI's
        // in-ScrollView geometry reporting misses late async content (the
        // translation result / LLM explanation that arrive a few hundred ms
        // after the dictionaries) — the window stayed sized to the pre-result
        // content and the result clipped. NSHostingController's
        // `.preferredContentSize` DOES capture the full ideal (including that
        // late content + the ScrollView's intrinsic height), so we toggle it
        // on just long enough to read the ideal, then turn it back off and
        // apply the height ourselves — keeping the window freely resizable.
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        let ideal = host.preferredContentSize
        host.sizingOptions = []
        let screenCap = panelScreenCap[id]
            ?? max((panel.screen?.visibleFrame.height ?? 900)
                   - Self.screenEdgeMargin, 320)
        // Re-assert a resizable range — toggling `.preferredContentSize` may
        // have pinned contentMin/Max; restore room to drag.
        panel.contentMinSize = NSSize(width: 320, height: 200)
        panel.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: screenCap)
        guard ideal.height > 0 else { return }
        let current = panel.contentRect(forFrameRect: panel.frame).size
        let targetHeight = min(ideal.height, screenCap)
        // Nothing to do if we're already there (avoids a redundant resize +
        // a spurious didResize that could be misread as a user drag).
        guard abs(targetHeight - current.height) > 1 else {
            lastAutoFitSize[id] = current
            return
        }
        // Grow upward from the current bottom edge so the panel doesn't creep
        // down the screen as it fills; clamp so it stays on-screen.
        var frame = panel.frame
        let newSize = NSSize(width: current.width, height: targetHeight)
        let delta = targetHeight - current.height
        let contentFrame = panel.frameRect(forContentRect:
            NSRect(origin: .zero, size: newSize))
        frame.size = contentFrame.size
        frame.origin.y -= delta
        if let visible = panel.screen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        lastAutoFitSize[id] = newSize
        panel.setFrame(frame, display: true)
    }

    // MARK: - Hide to bubble ("minimize")

    /// Hide `popup` behind a small floating bubble at the right screen
    /// edge. The window is only `orderOut`'d — NOT miniaturized — so its
    /// IME binding survives and `restoreFromBubble` can bring it back
    /// exactly as it was. This is the privacy gesture: tuck a translation
    /// or chat out of sight, restore it with one click on the bubble.
    func hideToBubble(_ popup: PopupPanel) {
        let key = ObjectIdentifier(popup)
        guard bubbleForPopup[key] == nil else { return }  // already hidden
        // Capture the popup's screen BEFORE ordering it out — once a
        // window is hidden `window.screen` goes nil and `NSScreen.main`
        // can resolve to a different display, parking the bubble off on
        // a secondary monitor. Pin the bubble column to the screen the
        // popup was actually on.
        bubbleScreenFrame = popup.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? bubbleScreenFrame
        Log.debug(.popup, "hideToBubble — hiding popup behind bubble", op: "hide")
        popup.orderOut(nil)
        let bubble = makeBubble(restore: { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.restoreFromBubble(popup)
        })
        bubbleForPopup[key] = bubble
        layoutBubbles()
        bubble.orderFrontRegardless()
    }

    /// Bring a hidden popup back: drop its bubble and re-order the
    /// window front. `orderFront` re-shows the same NSPanel (never
    /// destroyed, never miniaturized), so the IME candidate window
    /// rebinds the moment the user taps back into a text field —
    /// the same first-open behavior, not the broken post-miniaturize
    /// state.
    func restoreFromBubble(_ popup: PopupPanel) {
        let key = ObjectIdentifier(popup)
        if let bubble = bubbleForPopup.removeValue(forKey: key) {
            bubble.orderOut(nil)
        }
        Log.debug(.popup, "restoreFromBubble — re-showing popup", op: "hide")
        popup.orderFrontRegardless()
        layoutBubbles()
    }

    /// Build the little click-to-restore bubble. Borderless,
    /// non-activating, floating — same agent traits as the popup so it
    /// rides over full-screen apps too. Hosts `PopupBubbleView`.
    private func makeBubble(restore: @escaping () -> Void) -> NSPanel {
        let size = Self.bubbleSize
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // the SwiftUI bubble draws its own shadow
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: PopupBubbleView(onRestore: restore))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        return p
    }

    private static let bubbleSize = NSSize(width: 56, height: 56)

    /// Visible frame of the screen the bubbles live on — the screen the
    /// most-recently-hidden popup was on. Captured in `hideToBubble`
    /// before the popup is ordered out (after which its screen is nil).
    private var bubbleScreenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// Stack all current bubbles down the right edge of the bubble
    /// screen's visible frame. Re-run whenever a bubble is added or
    /// removed so the column stays gap-free.
    private func layoutBubbles() {
        let screen = bubbleScreenFrame
        let size = Self.bubbleSize
        let margin: CGFloat = 14
        let gap: CGFloat = 10
        let x = screen.maxX - size.width - margin
        var y = screen.maxY - size.height - 90
        for bubble in bubbleForPopup.values {
            bubble.setFrame(NSRect(x: x, y: max(y, screen.minY), width: size.width, height: size.height),
                            display: true)
            y -= (size.height + gap)
        }
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
    /// windows means there's no "current" panel to reuse anymore. Every popup
    /// is `.resizable` so the user can drag any edge/corner; the content
    /// auto-fits the height until they do (see `autoFitIfNeeded`).
    private func createPanel(resizable: Bool = false) -> PopupPanel {
        // IME-SAFE popup design. This is the combination that makes the
        // CJK input-method candidate window render correctly:
        //   - `.nonactivatingPanel` + LSUIElement agent mode
        //   - `.floating` level + `.fullScreenAuxiliary`
        // Do NOT add `.miniaturizable` / native minimize here: minimizing
        // and restoring the panel loses the IME binding (the candidate
        // window stops appearing), which is a worse regression than the
        // missing feature. (Confirmed empirically — "minimise break the
        // IMK candidate".) The native CLOSE button stays visible at the
        // top-left (standard position); PopupView adds a top inset
        // (`trafficLightInset`) so the source text no longer sits under
        // it ("a close button on the left of the selection").
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
        // Deliberately NOT `isMovableByWindowBackground`: a body-grab would
        // then MOVE the window and compete with the edge resize border (the
        // thin strip where the ↔ resize cursor appears), making the popup
        // hard to resize. The user resizes from any edge/corner; the window
        // can still be moved by dragging the transparent title-bar strip at
        // the top (the `.titled` region behind the traffic-light inset).
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        // Don't release on close — we control the lifetime via `panels`.
        p.isReleasedWhenClosed = false
        // `.fullScreenAuxiliary` lets the popup overlay a full-screen
        // source app without switching out of its space — part of the
        // IME-safe combination above.
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        // Native close button at top-left (standard). Minimize + zoom
        // hidden — minimize breaks IME, and maximizing a lookup popup
        // makes no sense.
        p.standardWindowButton(.closeButton)?.isHidden = false
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }
}

/// The little floating mascot the user clicks to bring a hidden popup
/// back. Lives at the right screen edge while its popup is hidden;
/// clicking calls `onRestore`. Deliberately tiny and self-shadowing so
/// it reads as an unobtrusive "peek" affordance rather than a window.
private struct PopupBubbleView: View {
    let onRestore: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onRestore) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: hovering ? 9 : 5, y: 2)
                if let mascot = NSImage(named: "StatusItemIcon") {
                    Image(nsImage: mascot)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(3)
            .frame(width: 56, height: 56)
            .scaleEffect(hovering ? 1.07 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Show Glotty"))
    }
}
