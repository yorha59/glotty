import SwiftUI
import PDFKit

/// Renders a PDF in a `PDFView` (continuous scroll, auto-scaled). A click resolves
/// the word under the pointer via `PDFPage.selectionForWord(at:)` and fires
/// Glotty's lookup — the PDF analogue of tapping a word in the EPUB reader. The
/// current page is two-way bound so the outline TOC can jump and scrolling
/// reports back for resume-position.
struct PDFReaderView: NSViewRepresentable {
    let doc: PDFDocument
    @Binding var page: Int
    let onLookup: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = doc
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        context.coordinator.pdfView = v
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.click(_:)))
        click.delaysPrimaryMouseButtonEvents = false   // don't swallow PDFView's own handling
        v.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: v)
        if let p = doc.page(at: min(max(0, page), max(0, doc.pageCount - 1))) { v.go(to: p) }
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        context.coordinator.parent = self
        // External page change (TOC tap) → scroll there.
        if let cur = v.currentPage, doc.index(for: cur) != page,
           let p = doc.page(at: min(max(0, page), max(0, doc.pageCount - 1))) {
            v.go(to: p)
        }
    }

    final class Coordinator: NSObject {
        var parent: PDFReaderView
        weak var pdfView: PDFView?
        init(_ parent: PDFReaderView) { self.parent = parent }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = pdfView else { return }
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
        }
    }
}
