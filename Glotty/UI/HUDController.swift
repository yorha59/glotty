import AppKit
import SwiftUI

/// Floating, non-activating HUD shown while the Fn leader key is held.
/// Lists available commands so the user can learn / confirm before pressing the second key.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private static let size = NSSize(width: 320, height: 150)

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
                       label: "Translate selection")
            commandRow(key: Keycode.label(for: Keycode.currentPolish()),
                       label: "Polish to idiomatic")
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
