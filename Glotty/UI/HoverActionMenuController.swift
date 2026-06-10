import AppKit
import SwiftUI

/// Floating action menu shown when the pointer dwells over a text selection
/// (driven by `SelectionHoverWatcher`). Lists the same commands as the leader
/// HUD — Translate / Explain / Polish / Chat / Correct spelling — each a
/// clickable row that runs exactly what the corresponding hotkey does.
///
/// Like the other Glotty popups it's a `.nonactivatingPanel`, so the source
/// app keeps focus and its selection while the menu is up — which is what lets
/// the clicked action re-grab the same selection.
@MainActor
final class HoverActionMenuController {
    static let shared = HoverActionMenuController()

    struct Item {
        let icon: String
        let label: String
        let run: () -> Void
    }

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onDismiss: (() -> Void)?
    private let shadowMargin: CGFloat = 10

    var isVisible: Bool { panel != nil }
    /// The menu's window frame (for the watcher's "is the cursor still over the
    /// menu or selection" hit-test).
    var frame: NSRect? { panel?.frame }

    func show(items: [Item], nearAXRect axRect: CGRect?, onDismiss: @escaping () -> Void) {
        dismiss(notify: false)
        guard !items.isEmpty else { return }
        self.onDismiss = onDismiss

        let view = HoverMenuView(items: items) { [weak self] in self?.dismiss(notify: true) }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 2 || size.height < 2 { size = fallbackSize(rowCount: items.count) }
        host.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.contentView = host
        p.setContentSize(size)
        p.setFrameOrigin(origin(forAXRect: axRect, size: size))
        p.orderFrontRegardless()
        panel = p

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss(notify: true)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.dismiss(notify: true); return nil }
            return e
        }
    }

    func dismiss(notify: Bool = true) {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        let cb = onDismiss
        onDismiss = nil
        if notify { cb?() }
    }

    // MARK: - Placement (mirrors SpellCandidateController)

    private func origin(forAXRect axRect: CGRect?, size: NSSize) -> NSPoint {
        let gap: CGFloat = 2
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0

        var anchorX: CGFloat
        var anchorBottomY: CGFloat
        let wordTopY: CGFloat
        if let axRect, primaryHeight > 0 {
            anchorX = axRect.minX
            anchorBottomY = primaryHeight - axRect.maxY
            wordTopY = primaryHeight - axRect.minY
        } else {
            let mouse = NSEvent.mouseLocation
            anchorX = mouse.x
            anchorBottomY = mouse.y
            wordTopY = mouse.y + 16
        }

        var origin = NSPoint(x: anchorX - shadowMargin,
                             y: anchorBottomY - gap - size.height + shadowMargin)

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorX, y: anchorBottomY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if origin.y < vf.minY {
            origin.y = wordTopY + gap - shadowMargin
        }
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        return origin
    }

    private func fallbackSize(rowCount: Int) -> NSSize {
        let rows = CGFloat(max(1, rowCount))
        let rowHeight: CGFloat = 32
        let cardWidth: CGFloat = 260
        let vStackPadding: CGFloat = 12
        let height = 2 * shadowMargin + vStackPadding + rows * rowHeight + (rows - 1)
        return NSSize(width: cardWidth + 2 * shadowMargin, height: height)
    }
}

private struct HoverMenuView: View {
    let items: [HoverActionMenuController.Item]
    let onPicked: () -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                Button {
                    onPicked()
                    item.run()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 18)
                        Text(item.label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hovered == idx ? Color.accentColor.opacity(0.85) : .clear)
                    )
                    .foregroundStyle(hovered == idx ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? idx : (hovered == idx ? nil : hovered) }
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
        .padding(10)
    }
}
