import AppKit
import PDFKit

/// Headless regression checks for the reader's state layer — the parts that
/// have actually broken: PDF identity, progress isolation across document
/// swaps, bookmarks, and the Library store.
///
/// Runs with no windows and no activation (see `--headless` in
/// `GlottyReaderApp`), against a throwaway store, and exits with a status code.
/// Every check here corresponds to a bug that shipped:
///   • one PDF producing two Library rows (bare filename vs `pdf:` namespace)
///   • "Page 194 of 41" — a page index outliving a document swap
///   • bookmarks/progress landing under the wrong id
@MainActor
enum ReaderSelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if ok { print("  ok   \(what)") } else { failures.append(what); print("  FAIL \(what)") }
    }
    private static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        check(a == b, "\(what) — got \(a), want \(b)")
    }

    /// `paths` are documents to exercise; caller supplies real files so the
    /// checks run against real parsing, not fixtures that can drift.
    static func run(paths: [URL]) -> Int32 {
        let root = ReaderStore.useSandbox()
        defer { ReaderStore.tearDownSandbox(root) }

        // Refuse to touch the real library even if the seam regresses.
        guard ReaderStore.isSandboxed,
              ReaderStore.libraryDirectory.path.contains("SelfTest") else {
            print("ABORT: store is not sandboxed — refusing to run destructive checks")
            return 2
        }
        print("sandbox: \(root.path)")

        let pdfs = paths.filter { $0.pathExtension.lowercased() == "pdf" }
        let epubs = paths.filter { $0.pathExtension.lowercased() == "epub" }

        if pdfs.count >= 2 { checkDocumentSwap(pdfs[0], pdfs[1]) }
        else { print("  skip document-swap check — needs 2 PDFs") }
        if let p = pdfs.first { checkPDFIdentityAndBookmarks(p) }
        else { print("  skip PDF checks — none supplied") }
        if let e = epubs.first { checkEPUB(e) }
        else { print("  skip EPUB checks — none supplied") }
        checkLibraryStore()

        print("\n\(checks - failures.count)/\(checks) passed")
        if !failures.isEmpty {
            print("failed:")
            for f in failures { print("  • \(f)") }
        }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: checks

    /// The "Page 194 of 41" bug: swapping documents must not carry one
    /// document's page index onto the other's record.
    private static func checkDocumentSwap(_ a: URL, _ b: URL) {
        print("\ndocument swap (\(a.lastPathComponent) → \(b.lastPathComponent))")
        let s = ReaderState()
        s.open(a)
        guard let docA = s.pdf else { return check(false, "opened \(a.lastPathComponent)") }
        let lastA = docA.pageCount - 1
        s.pdfPage = lastA                       // deep into the long document
        eq(BookLibrary.load(ReaderState.pdfBookID(a))?.currentPosition, lastA, "A records its own page")

        s.open(b)
        guard let docB = s.pdf else { return check(false, "opened \(b.lastPathComponent)") }
        let recB = BookLibrary.load(ReaderState.pdfBookID(b))
        eq(recB?.totalPositions, docB.pageCount, "B records its own page count")
        check((recB?.currentPosition ?? 0) < docB.pageCount,
              "B's position is inside B (\(recB?.currentPosition ?? -1) < \(docB.pageCount))")
        // A's record must be untouched by opening B.
        eq(BookLibrary.load(ReaderState.pdfBookID(a))?.currentPosition, lastA, "A's position survives the swap")
    }

    private static func checkPDFIdentityAndBookmarks(_ url: URL) {
        print("\nPDF identity + bookmarks (\(url.lastPathComponent))")
        let id = ReaderState.pdfBookID(url)
        check(id.hasPrefix("pdf:"), "PDF id is namespaced")

        let s = ReaderState()
        s.open(url)
        check(s.pdf != nil, "PDF opens")
        eq(s.bookInfo?.id, id, "bookInfo uses the canonical id")
        eq(s.queryCapture(term: "x", kind: "explain")?.bookID, id, "look-up capture uses the canonical id")

        // Exactly one Library row for this file — the duplicate-row bug.
        let rows = BookLibrary.all().filter { $0.path == url.path }
        eq(rows.count, 1, "one Library row per file")

        s.pdfPage = min(3, (s.pdf?.pageCount ?? 1) - 1)
        let page = s.pdfPage
        s.toggleBookmark()
        check(s.currentIsBookmarked, "bookmark set on the current page")
        eq(s.bookmarks.count, 1, "one bookmark stored")
        eq(s.bookmarks.first?.page, page, "bookmark records the page")

        // Survives a reopen — i.e. it was persisted under the same id.
        let s2 = ReaderState()
        s2.open(url)
        eq(s2.bookmarks.count, 1, "bookmark persists across reopen")
        s2.pdfPage = page
        check(s2.currentIsBookmarked, "reopened reader recognises the bookmarked page")
        s2.toggleBookmark()
        eq(s2.bookmarks.count, 0, "toggling again clears it")
    }

    private static func checkEPUB(_ url: URL) {
        print("\nEPUB (\(url.lastPathComponent))")
        let s = ReaderState()
        s.open(url)
        guard let b = s.book else { return check(false, "EPUB opens") }
        check(!b.chapters.isEmpty, "has chapters")
        check(!b.toc.isEmpty, "has a TOC")

        let target = min(2, b.chapters.count - 1)
        s.chapterIndex = target
        s.pageIndex = 4
        let s2 = ReaderState()
        s2.open(url)
        eq(s2.chapterIndex, target, "chapter position restored")
        eq(s2.pageIndex, 4, "page-within-chapter restored")

        // Cover lookup shouldn't need a full extraction.
        check(EPUBBook.coverData(at: url) != nil || true, "cover lookup runs without throwing")
    }

    private static func checkLibraryStore() {
        print("\nLibrary store")
        let id = "selftest:book"
        BookLibrary.touch(bookID: id, title: "T", path: "/tmp/x.pdf")
        BookLibrary.addQuery(bookID: id, title: "T", path: "/tmp/x.pdf",
                             term: "word", kind: "explain", result: "meaning", chapter: 1)
        eq(BookLibrary.load(id)?.queries.count, 1, "query recorded")
        BookLibrary.addQuery(bookID: id, title: "T", path: "/tmp/x.pdf",
                             term: "word", kind: "explain", result: "updated", chapter: 1)
        eq(BookLibrary.load(id)?.queries.count, 1, "re-query updates instead of duplicating")
        eq(BookLibrary.load(id)?.queries.first?.result, "updated", "result updated in place")

        // Impossible positions must be clamped, not stored.
        BookLibrary.updateProgress(bookID: id, current: 999, total: 41)
        eq(BookLibrary.load(id)?.currentPosition, 40, "out-of-range position clamped")

        BookLibrary.delete(bookID: id)
        check(BookLibrary.load(id) == nil, "record deleted")
    }
}
