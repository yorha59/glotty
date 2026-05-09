import AppKit
import SwiftUI

@MainActor
final class PopupController {
    private var panel: NSPanel?
    private static let size = NSSize(width: 380, height: 200)

    func show(sourceText: String) {
        let panel = ensurePanel()

        let host = NSHostingView(rootView: PopupView(
            sourceText: sourceText,
            onClose: { [weak self] in self?.dismiss() }
        ))
        host.frame = NSRect(origin: .zero, size: PopupController.size)
        panel.contentView = host
        panel.setContentSize(PopupController.size)

        // Place near the cursor, clamped on-screen
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = min(max(mouse.x, screenFrame.minX),
                          screenFrame.maxX - PopupController.size.width)
        let originY = max(mouse.y - PopupController.size.height - 8, screenFrame.minY)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: PopupController.size),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
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
