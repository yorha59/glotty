import SwiftUI

/// Renders an LLM reply as Markdown for the reader's chat. SwiftUI's
/// `Text(AttributedString(markdown:))` only styles *inline* syntax (bold,
/// italic, code, links); headings, bullets and block quotes come through as
/// literal `##` / `-` / `>`, which is what filled the chat with raw markers.
/// So block structure is laid out line by line here, and each line's inline
/// syntax is still parsed.
///
/// Lives in `Reader/` rather than reusing the popup's version: `Reader/`
/// compiles into the standalone app too and can't reach `Glotty/UI`.
struct ReaderMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] { Self.parse(text) }

    // MARK: parsing

    private struct Block: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    private static func parse(_ raw: String) -> [Block] {
        raw.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                return Block(view: AnyView(Color.clear.frame(height: 3)))
            }
            // Heading: #, ##, ### … — bigger the fewer the hashes.
            if let (level, content) = heading(t) {
                let size: CGFloat = level <= 1 ? 17 : level == 2 ? 15 : 13.5
                return Block(view: AnyView(
                    inline(content)
                        .font(.system(size: size, weight: .semibold))
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)))
            }
            // Block quote: a bar and indented, secondary text.
            if t.hasPrefix(">") {
                let content = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                return Block(view: AnyView(
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.tint.opacity(0.5)).frame(width: 3)
                        inline(content).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)))
            }
            // List item: real bullet or the author's own number, hanging indent.
            if let (marker, content) = listMarker(t) {
                return Block(view: AnyView(
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit()
                        inline(content).frame(maxWidth: .infinity, alignment: .leading)
                    }))
            }
            return Block(view: AnyView(
                inline(t).frame(maxWidth: .infinity, alignment: .leading)))
        }
    }

    /// `### Foo` → `(3, "Foo")`, else nil.
    private static func heading(_ line: String) -> (level: Int, content: String)? {
        var hashes = 0
        for c in line { if c == "#" { hashes += 1 } else { break } }
        guard hashes > 0, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Leading list marker, or nil. Bullets normalise to "•"; numbered lists
    /// keep the author's own number.
    private static func listMarker(_ line: String) -> (marker: String, content: String)? {
        for p in ["- ", "* ", "• ", "+ "] where line.hasPrefix(p) {
            return ("•", String(line.dropFirst(p.count)))
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let head = line[line.startIndex..<dot]
            if !head.isEmpty, head.allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                return (String(head) + ".", String(line[line.index(dot, offsetBy: 2)...]))
            }
        }
        return nil
    }

    /// One line's inline markdown (bold / italic / code / links). Falls back to
    /// plain text if parsing fails — mid-stream fragments still parse thanks to
    /// the partial policy.
    private static func inline(_ s: String) -> Text {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        if let attr = try? AttributedString(markdown: s, options: opts) { return Text(attr) }
        return Text(s)
    }
}
