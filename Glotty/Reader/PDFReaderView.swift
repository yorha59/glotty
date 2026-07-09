import SwiftUI
import PDFKit
import AppKit

/// Renders a PDF in a `PDFView` (continuous scroll, auto-scaled) with an overlay
/// layer for the inline-translation feature:
///   • click a word → Glotty lookup (`onLookup`), the PDF analogue of an EPUB tap.
///   • select a run of text → a floating **Translate** chip appears above it;
///     clicking it calls `onTranslate`, and the resulting translation is drawn
///     as a bubble anchored just under the selection.
///   • bubbles for already-saved translations (`translations`) are re-drawn and
///     tracked through scroll / zoom via PDFKit notifications.
struct PDFReaderView: NSViewRepresentable {
    let doc: PDFDocument
    @Binding var page: Int
    let translations: [ReaderTranslation]
    let onLookup: (String) -> Void
    let onTranslate: (Int, CGRect, String) -> Void
    let onRemove: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator

        let container = NSView()
        let v = PDFView()
        v.document = doc
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.postsFrameChangedNotifications = true
        container.addSubview(v)

        let overlay = PassthroughView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)      // above the PDFView

        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        c.pdfView = v
        c.overlay = overlay

        // The floating Translate chip (hidden until there's a selection).
        let chip = NSHostingView(rootView: TranslateChip { [weak c] in c?.translateTapped() })
        chip.frame.size = chip.fittingSize
        chip.isHidden = true
        overlay.addSubview(chip)
        c.chip = chip

        let click = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.click(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        v.addGestureRecognizer(click)

        let nc = NotificationCenter.default
        nc.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        nc.addObserver(c, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: v)
        nc.addObserver(c, selector: #selector(Coordinator.viewChanged), name: .PDFViewScaleChanged, object: v)
        nc.addObserver(c, selector: #selector(Coordinator.viewChanged), name: NSView.frameDidChangeNotification, object: v)

        if let p = doc.page(at: clamp(page)) { v.go(to: p) }

        // Scroll tracking: observe the PDFView's internal scroll content view.
        DispatchQueue.main.async { [weak c] in
            c?.attachScrollObserver()
            c?.syncBubbles()
        }
        return container
    }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let pv = c.pdfView else { return }
        if let cur = pv.currentPage, doc.index(for: cur) != page, let p = doc.page(at: clamp(page)) {
            pv.go(to: p)
        }
        c.syncBubbles()
    }

    private func clamp(_ i: Int) -> Int { min(max(0, i), max(0, doc.pageCount - 1)) }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: PDFReaderView
        weak var pdfView: PDFView?
        weak var overlay: NSView?
        weak var chip: NSHostingView<TranslateChip>?
        private var bubbles: [UUID: NSHostingView<PDFTranslationBubble>] = [:]
        private var bubbleWidth: [UUID: CGFloat] = [:]
        private var pendingSelection: (page: PDFPage, rect: CGRect, text: String)?

        init(_ parent: PDFReaderView) { self.parent = parent }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = pdfView else { return }
            // A drag-select ends as a click too; don't fire a word lookup when
            // there's an active selection (the Translate chip handles that).
            if let s = v.currentSelection?.string, !s.trimmingCharacters(in: .whitespaces).isEmpty { return }
            let pt = g.location(in: v)
            guard let page = v.page(for: pt, nearest: true) else { return }
            let onPage = v.convert(pt, to: page)
            guard let word = page.selectionForWord(at: onPage)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else { return }
            parent.onLookup(word)
        }

        @objc func pageChanged() {
            guard let v = pdfView, let cur = v.currentPage else { return }
            let idx = v.document?.index(for: cur) ?? 0
            if parent.page != idx { parent.page = idx }
            viewChanged()
        }

        @objc func selectionChanged() { layoutChip() }

        @objc func viewChanged() { layoutChip(); layoutBubbles() }

        func attachScrollObserver() {
            guard let v = pdfView, let sv = Self.scrollView(in: v) else { return }
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewChanged),
                                                   name: NSView.boundsDidChangeNotification, object: sv.contentView)
        }

        // MARK: selection → Translate chip

        private func currentSelectionInfo() -> (page: PDFPage, rect: CGRect, text: String)? {
            guard let v = pdfView, let sel = v.currentSelection,
                  let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let page = sel.pages.first else { return nil }
            var rect = CGRect.null
            for line in sel.selectionsByLine() {
                let r = line.bounds(for: page)
                if r.width > 1, r.height > 1 { rect = rect.union(r) }
            }
            guard !rect.isNull, rect.width > 1 else { return nil }
            return (page, rect, text)
        }

        private func layoutChip() {
            guard let v = pdfView, let overlay = overlay, let chip = chip else { return }
            guard let info = currentSelectionInfo() else { chip.isHidden = true; pendingSelection = nil; return }
            pendingSelection = info
            let r = overlay.convert(v.convert(info.rect, from: info.page), from: v)
            let size = chip.fittingSize
            var x = r.maxX - size.width
            x = min(max(overlay.bounds.minX + 2, x), overlay.bounds.maxX - size.width - 2)
            chip.frame = NSRect(x: x, y: r.maxY + 4, width: size.width, height: size.height)
            chip.isHidden = false
        }

        @objc func translateTapped() {
            guard let v = pdfView, let s = pendingSelection, let doc = v.document else { return }
            parent.onTranslate(doc.index(for: s.page), s.rect, s.text)
            v.clearSelection()
            chip?.isHidden = true
            pendingSelection = nil
        }

        // MARK: persistent bubbles

        func syncBubbles() {
            guard let overlay = overlay else { return }
            let ids = Set(parent.translations.map(\.id))
            for (id, host) in bubbles where !ids.contains(id) {
                host.removeFromSuperview(); bubbles[id] = nil; bubbleWidth[id] = nil
            }
            for t in parent.translations where bubbles[t.id] == nil {
                let id = t.id
                let host = NSHostingView(rootView: PDFTranslationBubble(text: t.translation, width: 200,
                                                                        onClose: { [weak self] in self?.parent.onRemove(id) }))
                overlay.addSubview(host)
                bubbles[id] = host
            }
            layoutBubbles()
        }

        private func layoutBubbles() {
            guard let v = pdfView, let overlay = overlay, let doc = v.document else { return }
            let visible = Set(v.visiblePages.map { doc.index(for: $0) })
            for t in parent.translations {
                guard let host = bubbles[t.id] else { continue }
                guard visible.contains(t.page), let page = doc.page(at: t.page) else { host.isHidden = true; continue }
                let sel = overlay.convert(v.convert(t.bounds, from: page), from: v)
                let width = max(140, sel.width)
                if abs((bubbleWidth[t.id] ?? -1) - width) > 0.5 {
                    host.rootView = PDFTranslationBubble(text: t.translation, width: width,
                                                         onClose: { [weak self] in self?.parent.onRemove(t.id) })
                    bubbleWidth[t.id] = width
                }
                host.layoutSubtreeIfNeeded()
                let h = host.fittingSize.height
                // "Under" the selection: PDF/AppKit y-axis is bottom-up, so below = smaller y.
                host.frame = NSRect(x: sel.minX, y: sel.minY - h - 4, width: width, height: h)
                host.isHidden = false
            }
        }

        private static func scrollView(in v: NSView) -> NSScrollView? {
            for sub in v.subviews {
                if let s = sub as? NSScrollView { return s }
                if let s = scrollView(in: sub) { return s }
            }
            return nil
        }
    }
}

/// Overlay that only captures clicks that land on its subviews (chip / bubbles);
/// empty areas fall through to the PDFView so text selection still works.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

struct TranslateChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 12, weight: .semibold))
                Text("Translate").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct PDFTranslationBubble: View {
    let text: String
    let width: CGFloat
    let onClose: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}
