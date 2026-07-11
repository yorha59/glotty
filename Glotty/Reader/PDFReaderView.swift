import SwiftUI
import PDFKit
import AppKit

/// Renders a PDF with saved translations spliced inline (see `ReflowPDF`): the
/// PDFView shows the reflowed document, so translations push following content
/// down instead of overlaying it, while selection / hit-testing / zoom stay
/// native. An overlay hosts the floating **Translate** chip shown on selection.
///   • click a word → `onLookup`.
///   • select a run → Translate chip → `onTranslate(originalPage, bounds, text)`.
///   • click the ✕ on a translation band → `onRemove(id)`.
struct PDFReaderView: NSViewRepresentable {
    let doc: PDFDocument                       // the original, untouched document
    @Binding var page: Int                     // ORIGINAL page index (TOC / resume)
    let translations: [ReaderTranslation]
    let onLookup: (String) -> Void
    let onTranslate: (Int, CGRect, String) -> Void
    let onRemove: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator

        let container = NSView()
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = false          // seamless: slices + bands read as one flow
        v.translatesAutoresizingMaskIntoConstraints = false
        v.postsFrameChangedNotifications = true
        container.addSubview(v)

        let overlay = PassthroughView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

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
        c.rebuild(initial: true)

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
        return container
    }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.translationsChanged { c.rebuild(initial: false) }
        else { c.goToOriginalIfNeeded(page) }
    }

    final class Coordinator: NSObject {
        var parent: PDFReaderView
        weak var pdfView: PDFView?
        weak var overlay: NSView?
        weak var chip: NSHostingView<TranslateChip>?

        private var derived = ReflowPDF.Result(doc: PDFDocument(), originalIndex: [], translationID: [:])
        private var originalToDerived: [Int: Int] = [:]
        private var lastIDs: [UUID] = []
        private var pendingSelection: (page: PDFPage, rect: CGRect, text: String)?

        init(_ parent: PDFReaderView) { self.parent = parent }

        var translationsChanged: Bool { parent.translations.map(\.id) != lastIDs }

        // MARK: build / reflow

        func rebuild(initial: Bool) {
            guard let v = pdfView else { return }
            let keepOriginal = currentOriginalPage()
            derived = ReflowPDF.build(original: parent.doc, translations: parent.translations)
            lastIDs = parent.translations.map(\.id)
            originalToDerived.removeAll()
            for (d, o) in derived.originalIndex.enumerated() where originalToDerived[o] == nil {
                originalToDerived[o] = d
            }
            v.document = derived.doc
            let target = initial ? parent.page : keepOriginal
            goToOriginalIfNeeded(target, force: true)
        }

        private func currentOriginalPage() -> Int {
            guard let v = pdfView, let cur = v.currentPage, let doc = v.document else { return parent.page }
            let d = doc.index(for: cur)
            return derived.originalIndex.indices.contains(d) ? derived.originalIndex[d] : parent.page
        }

        func goToOriginalIfNeeded(_ original: Int, force: Bool = false) {
            guard let v = pdfView, let doc = v.document else { return }
            if !force, currentOriginalPage() == original { return }
            let d = originalToDerived[original] ?? min(max(0, original), max(0, doc.pageCount - 1))
            if let p = doc.page(at: d) { v.go(to: p) }
        }

        // MARK: input

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = pdfView else { return }
            let pt = g.location(in: v)
            guard let page = v.page(for: pt, nearest: true), let doc = v.document else { return }
            let d = doc.index(for: page)
            // Translation band: only the ✕ is actionable (delete it).
            if let id = derived.translationID[d] {
                let onPage = v.convert(pt, to: page)
                if ReflowPDF.closeRect(on: page).contains(onPage) { parent.onRemove(id) }
                return
            }
            // A drag-select ends as a click too — don't fire a lookup then.
            if let s = v.currentSelection?.string, !s.trimmingCharacters(in: .whitespaces).isEmpty { return }
            let onPage = v.convert(pt, to: page)
            guard let word = page.selectionForWord(at: onPage)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else { return }
            parent.onLookup(word)
        }

        @objc func pageChanged() {
            let o = currentOriginalPage()
            if parent.page != o { parent.page = o }
            viewChanged()
        }

        @objc func selectionChanged() { layoutChip() }
        @objc func viewChanged() { layoutChip() }

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
            let x = min(max(overlay.bounds.minX + 2, r.maxX - size.width), overlay.bounds.maxX - size.width - 2)
            chip.frame = NSRect(x: x, y: r.maxY + 4, width: size.width, height: size.height)
            chip.isHidden = false
        }

        @objc func translateTapped() {
            guard let v = pdfView, let s = pendingSelection, let doc = v.document else { return }
            let d = doc.index(for: s.page)
            let original = derived.originalIndex.indices.contains(d) ? derived.originalIndex[d] : d
            parent.onTranslate(original, s.rect, s.text)
            v.clearSelection()
            chip?.isHidden = true
            pendingSelection = nil
        }
    }
}

/// Overlay that only captures clicks on its subviews (the chip); empty areas
/// fall through to the PDFView so selection still works.
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
