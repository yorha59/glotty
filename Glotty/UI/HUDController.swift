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
    private static let contentSize = NSSize(width: 320, height: 210)
    /// Margin around the visible card inside the panel — gives
    /// SwiftUI's `.shadow(radius: 22, y: 8)` room to spill past the
    /// rounded rectangle. Without this the shadow clips at the
    /// panel's rectangular bounds, producing visible square
    /// "shadow corners" especially top-left where the shadow
    /// travels furthest. The HUDView's body wraps its content in
    /// `.padding(shadowMargin)` to keep the visible card at
    /// `contentSize` while the panel itself is larger.
    private static let shadowMargin: CGFloat = 32
    /// Outer panel size — content + shadow margin on every side.
    private static var panelSize: NSSize {
        NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
    }

    func show() {
        let panel = ensurePanel()

        let host = NSHostingView(rootView: HUDView())
        host.frame = NSRect(origin: .zero, size: HUDController.panelSize)
        panel.contentView = host
        panel.setContentSize(HUDController.panelSize)

        // Center the visible glass card horizontally on the active
        // screen, ~25% down from the top. The panel is panelSize
        // (content + shadowMargin*2), but the user perceives it as
        // contentSize — subtract the margin from origin so the visible
        // card lands where they expect, with the invisible shadow
        // buffer extending outward into the surrounding desktop.
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - HUDController.contentSize.width / 2 - HUDController.shadowMargin
        let originY = screenFrame.maxY - HUDController.contentSize.height - screenFrame.height * 0.25 - HUDController.shadowMargin
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
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
            Text("\(String(localized: "Release")) \(Keycode.currentLeader().label) \(String(localized: "to cancel"))")
                .font(.caption2)
                .foregroundStyle(hintColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(glassmorphism)
        // Padding around the visible glass card so the .shadow() on
        // glassmorphism has room to draw without being clipped at the
        // NSPanel's rectangular bounds. Matches `HUDController.shadowMargin`.
        .padding(32)
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
