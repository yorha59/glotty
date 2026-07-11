import PDFKit
import AppKit

/// Builds a *reflowed* copy of a PDF: for every saved translation, the host page
/// is split at the selection's baseline into two cropped pages and a generated
/// translation page is spliced in between. Rendered with page breaks off, the
/// result reads as an inline insertion that pushes the following content down —
/// without overlapping anything, and because the slices are real `PDFPage`s the
/// PDFView keeps native selection, hit-testing, scroll and zoom.
enum ReflowPDF {
    struct Result {
        let doc: PDFDocument
        /// Original page index for each derived page (translation pages map to
        /// the page they belong to).
        let originalIndex: [Int]
        /// Derived page index → translation id, for the pages that ARE a
        /// translation band (so a tap on the ✕ can delete it).
        let translationID: [Int: UUID]
    }

    static func build(original: PDFDocument, translations: [ReaderTranslation]) -> Result {
        // Common case — nothing inserted, hand back the original untouched.
        guard !translations.isEmpty else {
            return Result(doc: original,
                          originalIndex: Array(0..<original.pageCount),
                          translationID: [:])
        }

        let out = PDFDocument()
        var originalIndex: [Int] = []
        var translationID: [Int: UUID] = [:]

        func emit(_ page: PDFPage, original i: Int, translation id: UUID? = nil) {
            let at = out.pageCount
            out.insert(page, at: at)
            originalIndex.append(i)
            if let id { translationID[at] = id }
        }

        for i in 0..<original.pageCount {
            guard let page = original.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let ts = translations.filter { $0.page == i }
                .sorted { $0.bounds.minY > $1.bounds.minY }   // top-most (highest y) first

            guard !ts.isEmpty else { emit(copy(page), original: i); continue }

            var hi = box.maxY
            for t in ts {
                let y = min(max(t.bounds.minY, box.minY), box.maxY)
                if hi - y > 2 { emit(slice(page, box: box, yLo: y, yHi: hi), original: i) }
                if let tp = translationPage(t.translation, width: box.width) {
                    emit(tp, original: i, translation: t.id)
                }
                hi = y
            }
            if hi - box.minY > 2 { emit(slice(page, box: box, yLo: box.minY, yHi: hi), original: i) }
        }

        return Result(doc: out, originalIndex: originalIndex, translationID: translationID)
    }

    // MARK: - helpers

    private static func copy(_ page: PDFPage) -> PDFPage { page.copy() as! PDFPage }

    /// A cropped copy showing only the `[yLo, yHi]` vertical band of `page`.
    private static func slice(_ page: PDFPage, box: CGRect, yLo: CGFloat, yHi: CGFloat) -> PDFPage {
        let c = copy(page)
        c.setBounds(CGRect(x: box.minX, y: yLo, width: box.width, height: yHi - yLo), for: .cropBox)
        return c
    }

    /// A generated, vector (crisp + zoomable) page holding the translation, sized
    /// to fit the text at the page width, with an accent bar and a ✕ affordance.
    static func translationPage(_ text: String, width: CGFloat) -> PDFPage? {
        let inset: CGFloat = 12
        let barGap: CGFloat = 8
        let font = NSFont.systemFont(ofSize: 13)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
            .paragraphStyle: para,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textW = width - inset * 2 - barGap
        let textH = ceil(attr.boundingRect(with: CGSize(width: textW, height: 1e5),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let pageH = textH + inset * 2

        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: pageH)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)

        ctx.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor); ctx.fill(mediaBox)
        ctx.setFillColor(NSColor(calibratedRed: 0.04, green: 0.52, blue: 1, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 3, height: pageH))

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        attr.draw(with: CGRect(x: inset + barGap, y: inset, width: textW, height: textH),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        // ✕ in the top-right corner (page coords are y-up, so top == high y).
        let close = NSAttributedString(string: "\u{2715}", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1)])
        close.draw(at: CGPoint(x: width - 18, y: pageH - 17))
        NSGraphicsContext.restoreGraphicsState()

        ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Rect (page coords) of the ✕ on a translation page, for hit-testing taps.
    static func closeRect(on page: PDFPage) -> CGRect {
        let b = page.bounds(for: .cropBox)
        return CGRect(x: b.maxX - 26, y: b.maxY - 26, width: 26, height: 26)
    }
}
