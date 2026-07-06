import AppKit
import SwiftUI

/// A small floating list of spelling suggestions, anchored just under the word
/// the user selected. Used by Fn → R when there's more than one candidate: the
/// user clicks one and it's written back over the selection.
///
/// The panel is `.nonactivatingPanel` and never becomes key, so the source
/// app's text field keeps focus and selection — that's what lets the click-
/// through replace (AX set / Cmd+V) land on the right field.
@MainActor
final class SpellCandidateController {
    static let shared = SpellCandidateController()

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Transparent margin baked into the SwiftUI view so its drop shadow isn't
    /// clipped by the panel bounds. Mirrors HUDController's shadow handling.
    private let shadowMargin: CGFloat = 10

    func show(candidates: [String],
              nearAXRect axRect: CGRect?,
              onPick: @escaping (String) -> Void) {
        dismiss()
        guard !candidates.isEmpty else { return }

        let view = SpellCandidateView(candidates: candidates) { [weak self] word in
            self?.dismiss()
            onPick(word)
        }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        // Belt-and-suspenders: if the hosting view reports a degenerate size
        // (it has before), fall back to a deterministic size derived from the
        // fixed card width + row count, so we never show a 0×0 panel.
        if size.width < 2 || size.height < 2 {
            size = fallbackSize(rowCount: candidates.count)
        }
        host.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false   // shadow is drawn inside the SwiftUI card
        p.contentView = host
        p.setContentSize(size)
        p.setFrameOrigin(origin(forAXRect: axRect, size: size))
        p.orderFrontRegardless()
        panel = p

        // Click anywhere outside (i.e. in another app) dismisses. Clicks on the
        // candidates are local events, so they fire the button first.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        // Esc dismisses.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.dismiss(); return nil }
            return e
        }
    }

    func dismiss() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    /// Place the list so the **whole panel** stays inside the visible frame —
    /// anchored just under the word, flipped above when it would drop off the
    /// bottom, then hard-clamped on all four sides as a final safety net so it
    /// can never end up half off-screen regardless of the AX geometry. Falls
    /// back to the mouse location when there's no AX rect.
    private func origin(forAXRect axRect: CGRect?, size: NSSize) -> NSPoint {
        let gap: CGFloat = 2

        // AX rects are flipped (top-left origin) relative to the *primary*
        // screen — the one whose frame origin is (0,0). Use its height to flip
        // into Cocoa's bottom-left global space.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0

        // Anchor = the word's bottom-left (Cocoa). The panel's visible card
        // top-left should sit a hair below it; account for the shadow border.
        var anchorX: CGFloat
        var anchorBottomY: CGFloat   // Cocoa Y of the word's bottom edge
        let wordTopY: CGFloat        // Cocoa Y of the word's top edge (for flip)
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

        // Panel bottom-left origin to put the card just under the word.
        var origin = NSPoint(x: anchorX - shadowMargin,
                             y: anchorBottomY - gap - size.height + shadowMargin)

        // Screen the word is on (fall back to main, then primary).
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorX, y: anchorBottomY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Flip above the word if the panel would spill below the visible area.
        if origin.y < vf.minY {
            origin.y = wordTopY + gap - shadowMargin   // panel sits above the word
        }

        // Final safety net: clamp the ENTIRE panel inside the visible frame.
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        return origin
    }

    /// Deterministic size matching `SpellCandidateView`'s fixed-width layout,
    /// used when the hosting view fails to report a real `fittingSize`.
    private func fallbackSize(rowCount: Int) -> NSSize {
        let rows = CGFloat(max(1, rowCount))
        let rowHeight: CGFloat = 29       // .body text + 6pt vertical padding
        let cardWidth: CGFloat = 220      // matches SpellCandidateView .frame(width:)
        let vStackPadding: CGFloat = 12   // .padding(6) top + bottom
        let height = 2 * shadowMargin + vStackPadding + rows * rowHeight + (rows - 1)
        return NSSize(width: cardWidth + 2 * shadowMargin, height: height)
    }
}

private struct SpellCandidateView: View {
    let candidates: [String]
    let onPick: (String) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { idx, word in
                Button { onPick(word) } label: {
                    HStack(spacing: 0) {
                        Text(word)
                            .font(.system(.body))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
        // Fixed width, intrinsic height — gives NSHostingView a deterministic
        // fittingSize (a `maxWidth` + `.fixedSize()` collapsed to 0×0). Matches
        // the HUD's sizing approach.
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
        .padding(10) // shadow margin (matches SpellCandidateController.shadowMargin)
    }
}
