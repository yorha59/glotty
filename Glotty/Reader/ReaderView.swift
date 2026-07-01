import SwiftUI

/// The reader UI: a toggleable table-of-contents sidebar, a control bar
/// (chapter nav, font size, theme), and the chapter web view. A tap on any word
/// runs Glotty's explain popup and underlines the word.
struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @State private var showTOC = true

    var body: some View {
        if let book = state.book {
            HStack(spacing: 0) {
                if showTOC {
                    tocSidebar(book)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                VStack(spacing: 0) {
                    controlBar(book)
                    Divider()
                    EPUBWebView(
                        book: book,
                        chapterIndex: state.chapterIndex,
                        fontScale: state.fontScale,
                        theme: state.theme,
                        fontCSS: state.font.css ?? "",
                        lookedUp: state.lookedUp,
                        onLookup: { word in
                            state.markLookedUp(word)
                            (NSApp.delegate as? AppDelegate)?.handleFire(mode: .explain, providedText: word)
                        }
                    )
                    .id(book.identifier)   // fresh web view per book
                }
            }
        } else {
            emptyState
        }
    }

    private func tocSidebar(_ book: EPUBBook) -> some View {
        List {
            Section(book.title) {
                ForEach(Array(book.toc.enumerated()), id: \.element.id) { _, item in
                    Button {
                        if let i = item.chapterIndex { state.goto(i) }
                    } label: {
                        HStack {
                            Text(item.label).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .foregroundStyle(item.chapterIndex == state.chapterIndex ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.chapterIndex == nil)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func controlBar(_ book: EPUBBook) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { showTOC.toggle() } } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle contents")

            Spacer()

            Button { state.prev() } label: { Image(systemName: "chevron.left") }
                .disabled(state.chapterIndex <= 0)
            Text("\(state.chapterIndex + 1) / \(state.chapterCount)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { state.next() } label: { Image(systemName: "chevron.right") }
                .disabled(state.chapterIndex >= state.chapterCount - 1)

            Spacer()

            Button { state.adjustFont(-0.1) } label: { Text("A").font(.system(size: 12)) }
                .help("Smaller text")
            Button { state.adjustFont(0.1) } label: { Text("A").font(.system(size: 18)) }
                .help("Larger text")
            Picker("", selection: $state.font) {
                ForEach(ReaderState.ReaderFont.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Font")
            Picker("", selection: $state.theme) {
                ForEach(ReaderState.Theme.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Background")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Open an EPUB to start reading.")
                .foregroundStyle(.secondary)
            Button("Open Book…") { ReaderWindowController.shared.openBook() }
                .buttonStyle(.borderedProminent)
            if let err = state.openError {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
