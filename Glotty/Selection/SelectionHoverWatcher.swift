import AppKit

/// Alternative, shortcut-free trigger: when the pointer rests over an existing
/// text selection for a short dwell, pop up `HoverActionMenuController` with the
/// same commands as the leader HUD. Polls the mouse on a light timer (no global
/// event tap), and only ever queries Accessibility once the pointer has gone
/// still — so it costs nothing while you're moving the cursor or reading without
/// a selection. Opt-out via Settings (`glotty.hover.enabled`).
@MainActor
final class SelectionHoverWatcher {
    enum Kind { case translate, explain, polish, chat, speak }

    /// Set by AppDelegate to run the chosen command (same handlers the hotkeys
    /// use). The selection is still live because the menu is non-activating.
    var onAction: ((Kind) -> Void)?

    static let enabledKey = "glotty.hover.enabled"
    static let dwellKey = "glotty.hover.dwell"
    /// Default dwell before the menu appears, and the bounds the Settings slider
    /// (and any stored value) is clamped to.
    static let defaultDwell = 0.6
    static let dwellRange: ClosedRange<Double> = 0.1...5.0

    private let grabber: SelectionGrabber
    private var timer: Timer?

    private var lastPos: NSPoint = .zero
    private var lastMoveAt: CFAbsoluteTime = 0
    private var restChecked = false          // one AX probe per rest period
    private var cooldownUntil: CFAbsoluteTime = 0
    private var shownSelectionRect: CGRect?  // Cocoa rect of the selection the menu is currently showing for
    /// Last selected text we observed — used to detect a *fresh* selection (so
    /// the bar fires once per selection, not on every rest).
    private var lastSelectionText: String?
    /// Where the most recent left-mouse-up landed (where a drag-select ends) and
    /// when. The bar only fires while the pointer is still resting there — i.e.
    /// the user selected and DIDN'T move away.
    private var lastMouseUpPos: NSPoint?
    private var lastMouseUpAt: CFAbsoluteTime = 0
    private var mouseUpMonitor: Any?
    /// How far the pointer may be from the selection-end point and still count
    /// as "didn't move after selecting".
    private let selectionEndTolerance: CGFloat = 12

    private let pollInterval: CFTimeInterval = 0.15
    private let moveThreshold: CGFloat = 3

    /// Read live from UserDefaults so the Settings slider takes effect without a
    /// relaunch. Clamped to `dwellRange`.
    private var dwell: CFTimeInterval {
        let v = UserDefaults.standard.object(forKey: Self.dwellKey) as? Double ?? Self.defaultDwell
        return min(max(v, Self.dwellRange.lowerBound), Self.dwellRange.upperBound)
    }

    init(grabber: SelectionGrabber) {
        self.grabber = grabber
    }

