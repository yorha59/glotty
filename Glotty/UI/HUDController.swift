import AppKit
import SwiftUI

/// Floating, non-activating HUD shown while the Fn leader key is held.
/// Lists available commands so the user can learn / confirm before pressing the second key.
@MainActor
final class HUDController {
    /// Process-wide instance. Settings and the snapshotter reach
    /// the HUD through this — the AppDelegate also holds a
    /// reference so the singleton survives across notifications.
    static let shared = HUDController()

    private var panel: NSPanel?
    /// Exposed for the debug snapshotter so it can capture the
    /// HUD's content view via NSView bitmap. Read-only.
    var currentPanel: NSPanel? { panel }
    /// Visible glass-card size (header + 4 command rows + footer).
    /// `fileprivate` so `HUDView` can size its own card to match.
    fileprivate static let contentSize = NSSize(width: 320, height: 210)
    /// Margin around the visible card inside the panel — gives
    /// SwiftUI's `.shadow(radius: 22, y: 8)` room to spill past the
    /// rounded rectangle. Without this the shadow clips at the
    /// panel's rectangular bounds, producing visible square
    /// "shadow corners" especially top-left where the shadow
    /// travels furthest. The HUDView's body wraps its content in
    /// `.padding(shadowMargin)` to keep the visible card at
    /// `contentSize` while the panel itself is larger.
    fileprivate static let shadowMargin: CGFloat = 32
    /// Outer panel size — content + shadow margin on every side.
    private static var panelSize: NSSize {
        NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
    }

    func show() {
        // A fresh Fn-hold cancels any pending hint auto-dismiss so the
        // hint timer can't later hide the real (newly-shown) leader HUD.
        hintDismiss?.cancel()
        present(HUDView())
    }

    /// Re-show the leader HUD with a transient hint line at its bottom.
    /// Used when a leader action can't proceed — e.g. Fn→Translate fired
    /// with nothing selected. Folding the message into the HUD (instead of
    /// a separate toast window) keeps it reading as one surface, and the
    /// command list above doubles as a reminder of what each chord needs.
    /// Auto-dismisses after `duration`.
    func showHint(_ message: String,
                  systemImage: String = "character.cursor.ibeam",
                  duration: TimeInterval = 2.6) {
        hintDismiss?.cancel()
        present(HUDView(hint: message, hintImage: systemImage))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hintDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private var hintDismiss: DispatchWorkItem?

    /// Size the HUD to its content (so an optional hint row doesn't clip),
    /// center the visible card horizontally ~25% down the active screen,
    /// and show it.
    private func present(_ rootView: HUDView) {
        let panel = ensurePanel()

        let host = NSHostingView(rootView: rootView)
        // Drive the panel size from the content's fitting size rather than
        // a fixed frame — the card grows by a row when a hint is present.
        host.sizingOptions = []
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)

        // `size` includes the shadow margin on every side; the user
        // perceives only the inner card (size − margin*2). Offset by the
        // margin so that visible card lands centered, ~25% down from top,
        // with the invisible shadow buffer spilling into the desktop.
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - size.width / 2
        let originY = screenFrame.maxY - size.height
            - screenFrame.height * 0.25 + HUDController.shadowMargin
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Transient hint toast

    /// Separate, lighter panel from the leader HUD so a hint can show
    /// the moment after the leader key is released (which hides the
    /// HUD) without the two fighting over one window.
    private var toastPanel: NSPanel?
    private var toastDismiss: DispatchWorkItem?

    /// Brief, non-interactive glass toast near the top of the active
    /// screen. Used to HINT the user when an action can't proceed —
    /// e.g. Fn→Translate fired with nothing selected — instead of
    /// failing silently, which reads as "the app is broken". Auto-
    /// dismisses after `duration`; repeated calls replace the prior toast.
    func toast(_ message: String,
               systemImage: String = "character.cursor.ibeam",
               duration: TimeInterval = 2.2) {
        toastDismiss?.cancel()
        let p = ensureToastPanel()
        let host = NSHostingView(rootView: HUDToastView(message: message, systemImage: systemImage))
        // Stop the hosting view from driving the panel's size off the
        // SwiftUI content's intrinsic size — left on, a `.frame(maxHeight:
        // .infinity)` content stretched the window to ~600pt tall and the
        // text got vertically centered off-screen. We size the panel
        // ourselves from the content's fitting size instead.
        host.sizingOptions = []
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setContentSize(size)

        // Place the toast on the screen the user is actually working on
        // (under the mouse), not always the primary — matches where the
        // popup appears and where they just tried to select text.
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - size.width / 2
        let originY = screenFrame.maxY - size.height - screenFrame.height * 0.18
        p.setFrameOrigin(NSPoint(x: originX, y: originY))

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let tp = self?.toastPanel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                tp.animator().alphaValue = 0
            }, completionHandler: { tp.orderOut(nil) })
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func ensureToastPanel() -> NSPanel {
        if let toastPanel { return toastPanel }
        // Initial size is a placeholder — `toast(_:)` resizes the panel
        // to the content's fitting size before showing it.
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        // `.fullScreenAuxiliary` so the hint still shows when the user
        // is in another app's full-screen space (a common moment to
        // fire Fn→Translate on selected text and get nothing back).
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        toastPanel = p
        return p
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDController.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        // AppKit's window-level shadow follows the panel's RECTANGULAR
        // bounds, not the rounded SwiftUI content inside — that draws
        // a visible square shadow halo poking out past the rounded
        // corners (the "圆角不对" report). Disable it here and let
        // SwiftUI's `.shadow()` on the glassmorphism RoundedRectangle
        // produce a shadow that matches the rounded shape.
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel = p
        return p
    }
}

