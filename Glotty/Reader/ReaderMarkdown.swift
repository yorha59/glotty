import SwiftUI
import Textual

/// Renders an LLM reply as a complete Markdown document. Textual preserves
/// cross-line structure, so tables, nested lists, block quotes, fenced code,
/// images and thematic breaks render correctly instead of exposing markers.
/// Parsing still happens only after streaming finishes at the call site.
struct ReaderMarkdownText: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.default)
            .textual.tableStyle(.overflow(relativeWidth: 1.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
