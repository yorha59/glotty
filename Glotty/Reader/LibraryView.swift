import SwiftUI

/// The Library: every book the reader has opened, with its recorded look-ups.
/// Reads `BookLibrary` on appear; select a book to see its query history and
/// reopen it.
struct LibraryView: View {
    @State private var books: [BookRecord] = []
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            List(books, selection: $selectedID) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).lineLimit(1)
                    Text("\(b.queries.count) look-ups · \(b.lastOpened.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(b.id)
            }
            .navigationTitle(Text("Library"))
            .frame(minWidth: 250)
        } detail: {
            if let b = books.first(where: { $0.id == selectedID }) {
                BookDetailView(book: b)
            } else {
                ContentUnavailableView("Select a book", systemImage: "books.vertical")
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { books = BookLibrary.all() }
    }
}

private struct BookDetailView: View {
    let book: BookRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.title2).bold().lineLimit(2)
                    Text("\(book.queries.count) look-ups").font(.caption).foregroundStyle(.secondary)
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
            if book.queries.isEmpty && book.dialogueList.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
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
            Text(q.result).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
