import AppKit
import SwiftUI

/// Standalone window listing every accepted memory in a given scope
/// (Global or a specific context). Opened from the Memory settings
/// tab via the "Manage memories…" button on the Global row or on
/// each Context row. Same per-row affordances as the inline list
/// previously offered: edit, move to another scope, delete.
///
/// One window at a time — opening a second scope replaces the
/// contents of the existing window, mirroring how
/// `MistakeTypeWindowController` behaves.
@MainActor
final class MemoryItemsWindowController {
    static let shared = MemoryItemsWindowController()

    private var window: NSWindow?
    private var activationToken: UUID?
    private var closeObserver: NSObjectProtocol?
    private let contentWidth: CGFloat = 560

    func show(scope: MemoryScope) {
        let view = MemoryItemsView(scope: scope) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: view)
        // One-shot intrinsic sizing (like HUDController) — NOT
        // `.preferredContentSize`. The latter makes the hosting controller
        // re-push its size into the window *continuously*; combined with the
        // inner `ScrollView` + the outer `.fixedSize(vertical:)`, a populated
        // scope produced an oscillating preferred height that re-invalidated
        // the window's constraints *during* its own layout pass. AppKit throws
        // on that re-entrancy (`_postWindowNeedsUpdateConstraints`), crashing
        // the app whenever a non-empty Memory scope was opened. `[]` sizes the
        // window once below and then leaves it (user-resizable) alone.
        host.sizingOptions = []

        let title = Self.titleFor(scope: scope)

        if let window {
            window.contentViewController = host
            window.title = title
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        w.setContentSizeClampedToScreen(
            fitting.width > 0 && fitting.height > 0
                ? fitting
                : NSSize(width: contentWidth, height: 420)
        )
        w.contentMinSize = NSSize(width: contentWidth, height: 240)
        w.center()
        // No `.moveToActiveSpace` — see SettingsWindow for the why.
        window = w

        // Same .regular activation slot pattern as Settings — see
        // AppActivation for why managed windows take the slot.
        activationToken = AppActivation.register { [weak w] in
            w?.performClose(nil)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWindowClosed() }
        }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        Log.activationSnapshot(window: w, name: "Memory", op: "open-memory")
    }

    private static func titleFor(scope: MemoryScope) -> String {
        // Format string lets locales reorder the "Memory — <scope>"
        // pieces; the scope name (Global / context name) is user
        // content and isn't itself localized.
        let format = "Memory — %@".t
        switch scope {
        case .global:
            return String(format: format, "Global".t)
        case .context(let id):
            let name = MemoryContextStore.shared.context(id: id)?.name
                ?? "Context".t
            return String(format: format, name)
        }
    }

    private func handleWindowClosed() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
        if let token = activationToken {
            activationToken = nil
            AppActivation.unregister(token)
        }
    }
}

/// SwiftUI body for the memory-items window. Reads the matching
/// accepted memories from `LearnedMemoryStore` and re-reads on
/// every mutation via `refreshToken`. Each row shows the kind
/// badge + term (for glossary) + content with edit / move-to /
/// delete actions inline — same affordances the Settings tab
/// used to offer.
@MainActor
struct MemoryItemsView: View {
    let scope: MemoryScope
    let onClose: () -> Void

    @State private var refreshToken = 0
    @State private var editingID: UUID?
    @State private var editTerm: String = ""
    @State private var editContent: String = ""

    private let contentWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if memories.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(memories) { memory in
                            row(memory)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 520)
            }
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .localizationAware()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .font(.title3.bold())
                // Plural-aware via a single format key — Chinese,
                // Japanese, Korean don't decline so a single string
                // avoids two near-identical catalog entries.
                Text(String(format: "%d memories".t, memories.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No memories in this scope.".t)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private func row(_ memory: LearnedMemory) -> some View {
        if editingID == memory.id {
            editorRow(memory)
        } else {
            HStack(alignment: .top, spacing: 8) {
                kindBadge(memory.kind)
                if let lang = memory.sourceLanguage {
                    // Compact chip so the user can see "this memory
                    // was about ENGLISH" / "about Chinese" at a glance.
                    // Drives the strict language filter in
                    // contextBlock(for:targetLanguage:).
                    Text(LanguageOptions.localizedName(for: lang))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let term = memory.term {
                        Text(term).font(.callout.bold())
                    }
                    Text(memory.content)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Menu {
                    Button {
                        LearnedMemoryStore.shared.accept(id: memory.id, scope: .global)
                        refreshToken &+= 1
                    } label: {
                        if case .global = memory.effectiveScope {
                            Label("Global".t, systemImage: "checkmark")
                        } else {
                            Text("Global".t)
                        }
                    }
                    ForEach(MemoryContextStore.shared.all()) { ctx in
                        Button {
                            LearnedMemoryStore.shared.accept(id: memory.id, scope: .context(ctx.id))
                            refreshToken &+= 1
                        } label: {
                            if memory.effectiveScope.contextID == ctx.id {
                                Label(ctx.name, systemImage: "checkmark")
                            } else {
                                Text(ctx.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("Move to a different scope")

                Button {
                    editingID = memory.id
                    editTerm = memory.term ?? ""
                    editContent = memory.content
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit")

                Button {
                    LearnedMemoryStore.shared.delete(id: memory.id)
                    refreshToken &+= 1
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    @ViewBuilder
    private func editorRow(_ memory: LearnedMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                kindBadge(memory.kind)
                Spacer()
            }
            if memory.kind == .glossary {
                TextField("Term", text: $editTerm)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Memory", text: $editContent, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack(spacing: 8) {
                Button("Save") {
                    LearnedMemoryStore.shared.edit(
                        id: memory.id,
                        term: memory.kind == .glossary ? editTerm : nil,
                        content: editContent
                    )
                    editingID = nil
                    refreshToken &+= 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (memory.kind == .glossary
                              && editTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Button("Cancel") { editingID = nil }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var scopeTitle: String {
        switch scope {
        case .global:
            return "Global memory".t
        case .context(let id):
            // User-content name (no translation), with a localized
            // fallback when the context has been deleted.
            return MemoryContextStore.shared.context(id: id)?.name
                ?? "Context memory".t
        }
    }

    /// Re-read on every mutation. refreshToken is the only
    /// dependency — bumping it forces SwiftUI to recompute.
    private var memories: [LearnedMemory] {
        _ = refreshToken
        return LearnedMemoryStore.shared.accepted().filter { memory in
            switch (scope, memory.effectiveScope) {
            case (.global, .global): return true
            case (.context(let a), .context(let b)): return a == b
            default: return false
            }
        }
    }

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
}
