import SwiftUI

/// Settings → Memory tab. Three sections:
///   - Suggestions: pending proposals from the post-chat extractor.
///     The user accepts (promote to live memory) or rejects (kept in
///     the store so the extractor doesn't re-propose).
///   - Accepted memories: the active set that's injected into LLM
///     prompts. Editable inline; deletable.
///   - Settings: toggle the extractor on/off, view storage path,
///     clear everything.
///
/// SwiftUI doesn't observe `LearnedMemoryStore` directly (it's a
/// plain class, not ObservableObject) — instead each user action
/// bumps `refreshToken`, which forces the computed view bodies to
/// re-read the store. Cheap because the store keeps everything in
/// memory; nothing on the hot path here.
struct LearnedMemorySettingsSection: View {
    @State private var refreshToken = 0
    @AppStorage(MemoryExtractor.modeKey) private var extractionModeRaw: String = MemoryExtractor.Mode.auto.rawValue

    var body: some View {
        Group {
            settingsSection
            globalMemorySection
            contextsSection
            suggestionsSection
        }
        // Auto-refresh when the store mutates from anywhere —
        // background extractor, accept/reject from the popup card,
        // delete from the management window. Without this the
        // Settings tab would only update on direct user interaction.
        .onReceive(NotificationCenter.default.publisher(for: LearnedMemoryStore.didChangeNotification)) { _ in
            refreshToken &+= 1
        }
    }

    // MARK: - Global memory