    func start() {
        guard timer == nil else { return }
        lastPos = NSEvent.mouseLocation
        lastMoveAt = CFAbsoluteTimeGetCurrent()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Track where drag-selections end (the last left-mouse-up) in other
        // apps. The hover bar only fires while the pointer is still resting at
        // that point — so moving the cursor after selecting cancels it.
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pos = NSEvent.mouseLocation
                    let now = CFAbsoluteTimeGetCurrent()
                    self.lastMouseUpPos = pos
                    self.lastMouseUpAt = now
                    // Enable AX on the app the user just selected in, early — a
                    // Chromium app needs a beat to build its tree before the
                    // dwell probe reads the selection.
                    self.grabber.enableManualAccessibility()
                    // Re-arm the dwell from the release. A long selection often
                    // holds the cursor still mid-drag (a pause or auto-scroll),
                    // which fires a probe and sets restChecked=true; without
                    // this reset the post-release probe would be skipped because
                    // the cursor "didn't move" after the mouse-up.
                    self.restChecked = false
                    self.lastMoveAt = now
                    self.lastPos = pos
                }
            }
        }
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func tick() {
        let menu = HoverActionMenuController.shared

        guard enabled else {
            if menu.isVisible { menu.dismiss(notify: false); resetState() }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let pos = NSEvent.mouseLocation

        // While the menu is up, keep it only while the pointer stays over the
        // menu or the selection it belongs to.
        if menu.isVisible {
            let overMenu = menu.frame.map { $0.insetBy(dx: -8, dy: -8).contains(pos) } ?? false
            let overSel = shownSelectionRect.map { $0.insetBy(dx: -10, dy: -10).contains(pos) } ?? false
            if !overMenu && !overSel { menu.dismiss(notify: true) }
            return
        }

        // Track movement vs. stillness.
        if hypot(pos.x - lastPos.x, pos.y - lastPos.y) > moveThreshold {
            lastPos = pos
            lastMoveAt = now
            restChecked = false
            return
        }

        // Pointer is still — probe once per rest, after the dwell, past cooldown.
        // `restChecked` (reset on the next movement) is what prevents flashing;
        // re-resting after any move legitimately re-triggers the menu.
        guard !restChecked, now - lastMoveAt >= dwell, now >= cooldownUntil else { return }
        restChecked = true

        guard let sel = grabber.hoverSelection() else {
            lastSelectionText = nil
            return
        }
        // Fire only right after a NEW selection that the user hasn't moved away
        // from: (1) the selected text just changed, and (2) the pointer is still
        // resting where the selection ended (the last mouse-up). Moving the
        // cursor after selecting → no bar. Works the same in native apps and in
        // Chromium/Electron (no selection-bounds needed for the gate).
        guard sel.text != lastSelectionText else { return }
        guard let up = lastMouseUpPos,
              now - lastMouseUpAt < 5,
              hypot(pos.x - up.x, pos.y - up.y) <= selectionEndTolerance else { return }
        lastSelectionText = sel.text

        // Anchor under the selection when we have its bounds, otherwise at the
        // pointer. The hit region (for keeping the menu up) is the selection /
        // element frame, or a small area around the pointer as a last resort.
        let hitAX = sel.selectionRect ?? sel.elementFrame
        let hitCocoa = hitAX.map { cocoaRect(fromAX: $0) }
            ?? CGRect(x: pos.x - 20, y: pos.y - 12, width: 40, height: 24)
        present(axRect: sel.selectionRect, hitCocoa: hitCocoa)
    }

    private func present(axRect: CGRect?, hitCocoa: CGRect) {
        shownSelectionRect = hitCocoa
        HoverActionMenuController.shared.show(items: buildItems(), nearAXRect: axRect) { [weak self] in
            guard let self else { return }
            // Short cooldown only — so a dismiss can't instantly re-fire in the
            // same beat, but re-hovering shortly after works.
            self.shownSelectionRect = nil
            self.cooldownUntil = CFAbsoluteTimeGetCurrent() + 0.2
        }
    }

    private func buildItems() -> [HoverActionMenuController.Item] {
        // Concise labels — this is a click menu, not the keyboard reference, so
        // the verb alone reads cleaner than the HUD's "Translate to <lang>".
        func item(_ icon: String, _ label: String, _ kind: Kind) -> HoverActionMenuController.Item {
            .init(icon: icon, label: label) { [weak self] in self?.onAction?(kind) }
        }
        return [
            item("globe", String(localized: "Translate"), .translate),
            item("lightbulb", String(localized: "Explain"), .explain),
            item("wand.and.stars", String(localized: "Polish"), .polish),
            item("bubble.left.and.bubble.right", String(localized: "Chat"), .chat),
            item("speaker.wave.2.fill", String(localized: "Speak aloud"), .speak),
        ]
    }

    private func resetState() {
        shownSelectionRect = nil
        restChecked = false
        lastSelectionText = nil
    }

    /// AX rect (top-left origin, primary-screen space) → Cocoa rect (bottom-left).
    private func cocoaRect(fromAX r: CGRect) -> CGRect {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }
                        ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }
}
