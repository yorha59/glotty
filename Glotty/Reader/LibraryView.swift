import SwiftUI
import PDFKit

/// The Library: every book the reader has opened, with its recorded look-ups.
/// Reads `BookLibrary` on appear; select a book to see its query history and
/// reopen it. Right-click a row to delete its record.
struct LibraryView: View {
    @State private var books: [BookRecord] = []
    @State private var selectedID: String?
    /// The row a delete was requested for — driving the confirmation below.
    /// Non-nil is exactly "confirmation showing".
    @State private var pendingDelete: BookRecord?

    private func fileExists(_ b: BookRecord) -> Bool {
        guard let p = b.path else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    private func open(_ b: BookRecord) {
        guard let p = b.path, FileManager.default.fileExists(atPath: p) else { return }
        ReaderWindowController.shared.open(url: URL(fileURLWithPath: p))
    }

    private func openPanel() {
        ReaderWindowController.shared.chooseBook(over: LibraryWindowController.shared.window)
    }

    var body: some View {
        NavigationSplitView {
            List(books, selection: $selectedID) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).lineLimit(1)
                    Text("\(b.queries.count) look-ups · \(b.lastOpened.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(b.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Selection is set here rather than left to `List(selection:)`,
                // in one gesture that branches on the click count. Two tap
                // gestures on a row (count 2 and count 1) leave SwiftUI to pick
                // a winner, and the loser silently never fires — which is how a
                // click came to land on a row and change nothing.
                .onTapGesture {
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(b) }
                    else { selectedID = b.id }
                }
                .contextMenu {
                    Button { open(b) } label: { Label("Open", systemImage: "book") }
                        .disabled(!fileExists(b))
                    Divider()
                    Button(role: .destructive) { pendingDelete = b } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(Text("Library"))
            .frame(minWidth: 250)
            .toolbar {
                // The Library is the app's start page, so it has to be able to
                // open a file that isn't in it yet — otherwise a first run,
                // with nothing recorded, is a dead end.
                Button { openPanel() } label: { Label("Open Book…", systemImage: "plus") }
                    .help("Open an EPUB or PDF")
            }
        } detail: {
            if let b = books.first(where: { $0.id == selectedID }) {
                BookDetailView(book: b)
            } else if books.isEmpty {
                ContentUnavailableView {
                    Label("No books yet", systemImage: "books.vertical")
                } description: {
                    Text("Open an EPUB or PDF to start reading. Books you open show up here with their look-ups and conversations.")
                } actions: {
                    Button("Open Book…") { openPanel() }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Select a book", systemImage: "books.vertical")
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { books = BookLibrary.all() }
        // The list is a snapshot taken on appear; opening a book updates its
        // record (position, last-opened), so re-read when we come back to it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            books = BookLibrary.all()
        }
        // Matches SettingsView's "Clear history…" confirmations — a question
        // title, a scope+irreversibility message, a repeat-the-verb destructive
        // button. Named in the message (not the title) since a right-click can
        // target any row and the title alone wouldn't say which book.
        .confirmationDialog(
            "Delete this book's record?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let b = pendingDelete else { return }
                BookLibrary.delete(bookID: b.bookID)
                books = BookLibrary.all()
                if selectedID == b.id { selectedID = nil }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let b = pendingDelete {
                Text("This removes “\(b.title)” and everything recorded for it — look-ups, conversations, and reading progress. Cannot be undone.")
            }
        }
    }
}

private struct BookDetailView: View {
    let book: BookRecord
    @State private var cover: NSImage?
    @State private var bookmarks: [ReaderState.Bookmark] = []

    private var isPDF: Bool {
        (book.path.map { ($0 as NSString).pathExtension.lowercased() } ?? "") == "pdf"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                coverView
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.title2).bold().lineLimit(2)
                    Text("\(book.queries.count) look-ups").font(.caption).foregroundStyle(.secondary)
                    if let current = book.currentPosition, let total = book.totalPositions, total > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: Double(current + 1), total: Double(total))
                                .frame(maxWidth: 200)
                            Text("\(isPDF ? "Page" : "Chapter") \(current + 1) of \(total)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    pathRow
                }
                Spacer()
                if let path = book.path, FileManager.default.fileExists(atPath: path) {
                    Button {
                        ReaderWindowController.shared.open(url: URL(fileURLWithPath: path))
                    } label: { Label("Open", systemImage: "book") }
                }
            }
            .padding()
            Divider()
            if book.queries.isEmpty && book.dialogueList.isEmpty && bookmarks.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !bookmarks.isEmpty {
                        Section("Bookmarks") {
                            ForEach(bookmarks) { bookmarkRow($0) }
                        }
                    }
                    if !book.queries.isEmpty {
                        Section("Look-ups") {
                            ForEach(book.queries.sorted { $0.date > $1.date }) { queryRow($0) }
                        }
                    }
                    if !book.dialogueList.isEmpty {
                        Section("Conversations") {
                            ForEach(book.dialogueList.sorted { $0.date > $1.date }) { dialogueRow($0) }
                        }
                    }
                }
            }
        }
        .task(id: book.id) {
            bookmarks = ReaderState.savedBookmarks(for: book.bookID)
            await loadCover()
        }
    }

    /// Where the file actually lives. Truncated in the middle so both the
    /// folder and the filename stay readable; the full path is selectable and
    /// in the tooltip. A record outlives the file it points at (moved, renamed,
    /// deleted), so say so rather than showing a path that no longer resolves.
    @ViewBuilder
    private var pathRow: some View {
        if let path = book.path {
            let exists = FileManager.default.fileExists(atPath: path)
            HStack(spacing: 4) {
                Image(systemName: exists ? "folder" : "exclamationmark.triangle.fill")
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.caption2)
            .foregroundStyle(exists ? Color.secondary : Color.orange)
            .help(exists ? path : String(localized: "File not found at \(path)"))
            .padding(.top, 2)
        }
    }

    private var coverView: some View {
        Group {
            if let cover {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        .frame(width: 68, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
    }

    /// Cover art, loaded off the reading path entirely so browsing the Library
    /// never touches temp-directory extraction (EPUB) or the full reader
    /// pipeline (PDF) — see EPUBBook.coverData's doc comment.
    private func loadCover() async {
        cover = nil
        guard let path = book.path, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            if url.pathExtension.lowercased() == "pdf" {
                guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
                return page.thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
            }
            return EPUBBook.coverData(at: url).flatMap(NSImage.init(data:))
        }.value
        // The task can outlive a fast re-selection; id-scoping via .task(id:)
        // already cancels the old task, but confirm we're still on this book
        // before publishing, since Task.detached's cancellation is cooperative.
        guard !Task.isCancelled else { return }
        cover = img
    }

    /// A saved place, shown the way the reader's own list shows it: where it
    /// is and when it was made. Clicking opens the book there rather than at
    /// wherever reading last stopped.
    private func bookmarkRow(_ b: ReaderState.Bookmark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.label).font(.callout.weight(.medium)).lineLimit(1)
                Text(b.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(isPDF ? "p.\(b.page + 1)" : "ch.\(b.chapter + 1) · p.\(b.page + 1)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { openAt(b) }
    }

    /// Open the book and jump to the bookmark.
    private func openAt(_ b: ReaderState.Bookmark) {
        guard let p = book.path, FileManager.default.fileExists(atPath: p) else { return }
        ReaderWindowController.shared.open(url: URL(fileURLWithPath: p))
        ReaderWindowController.shared.state.goToBookmark(b)
    }

    private func queryRow(_ q: QueryRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(q.term).font(.headline).lineLimit(1)
                Text(q.kind == "translate" ? "Translation" : "Explanation")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(.tint)
                Spacer()
                Text(q.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Explanations come back as Markdown; render it rather than showing
            // raw ## and - (same as the chat).
            ReaderMarkdownText(text: q.result)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
    }

    private func dialogueRow(_ d: SavedDialogue) -> some View {
        DisclosureGroup {
            ForEach(d.messages) { m in
                HStack(alignment: .top, spacing: 8) {
                    Text(m.role == "user" ? "You" : "Glotty")
                        .font(.caption2).bold()
                        .foregroundStyle(m.role == "user" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 46, alignment: .leading)
                    Text(m.text).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.headline).lineLimit(1)
                Text("\(d.messages.count) messages · \(d.date.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
