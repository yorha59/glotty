import SwiftUI
import PDFKit
import AppKit

/// Renders a PDF with saved translations spliced inline (see `ReflowPDF`): the
/// PDFView shows the reflowed document, so translations push following content
/// down instead of overlaying it, while selection / hit-testing / zoom stay
/// native. An overlay hosts the floating **Translate** chip shown on selection.
///   • select a run → Translate / What is this / Add chip.
///   • click the ✕ on a translation band → `onRemove(id)`.
struct PDFReaderView: NSViewRepresentable {
    let doc: PDFDocument                       // the original, untouched document
    @Binding var page: Int                     // ORIGINAL page index (TOC / resume)
    let translations: [ReaderTranslation]
    let onTranslate: (Int, CGRect, String) -> Void
    let onAsk: (String) -> Void
    let onAdd: (String) -> Void
    let onRemove: (UUID) -> Void
    /// A passage to select + scroll to (from a chat-quote jump); identity
    /// carries the request. nil selects nothing.
    var highlight: ReaderState.PassageHighlight? = nil

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

        let chip = NSHostingView(rootView: SelectionChip(
            onTranslate: { [weak c] in c?.translateTapped() },
            onAsk: { [weak c] in c?.askTapped() },
            onAdd: { [weak c] in c?.addTapped() }))
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
        context.coordinator.parent = self
        context.coordinator.syncToParent()
    }

    final class Coordinator: NSObject {
        var parent: PDFReaderView
        weak var pdfView: PDFView?
        weak var overlay: NSView?
        weak var chip: NSHostingView<SelectionChip>?

        private var derived = ReflowPDF.Result(doc: PDFDocument(), originalIndex: [], translationID: [:])
        private var originalToDerived: [Int: Int] = [:]
        private var lastIDs: [UUID] = []
        private var pendingSelection: (page: PDFPage, rect: CGRect, text: String)?
        /// Id of the last handled highlight request, so paging doesn't re-fire it.
        var lastHighlightID: UUID?
        /// The document the view was last built from. Identity, not equality:
        /// PDFDocument has no useful `==`, and two different files can share a
        /// page count, so only "is this the same object" is meaningful.
        private weak var builtFrom: PDFDocument?

        init(_ parent: PDFReaderView) { self.parent = parent }

        var translationsChanged: Bool { parent.translations.map(\.id) != lastIDs }
        var documentChanged: Bool { builtFrom !== parent.doc }

        /// Bring the view in line with `parent`. This is the whole of what
        /// `updateNSView` does, factored out so the self-test can drive the
        /// real decision instead of a copy of it — a test that reimplements
        /// the branch it's checking passes just as happily when the branch is
        /// wrong, which is exactly how the bug below survived.
        ///
        /// A different document must rebuild even when nothing else changed.
        /// Rebuilding only on `translationsChanged` left the previous PDF
        /// rendered — two documents with no translations compare equal — while
        /// the TOC, page count and progress all switched to the new one.
        func syncToParent() {
            if documentChanged { rebuild(initial: true) }
            else if translationsChanged { rebuild(initial: false) }
            else { goToOriginalIfNeeded(parent.page) }
            if let h = parent.highlight, h.id != lastHighlightID {
                lastHighlightID = h.id
                highlightPassage(h.text)
            }
        }

        /// Select the passage a chat quote came from and scroll it into view.
        /// PDFKit's search runs over the whole document in reading order, and a
        /// section title also appears in the table of contents — so `.first`
        /// would jump to the TOC, not the page the quote was picked from. Pick
        /// the match nearest the page we just navigated to, and ignore matches
        /// far from it (a TOC hit when the real page's text didn't match), so
        /// the highlight never overrides a correct page-level jump.
        private func highlightPassage(_ text: String) {
            guard let v = pdfView, let doc = v.document else { return }
            let matches = doc.findString(text, withOptions: [.caseInsensitive])
            guard !matches.isEmpty else { return }
            let target = originalToDerived[parent.page] ?? parent.page
            func distance(_ sel: PDFSelection) -> Int {
                guard let p = sel.pages.first else { return .max }
                return abs(doc.index(for: p) - target)
            }
            guard let best = matches.min(by: { distance($0) < distance($1) }),
                  distance(best) <= 2 else { return }   // >2 pages off ⇒ a stray/TOC hit; leave the page jump
            v.setCurrentSelection(best, animate: true)
            v.go(to: best)
        }

        // MARK: build / reflow

        func rebuild(initial: Bool) {
            guard let v = pdfView else { return }
            let keepOriginal = currentOriginalPage()
            derived = ReflowPDF.build(original: parent.doc, translations: parent.translations)
            lastIDs = parent.translations.map(\.id)
            builtFrom = parent.doc
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
            // The only thing a bare click does now is delete a translation band
            // via its ✕. It no longer looks a word up: that fired on any click
            // during normal reading, and two quick-but-not-double clicks each
            // opened a popup before the selection registered — the doubled
            // explain windows. Looking up is a deliberate act now, same as the
            // EPUB reader: select the word (double-click selects it) and use
            // the chip's "What is this".
            guard let v = pdfView else { return }
            let pt = g.location(in: v)
            guard let page = v.page(for: pt, nearest: true), let doc = v.document else { return }
            let d = doc.index(for: page)
            if let id = derived.translationID[d] {
                let onPage = v.convert(pt, to: page)
                if ReflowPDF.closeRect(on: page).contains(onPage) { parent.onRemove(id) }
            }
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

        func translateTapped() {
            guard let v = pdfView, let s = pendingSelection, let doc = v.document else { return }
            let d = doc.index(for: s.page)
            let original = derived.originalIndex.indices.contains(d) ? derived.originalIndex[d] : d
            parent.onTranslate(original, s.rect, s.text)
            clearSelectionUI()
        }

        func addTapped() {
            guard let s = pendingSelection else { return }
            parent.onAdd(s.text)
            clearSelectionUI()
        }

        func askTapped() {
            guard let s = pendingSelection else { return }
            parent.onAsk(s.text)
            clearSelectionUI()
        }

        private func clearSelectionUI() {
            pdfView?.clearSelection()
            chip?.isHidden = true
            pendingSelection = nil
        }
    }
}

/// Overlay that only captures clicks on its subviews (the chip); empty areas
/// fall through to the content view so selection still works. Shared by the
/// PDF and EPUB readers.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

struct SelectionChip: View {
    let onTranslate: () -> Void
    let onAsk: () -> Void
    /// Put the passage in the composer instead of sending it. Ask covers
    /// "explain this"; Add is for when the question is something else and the
    /// passage is just what it's about.
    let onAdd: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            button("globe", "Translate", onTranslate)
            Divider().frame(height: 16).overlay(Color.white.opacity(0.35))
            button("bubble.left.and.bubble.right", "What is this", onAsk)
            Divider().frame(height: 16).overlay(Color.white.opacity(0.35))
            button("text.append", "Add", onAdd)
        }
        .background(Color.accentColor)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
