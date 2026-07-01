import SwiftUI
import PDFKit

/// Observable state for the EPUB reader window: the open book, current chapter,
/// type settings, and the per-book set of looked-up words (underlined in the
/// text). Reading progress, font, theme, and looked-up words persist across
/// launches — font/theme globally, progress + looked-up words per book id.
@MainActor
final class ReaderState: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case light, sepia, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light: return String(localized: "Light")
            case .sepia: return String(localized: "Sepia")
            case .dark:  return String(localized: "Dark")
            }
        }
        /// Preset background / text colors. Selecting a theme applies these to
        /// the color wells (which the user can then fine-tune).
        var bg: String {
            switch self { case .light: return "#ffffff"; case .sepia: return "#f4ecd8"; case .dark: return "#1c1c1e" }
        }
        var fg: String {
            switch self { case .light: return "#111111"; case .sepia: return "#5b4636"; case .dark: return "#d8d8d8" }
        }
    }

    enum ReaderFont: String, CaseIterable, Identifiable {
        case bookDefault, system, newYork, georgia, palatino, charter, times, helvetica
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bookDefault: return String(localized: "Book Default")
            case .system:      return String(localized: "System")
            case .newYork:     return "New York"
            case .georgia:     return "Georgia"
            case .palatino:    return "Palatino"
            case .charter:     return "Charter"
            case .times:       return "Times"
            case .helvetica:   return "Helvetica"
            }
        }
        /// CSS font-family stack, or nil to keep the book's own font.
        var css: String? {
            switch self {
            case .bookDefault: return nil
            case .system:      return "-apple-system, system-ui, sans-serif"
            case .newYork:     return "'New York', ui-serif, Georgia, serif"
            case .georgia:     return "Georgia, 'Times New Roman', serif"
            case .palatino:    return "'Palatino', 'Palatino Linotype', 'Book Antiqua', serif"
            case .charter:     return "'Charter', Georgia, serif"
            case .times:       return "'Times New Roman', Times, serif"
            case .helvetica:   return "'Helvetica Neue', Helvetica, Arial, sans-serif"
            }
        }
    }

    @Published private(set) var book: EPUBBook?
    @Published var chapterIndex: Int = 0 { didSet { saveProgress() } }
    @Published var openError: String?

    // PDF backend — books are EPUB (reflowable, WKWebView); PDFs render fixed via
    // PDFKit, so font / theme / spacing don't apply, but tap-to-look-up + the
    // outline TOC + page position do.
    struct PDFTOCItem: Identifiable { let id = UUID(); let label: String; let pageIndex: Int; let level: Int }
    @Published var pdf: PDFDocument?
    @Published var pdfTOC: [PDFTOCItem] = []
    @Published var pdfPage: Int = 0 { didSet { savePDFPage() } }
    private var pdfURL: URL?

    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: Self.fontKey) }
    }
    @Published var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
            // A theme IS its palette — picking one drives the color wells (the
            // color pickers are bound to bgColorHex/fgColorHex, so they update
            // in step). The user can still fine-tune either color afterward.
            bgColorHex = theme.bg
            fgColorHex = theme.fg
        }
    }
    @Published var font: ReaderFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Self.fontFamilyKey) }
    }
    @Published var lineHeight: Double {
        didSet { UserDefaults.standard.set(lineHeight, forKey: Self.lineKey) }
    }
    @Published var letterSpacing: Double {
        didSet { UserDefaults.standard.set(letterSpacing, forKey: Self.letterKey) }
    }
    @Published var bgColorHex: String {
        didSet { UserDefaults.standard.set(bgColorHex, forKey: Self.bgKey) }
    }
    @Published var fgColorHex: String {
        didSet { UserDefaults.standard.set(fgColorHex, forKey: Self.fgKey) }
    }
    @Published private(set) var lookedUp: Set<String> = []

    private static let fontKey = "glotty.reader.fontScale"
    private static let themeKey = "glotty.reader.theme"
    private static let fontFamilyKey = "glotty.reader.fontFamily"
    private static let lineKey = "glotty.reader.lineHeight"
    private static let letterKey = "glotty.reader.letterSpacing"
    private static let bgKey = "glotty.reader.bgColor"
    private static let fgKey = "glotty.reader.fgColor"

    init() {
        let d = UserDefaults.standard
        let f = d.double(forKey: Self.fontKey)
        fontScale = f > 0 ? f : 1.0
        let t = Theme(rawValue: d.string(forKey: Self.themeKey) ?? "") ?? .light
        theme = t   // didSet doesn't run in init, so the stored colors below stand
        font = ReaderFont(rawValue: d.string(forKey: Self.fontFamilyKey) ?? "") ?? .bookDefault
        let lh = d.double(forKey: Self.lineKey)
        lineHeight = lh > 0 ? lh : 1.65
        letterSpacing = d.object(forKey: Self.letterKey) as? Double ?? 0
        bgColorHex = d.string(forKey: Self.bgKey) ?? t.bg
        fgColorHex = d.string(forKey: Self.fgKey) ?? t.fg
    }

    /// Restore all typography + colors to defaults (Light theme).
    func resetTypography() {
        fontScale = 1.0
        lineHeight = 1.65
        letterSpacing = 0
        font = .bookDefault
        theme = .light   // didSet resets bg/fg to the Light palette
    }

    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" { openPDF(url) } else { openEPUB(url) }
    }

    private func openEPUB(_ url: URL) {
        do {
            let b = try EPUBBook.open(url)
            pdf = nil; pdfTOC = []
            book = b
            openError = nil
            lookedUp = Self.loadWords(b.identifier)
            chapterIndex = min(max(0, UserDefaults.standard.integer(forKey: Self.progressKey(b.identifier))),
                               b.chapters.count - 1)
        } catch {
            book = nil
            openError = String(format: String(localized: "Couldn't open this book: %@"),
                               String(describing: error))
        }
    }

    private func openPDF(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            pdf = nil
            openError = String(localized: "Couldn't open this PDF.")
            return
        }
        book = nil
        pdfURL = url
        pdf = doc
        openError = nil
        pdfTOC = Self.buildPDFTOC(doc)
        pdfPage = min(max(0, UserDefaults.standard.integer(forKey: Self.pdfPageKey(url))),
                      max(0, doc.pageCount - 1))
    }

    var chapterCount: Int { book?.chapters.count ?? 0 }
    func goto(_ index: Int) {
        guard let b = book, b.chapters.indices.contains(index) else { return }
        chapterIndex = index
    }
    func next() { goto(chapterIndex + 1) }
    func prev() { goto(chapterIndex - 1) }
    func adjustFont(_ delta: Double) {
        fontScale = min(2.5, max(0.7, (fontScale + delta * 100).rounded() / 100))
    }

    /// Underline a word the user deliberately marked (the popup's Mark button);
    /// persists per book. Requires a letter so a stray punctuation tap (a lone
    /// quote) can't be marked.
    func markLookedUp(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, w.contains(where: \.isLetter), let b = book else { return }
        guard !lookedUp.contains(w) else { return }
        lookedUp.insert(w)
        UserDefaults.standard.set(Array(lookedUp), forKey: Self.wordsKey(b.identifier))
    }

    // MARK: - Persistence keys

    private static func progressKey(_ id: String) -> String { "glotty.reader.progress.\(id)" }
    // New key namespace (was ".words.") — abandons the old auto-marked flood so
    // only deliberately-marked words underline going forward.
    private static func wordsKey(_ id: String) -> String { "glotty.reader.marks.\(id)" }
    private static func loadWords(_ id: String) -> Set<String> {
        Set((UserDefaults.standard.array(forKey: wordsKey(id)) as? [String]) ?? [])
    }
    private func saveProgress() {
        guard let b = book else { return }
        UserDefaults.standard.set(chapterIndex, forKey: Self.progressKey(b.identifier))
    }

    // MARK: - PDF helpers

    private static func pdfPageKey(_ url: URL) -> String { "glotty.reader.pdfpage.\(url.lastPathComponent)" }
    private func savePDFPage() {
        guard let u = pdfURL else { return }
        UserDefaults.standard.set(pdfPage, forKey: Self.pdfPageKey(u))
    }
    private static func buildPDFTOC(_ doc: PDFDocument) -> [PDFTOCItem] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [PDFTOCItem] = []
        func walk(_ node: PDFOutline, _ level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let label = child.label, !label.isEmpty, let page = child.destination?.page {
                    out.append(PDFTOCItem(label: label, pageIndex: doc.index(for: page), level: level))
                }
                walk(child, level + 1)
            }
        }
        walk(root, 0)
        return out
    }
}
