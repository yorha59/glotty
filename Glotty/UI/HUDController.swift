import AppKit
import SwiftUI

/// Floating, non-activating HUD shown while the Fn leader key is held.
/// Lists available commands so the user can learn / confirm before pressing the second key.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    /// Height tuned to fit three command rows (Translate, Explain, Polish).
    /// Practice/Chat is proactive-only — no hotkey, no HUD row.
    private static let size = NSSize(width: 320, height: 178)

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
                Image(systemName: "globe")
                    .foregroundStyle(.white.opacity(0.85))
                Text("Glotty")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Keycode.currentLeader().label) held")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Divider().background(.white.opacity(0.15))
            commandRow(key: Keycode.label(for: Keycode.currentTranslate()),
                       label: "Translate to \(HUDView.nativeLangName)")
            commandRow(key: Keycode.label(for: Keycode.currentExplain()),
                       label: "Explain in \(HUDView.nativeLangName)")
            commandRow(key: Keycode.label(for: Keycode.currentPolish()),
                       label: "Polish to idiomatic \(HUDView.polishLangName)")
            Text("Release \(Keycode.currentLeader().label) to cancel")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .colorScheme(.dark)
    }

    /// Localized name of the user's native language. Both Translate and
    /// Explain output in this — the saved Translation "target" is where decode
    /// lands its results, by convention also where Explain's prose lands.
    /// Empty pin falls back to English (most common default for our audience).
    static var nativeLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.targetLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localizedName(for: raw.isEmpty ? "en" : raw)
    }

    /// Localized name of the Polish output language — separate from the native
    /// lang because Polish rewrites the user's draft INTO the target tongue
    /// they're learning (e.g. "make my Chinese sound natural"), not back into
    /// the user's native. Settings → Polish → Polish output language drives it.
    static var polishLangName: String {
        let raw = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localizedName(for: raw.isEmpty ? "en" : raw)
    }

    /// `Chinese, Simplified` → `Chinese (Simplified)` to match Figma's convention.
    private static func localizedName(for identifier: String) -> String {
        let raw = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        if let commaRange = raw.range(of: ", ") {
            return "\(raw[..<commaRange.lowerBound]) (\(raw[commaRange.upperBound...]))"
        }
        return raw
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
