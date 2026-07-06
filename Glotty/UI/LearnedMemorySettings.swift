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
                    Text("Global memory".t)
                        .font(.callout.bold())
                    // Single format string instead of inline plural
                    // interpolation so each locale gets one catalog
                    // entry. Chinese, Japanese, Korean etc. don't
                    // distinguish singular/plural — keeping it as one
                    // key avoids two near-identical catalog entries.
                    Text(String(format: "%d memories".t, count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                injectionPicker(current: MemoryContextStore.shared.globalInjection) { rule in
                    MemoryContextStore.shared.globalInjection = rule
                    refreshToken &+= 1
                }
                Button("Manage\u{2026}") {
                    MemoryItemsWindowController.shared.show(scope: .global)
                }
                .controlSize(.small)
                .disabled(count == 0)
            }
        } header: {
            Text("Global memory".t)
        } footer: {
            Text("Persistent facts about you, injected into every LLM prompt regardless of which context is active.".t)
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

    /// Compact menu for a memory set's injection rule — `.everywhere`
    /// (Translate/Explain/Polish/Chat) or `.chatOnly` (only the Fn+C tutor
    /// chat). Reused by the Global section and each context row.
    @ViewBuilder
    private func injectionPicker(current: MemoryInjectionScope,
                                 set: @escaping (MemoryInjectionScope) -> Void) -> some View {
        Menu {
            Button { set(.everywhere) } label: {
                if current == .everywhere {
                    Label("Every scenario".t, systemImage: "checkmark")
                } else { Text("Every scenario".t) }
            }
            Button { set(.chatOnly) } label: {
                if current == .chatOnly {
                    Label("Chat only (Fn + C)".t, systemImage: "checkmark")
                } else { Text("Chat only (Fn + C)".t) }
            }
        } label: {
            Label(current == .chatOnly ? "Chat only".t : "Every scenario".t,
                  systemImage: current == .chatOnly ? "text.bubble" : "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("When this memory set is injected into prompts")
    }

    // MARK: - Contexts

    @State private var newContextName: String = ""
    @State private var editingContext: MemoryContext?
    @State private var renameDraft: String = ""
    @State private var noteDraft: String = ""
    @State private var generatingIntro = false

    private var contextsSection: some View {
        let contexts = readContexts()
        let activeID = readActiveContextID()
        return Section {
            HStack(spacing: 8) {
                Text("Active context".t)
                Picker("Active", selection: Binding<UUID?>(
                    get: { activeID },
                    set: { newID in
                        MemoryContextStore.shared.activeContextID = newID
                        refreshToken &+= 1
                    }
                )) {
                    Text("None (global only)".t).tag(UUID?.none)
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
            Text("Contexts".t)
        } footer: {
            Text("Contexts let you keep parallel sets of memories. When a context is active, its memories inject alongside Global ones; memories scoped to other contexts stay dormant.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editingContext) { ctx in
            contextEditSheet(ctx)
        }
    }

    private func contextRow(_ ctx: MemoryContext, isActive: Bool) -> some View {
        let count = countInContext(ctx.id)
        return HStack(spacing: 8) {
            // The whole name area is the switch — click to activate, or click
            // the active one to drop back to Global only. (Top dropdown does
            // the same thing.)
            Button {
                MemoryContextStore.shared.activeContextID = isActive ? nil : ctx.id
                refreshToken &+= 1
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.name)
                        if let note = ctx.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(String(format: "%d memories".t, count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive
                  ? "Active — click to switch to Global only".t
                  : "Click to make this the active context".t)
            Spacer()
            injectionPicker(current: ctx.effectiveInjection) { rule in
                MemoryContextStore.shared.setInjection(id: ctx.id, rule)
                refreshToken &+= 1
            }
            Button("Manage\u{2026}") {
                MemoryItemsWindowController.shared.show(scope: .context(ctx.id))
            }
            .controlSize(.small)
            .disabled(count == 0)

            // Opens the edit pop-up (name + short intro).
            Button {
                renameDraft = ctx.name
                noteDraft = ctx.note ?? ""
                editingContext = ctx
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit name & intro")

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

    /// Pop-up editor for a context's name + short intro (with ✨ LLM draft).
    private func contextEditSheet(_ ctx: MemoryContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit context".t)
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("Name".t).font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Short intro".t).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("What this context is for (optional)",
                              text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    // Draft the intro from the name with the user's AI provider.
                    Button {
                        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        generatingIntro = true
                        Task {
                            let intro = await generateIntro(forName: name)
                            if let intro { noteDraft = intro }
                            generatingIntro = false
                        }
                    } label: {
                        if generatingIntro {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Draft from the name (uses your AI provider)")
                    .disabled(generatingIntro
                              || renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || LLMRegistry.current() == nil)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { editingContext = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    MemoryContextStore.shared.rename(id: ctx.id, to: renameDraft)
                    MemoryContextStore.shared.setNote(id: ctx.id, noteDraft)
                    editingContext = nil
                    refreshToken &+= 1
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
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

    /// Draft a one-line context intro from its name via the user's LLM.
    /// Returns nil if no provider is configured or the call fails.
    @MainActor
    private func generateIntro(forName name: String) async -> String? {
        guard let provider = LLMRegistry.current() else { return nil }
        let prompt = """
            Write a very short intro — one concise phrase, at most ~12 words — \
            describing what a memory "context" named below is most likely about. \
            Reply with ONLY the phrase: no quotes, no label, no trailing period.

            Context name: \(name)
            """
        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.polish) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return nil
        }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return cleaned.isEmpty ? nil : cleaned
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
                    Text("No suggestions yet.".t)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("After you chat with Glotty under a polish or explain popup, new memories Glotty notices will land here for review.".t)
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
                Text("Suggestions".t)
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
                Text("Click a suggestion to reopen the conversation that produced it — approve or reject it from there. Or use Dismiss all to clear the whole queue.".t)
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
                if let lang = memory.sourceLanguage {
                    Text(LanguageOptions.localizedName(for: lang))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
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
                    Text("Source conversation no longer in History.".t)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Open conversation to review".t)
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
            Text("Settings".t)
        } footer: {
            Text("Every memory still requires your approval before it's injected into LLM prompts.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func kindBadge(_ kind: LearnedMemoryKind) -> some View {
        Text(kind.label.t)
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