/// Translucent HUD that adapts to the system colorScheme. Previously
/// hardcoded dark (with `.colorScheme(.dark)` + white text); a user on
/// a light-mode Mac reported the panel still came up dark, which read
/// as a bug. Now uses `@Environment(\.colorScheme)` plus semantic
/// colors so light-mode users get a matching panel.
private struct HUDView: View {
    /// When set, the HUD shows this as a hint row at its bottom (in place
    /// of the "Release … to cancel" footer) — see `HUDController.showHint`.
    var hint: String? = nil
    var hintImage: String = "character.cursor.ibeam"
    @Environment(\.colorScheme) private var colorScheme

    private var titleColor: Color { colorScheme == .dark ? .white : .black }
    private var secondaryColor: Color {
        colorScheme == .dark ? .white.opacity(0.55) : .black.opacity(0.55)
    }
    private var dividerColor: Color {
        colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.10)
    }
    private var hintColor: Color {
        colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.45)
    }
    private var mascotTint: Color {
        colorScheme == .dark ? .white.opacity(0.85) : .black.opacity(0.85)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Use the actual menu-bar mascot here so the HUD
                // matches the icon the user just clicked on / saw
                // animate. The globe SF symbol fallback only kicks
                // in during dev builds where the asset is missing.
                if let mascot = NSImage(named: "StatusItemIcon") {
                    Image(nsImage: mascot)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(mascotTint)
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(mascotTint)
                }
                Text("Glotty")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(titleColor)
                Spacer()
                Text("\(Keycode.currentLeader().label) \(String(localized: "held"))")
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
            }
            Divider().background(dividerColor)
            // Use full %@ format strings rather than concat-with-prefix:
            // Chinese (and other) word orders place the language name
            // BEFORE the verb (e.g. "用中文解释"), which a bare
            // "Explain in" + " 中文" prefix-concat can't express. The
            // %@-style key lets each locale put the placeholder
            // wherever it reads naturally, including wrapping it in
            // matching parens.
            commandRow(key: Keycode.label(for: Keycode.currentTranslate()),
                       label: String(format: String(localized: "Translate to %@"),
                                     HUDView.nativeLangName))
            commandRow(key: Keycode.label(for: Keycode.currentExplain()),
                       label: String(format: String(localized: "Explain in %@"),
                                     HUDView.nativeLangName))
            commandRow(key: Keycode.label(for: Keycode.currentPolish()),
                       label: String(format: String(localized: "Polish to idiomatic %@"),
                                     HUDView.polishLangName))
            commandRow(key: Keycode.label(for: Keycode.currentChat()),
                       label: String(format: String(localized: "Chat with Glotty in %@"),
                                     HUDView.nativeLangName))
            commandRow(key: Keycode.label(for: Keycode.currentReplace()),
                       label: String(localized: "Correct the selected word's spelling"))
            commandRow(key: Keycode.label(for: Keycode.currentSpeak()),
                       label: String(localized: "Speak the selection aloud"))
            if let hint {
                Divider().background(dividerColor)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: hintImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(titleColor.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                Text("\(String(localized: "Release")) \(Keycode.currentLeader().label) \(String(localized: "to cancel"))")
                    .font(.caption2)
                    .foregroundStyle(hintColor)
            }
        }
        .padding(14)
        // Fixed width, intrinsic height — the card grows by a row when a
        // hint is present (HUDController sizes the panel from this).
        .frame(width: HUDController.contentSize.width, alignment: .topLeading)
        .background(glassmorphism)
        // Padding around the visible glass card so the .shadow() on
        // glassmorphism has room to draw without being clipped at the
        // NSPanel's rectangular bounds. Matches `HUDController.shadowMargin`.
        .padding(HUDController.shadowMargin)
        .localizationAware()
    }

    /// Glassmorphism panel — frosted backdrop blur (NSVisualEffectView
    /// via `.thickMaterial`) with a tint matched to the active
    /// colorScheme so the same panel works on both light and dark
    /// desktops. The diagonal highlight + hairline border give the
    /// "glass" sheen on both.
    private var glassmorphism: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let washColor: Color = colorScheme == .dark
            ? Color.black.opacity(0.55)
            : Color.white.opacity(0.55)
        let highlightTop: Color = colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.55)
        let borderColors: [Color] = colorScheme == .dark
            ? [Color.white.opacity(0.28), Color.white.opacity(0.06)]
            : [Color.black.opacity(0.18), Color.black.opacity(0.04)]
        let shadowColor: Color = colorScheme == .dark
            ? Color.black.opacity(0.35)
            : Color.black.opacity(0.18)
        return shape
            .fill(.thickMaterial)
            .overlay(
                // Tint wash for legibility. Dark wash on dark mode keeps
                // the panel readable against bright desktops; light wash
                // on light mode keeps it readable against dark wallpapers
                // without dragging the text into low-contrast territory.
                shape.fill(washColor)
            )
            .overlay(
                // Soft diagonal highlight along the top edge — the
                // subtle "wet glass" cue, brighter in light mode to
                // suggest a frosted-glass top.
                shape.fill(
                    LinearGradient(
                        colors: [highlightTop, Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: borderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: shadowColor, radius: 22, y: 8)
    }

    /// Localized name of the user's native language. Both Translate and
    /// Explain output in this — the saved Translation "target" is where decode
    /// lands its results, by convention also where Explain's prose lands.
    /// Empty pin falls back to English (most common default for our audience).
    static var nativeLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.targetLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanguageOptions.localizedName(for: raw.isEmpty ? "en" : raw)
    }

    /// Localized name of the Polish output language — separate from the native
    /// lang because Polish rewrites the user's draft INTO the target tongue
    /// they're learning (e.g. "make my Chinese sound natural"), not back into
    /// the user's native. Settings → Polish → Polish output language drives it.
    static var polishLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanguageOptions.localizedName(for: raw.isEmpty ? "en" : raw)
    }

    private func commandRow(key: String, label: String) -> some View {
        let isDark = colorScheme == .dark
        let keyTextColor: Color = isDark ? .white : .black
        let keyFill: Color = isDark ? .white.opacity(0.12) : .black.opacity(0.08)
        let keyStroke: Color = isDark ? .white.opacity(0.18) : .black.opacity(0.18)
        let labelColor: Color = isDark ? .white.opacity(0.9) : .black.opacity(0.82)
        return HStack(spacing: 10) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .foregroundStyle(keyTextColor)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(keyFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(keyStroke, lineWidth: 0.5)
                        )
                )
            Text(label)
                .font(.callout)
                .foregroundStyle(labelColor)
            Spacer()
        }
    }
}

/// Compact glass toast for transient hints (see `HUDController.toast`).
/// Mirrors the leader HUD's glassmorphism so the two read as one design
/// language, but holds just an icon + a short message.
private struct HUDToastView: View {
    let message: String
    let systemImage: String
    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Definite width so the panel can size itself from the content's
        // fitting size; height stays intrinsic (1–2 wrapped lines).
        .frame(width: 264, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(glass)
        // Match HUDController.shadowMargin so the .shadow() has room to
        // draw without clipping at the panel's rectangular bounds.
        .padding(32)
        .localizationAware()
    }

    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let wash: Color = colorScheme == .dark
            ? Color.black.opacity(0.50) : Color.white.opacity(0.50)
        let border: Color = colorScheme == .dark
            ? Color.white.opacity(0.20) : Color.black.opacity(0.12)
        let shadow: Color = colorScheme == .dark
            ? Color.black.opacity(0.35) : Color.black.opacity(0.18)
        return shape
            .fill(.thickMaterial)
            .overlay(shape.fill(wash))
            .overlay(shape.strokeBorder(border, lineWidth: 0.8))
            .shadow(color: shadow, radius: 18, y: 6)
    }
}
