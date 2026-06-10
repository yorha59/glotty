import AppKit

/// Alternative, shortcut-free trigger: when the pointer rests over an existing
/// text selection for a short dwell, pop up `HoverActionMenuController` with the
/// same commands as the leader HUD. Polls the mouse on a light timer (no global
/// event tap), and only ever queries Accessibility once the pointer has gone
/// still — so it costs nothing while you're moving the cursor or reading without
/// a selection. Opt-out via Settings (`glotty.hover.enabled`).
@MainActor
final class SelectionHoverWatcher {
    enum Kind { case translate, explain, polish, chat, replace }

    /// Set by AppDelegate to run the chosen command (same handlers the hotkeys
    /// use). The selection is still live because the menu is non-activating.
    var onAction: ((Kind) -> Void)?

    static let enabledKey = "glotty.hover.enabled"
    static let dwellKey = "glotty.hover.dwell"
    /// Default dwell before the menu appears, and the bounds the Settings slider
    /// (and any stored value) is clamped to.
    static let defaultDwell = 0.6
    static let dwellRange: ClosedRange<Double> = 0.2...1.5

    private let grabber: SelectionGrabber
    private var timer: Timer?

    private var lastPos: NSPoint = .zero
    private var lastMoveAt: CFAbsoluteTime = 0
    private var restChecked = false          // one AX probe per rest period
    private var cooldownUntil: CFAbsoluteTime = 0
    private var suppressRect: CGRect?        // Cocoa rect we just showed for; don't reshow until the pointer leaves it
    private var shownSelectionRect: CGRect?  // Cocoa rect of the selection the menu is currently showing for

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
            if let s = suppressRect, !s.contains(pos) { suppressRect = nil }
            return
        }

        // Pointer is still — probe once per rest, after the dwell, past cooldown.
        guard !restChecked, now - lastMoveAt >= dwell, now >= cooldownUntil else { return }
        restChecked = true
        if let s = suppressRect, s.contains(pos) { return }

        guard let sel = grabber.hoverSelection() else { return }
        // Hit-test against the precise selection bounds when available, else the
        // focused element's frame. Anchor the menu under the selection when we
        // have its rect, otherwise at the pointer.
        guard let hitAX = sel.selectionRect ?? sel.elementFrame else { return }
        let hitCocoa = cocoaRect(fromAX: hitAX)
        guard hitCocoa.insetBy(dx: -6, dy: -6).contains(pos) else { return }

        present(axRect: sel.selectionRect, hitCocoa: hitCocoa)
    }

    private func present(axRect: CGRect?, hitCocoa: CGRect) {
        shownSelectionRect = hitCocoa
        HoverActionMenuController.shared.show(items: buildItems(), nearAXRect: axRect) { [weak self] in
            guard let self else { return }
            // Re-arm: suppress until the pointer leaves this selection, with a
            // short cooldown so the menu can't immediately flash back.
            self.suppressRect = self.shownSelectionRect
            self.shownSelectionRect = nil
            self.cooldownUntil = CFAbsoluteTimeGetCurrent() + 0.25
        }
    }

    private func buildItems() -> [HoverActionMenuController.Item] {
        let native = Self.nativeLangName
        let polish = Self.polishLangName
        func item(_ icon: String, _ label: String, _ kind: Kind) -> HoverActionMenuController.Item {
            .init(icon: icon, label: label) { [weak self] in self?.onAction?(kind) }
        }
        return [
            item("globe", String(format: String(localized: "Translate to %@"), native), .translate),
            item("lightbulb", String(format: String(localized: "Explain in %@"), native), .explain),
            item("wand.and.stars",
                 String(format: String(localized: "Polish to idiomatic %@"), polish), .polish),
            item("bubble.left.and.bubble.right",
                 String(format: String(localized: "Chat with Glotty in %@"), native), .chat),
            item("textformat.abc",
                 String(localized: "Correct the selected word's spelling"), .replace),
        ]
    }

    private func resetState() {
        shownSelectionRect = nil
        suppressRect = nil
        restChecked = false
    }

    /// AX rect (top-left origin, primary-screen space) → Cocoa rect (bottom-left).
    private func cocoaRect(fromAX r: CGRect) -> CGRect {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }
                        ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    // Localized language names — mirror HUDController's helpers so the hover
    // menu labels read identically to the leader HUD.
    static var nativeLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.targetLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanguageOptions.localizedName(for: raw.isEmpty ? "en" : raw)
    }
    static var polishLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanguageOptions.localizedName(for: raw.isEmpty ? "en" : raw)
    }
}
