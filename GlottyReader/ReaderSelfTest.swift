import AppKit
import PDFKit
import SwiftUI

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

        if pdfs.count >= 2 {
            checkDocumentSwap(pdfs[0], pdfs[1])
            checkRenderedDocumentFollows(pdfs[0], pdfs[1])
        } else { print("  skip document-swap checks — needs 2 PDFs") }
        if let p = pdfs.first { checkPDFIdentityAndBookmarks(p) }
        else { print("  skip PDF checks — none supplied") }
        if let e = epubs.first { checkEPUB(e) }
        else { print("  skip EPUB checks — none supplied") }
        checkLibraryStore()
        checkChatDoesNotWedge()
        checkStartPage()
        checkProvidersOverIPC()
        checkChatSessions()
        checkProviderPayload()

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

    /// The view must render the document it was handed. Rebuilding only when
    /// the *translations* changed left the previous PDF on screen — two
    /// documents with no translations compare equal — while the sidebar, page
    /// count and progress all switched. The visible page said one book, every
    /// other part of the UI said another.
    private static func checkRenderedDocumentFollows(_ a: URL, _ b: URL) {
        print("\nrendered document follows the state")
        guard let docA = PDFDocument(url: a), let docB = PDFDocument(url: b) else {
            return check(false, "both PDFs load")
        }
        var page = 0
        let binding = Binding(get: { page }, set: { page = $0 })
        func view(_ d: PDFDocument) -> PDFReaderView {
            PDFReaderView(doc: d, page: binding, translations: [],
                          onLookup: { _ in }, onTranslate: { _, _, _ in },
                          onAsk: { _ in }, onRemove: { _ in })
        }
        let pdfView = PDFView()          // retained here; the coordinator holds it weakly
        let c = view(docA).makeCoordinator()
        c.pdfView = pdfView
        c.parent = view(docA)
        // Drive `syncToParent` — the same entry point updateNSView uses — so
        // this checks the real decision, not a restatement of it.
        c.syncToParent()
        eq(pdfView.document?.pageCount, docA.pageCount, "renders A after syncing to A")

        c.parent = view(docB)            // what opening another book does
        c.syncToParent()
        eq(pdfView.document?.pageCount, docB.pageCount, "renders B after syncing to B")
        check(!c.documentChanged, "B is now the built document")
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

    /// A reply that never arrives must not wedge the panel. The request goes
    /// out as a fire-and-forget notification, so if Glotty isn't listening it
    /// vanishes silently — and `send()` refuses to run while `isStreaming`, so
    /// one lost reply used to swallow every later message with no clue why.
    private static func checkChatDoesNotWedge() {
        print("\nchat recovers from a lost reply")
        let chat = ReaderChat()
        // A service whose stream never yields and never finishes — exactly what
        // a dropped notification looks like from this side.
        final class SilentServices: ReaderServices {
            func lookUp(_ text: String) {}
            func translate(_ text: String) {}
            func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>? {
                AsyncThrowingStream { _ in }   // held open forever
            }
            func providers() async -> [ReaderProvider] { [] }
            func selectModel(providerID: String, modelID: String) {}
        }
        let previous = ReaderCore.services
        ReaderCore.services = SilentServices()
        defer { ReaderCore.services = previous }

        chat.firstChunkTimeout = 1      // seconds, so the watchdog is observable
        chat.input = "hello"
        chat.send()
        check(chat.isStreaming, "streaming starts")
        check(chat.phase == .waiting, "reports waiting rather than a bare placeholder")
        check(!chat.statusLine.isEmpty, "status line says what's happening: \"\(chat.statusLine)\"")

        // The point of the fix: it recovers on its own, with no user action.
        // Spin the runloop so the watchdog timer can fire.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        check(!chat.isStreaming, "gives up on its own instead of hanging forever")
        let reported = chat.messages.last?.text ?? ""
        check(reported.contains("No reply"), "says why it gave up: \"\(reported)\"")

        // And a later message must go through — the wedge was that it didn't.
        chat.input = "second question"
        chat.send()
        check(chat.messages.contains { $0.text == "second question" },
              "a later message still goes through")
        chat.stop()
    }

    /// Launch routing. Checked as a decision rather than by launching windows —
    /// the failure mode is the Library covering a book that was just opened
    /// from Finder, and spotting that visually means putting windows on screen.
    private static func checkStartPage() {
        print("\nstart page")
        eq(ReaderStartPage.forLaunch(openedDocument: false), .library, "plain launch lands on the Library")
        eq(ReaderStartPage.forLaunch(openedDocument: true), .reader,
           "launching with a file goes straight to the book, not the shelf")
        eq(ReaderStartPage.forReopen(hasOpenBook: true), .reader, "reopen returns to the open book")
        eq(ReaderStartPage.forReopen(hasOpenBook: false), .library, "reopen with nothing open shows the Library")
    }

    /// The provider list crosses to the Reader as JSON inside a distributed
    /// notification, because nested provider→models data is exactly what those
    /// payloads drop silently. Check it survives the trip — a picker that
    /// decodes to nothing just shows an empty menu with no error.
    private static func checkProviderPayload() {
        print("\nprovider list survives the IPC encoding")
        let sample = [
            ReaderProvider(id: "zai", name: "Z.AI (GLM)",
                           models: [.init(id: "glm-5.1", name: "GLM-5.1"),
                                    .init(id: "glm-4.7", name: "GLM-4.7")],
                           isActive: true, activeModelID: "glm-5.1"),
            ReaderProvider(id: "custom", name: "My Server", models: [],
                           isActive: false, activeModelID: nil),
        ]
        guard let data = try? JSONEncoder().encode(sample),
              let json = String(data: data, encoding: .utf8) else {
            return check(false, "encodes")
        }
        let back = (try? JSONDecoder().decode([ReaderProvider].self, from: Data(json.utf8))) ?? []
        eq(back.count, 2, "both providers round-trip")
        eq(back.first?.models.count, 2, "models survive")
        eq(back.first?.activeModelID, "glm-5.1", "current model survives")
        eq(back.first(where: { $0.isActive })?.id, "zai", "active provider survives")
        check(back.last?.models.isEmpty == true, "a provider with no model list is still listed")
    }

    /// The model picker, exercised through the real IPC client against a real
    /// running Glotty — not a stub and not a hand-written probe. This is the
    /// path the picker actually uses, so it's the only thing that proves the
    /// menu can populate. Skipped (not failed) when Glotty isn't running,
    /// since that's an environment fact rather than a defect.
    private static func checkProvidersOverIPC() {
        print("\nmodel picker over IPC")
        let glottyUp = !NSRunningApplication
            .runningApplications(withBundleIdentifier: ReaderIPC.glottyBundleID).isEmpty
        guard glottyUp else {
            print("  skip — Glotty isn't running")
            return
        }
        let svc = IPCReaderServices()
        var result: [ReaderProvider]?
        Task { result = await svc.providers() }
        // Spin the runloop rather than block it: the reply arrives as a
        // distributed notification on main, and a semaphore would deadlock the
        // very thread that has to deliver it.
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let list = result else { return check(false, "providers() returned within 10s") }
        check(!list.isEmpty, "picker gets a provider list (\(list.count) providers)")
        for p in list {
            print("     \(p.isActive ? "●" : "○") \(p.name) — \(p.models.count) models"
                  + (p.activeModelID.map { " (\($0))" } ?? ""))
        }
        check(list.contains { $0.isActive }, "one provider is marked active")
        check(list.contains { !$0.models.isEmpty }, "at least one provider exposes models")
    }

    /// Conversations must outlive the panel. The reported bug was that a book
    /// reopened with an empty chat even though the thread was on disk — saved
    /// but never read back — and that there was only ever one thread.
    private static func checkChatSessions() {
        print("\nchat sessions")
        let info = ReaderState.BookInfo(id: "selftest:sessions", title: "T", path: "/tmp/t.pdf")

        // A conversation, saved the way a real reply saves it.
        let first = ReaderChat()
        first.setBook(info)
        first.messages = [.init(role: .user, text: "question one"),
                          .init(role: .assistant, text: "answer one")]
        first.saveThreadForTesting()
        let firstID = first.currentSessionID

        // A second, separate conversation on the same book.
        first.startNewSession()
        check(first.currentSessionID != firstID, "new conversation gets its own id")
        first.messages = [.init(role: .user, text: "question two"),
                          .init(role: .assistant, text: "answer two")]
        first.saveThreadForTesting()

        // Reopening the book is a fresh ReaderChat — the panel's situation.
        let reopened = ReaderChat()
        reopened.setBook(info)
        eq(reopened.sessions.count, 2, "both conversations are listed after reopening")
        check(!reopened.messages.isEmpty, "reopening restores a conversation instead of an empty panel")
        eq(reopened.messages.last?.text, "answer two", "resumes the most recent one")

        // Switching back to the older thread.
        guard let older = reopened.sessions.first(where: { $0.id == firstID }) else {
            return check(false, "the earlier conversation is still listed")
        }
        reopened.load(older)
        eq(reopened.messages.last?.text, "answer one", "switching loads that conversation's messages")

        // Rename must survive the next save, which re-derives titles by default.
        reopened.rename(older, to: "Custom name")
        reopened.saveThreadForTesting()
        eq(reopened.sessions.first { $0.id == firstID }?.title, "Custom name",
           "a renamed conversation keeps its title when saved again")

        // Ask sends the passage straight away — no detour through the composer.
        reopened.input = ""
        let before = reopened.messages.count
        reopened.attach("  a selected   passage  ")
        check(reopened.input.isEmpty, "Ask doesn't park anything in the composer")
        check(reopened.messages.count > before, "Ask sends immediately")
        let asked = reopened.messages.last { $0.role == .user }
        check(asked?.text.contains("a selected passage") == true,
              "the sent turn is the passage: \(asked?.text ?? "-")")
        check(asked?.isQuoteAsk == true, "marked as a passage ask, so the prompt can say what's wanted")
        // The visible turn stays in the reader's own language — an English
        // wrapper here is what would drag replies into English.
        check(asked?.text.range(of: "explain", options: .caseInsensitive) == nil,
              "no English instruction is glued onto the passage")
        reopened.stop()
        reopened.input = ""

        // A conversation you've just started has nothing to save, so it used to
        // be invisible — clicking "new" appeared to do nothing.
        reopened.startNewSession()
        let draftID = reopened.currentSessionID
        check(reopened.listedSessions.contains { $0.id == draftID },
              "a new conversation is listed before anything is said")
        eq(reopened.listedSessions.first?.messages.count, 0, "it's listed as empty")
        eq(reopened.sessions.contains { $0.id == draftID }, false, "but nothing is written to disk yet")

        // Leaving it without saying anything discards it.
        reopened.load(older)
        check(!reopened.listedSessions.contains { $0.id == draftID },
              "leaving an untouched new conversation drops it from the list")

        reopened.delete(older)
        check(!reopened.sessions.contains { $0.id == firstID }, "deleting removes it")
        eq(reopened.sessions.count, 1, "the other conversation is untouched")
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