    /// Single row showing how many memories are in the Global scope
    /// + a button to open the management window. The actual list of
    /// memories lives in `MemoryItemsWindowController` so this tab
    /// stays scannable even with dozens of memories.
    private var globalMemorySection: some View {
        let count = readGlobalCount()
        return Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global memory")
                        .font(.callout.bold())
                    // Single format string instead of inline plural
                    // interpolation so each locale gets one catalog
                    // entry. Chinese, Japanese, Korean etc. don't
                    // distinguish singular/plural — keeping it as one
                    // key avoids two near-identical catalog entries.
                    Text(String(format: String(localized: "%d memories · always injected"), count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage\u{2026}") {
                    MemoryItemsWindowController.shared.show(scope: .global)
                }
                .controlSize(.small)
                .disabled(count == 0)
            }
        } header: {
            Text("Global memory")
        } footer: {
            Text("Persistent facts about you, injected into every LLM prompt regardless of which context is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func readGlobalCount() -> Int {
        _ = refreshToken
        return LearnedMemoryStore.shared.accepted().filter {
            if case .global = $0.effectiveScope { return true }
            return false
        }.count
    }

    // MARK: - Contexts

    @State private var newContextName: String = ""
    @State private var renamingContextID: UUID?
    @State private var renameDraft: String = ""

    private var contextsSection: some View {
        let contexts = readContexts()
        let activeID = readActiveContextID()
        return Section {
            HStack(spacing: 8) {
                Text("Active context")
                Picker("Active", selection: Binding<UUID?>(
                    get: { activeID },
                    set: { newID in
                        MemoryContextStore.shared.activeContextID = newID
                        refreshToken &+= 1
                    }
                )) {
                    Text("None (global only)").tag(UUID?.none)
                    ForEach(contexts) { ctx in
                        Text(ctx.name).tag(UUID?.some(ctx.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if !contexts.isEmpty {
                ForEach(contexts) { ctx in
                    contextRow(ctx, isActive: ctx.id == activeID)
                }
            }

            HStack(spacing: 8) {
                TextField("New context name", text: $newContextName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addContext)
                Button("Add") { addContext() }
                    .controlSize(.small)
                    .disabled(newContextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Contexts")
        } footer: {
            Text("Contexts let you keep parallel sets of memories. When a context is active, its memories inject alongside Global ones; memories scoped to other contexts stay dormant.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contextRow(_ ctx: MemoryContext, isActive: Bool) -> some View {
        if renamingContextID == ctx.id {
            HStack(spacing: 8) {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    MemoryContextStore.shared.rename(id: ctx.id, to: renameDraft)
                    renamingContextID = nil
                    refreshToken &+= 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { renamingContextID = nil }
                    .controlSize(.small)
            }
        } else {
            let count = countInContext(ctx.id)
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.name)
                    Text(String(format: String(localized: "%d memories"), count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage\u{2026}") {
                    MemoryItemsWindowController.shared.show(scope: .context(ctx.id))
                }
                .controlSize(.small)
                .disabled(count == 0)

                Button {
                    renamingContextID = ctx.id
                    renameDraft = ctx.name
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename")

                Button {
                    MemoryContextStore.shared.delete(id: ctx.id)
                    refreshToken &+= 1
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete — memories scoped to this context become orphaned and stop injecting.")
            }
        }
    }

    private func countInContext(_ id: UUID) -> Int {
        _ = refreshToken
        return LearnedMemoryStore.shared.accepted().filter {
            $0.effectiveScope.contextID == id
        }.count
    }

    private func addContext() {
        let trimmed = newContextName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        MemoryContextStore.shared.add(name: trimmed)
        newContextName = ""
        refreshToken &+= 1
    }

    private func readContexts() -> [MemoryContext] {
        _ = refreshToken
        return MemoryContextStore.shared.all()
    }

    private func readActiveContextID() -> UUID? {
        _ = refreshToken
        return MemoryContextStore.shared.activeContextID
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        let pending = readPending()
        return Section {
            if pending.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No suggestions yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("After you chat with Glotty under a polish or explain popup, new memories Glotty notices will land here for review.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(pending) { memory in
                    suggestionRow(memory)
                }
                HStack {
                    Spacer()
                    Button("Dismiss all", role: .destructive) {
                        LearnedMemoryStore.shared.dismissAllPending()
                        refreshToken &+= 1
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            HStack {
                Text("Suggestions")
                if !pending.isEmpty {
                    Text("\(pending.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        } footer: {
            if !pending.isEmpty {
                Text("Click a suggestion to reopen the conversation that produced it — approve or reject it from there. Or use Dismiss all to clear the whole queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One pending-suggestion row. Acts as a navigation tile —
    /// tapping it reopens the source polish/explain conversation
    /// (just like clicking a History entry), where the user sees
    /// the original context and approves or rejects via the
    /// inline card the chat now renders.
    @ViewBuilder
    private func suggestionRow(_ memory: LearnedMemory) -> some View {
        let event = sourceEvent(for: memory)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                kindBadge(memory.kind)
                if let term = memory.term {
                    Text(term).font(.callout.bold())
                }
                Spacer()
                Text(memory.proposedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(memory.content)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let quote = memory.sourceQuote {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if event == nil {
                    Text("Source conversation no longer in History.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Open conversation to review")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let event { openSourceConversation(for: event) }
        }
    }

    /// Look up the originating MemoryEvent for a suggestion's
    /// `sourceEventID`. Returns nil if the event was deleted from
    /// History (the source conversation is gone — suggestion can
    /// still be dismissed but not reopened).
    private func sourceEvent(for memory: LearnedMemory) -> MemoryEvent? {
        guard let id = memory.sourceEventID else { return nil }
        return MemoryStore.shared.allEvents().first { $0.id == id }
    }

    /// Reopen the polish/explain popup for the source event so the
    /// user can approve/reject the suggestion from the inline card
    /// the chat renders. Mirrors the History click-to-replay flow.
    private func openSourceConversation(for event: MemoryEvent) {
        guard let replay = PopupReplayPayload.from(event) else { return }
        let mode: PopupMode
        switch event.kind {
        case .polish: mode = .polish
        case .explain: mode = .explain
        case .translate: mode = .translate
        }
        PopupController.shared.show(
            sourceText: event.sourceText,
            mode: mode,
            replay: replay
        )
    }

    // MARK: - Settings

    private var settingsSection: some View {
        let mode = MemoryExtractor.Mode(rawValue: extractionModeRaw) ?? .auto
        return Section {
            Picker("Memory extraction", selection: Binding<MemoryExtractor.Mode>(
                get: { MemoryExtractor.Mode(rawValue: extractionModeRaw) ?? .auto },
                set: { extractionModeRaw = $0.rawValue }
            )) {
                ForEach(MemoryExtractor.Mode.allCases) { m in
                    Text(m.displayName.t).tag(m)
                }
            }
            Text(mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear all memories", role: .destructive) {
                    LearnedMemoryStore.shared.clearAll()
                    refreshToken &+= 1
                }
                .controlSize(.small)
                Spacer()
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("Every memory still requires your approval before it's injected into LLM prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func kindBadge(_ kind: LearnedMemoryKind) -> some View {
        Text(kind.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeColor(kind).opacity(0.18)))
            .foregroundStyle(badgeColor(kind))
    }

    private func badgeColor(_ kind: LearnedMemoryKind) -> Color {
        switch kind {
        case .glossary:   return .blue
        case .preference: return .purple
        case .fact:       return .green
        case .project:    return .orange
        }
    }

    /// Re-read the store on every render. `refreshToken` is the only
    /// dependency — bumping it forces SwiftUI to recompute the body.
    private func readPending() -> [LearnedMemory] {
        _ = refreshToken
        return LearnedMemoryStore.shared.pending()
    }

}
