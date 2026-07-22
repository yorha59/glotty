import SwiftUI

/// The reader's right-hand tutor panel: an attached passage chip, a streaming
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
    }

    /// Header, transcript, attached passage, composer.
    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            // The attached passage belongs with the composer, not at the top of
            // the transcript: it's what the next question is about, and up
            // there it scrolled away exactly when it mattered.
            if let ctx = chat.context, !ctx.isEmpty {
                contextChip(ctx)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
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
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Rename") { chat.rename(s, to: renameText); renaming = nil }
                        .buttonStyle(.borderedProminent)
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
            if chat.sessions.isEmpty {
                Text("No conversations yet")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(chat.sessions) { s in sessionRow(s) }
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
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor : .clear))
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
                    if chat.messages.isEmpty && chat.context == nil {
                        Text("Select text in the document and tap **Ask** to bring it here, then ask about it.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    ForEach(chat.messages) { bubble($0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func contextChip(_ ctx: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
            Text(ctx).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Spacer(minLength: 0)
            Button(action: chat.clearContext) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
                } else {
                    Text(m.text.isEmpty ? "…" : LocalizedStringKey(m.text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(m.role == .user ? Color.white : Color.primary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(m.role == .user ? Color.accentColor : Color.primary.opacity(0.07)))
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
                    Menu(p.name) {
                        ForEach(p.models) { m in
                            Button { select(p, m.id) } label: {
                                if p.isActive && m.id == p.activeModelID {
                                    Label(m.name, systemImage: "checkmark")
                                } else {
                                    Text(m.name)
                                }
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

    private var composer: some View {
        // Text on top, controls along the bottom edge: the picker belongs at
        // the bottom-left of the box, not squeezed beside the send button.
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask about the passage…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .focused($inputFocused)
                .onSubmit(chat.send)
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
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(10)
    }
}
