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
    /// Height tuned to fit four command rows (Translate, Explain,
    /// Polish, Chat).
    private static let size = NSSize(width: 320, height: 210)

    func show() {
        let panel = ensurePanel()

        let host = NSHostingView(rootView: HUDView())
        host.frame = NSRect(origin: .zero, size: HUDController.size)
        panel.contentView = host
        panel.setContentSize(HUDController.size)

        // Center horizontally on the active screen, ~25% down from the top.
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - HUDController.size.width / 2
        let originY = screenFrame.maxY - HUDController.size.height - screenFrame.height * 0.25
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDController.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel = p
        return p
    }
}

/// Translucent dark HUD — uses `.ultraThinMaterial` so it adapts to the desktop
/// behind it in both light and dark modes (matches the previous design after a
/// brief Figma-styled detour).
private struct HUDView: View {
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
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("Glotty")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Keycode.currentLeader().label) \(String(localized: "held"))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Divider().background(.white.opacity(0.15))
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
                                     HUDView.polishLangName))
            Text("\(String(localized: "Release")) \(Keycode.currentLeader().label) \(String(localized: "to cancel"))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(glassmorphism)
        .colorScheme(.dark)
        .localizationAware()
    }

    /// Glassmorphism panel — frosted backdrop blur (NSVisualEffectView
    /// via `.thickMaterial`) with a dark tint laid on top so white
    /// text reads clearly against any desktop. A faint diagonal
    /// highlight at the top gives the "glass" sheen; the hairline
    /// white border defines the edges.
    private var glassmorphism: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(.thickMaterial)
            .overlay(
                // Dark wash for legibility — the material alone reads
                // too bright in many desktops behind. ~55% black puts
                // us back into a dark, readable panel without losing
                // the backdrop blur.
                shape.fill(Color.black.opacity(0.55))
            )
            .overlay(
                // Soft diagonal highlight along the top edge — the
                // subtle "wet glass" cue without lightening the
                // overall panel.
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 22, y: 8)
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
        HStack(spacing: 10) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        )
                )
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
    }
}
