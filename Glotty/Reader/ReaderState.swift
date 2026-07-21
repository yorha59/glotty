import SwiftUI
import PDFKit
import AppKit

/// Observable state for the EPUB reader window: the open book, current chapter,
/// type settings, and the per-book set of looked-up words (underlined in the
/// text). Reading progress, font, theme, and looked-up words persist across
/// launches — font/theme globally, progress + looked-up words per book id.
@MainActor
final class ReaderState: ObservableObject {
    /// Reading themes, ordered lightest to darkest. `light`/`sepia`/`dark` keep
    /// their raw values so existing preferences still resolve.
    enum Theme: String, CaseIterable, Identifiable {
        case light, paper, sepia, solarized, gray, nord, dark, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light:     return String(localized: "Light")
            case .paper:     return String(localized: "Paper")
            case .sepia:     return String(localized: "Sepia")
            case .solarized: return String(localized: "Solarized")
            case .gray:      return String(localized: "Gray")
            case .nord:      return String(localized: "Nord")
            case .dark:      return String(localized: "Dark")
            case .black:     return String(localized: "Black")
            }
        }
        /// Preset background / text colors. Selecting a theme applies these to
        /// the color wells (which the user can then fine-tune).
        var bg: String {
            switch self {
            case .light:     return "#ffffff"
            case .paper:     return "#faf6ef"
            case .sepia:     return "#f4ecd8"
            case .solarized: return "#fdf6e3"
            case .gray:      return "#3a3a3c"
            case .nord:      return "#2e3440"
            case .dark:      return "#1c1c1e"
            case .black:     return "#000000"
            }
        }
        var fg: String {
            switch self {
            case .light:     return "#111111"
            case .paper:     return "#33302b"
            case .sepia:     return "#5b4636"
            case .solarized: return "#55606b"
            case .gray:      return "#dcdcdc"
            case .nord:      return "#d8dee9"
            case .dark:      return "#d8d8d8"
            case .black:     return "#a8a8a8"
            }
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
    /// Page within the current chapter, in the paged layout. Persisted with the
    /// chapter so reopening a book returns to the exact page, not the chapter
    /// opening.
    @Published var pageIndex: Int = 0 { didSet { saveProgress() } }
    @Published var openError: String?

    /// A place the reader saved deliberately, so they can jump back to it.
    struct Bookmark: Codable, Identifiable, Equatable {
        var id = UUID()
        /// EPUB chapter index. PDFs have no chapters, so they leave this 0 and
        /// carry the whole position in `page`.
        var chapter: Int
        var page: Int
        /// Chapter title (EPUB) or nearest outline entry (PDF), for the jump list.
        var label: String
        var date = Date()
    }
    @Published private(set) var bookmarks: [Bookmark] = []

    // PDF backend — books are EPUB (reflowable, WKWebView); PDFs render fixed via
    // PDFKit, so font / theme / spacing don't apply, but tap-to-look-up + the
    // outline TOC + page position do.
    struct PDFTOCItem: Identifiable { let id = UUID(); let label: String; let pageIndex: Int; let level: Int }
    @Published var pdf: PDFDocument?
    @Published var pdfTOC: [PDFTOCItem] = []
    @Published var pdfPage: Int = 0 { didSet { savePDFPage() } }
    private var pdfURL: URL?
    private var bookURL: URL?
    /// True while a book's saved position is being restored, so the partial
    /// assignments don't save over what's still being read.
    private var restoring = false

    /// Text of the page currently on screen. EPUB pushes this from the web view
    /// (only the visible columns); PDF derives it from the current page. The
    /// chat sends it as context so questions can be about what's being read
    /// rather than only about an explicitly selected passage.
    @Published var visiblePageText: String = ""

    /// The one id a PDF is known by — library record, look-ups, chat threads,
    /// bookmarks, progress. The `pdf:` namespace keeps a file called `X.pdf`
    /// from colliding with an EPUB whose `dc:identifier` is literally "X.pdf".
    /// Everything that identifies a PDF must go through this: using the bare
    /// filename in some places and this in others gave one file two library
    /// records.
    static func pdfBookID(_ url: URL) -> String { "pdf:" + url.lastPathComponent }
    static func pdfTitle(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    struct BookInfo: Equatable { let id: String; let title: String; let path: String? }
    /// Identity of the open book/PDF, for the chat + library.
    var bookInfo: BookInfo? {
        if let b = book { return BookInfo(id: b.identifier, title: b.title, path: bookURL?.path) }
        if let u = pdfURL {
            return BookInfo(id: Self.pdfBookID(u), title: Self.pdfTitle(u), path: u.path)
        }
        return nil
    }

    /// Capture context for a look-up fired from the reader, so the popup can
    /// record the result into `BookLibrary` and underline the term.
    func queryCapture(term: String, kind: String) -> ReaderMark.Capture? {
        if let b = book {
            return ReaderMark.Capture(bookID: b.identifier, title: b.title, path: bookURL?.path,
                                      term: term, kind: kind, chapter: chapterIndex)
        }
        if let u = pdfURL {
            return ReaderMark.Capture(bookID: Self.pdfBookID(u), title: Self.pdfTitle(u), path: u.path,
                                      term: term, kind: kind, chapter: pdfPage)
        }
        return nil
    }

    // Inline PDF translations: bubbles anchored under a selection, persisted
    // per document. `pendingPDFTranslation` is the request the reader's
    // `.translationTask` picks up to run Apple's on-device translator.
    struct PendingPDFTranslation: Equatable {
        let page: Int
        let bounds: CGRect
        let source: String
    }
    @Published var pdfTranslations: [ReaderTranslation] = []
    @Published var pendingPDFTranslation: PendingPDFTranslation?

    /// Ask for a translation of `source` (the selected text) anchored at
    /// `bounds` on `page`. The reader's `.translationTask` fulfils it.
    func requestPDFTranslation(page: Int, bounds: CGRect, source: String) {
        let src = Self.cleanSelection(source)
        guard !src.isEmpty else { return }
        pendingPDFTranslation = PendingPDFTranslation(page: page, bounds: bounds, source: src)
    }

    /// PDF selections carry the document's hard line breaks — often mid-word
    /// ("synthe-\nsis"). Translating that verbatim fragments the output and
    /// mistranslates the pieces. Rejoin into flowing sentences first: drop
    /// end-of-line hyphenation, turn line breaks into spaces, collapse runs.
    static func cleanSelection(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-\\s*\\n\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func completePDFTranslation(_ pending: PendingPDFTranslation, translation: String) {
        pendingPDFTranslation = nil
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = pdfURL else { return }
        pdfTranslations.append(ReaderTranslation(page: pending.page, bounds: pending.bounds,
                                                 source: pending.source, translation: t))
        ReaderTranslationStore.save(pdfTranslations, for: u)
    }

    func cancelPDFTranslation() { pendingPDFTranslation = nil }

    func removePDFTranslation(_ id: UUID) {
        pdfTranslations.removeAll { $0.id == id }
        if let u = pdfURL { ReaderTranslationStore.save(pdfTranslations, for: u) }
    }

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
        if openError == nil { ReaderRecents.record(url) }
    }

    private func openEPUB(_ url: URL) {
        do {
            let b = try EPUBBook.open(url)
            pdf = nil; pdfTOC = []
            book = b
            bookURL = url
            openError = nil
            lookedUp = Self.loadWords(b.identifier)
            BookLibrary.touch(bookID: b.identifier, title: b.title, path: url.path)
            bookmarks = Self.loadBookmarks(b.identifier)
            // Read both stored values before assigning either — see saveProgress.
            let savedChapter = min(max(0, UserDefaults.standard.integer(forKey: Self.progressKey(b.identifier))),
                                   b.chapters.count - 1)
            let savedPage = max(0, UserDefaults.standard.integer(forKey: Self.pageKey(b.identifier)))
            restoring = true
            chapterIndex = savedChapter
            pageIndex = savedPage
            restoring = false
            // The restore above is guarded out of saveProgress() (see its own
            // comment), so the Library's position needs its own explicit sync
            // here — otherwise it would show whatever was last saved from
            // in-book navigation, not the position we actually just restored to.
            syncLibraryProgress()
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
        // PDFs have no manifest identifier like EPUB, so they're keyed by
        // filename under the `pdf:` namespace — see pdfBookID.
        let id = Self.pdfBookID(url)
        BookLibrary.mergeLegacyPDFRecord(filename: url.lastPathComponent, into: id)
        Self.migrateLegacyBookmarks(from: url.lastPathComponent, to: id)
        BookLibrary.touch(bookID: id, title: Self.pdfTitle(url), path: url.path)
        bookmarks = Self.loadBookmarks(id)
        pdfTOC = Self.buildPDFTOC(doc)
        // Many PDFs (arXiv papers especially) ship no bookmark outline. Fall
        // back to a TOC synthesized from section headings so the sidebar is
        // still useful instead of empty.
        if pdfTOC.isEmpty { pdfTOC = Self.synthesizePDFTOC(doc) }
        pdfTranslations = ReaderTranslationStore.load(url)
        pendingPDFTranslation = nil
        pdfPage = min(max(0, UserDefaults.standard.integer(forKey: Self.pdfPageKey(url))),
                      max(0, doc.pageCount - 1))
        syncLibraryProgress()
        refreshPDFPageText()   // pdfPage's didSet is a no-op when the value didn't change
    }

    /// Keep the Library's stored reading position current — chapter index for
    /// EPUB (page count is dynamic/reflowable, not a stable total; chapter
    /// count is), page index for PDF (a genuinely fixed total).
    private func syncLibraryProgress() {
        if let b = book {
            BookLibrary.updateProgress(bookID: b.identifier, current: chapterIndex, total: b.chapters.count)
        } else if let url = pdfURL, let doc = pdf, pdfPage < doc.pageCount {
            // The page bound must belong to *this* document. Swapping documents
            // installs the new one before PDFKit reports its first page, so the
            // page-changed callback can fire with the previous document's index
            // — that's how a 41-page paper ended up recorded at "page 194".
            BookLibrary.updateProgress(bookID: Self.pdfBookID(url), current: pdfPage, total: doc.pageCount)
        }
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
    /// Longest term we'll underline. Selection-translate can hand us a whole
    /// paragraph; recording it in the library is useful, but underlining it
    /// would stripe the entire page. Longer passages are still saved — they
    /// just don't get a mark.
    private static let maxMarkLength = 40

    func markLookedUp(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, w.count <= Self.maxMarkLength,
              w.contains(where: \.isLetter), let b = book else { return }
        guard !lookedUp.contains(w) else { return }
        lookedUp.insert(w)
        UserDefaults.standard.set(Array(lookedUp), forKey: Self.wordsKey(b.identifier))
    }

    /// Drop a word's underline. The library keeps the look-up itself — this
    /// only clears the mark on the page.
    func unmarkLookedUp(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let b = book, lookedUp.remove(w) != nil else { return }
        UserDefaults.standard.set(Array(lookedUp), forKey: Self.wordsKey(b.identifier))
    }

    // MARK: - Persistence keys

    private static func progressKey(_ id: String) -> String { "glotty.reader.progress.\(id)" }
    private static func pageKey(_ id: String) -> String { "glotty.reader.page.\(id)" }
    private static func bookmarksKey(_ id: String) -> String { "glotty.reader.bookmarks.\(id)" }
    // New key namespace (was ".words.") — abandons the old auto-marked flood so
    // only deliberately-marked words underline going forward.
    private static func wordsKey(_ id: String) -> String { "glotty.reader.marks.\(id)" }
    private static func loadWords(_ id: String) -> Set<String> {
        Set((UserDefaults.standard.array(forKey: wordsKey(id)) as? [String]) ?? [])
    }
    private func saveProgress() {
        // Restoring assigns chapter and page one at a time; without this guard
        // the first assignment's didSet would write the half-restored pair back
        // over the stored one, losing the page we were about to read.
        guard !restoring, let b = book else { return }
        UserDefaults.standard.set(chapterIndex, forKey: Self.progressKey(b.identifier))
        UserDefaults.standard.set(pageIndex, forKey: Self.pageKey(b.identifier))
        syncLibraryProgress()
    }

    // MARK: - Bookmarks

    /// Bookmarks briefly landed under a PDF's bare filename before the id was
    /// unified; move them so they aren't orphaned. No-op after the first run.
    private static func migrateLegacyBookmarks(from legacyID: String, to newID: String) {
        guard legacyID != newID,
              let old = UserDefaults.standard.data(forKey: bookmarksKey(legacyID)) else { return }
        if UserDefaults.standard.data(forKey: bookmarksKey(newID)) == nil {
            UserDefaults.standard.set(old, forKey: bookmarksKey(newID))
        }
        UserDefaults.standard.removeObject(forKey: bookmarksKey(legacyID))
    }

    private static func loadBookmarks(_ id: String) -> [Bookmark] {
        guard let d = UserDefaults.standard.data(forKey: bookmarksKey(id)) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: d)) ?? []
    }
    private func saveBookmarks() {
        guard let t = bookmarkTarget, let d = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(d, forKey: Self.bookmarksKey(t.id))
    }

    /// Identity + position of whatever is open, so one set of bookmark
    /// functions serves both formats: EPUB is chapter+page, PDF is a page
    /// alone. PDFs key on the filename, matching how their reading position,
    /// translations, and Library record are already keyed.
    private var bookmarkTarget: (id: String, chapter: Int, page: Int)? {
        if let b = book { return (b.identifier, chapterIndex, pageIndex) }
        if let u = pdfURL { return (Self.pdfBookID(u), 0, pdfPage) }
        return nil
    }

    /// Name for a new bookmark: the nearest outline/TOC entry at or before the
    /// current position, since neither EPUB chapters nor PDF pages carry a
    /// title of their own.
    private var bookmarkLabel: String {
        if book != nil {
            return book?.toc.last { ($0.chapterIndex ?? .max) <= chapterIndex }?.label
                ?? String(localized: "Chapter \(chapterIndex + 1)")
        }
        return pdfTOC.last { $0.pageIndex <= pdfPage }?.label
            ?? String(localized: "Page \(pdfPage + 1)")
    }

    /// Is the spot currently on screen already bookmarked?
    var currentIsBookmarked: Bool {
        guard let t = bookmarkTarget else { return false }
        return bookmarks.contains { $0.chapter == t.chapter && $0.page == t.page }
    }

    /// Bookmark the current page, or clear it if it's already bookmarked.
    func toggleBookmark() {
        guard let t = bookmarkTarget else { return }
        if let i = bookmarks.firstIndex(where: { $0.chapter == t.chapter && $0.page == t.page }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.append(Bookmark(chapter: t.chapter, page: t.page, label: bookmarkLabel))
            bookmarks.sort { ($0.chapter, $0.page) < ($1.chapter, $1.page) }
        }
        saveBookmarks()
    }

    func removeBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
        saveBookmarks()
    }

    /// Jump to a saved spot. Same-chapter jumps only move the page, so the web
    /// view pages rather than reloading.
    func goToBookmark(_ b: Bookmark) {
        if pdf != nil {
            pdfPage = b.page
            return
        }
        if chapterIndex != b.chapter { chapterIndex = b.chapter }
        pageIndex = b.page
    }

    // MARK: - PDF helpers

    private static func pdfPageKey(_ url: URL) -> String { "glotty.reader.pdfpage.\(url.lastPathComponent)" }
    private func savePDFPage() {
        // Same document-swap hazard as syncLibraryProgress: don't persist a
        // page index the current document doesn't have, or reopening would
        // restore a position from whatever was read before it.
        guard let u = pdfURL, let doc = pdf, pdfPage < doc.pageCount else { return }
        UserDefaults.standard.set(pdfPage, forKey: Self.pdfPageKey(u))
        syncLibraryProgress()
        refreshPDFPageText()
    }

    /// PDFKit hands us the page's text directly — no web view involved, so
    /// unlike EPUB this is pulled rather than pushed.
    private func refreshPDFPageText() {
        guard let doc = pdf, pdfPage >= 0, pdfPage < doc.pageCount else { return }
        visiblePageText = doc.page(at: pdfPage)?.string ?? ""
    }
    private static func buildPDFTOC(_ doc: PDFDocument) -> [PDFTOCItem] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [PDFTOCItem] = []
        func walk(_ node: PDFOutline, _ level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                // Outline items point at a page either directly (`destination`)
                // or via a GoTo action — resolve both, else we drop entries.
                let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let label = child.label, !label.isEmpty, let page = dest?.page {
                    out.append(PDFTOCItem(label: label, pageIndex: doc.index(for: page), level: level))
                }
                walk(child, level + 1)
            }
        }
        walk(root, 0)
        return out
    }

    /// Fallback TOC for PDFs with no embedded outline: scan each page's text for
    /// section headings. A heading is a numbered ("2.1 Title") or well-known
    /// ("Abstract", "References") line; single-number sections and named ones
    /// must be rendered larger than the body font (that's how we tell "3. Experiments"
    /// from a sentence starting "16 for…"), while dotted subsections are trusted
    /// at body size as long as they're Title-case and free of code punctuation.
    /// ponytail: font+regex heuristic tuned for academic papers — misses
    /// heading-less docs and unusual layouts; upgrade path is a proper layout
    /// analysis if it proves too coarse.
    private static func synthesizePDFTOC(_ doc: PDFDocument) -> [PDFTOCItem] {
        // Guard against a long stall on very large outline-less PDFs.
        guard doc.pageCount > 0, doc.pageCount <= 1500 else { return [] }

        // Modal body font size, sampled from the first pages (cheap, representative).
        var sizeCount: [Int: Int] = [:]
        for p in 0..<min(doc.pageCount, 15) {
            guard let a = doc.page(at: p)?.attributedString else { continue }
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
                if let f = v as? NSFont { sizeCount[Int(f.pointSize.rounded()), default: 0] += r.length }
            }
        }
        let body = sizeCount.max { $0.value < $1.value }?.key ?? 10

        let numbered = try! NSRegularExpression(pattern: "^(\\d{1,2}(?:\\.\\d{1,2}){0,3})\\.?\\s+([A-Z][^\\n]{1,60})$")
        let named = try! NSRegularExpression(pattern: "^(Abstract|Introduction|Related Work|Conclusions?|References|Acknowledge?ments?|Discussion|Appendix)$")
        let codeChars = CharacterSet(charactersIn: "={}()\"_;[]<>")

        var out: [PDFTOCItem] = []
        for p in 0..<doc.pageCount {
            guard let a = doc.page(at: p)?.attributedString else { continue }
            let ns = a.string as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, subRange, _, _ in
                let line = (sub ?? "").trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return }
                let rr = NSRange(line.startIndex..., in: line)
                var size = 0
                a.enumerateAttribute(.font, in: subRange) { v, _, _ in
                    if let f = v as? NSFont { size = max(size, Int(f.pointSize.rounded())) }
                }
                if let m = numbered.firstMatch(in: line, range: rr) {
                    let num = (line as NSString).substring(with: m.range(at: 1))
                    let title = (line as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    if title.rangeOfCharacter(from: codeChars) != nil { return }
                    let level = num.components(separatedBy: ".").count - 1
                    if level == 0 && size <= body { return }   // top-level section must be heading-size
                    if level >= 1 && size < body { return }     // subsection at ≥ body size drops tiny code lines
                    out.append(PDFTOCItem(label: "\(num) \(title)", pageIndex: p, level: level))
                } else if named.firstMatch(in: line, range: rr) != nil, size > body {
                    out.append(PDFTOCItem(label: line, pageIndex: p, level: 0))
                }
            }
        }
        return out
    }
}
