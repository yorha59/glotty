import AppKit
import SwiftUI

@MainActor
final class PopupController {
    private var panel: NSPanel?
    private static let translateSize = NSSize(width: 460, height: 520)

    /// Polish output is intrinsically larger (multi-variant + issues list) — default
    /// to ~70% of the visible screen height so it doesn't scroll on first glance.
    /// User can resize from there.
    private static func polishSize(on screen: NSRect) -> NSSize {
        let w = min(720, max(560, screen.width * 0.40))
        let h = min(900, max(640, screen.height * 0.70))
        return NSSize(width: w, height: h)
    }

    func show(sourceText: String, mode: PopupMode = .translate) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let size: NSSize
        switch mode {
        case .translate: size = Self.translateSize
        case .polish:    size = Self.polishSize(on: screenFrame)
        }

        // Polish is user-resizable; translate is fixed-ish. We use NSHostingView (not
        // NSHostingController) because the popup body contains a ScrollView, and
        // `.preferredContentSize` on a hosting controller around an unbounded-intrinsic
        // ScrollView crashes the auto-layout pass.
        let resizable = mode == .polish
        let panel = ensurePanel(resizable: resizable)

        let host = NSHostingView(rootView: PopupView(
            sourceText: sourceText,
            mode: mode,
            onClose: { [weak self] in self?.dismiss() }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        if resizable {
            panel.minSize = NSSize(width: 420, height: 480)
        }

        let originX = min(max(mouse.x, screenFrame.minX),
                          screenFrame.maxX - size.width)
        let originY = max(mouse.y - size.height - 8, screenFrame.minY)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Panel is rebuilt when resizability changes (style mask is fixed at construction).
    private func ensurePanel(resizable: Bool) -> NSPanel {
        let currentlyResizable = panel?.styleMask.contains(.resizable) ?? false
        if let existing = panel, currentlyResizable == resizable {
            return existing
        }
        panel?.orderOut(nil)
        var mask: NSWindow.StyleMask = [
            .nonactivatingPanel, .titled, .closable, .fullSizeContentView,
        ]
        if resizable { mask.insert(.resizable) }
        let p = NSPanel(
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
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive — pick one.
        p.collectionBehavior = [.moveToActiveSpace, .transient]
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        panel = p
        return p
    }
}
