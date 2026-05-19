import AppKit
import SwiftUI

@MainActor
final class PopupController {
    private var panel: NSPanel?
    private var translateHost: NSHostingController<PopupView>?
    /// Initial size for the translate panel before SwiftUI reports its intrinsic
    /// height. The hosting controller's `preferredContentSize` takes over right
    /// after the first layout pass, so this is just a placeholder so the panel
    /// doesn't flash at zero-size.
    private static let translateInitialSize = NSSize(width: 460, height: 240)

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

        let resizable = mode == .polish
        let panel = ensurePanel(resizable: resizable)

        let rootView = PopupView(
            sourceText: sourceText,
            mode: mode,
            onClose: { [weak self] in self?.dismiss() }
        )

        let initialSize: NSSize
        switch mode {
        case .translate, .express:
            // Auto-fit: NSHostingController with .preferredContentSize tells the
            // panel to resize itself whenever the SwiftUI content's intrinsic
            // size changes (initial layout, async translation arriving, dict
            // result appearing). Express produces shorter content than translate
            // (no phonetics / dict sections) so the panel ends up smaller — but
            // the sizing mechanism is the same.
            let host = NSHostingController(rootView: rootView)
            host.sizingOptions = [.preferredContentSize]
            panel.contentViewController = host
            translateHost = host
            host.view.layoutSubtreeIfNeeded()
            let preferred = host.preferredContentSize
            initialSize = (preferred.width > 0 && preferred.height > 0)
                ? preferred
                : Self.translateInitialSize
            panel.setContentSize(initialSize)
        case .polish:
            translateHost = nil
            let size = Self.polishSize(on: screenFrame)
            let host = NSHostingView(rootView: rootView)
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            panel.setContentSize(size)
            panel.minSize = NSSize(width: 420, height: 480)
            initialSize = size
        }

        let originX = min(max(mouse.x, screenFrame.minX),
                          screenFrame.maxX - initialSize.width)
        let originY = max(mouse.y - initialSize.height - 8, screenFrame.minY)
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
