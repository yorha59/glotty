import SwiftUI
import PDFKit

struct LibraryView: View {
    @State private var books: [BookRecord] = []
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var section: LibrarySection = .library
    @State private var pendingDelete: BookRecord?

    private var selectedBook: BookRecord? { books.first { $0.id == selectedID } }
    private var filteredBooks: [BookRecord] {
        searchText.isEmpty ? books : books.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                navigationRail.frame(width: 104)
                Divider()
                bookshelf.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(minWidth: 340, idealWidth: 400, maxWidth: 460, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1050, minHeight: 650)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .confirmationDialog(
            "Delete this book's record?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let book = pendingDelete else { return }
                BookLibrary.delete(bookID: book.bookID)
                pendingDelete = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let book = pendingDelete {
                Text("This removes “\(book.title)” and everything recorded for it. Cannot be undone.")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Text("GLOTTY")
                .font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.5)
                .frame(width: 104)
            Divider()
            HStack(spacing: 10) {
                Text("Library").font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search library", text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).frame(width: 260, height: 30)
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.18)))
                Button(action: openPanel) { Label("Open Book", systemImage: "plus") }
                    .buttonStyle(SquareButtonStyle(emphasized: true))
            }
            .padding(.horizontal, 18).frame(height: 54)
        }
    }

    private var navigationRail: some View {
        VStack(spacing: 0) {
            ForEach(LibrarySection.allCases) { item in
                Button {
                    section = item
                    if selectedID == nil { selectedID = books.first?.id }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 17))
                        Text(item.label).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .foregroundStyle(section == item ? Color.accentColor : .secondary)
                    .background(section == item ? Color.accentColor.opacity(0.08) : .clear)
                    .overlay(alignment: .leading) {
                        if section == item { Rectangle().fill(Color.accentColor).frame(width: 3) }
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }
            Spacer()
        }
        .background(Color.primary.opacity(0.025))
    }

    private var bookshelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bookshelf").font(.system(size: 24, weight: .semibold))
                Text("\(filteredBooks.count) books").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)

            if books.isEmpty {
                emptyLibrary
            } else if filteredBooks.isEmpty {
                ContentUnavailableView.search(text: searchText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 30)], spacing: 34) {
                        ForEach(filteredBooks) { book in
                            LibraryBookCard(book: book, selected: book.id == selectedID)
                                .onTapGesture {
                                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(book) }
                                    else { selectedID = book.id }
                                }
                                .contextMenu {
                                    Button { open(book) } label: { Label("Open", systemImage: "book") }
                                        .disabled(!fileExists(book))
                                    Divider()
                                    Button(role: .destructive) { pendingDelete = book } label: {
                                        Label("Delete…", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 34)
                }
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let book = selectedBook {
            BookInspectorView(book: book, section: section, open: { open(book) }).id(book.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(books.isEmpty ? "No book selected" : "Select a book")
                    .font(.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Your bookshelf is empty").font(.headline)
            Text("Open an EPUB or PDF to start reading.").font(.callout).foregroundStyle(.secondary)
            Button("Open Book") { openPanel() }.buttonStyle(SquareButtonStyle(emphasized: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileExists(_ book: BookRecord) -> Bool {
        book.path.map(FileManager.default.fileExists(atPath:)) ?? false
    }

    private func open(_ book: BookRecord) {
        guard let path = book.path, FileManager.default.fileExists(atPath: path) else { return }
        ReaderWindowController.shared.open(url: URL(fileURLWithPath: path))
    }

    private func openPanel() {
        ReaderWindowController.shared.chooseBook(over: LibraryWindowController.shared.window)
    }

    private func reload() {
        books = BookLibrary.all()
        if selectedBook == nil { selectedID = books.first?.id }
    }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case library, bookmarks, lookups
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self { case .library: "Library"; case .bookmarks: "Bookmarks"; case .lookups: "Look-ups" }
    }
    var title: LocalizedStringKey {
        switch self { case .library: "Recent Activity"; case .bookmarks: "Bookmarks"; case .lookups: "Look-ups" }
    }
    var icon: String {
        switch self { case .library: "books.vertical"; case .bookmarks: "bookmark"; case .lookups: "text.magnifyingglass" }
    }
}

private struct LibraryBookCard: View {
    let book: BookRecord
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LibraryBookCover(book: book, width: 150, height: 212).frame(maxWidth: .infinity)
            Text(book.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(book.queries.count) look-ups · \(book.lastOpened.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(Rectangle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

private struct BookInspectorView: View {
    let book: BookRecord
    let section: LibrarySection
    let open: () -> Void
    @State private var bookmarks: [ReaderState.Bookmark] = []

    private var isPDF: Bool { book.path.map { ($0 as NSString).pathExtension.lowercased() == "pdf" } ?? false }
    private var hasFile: Bool { book.path.map(FileManager.default.fileExists(atPath:)) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("BOOK DETAILS").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    LibraryBookCover(book: book, width: 72, height: 102)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(book.title).font(.title3.weight(.semibold)).lineLimit(3)
                        Text("\(book.queries.count) look-ups · \(book.dialogueList.count) conversations")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(action: open) { Label("Open Reader", systemImage: "book") }
                            .buttonStyle(SquareButtonStyle(emphasized: true)).disabled(!hasFile)
                    }
                }
                progress
                pathRow
            }
            .padding(22)
            Divider()
            HStack {
                Text(section.title).font(.headline)
                Spacer()
                Text(sectionCount).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).frame(height: 48)
            Divider()
            sectionContent
        }
        .task(id: book.id) { bookmarks = ReaderState.savedBookmarks(for: book.bookID) }
    }

    @ViewBuilder private var progress: some View {
        if let current = book.currentPosition, let total = book.totalPositions, total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.1))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * min(1, Double(current + 1) / Double(total)))
                    }
                }.frame(height: 4)
                Text("\(isPDF ? "Page" : "Chapter") \(current + 1) of \(total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var pathRow: some View {
        if let path = book.path {
            HStack(spacing: 5) {
                Image(systemName: hasFile ? "folder" : "exclamationmark.triangle.fill")
                Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .font(.caption2).foregroundStyle(hasFile ? Color.secondary : Color.orange).help(path)
        }
    }

    private var sectionCount: String {
        switch section {
        case .library: "\(book.queries.count + book.dialogueList.count + bookmarks.count) items"
        case .bookmarks: "\(bookmarks.count)"
        case .lookups: "\(book.queries.count)"
        }
    }

    @ViewBuilder private var sectionContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch section {
                case .library:
                    if bookmarks.isEmpty && book.queries.isEmpty && book.dialogueList.isEmpty { emptySection("Nothing recorded yet") }
                    ForEach(bookmarks) { bookmarkRow($0) }
                    ForEach(book.queries.sorted { $0.date > $1.date }) { queryRow($0) }
                    ForEach(book.dialogueList.sorted { $0.date > $1.date }) { dialogueRow($0) }
                case .bookmarks:
                    if bookmarks.isEmpty { emptySection("No bookmarks yet") }
                    ForEach(bookmarks) { bookmarkRow($0) }
                case .lookups:
                    if book.queries.isEmpty { emptySection("No look-ups yet") }
                    ForEach(book.queries.sorted { $0.date > $1.date }) { queryRow($0) }
                }
            }
        }
    }

    private func emptySection(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.callout).foregroundStyle(.secondary).padding(22).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.horizontal, 22).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func bookmarkRow(_ item: ReaderState.Bookmark) -> some View {
        row {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Color.red).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(isPDF ? "p.\(item.page + 1)" : "ch.\(item.chapter + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle()).onTapGesture { openAt(item) }
    }

    private func queryRow(_ query: QueryRecord) -> some View {
        row {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(query.term).font(.headline).lineLimit(1)
                    Text(query.kind == "translate" ? "TRANSLATION" : "EXPLANATION")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tint)
                    Spacer()
                    Text(query.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.secondary)
                }
                ReaderMarkdownText(text: query.result).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func dialogueRow(_ dialogue: SavedDialogue) -> some View {
        row {
            DisclosureGroup {
                ForEach(dialogue.messages) { message in
                    Text(message.text).font(.callout).textSelection(.enabled).padding(.vertical, 4)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dialogue.title).font(.headline).lineLimit(1)
                    Text("\(dialogue.messages.count) messages · \(dialogue.date.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openAt(_ bookmark: ReaderState.Bookmark) {
        guard let path = book.path, hasFile else { return }
        ReaderWindowController.shared.open(url: URL(fileURLWithPath: path))
        ReaderWindowController.shared.state.goToBookmark(bookmark)
    }
}

private struct LibraryBookCover: View {
    let book: BookRecord
    let width: CGFloat
    let height: CGFloat
    @State private var cover: NSImage?

    var body: some View {
        Group {
            if let cover { Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(Color.primary.opacity(0.08)).overlay(Image(systemName: "book.closed").foregroundStyle(.secondary)) }
        }
        .frame(width: width, height: height).clipped()
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.18)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 5)
        .task(id: book.id) { await loadCover() }
    }

    private func loadCover() async {
        cover = nil
        guard let path = book.path, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
                return page.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox)
            }
            return EPUBBook.coverData(at: url).flatMap(NSImage.init(data:))
        }.value
        guard !Task.isCancelled else { return }
        cover = image
    }
}

private struct SquareButtonStyle: ButtonStyle {
    var emphasized = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(emphasized ? Color.white : Color.primary)
            .background(emphasized ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) : Color.primary.opacity(0.06))
            .overlay(Rectangle().strokeBorder(emphasized ? Color.clear : Color.primary.opacity(0.18)))
    }
}
