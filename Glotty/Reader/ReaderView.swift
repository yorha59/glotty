import SwiftUI
import PDFKit

/// The reader UI: a toggleable table-of-contents sidebar, a control bar
/// (chapter nav, font size, theme), and the chapter web view. A tap on any word
/// runs Glotty's explain popup and underlines the word.
struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @State private var showTOC = true
    @State private var showCustomize = false
    @StateObject private var chat = ReaderChat()
    @State private var showChat = true
    @AppStorage("glotty.reader.chatWidth") private var chatWidth: Double = 380
    @State private var chatDragStart: Double?
    /// Live EPUB selection, mirrored out of the web view so ⌘T can act on it.
    @State private var epubSelection = ""
    /// Page count for the current chapter; the position itself lives in
    /// ReaderState so it persists with the chapter.
    @State private var epubPageCount = 1
    /// Set when the reader pages backwards into a chapter, so it opens at the end.
    @State private var landOnLastPage = false

    var body: some View {
        Group {
            if let book = state.book { epubBody(book) }
            else if let pdf = state.pdf { pdfBody(pdf) }
            else { emptyState }
        }
        .onAppear {
            chat.setBook(state.bookInfo)
            // Read at send time, so a question is answered about the page the
            // user is on right then — not the one open when the panel appeared.
            chat.pageTextProvider = { [weak state] in state?.visiblePageText ?? "" }
        }
        .onChange(of: state.bookInfo) { _, info in chat.setBook(info) }
    }

    private func epubBody(_ book: EPUBBook) -> some View {
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
                    bookID: book.identifier,
                    chapterIndex: state.chapterIndex,
                    fontScale: state.fontScale,
                    bg: state.bgColorHex,
                    fg: state.fgColorHex,
                    lineHeight: state.lineHeight,
                    letterSpacing: state.letterSpacing,
                    fontCSS: state.font.css ?? "",
                    lookedUp: state.lookedUp,
                    onLookup: { word in
                        // The result is captured into the library + the word
                        // underlined (see the popup).
                        ReaderMark.pending = word
                        ReaderMark.capture = state.queryCapture(term: word, kind: "explain")
                        ReaderCore.services?.lookUp(word)
                    },
                    onRemoveUnderline: { state.unmarkLookedUp($0) },
                    onTranslate: translateSelection,
                    onAsk: { text in
                        chat.attach(text)
                        withAnimation(.easeInOut(duration: 0.18)) { showChat = true }
                    },
                    onSelectionChange: { epubSelection = $0 },
                    page: $state.pageIndex,
                    pageCount: $epubPageCount,
                    onChapterFlip: { dir in flipChapter(book, dir) },
                    onPageText: { state.visiblePageText = $0 },
                    landOnLastPage: landOnLastPage
                )
                .id(book.identifier)   // fresh web view per book
                .background(translateShortcut)
                pageBar(book)
            }
            if showChat {
                chatResizeHandle
                ReaderChatPanel(chat: chat, width: CGFloat(chatWidth),
                                onClose: { withAnimation(.easeInOut(duration: 0.18)) { showChat = false } })
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Page counter under the text, Books-style: position in the chapter and
    /// how much of it is left. Paging past either end moves chapter.
    private func pageBar(_ book: EPUBBook) -> some View {
        let left = max(0, epubPageCount - state.pageIndex - 1)
        return HStack(spacing: 12) {
            Button { turnPage(book, -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(state.pageIndex == 0 && state.chapterIndex == 0)
            Spacer()
            Text("\(state.pageIndex + 1) of \(epubPageCount)")
            Spacer()
            Text(left == 0 ? "End of chapter" : "^[\(left) page](inflect: true) left in chapter")
            Spacer()
            Button { turnPage(book, 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(state.pageIndex >= epubPageCount - 1
                      && state.chapterIndex >= book.chapters.count - 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Turn one page, rolling over into the neighbouring chapter at the ends.
    private func turnPage(_ book: EPUBBook, _ dir: Int) {
        let next = state.pageIndex + dir
        if next < 0 || next >= epubPageCount { flipChapter(book, dir) } else { state.pageIndex = next }
    }

    private func flipChapter(_ book: EPUBBook, _ dir: Int) {
        let next = state.chapterIndex + dir
        guard book.chapters.indices.contains(next) else { return }
        landOnLastPage = dir < 0     // arriving backwards → open at the end
        state.pageIndex = 0
        state.chapterIndex = next
    }

    /// Translate a selected passage in Glotty's popup, recording it against the
    /// book so it shows up underlined + in the library.
    private func translateSelection(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ReaderMark.capture = state.queryCapture(term: text, kind: "translate")
        ReaderCore.services?.translate(text)
    }

    /// Keyboard path for the chip's Translate button. Zero-sized and behind the
    /// content — it exists only to own the ⌘T shortcut.
    private var translateShortcut: some View {
        Button("Translate Selection") { translateSelection(epubSelection) }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(epubSelection.isEmpty)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func pdfBody(_ pdf: PDFDocument) -> some View {
        HStack(spacing: 0) {
            if showTOC, !state.pdfTOC.isEmpty {
                pdfTOCSidebar
                    .frame(width: 260)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                pdfControlBar(pdf)
                Divider()
                PDFReaderView(
                    doc: pdf,
                    page: $state.pdfPage,
                    translations: [],
                    onLookup: { word in
                        ReaderMark.pending = word
                        ReaderMark.capture = state.queryCapture(term: word, kind: "explain")
                        ReaderCore.services?.lookUp(word)
                    },
                    onTranslate: { _, _, text in
                        // Show the result in Glotty's standard translate popup (a
                        // floating window) rather than an inline band — the popup
                        // owns the working Apple-translation path.
                        translateSelection(text)
                    },
                    onAsk: { text in
                        chat.attach(text)
                        withAnimation(.easeInOut(duration: 0.18)) { showChat = true }
                    },
                    onRemove: { _ in }
                )
            }
            if showChat {
                chatResizeHandle
                ReaderChatPanel(chat: chat, width: CGFloat(chatWidth),
                                onClose: { withAnimation(.easeInOut(duration: 0.18)) { showChat = false } })
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Draggable divider on the chat panel's leading edge — resize like the
    /// VSCode side panel; width persists across sessions.
    private var chatResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .overlay(Divider())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let base = chatDragStart ?? chatWidth
                        if chatDragStart == nil { chatDragStart = chatWidth }
                        chatWidth = min(680, max(300, base - v.translation.width))
                    }
                    .onEnded { _ in chatDragStart = nil }
            )
    }

    private var pdfTOCSidebar: some View {
        List {
            ForEach(state.pdfTOC) { item in
                Button { state.pdfPage = item.pageIndex } label: {
                    HStack {
                        Text(item.label).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(item.level) * 10)
                    .contentShape(Rectangle())
                    .foregroundStyle(item.pageIndex == state.pdfPage ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    private func pdfControlBar(_ pdf: PDFDocument) -> some View {
        HStack(spacing: 12) {
            if !state.pdfTOC.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.18)) { showTOC.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle contents")
            }
            Spacer()
            Button { if state.pdfPage > 0 { state.pdfPage -= 1 } } label: { Image(systemName: "chevron.left") }
                .disabled(state.pdfPage <= 0)
            Text("\(state.pdfPage + 1) / \(pdf.pageCount)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { if state.pdfPage < pdf.pageCount - 1 { state.pdfPage += 1 } } label: { Image(systemName: "chevron.right") }
                .disabled(state.pdfPage >= pdf.pageCount - 1)
            Spacer()

            bookmarkMenu

            Button { withAnimation(.easeInOut(duration: 0.18)) { showChat.toggle() } } label: {
                Image(systemName: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            }
            .help("Toggle chat")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    /// Themes as swatches rather than a segmented control — there are too many
    /// to fit as segments, and a chip rendered in the theme's own colors says
    /// what it does better than its name.
    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                  spacing: 6) {
            ForEach(ReaderState.Theme.allCases) { t in
                let selected = state.theme == t
                Button { state.theme = t } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(readerHex: t.bg))
                            .frame(height: 30)
                            .overlay(Text("Aa").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(readerHex: t.fg)))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                selected ? Color.accentColor : .secondary.opacity(0.35),
                                lineWidth: selected ? 2 : 1))
                        Text(t.label)
                            .font(.system(size: 9))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Bookmarks: the icon shows whether this page is saved, clicking toggles
    /// it, and the menu lists every saved spot to jump back to. Reading
    /// position is restored automatically — bookmarks are for going back to a
    /// place deliberately, not for resuming.
    private var bookmarkMenu: some View {
        Menu {
            Button(state.currentIsBookmarked ? "Remove bookmark" : "Bookmark this page") {
                state.toggleBookmark()
            }
            if !state.bookmarks.isEmpty {
                Divider()
                ForEach(state.bookmarks) { b in
                    Button("\(b.label) — p.\(b.page + 1)") { state.goToBookmark(b) }
                }
                Divider()
                Menu("Remove") {
                    ForEach(state.bookmarks) { b in
                        Button("\(b.label) — p.\(b.page + 1)") { state.removeBookmark(b) }
                    }
                }
            }
        } label: {
            Image(systemName: state.currentIsBookmarked ? "bookmark.fill" : "bookmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.bookmarks.isEmpty ? "Bookmarks" : "Bookmarks (\(state.bookmarks.count))")
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

            bookmarkMenu

            Button { showCustomize.toggle() } label: {
                Text("Aa").font(.system(size: 16, weight: .medium))
            }
            .help("Text & colors")
            .popover(isPresented: $showCustomize, arrowEdge: .bottom) { customizePanel }

            Button { withAnimation(.easeInOut(duration: 0.18)) { showChat.toggle() } } label: {
                Image(systemName: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            }
            .help("Toggle chat")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var customizePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text").font(.headline)
            Picker("Font", selection: $state.font) {
                ForEach(ReaderState.ReaderFont.allCases) { Text($0.label).tag($0) }
            }
            slider("Text size", $state.fontScale, 0.7...2.5) { "\(Int(($0 * 100).rounded()))%" }
            slider("Line spacing", $state.lineHeight, 1.0...2.4) { String(format: "%.2f", $0) }
            slider("Letter spacing", $state.letterSpacing, -0.02...0.15) { String(format: "%.2f em", $0) }

            Divider()

            Text("Background & Text").font(.headline)
            themeGrid
            ColorField(title: "Background", hex: $state.bgColorHex, presets: Self.bgPresets)
            ColorField(title: "Text", hex: $state.fgColorHex, presets: Self.fgPresets)

            Divider()
            HStack {
                Spacer()
                Button("Reset", role: .destructive) { state.resetTypography() }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    static let bgPresets = ["#ffffff", "#f4ecd8", "#e9e6df", "#1c1c1e", "#000000"]
    static let fgPresets = ["#111111", "#333333", "#5b4636", "#d8d8d8", "#ffffff"]

    /// One labeled slider row: title, live value readout, and the slider.
    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ fmt: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(fmt(value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Open an EPUB or PDF to start reading.")
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

/// A lightweight color control: current-color swatch, a hex field you can type
/// or paste a code into, and a row of preset swatches — no full system color
/// panel. Accepts `#rgb` / `#rrggbb` (with or without the `#`); invalid input
/// reverts on commit.
/// The kind of picker htmlcolorcodes.com uses: a saturation × brightness
/// square with a hue strip under it, inline in the panel. Deliberately not the
/// system `ColorPicker`, which throws up a separate window with wheel, palette,
/// image and crayon tabs.
private struct SimpleColorPicker: View {
    @Binding var hex: String
    @State private var hue = 0.0
    @State private var sat = 0.0
    @State private var bri = 0.0

    private static let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12)
        .map { Color(hue: $0, saturation: 1, brightness: 1) }

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black],
                                   startPoint: .top, endPoint: .bottom)
                    knob.position(x: sat * geo.size.width, y: (1 - bri) * geo.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    sat = clamp(v.location.x / geo.size.width)
                    bri = 1 - clamp(v.location.y / geo.size.height)
                    push()
                })
            }
            .frame(height: 84)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: Self.hues, startPoint: .leading, endPoint: .trailing)
                    knob.position(x: hue * geo.size.width, y: geo.size.height / 2)
                }
                .clipShape(Capsule())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    hue = clamp(v.location.x / geo.size.width)
                    push()
                })
            }
            .frame(height: 12)
        }
        .onAppear(perform: pull)
        .onChange(of: hex) { _, _ in pull() }
    }

    private var knob: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 2)
            .background(Circle().fill(.clear))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.5), radius: 1)
    }

    private func clamp(_ v: Double) -> Double { min(max(0, v), 1) }

    private func push() { hex = Color(hue: hue, saturation: sat, brightness: bri).readerHex }

    /// Adopt an externally-set hex (preset button, typed code). Skipped when it
    /// already matches what our own HSB produces — otherwise picking a grey or
    /// a black would snap the hue knob back to red, since those have no hue.
    private func pull() {
        guard Color(hue: hue, saturation: sat, brightness: bri).readerHex.lowercased()
                != hex.lowercased() else { return }
        let ns = NSColor(Color(readerHex: hex)).usingColorSpace(.sRGB) ?? .black
        hue = ns.hueComponent; sat = ns.saturationComponent; bri = ns.brightnessComponent
    }
}

private struct ColorField: View {
    let title: LocalizedStringKey
    @Binding var hex: String
    let presets: [String]

    @State private var draft = ""
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.15)) { picking.toggle() } } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(readerHex: hex))
                        .frame(width: 26, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(picking ? Color.accentColor : .secondary.opacity(0.4),
                                          lineWidth: picking ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Pick a color")
                TextField("#RRGGBB", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 92)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
            }
            if picking { SimpleColorPicker(hex: $hex) }
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { p in
                    Button { hex = p } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(readerHex: p))
                            .frame(width: 28, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(p.lowercased() == hex.lowercased()
                                                  ? Color.accentColor : Color.secondary.opacity(0.3),
                                                  lineWidth: p.lowercased() == hex.lowercased() ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        if let n = Self.normalize(draft) { hex = n; draft = n } else { draft = hex }
    }

    private static func normalize(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, t.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + t.lowercased()
    }
}
