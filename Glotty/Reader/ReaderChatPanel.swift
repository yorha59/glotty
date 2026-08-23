import AppKit
import SwiftUI

/// The reader's right-hand tutor panel: a conversations rail, a streaming
/// message list, and a composer. Reuses `LLMProvider.current()` via `ReaderChat`.
struct ReaderChatPanel: View {
    /// Providers as last reported by Glotty; refreshed when the picker opens.
    @State private var providers: [ReaderProvider] = []
    /// Conversation awaiting a delete confirmation; non-nil is "asking".
    @State private var pendingDelete: SavedDialogue?
    @State private var renaming: SavedDialogue?
    @State private var renameText = ""
    /// Whether the conversations rail is open. Persisted so it stays the way
    /// it was left, like the chat panel's own width. Open by default: shipped
    /// collapsed, it's a feature nobody finds — the toggle is the only clue it
    /// exists, and one click hides it for good if it's not wanted.
    @AppStorage("glotty.reader.chatSessionsShown") private var showSessions = true

    @ObservedObject var chat: ReaderChat
    let width: CGFloat
    @FocusState private var inputFocused: Bool

    /// Width of the conversations rail when it's open.
    private let sessionsWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: 0) {
            // The rail extends the panel rather than squeezing the transcript,
            // so showing it doesn't reflow the conversation you're reading.
            if showSessions {
                sessionsSidebar
                    .frame(width: sessionsWidth)
                    .transition(.move(edge: .leading))
                Divider()
            }
            chatColumn
        }
        .frame(width: width + (showSessions ? sessionsWidth + 1 : 0))
        .overlay { ReaderReplySelectionOverlay { chat.quote($0) } }
    }

    /// Header, transcript, attached passage, composer.
    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Same shape as the Library's delete: a question, the scope, and a
        // repeat-the-verb destructive button.
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { chat.delete(s) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let s = pendingDelete {
                Text("This removes \u{201C}\(s.title)\u{201D} and its \(s.messages.count) messages. Cannot be undone.")
            }
        }
        .sheet(item: $renaming) { s in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename conversation").font(.headline)
                TextField("Title", text: $renameText)
                    .textFieldStyle(.plain)
                    .frame(width: 260)
                    .padding(7)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.22)))
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Rename") { chat.rename(s, to: renameText); renaming = nil }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(.white).background(Color.accentColor)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSessions.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain).foregroundStyle(showSessions ? Color.accentColor : .secondary)
            .help(showSessions ? "Hide conversations" : "Show conversations")
            Text("Chat").font(.headline)
            Spacer()
            Button { chat.startNewSession() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("New conversation")
        }
        .padding(10)
    }

    /// Conversations for this book, as a rail beside the chat. Selecting one
    /// opens it; rename/delete live in each row's context menu, where they
    /// apply to the row you actually clicked.
    private var sessionsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if chat.listedSessions.isEmpty {
                Text("No conversations yet")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(chat.listedSessions) { s in sessionRow(s) }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color.primary.opacity(0.03))
    }

    private func sessionRow(_ s: SavedDialogue) -> some View {
        let selected = s.id == chat.currentSessionID
        return VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(.caption).lineLimit(2)
                .foregroundStyle(selected ? Color.white : .primary)
            Text(s.date.formatted(.relative(presentation: .named)))
                .font(.system(size: 9))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.white.opacity(0.65)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { chat.load(s) }
        .contextMenu {
            Button("Rename…") { renaming = s; renameText = s.title }
            Button("Delete…", role: .destructive) { pendingDelete = s }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        Text("Select text in the document, then **What is this** to have it explained, or **Add** to ask your own question about it.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    ForEach(chat.messages) { bubble($0) }
                    // A question with no reply — a thread reopened after a
                    // failed turn (errors aren't saved). Offer to send it again.
                    if chat.lastQuestionUnanswered {
                        HStack {
                            Spacer(minLength: 28)
                            Button { chat.retry() } label: {
                                Label("Retry", systemImage: "arrow.clockwise").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// The quoted passage as a clickable chip (Cursor-style reference token):
    /// a quote glyph, a one-line preview, and a corner arrow that reads as
    /// "takes you somewhere". Tapping jumps to the spot and highlights it.
    private func passageChip(_ m: ReaderChat.Msg, preview: String) -> some View {
        let flat = preview.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let label = flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
        return Button { chat.jump(to: m) } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.quote").font(.system(size: 10, weight: .semibold))
                Text(label).font(.caption).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.16))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Jump to this passage in the book")
    }

    /// A user turn's text with the leading quoted passage removed — the chip
    /// shows the passage, so only what was typed remains here. `srcText` is the
    /// passage `send()`/`attach()` prepended in quotes.
    private func spokenText(_ m: ReaderChat.Msg) -> String {
        guard let q = m.srcText else { return m.text }
        let quoted = "\u{201C}\(q)\u{201D}"
        var t = m.text
        if t.hasPrefix(quoted) { t = String(t.dropFirst(quoted.count)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bubble(_ m: ReaderChat.Msg) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 28) }
            Group {
                // An empty assistant bubble is the one still being answered.
                // Say what's happening and for how long — a bare "…" looks the
                // same whether the model is thinking or the request was lost.
                if m.text.isEmpty, m.role == .assistant, chat.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text(chat.statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                } else if m.isError {
                    // A failure keeps the question in the transcript, so retry
                    // just re-sends it — nothing to retype.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button { chat.retry() } label: {
                            Label("Retry", systemImage: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(chat.isStreaming)
                    }
                } else if m.role == .assistant {
                    Group {
                        // Parsing every completed line again for every token made
                        // long replies progressively slower. Format once finished.
                        if chat.isStreaming, m.id == chat.messages.last?.id {
                            Text(m.text).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ReaderMarkdownText(text: m.text)
                        }
                    }
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.primary)
                } else {
                    // A quoted passage rides as a chip — clicking it jumps back
                    // to the spot in the book and highlights it — with the typed
                    // question, if any, below. A plain question is just text.
                    VStack(alignment: .leading, spacing: 6) {
                        if m.hasSource, let passage = m.srcText {
                            passageChip(m, preview: passage)
                        }
                        let spoken = spokenText(m)
                        if !spoken.isEmpty {
                            Text(spoken)
                                .font(.callout)
                                .textSelection(.enabled)
                                .foregroundStyle(Color.white)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(m.role == .user ? Color.accentColor : Color.primary.opacity(0.07))
            .overlay(alignment: .leading) {
                if m.role == .assistant { Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2) }
            }
            if m.role == .assistant { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
    }

    /// Provider + model picker, in the composer's bottom-left. Lists every
    /// configured provider with its models; picking one switches Glotty's
    /// active provider/model, the same setting the menu bar shows.
    private var modelPicker: some View {
        Menu {
            if providers.isEmpty {
                // The models live in Glotty, so an empty list usually means
                // Glotty isn't running rather than nothing being configured —
                // say so, since the fix is different.
                Text("No models — is Glotty running?")
                Button("Try again") { Task { providers = await ReaderCore.services?.providers() ?? [] } }
            }
            ForEach(providers) { p in
                if p.models.isEmpty {
                    // Custom / on-device: nothing to enumerate, so the provider
                    // itself is the choice.
                    Button { select(p, "") } label: {
                        if p.isActive { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                } else {
                    ForEach(p.models) { m in
                        Button { select(p, m.id) } label: {
                            let label = "\(p.name) · \(m.name)"
                            if p.isActive && m.id == p.activeModelID {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu").font(.system(size: 10))
                Text(activeLabel).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Language model used for these answers")
        .task { providers = await ReaderCore.services?.providers() ?? [] }
    }

    /// What the picker shows when closed: the model in use, or the provider
    /// when it has no model list.
    private var activeLabel: String {
        guard let p = providers.first(where: \.isActive) else { return String(localized: "Model") }
        if let m = p.models.first(where: { $0.id == p.activeModelID }) { return m.name }
        return p.name
    }

    private func select(_ p: ReaderProvider, _ modelID: String) {
        ReaderCore.services?.selectModel(providerID: p.id, modelID: modelID)
        // Reflect the pick immediately; the source of truth is Glotty, which
        // we re-read next time the menu opens.
        providers = providers.map { row in
            var r = row
            r.isActive = row.id == p.id
            if row.id == p.id, !modelID.isEmpty { r.activeModelID = modelID }
            return r
        }
    }

    /// One staged passage, shown the way an attached file is: a small token
    /// you can recognise and remove, with the full text on hover.
    private func attachmentPill(_ a: ReaderChat.Attachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "text.quote").font(.system(size: 9))
            Text(a.label).font(.caption2).lineLimit(1)
            Text("\(a.text.count)").font(.system(size: 9)).foregroundStyle(.tertiary)
            Button { chat.removeAttachment(a) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.16))
        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.25)))
        .foregroundStyle(.tint)
        .help(a.text)
    }

    private var composer: some View {
        // Text on top, controls along the bottom edge: the picker belongs at
        // the bottom-left of the box, not squeezed beside the send button.
        VStack(alignment: .leading, spacing: 6) {
            // Staged passages sit above the field as compact references, so a
            // long selection doesn't bury what you're typing and any one of
            // them can be dropped on its own.
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(chat.attachments) { attachmentPill($0) }
                    }
                    .padding(.bottom, 1)
                }
                .frame(maxHeight: 26)
            }
            TextField("Ask about the passage…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .focused($inputFocused)
                .onSubmit(chat.send)
                .onChange(of: chat.focusRequests) { _, _ in inputFocused = true }
            HStack(spacing: 8) {
                modelPicker
                Spacer(minLength: 0)
                if chat.isStreaming {
                    Button(action: chat.stop) { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Button(action: chat.send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(chat.input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.045))
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.16)))
        .padding(10)
    }
}

/// Mirrors the document selection chip for text selected inside an AI reply.
/// The overlay is click-through except for its Add button, so scrolling and
/// selecting the transcript keep their native behaviour.
private struct ReaderReplySelectionOverlay: NSViewRepresentable {
    let onAdd: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAdd: onAdd) }

    func makeNSView(context: Context) -> PassthroughView {
        let overlay = PassthroughView()
        context.coordinator.install(in: overlay)
        return overlay
    }

    func updateNSView(_ overlay: PassthroughView, context: Context) {
        context.coordinator.onAdd = onAdd
    }

    final class Coordinator: NSObject {
        var onAdd: (String) -> Void
        private weak var overlay: PassthroughView?
        private weak var editor: NSTextView?
        private var selectedText = ""
        private var chip: NSHostingView<ReplySelectionAddChip>?

        init(onAdd: @escaping (String) -> Void) {
            self.onAdd = onAdd
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionChanged(_:)),
                name: NSTextView.didChangeSelectionNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func install(in overlay: PassthroughView) {
            self.overlay = overlay
            let chip = NSHostingView(rootView: ReplySelectionAddChip { [weak self] in self?.add() })
            chip.isHidden = true
            overlay.addSubview(chip)
            self.chip = chip
        }

        @objc private func selectionChanged(_ note: Notification) {
            guard let editor = note.object as? NSTextView,
                  let field = editor.delegate as? NSTextField,
                  field.isSelectable, !field.isEditable,
                  editor.window === overlay?.window,
                  let text = ReaderTextSelection.text(from: editor),
                  let overlay, let window = overlay.window, let chip else {
                chip?.isHidden = true
                return
            }
            self.editor = editor
            selectedText = text
            let screenRect = editor.firstRect(
                forCharacterRange: editor.selectedRange(), actualRange: nil)
            let localRect = overlay.convert(window.convertFromScreen(screenRect), from: nil)
            let size = chip.fittingSize
            let x = min(max(8, localRect.midX - size.width / 2), overlay.bounds.width - size.width - 8)
            let below = localRect.minY - size.height - 8
            let y = below >= 8 ? below : min(localRect.maxY + 8, overlay.bounds.height - size.height - 8)
            chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            chip.isHidden = false
        }

        private func add() {
            guard !selectedText.isEmpty else { return }
            onAdd(selectedText)
            if let editor {
                editor.setSelectedRange(NSRange(location: NSMaxRange(editor.selectedRange()), length: 0))
            }
            chip?.isHidden = true
        }
    }
}

private struct ReplySelectionAddChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add", systemImage: "text.append")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/// SwiftUI exposes selectable `Text`, but not its selected string. On macOS
/// the live selection still belongs to the window's field editor.
enum ReaderTextSelection {
    static func text(from responder: NSResponder?) -> String? {
        let editor: NSTextView?
        if let textView = responder as? NSTextView {
            editor = textView
        } else if let field = responder as? NSTextField {
            editor = field.currentEditor() as? NSTextView
        } else {
            editor = nil
        }
        guard let editor else { return nil }
        let range = editor.selectedRange()
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (editor.string as NSString).length else { return nil }
        return (editor.string as NSString).substring(with: range)
    }
}
