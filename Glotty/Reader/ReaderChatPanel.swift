import SwiftUI

/// The reader's right-hand tutor panel: an attached passage chip, a streaming
/// message list, and a composer. Reuses `LLMProvider.current()` via `ReaderChat`.
struct ReaderChatPanel: View {
    @ObservedObject var chat: ReaderChat
    let width: CGFloat
    let onClose: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
            Text("Chat").font(.headline)
            Spacer()
            if !chat.messages.isEmpty {
                Button(action: chat.reset) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear conversation")
            }
            Button(action: onClose) { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Hide chat")
        }
        .padding(10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let ctx = chat.context, !ctx.isEmpty { contextChip(ctx) }
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
            Text(m.text.isEmpty ? "…" : LocalizedStringKey(m.text))
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(m.role == .user ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(m.role == .user ? Color.accentColor : Color.primary.opacity(0.07)))
            if m.role == .assistant { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the passage…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($inputFocused)
                .onSubmit(chat.send)
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
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(10)
    }
}
