import SwiftUI
import PDFKit

/// The reader UI: a toggleable table-of-contents sidebar, a control bar
/// (chapter nav, font size, theme), and the chapter web view. A tap on any word
/// runs Glotty's explain popup and underlines the word.
struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @State private var showTOC = true
    @State private var showCustomize = false

    var body: some View {
        if let book = state.book { epubBody(book) }
        else if let pdf = state.pdf { pdfBody(pdf) }
        else { emptyState }
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
                    chapterIndex: state.chapterIndex,
                    fontScale: state.fontScale,
                    bg: state.bgColorHex,
                    fg: state.fgColorHex,
                    lineHeight: state.lineHeight,
                    letterSpacing: state.letterSpacing,
                    fontCSS: state.font.css ?? "",
                    lookedUp: state.lookedUp,
                    onLookup: { word in
                        // Tapping only looks up the meaning; marking is deliberate
                        // (the popup's Mark button). Arm it for this word.
                        ReaderMark.pending = word
                        (NSApp.delegate as? AppDelegate)?.handleFire(mode: .explain, providedText: word)
                    }
                )
                .id(book.identifier)   // fresh web view per book
            }
        }
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
                PDFReaderView(doc: pdf, page: $state.pdfPage, onLookup: { word in
                    (NSApp.delegate as? AppDelegate)?.handleFire(mode: .explain, providedText: word)
                })
            }
        }
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

            Button { showCustomize.toggle() } label: {
                Text("Aa").font(.system(size: 16, weight: .medium))
            }
            .help("Text & colors")
            .popover(isPresented: $showCustomize, arrowEdge: .bottom) { customizePanel }
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
            Picker("Theme", selection: $state.theme) {
                ForEach(ReaderState.Theme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
private struct ColorField: View {
    let title: LocalizedStringKey
    @Binding var hex: String
    let presets: [String]

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(readerHex: hex))
                    .frame(width: 26, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
                TextField("#RRGGBB", text: $draft)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 92)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
            }
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
