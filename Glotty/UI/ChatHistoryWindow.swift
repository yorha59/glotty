import AppKit
import SwiftUI

/// Standalone read-only viewer for one day's chat thread. Opened
/// from the Settings → Chat → History list. Resuming an old
/// conversation mid-context feels strange, so this window is
/// deliberately read-only — no input box, no Send. Today's chat
/// is the only live one (Fn → C).
///
/// One window at a time — opening another day's thread replaces the
/// contents of the existing window, mirroring how
/// `MistakeTypeWindowController` and `MemoryItemsWindowController`
/// behave.
@MainActor
final class ChatHistoryWindowController {
    static let shared = ChatHistoryWindowController()

    private var window: NSWindow?
    private var activationToken: UUID?
    private var closeObserver: NSObjectProtocol?
    private let contentWidth: CGFloat = 580

    func show(threadID: UUID) {
        guard let thread = ChatStore.shared.thread(id: threadID) else { return }

        let view = ChatHistoryView(thread: thread) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        // `Chat — Mon, Jun 2` etc. The format string is localized so
        // CJK / RTL locales can re-arrange the parts. The date label
        // itself is user content (output of `ChatDay.displayLabel`)
        // and stays as-is.
        let title = String(format: "Chat — %@".t,
                           ChatDay.displayLabel(for: thread.dayKey))

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
        let preferred = host.preferredContentSize
        w.setContentSizeClampedToScreen(
            preferred.width > 0 && preferred.height > 0
                ? preferred
                : NSSize(width: contentWidth, height: 480)
        )
        w.contentMinSize = NSSize(width: contentWidth, height: 280)
        w.center()
        // No `.moveToActiveSpace` — see SettingsWindow for the why.
        window = w

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
        Log.activationSnapshot(window: w, name: "ChatHistory", op: "open-chat-history")
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

/// SwiftUI body for the read-only chat history view. Renders the
/// thread in the same bubble + inline-correction style the live
/// popup uses, so a day's history reads exactly like the
/// conversation did when it happened.
@MainActor
struct ChatHistoryView: View {
    let thread: DailyChatThread
    let onClose: () -> Void

    private let contentWidth: CGFloat = 580
    private let bodySize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(thread.turns.indices, id: \.self) { idx in
                        bubble(thread.turns[idx])
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 560)
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .localizationAware()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatDay.displayLabel(for: thread.dayKey))
                    .font(.title3.bold())
                let userTurns = thread.turns.filter { $0.role == .user }.count
                // "12 messages · 5 from you" — single format, locales
                // re-order. Singular/plural pluralization isn't a thing
                // in the locales we ship, so we use one key for both.
                Text(String(format: "%d messages · %d from you".t,
                            thread.turns.count, userTurns))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func bubble(_ turn: TutorTurnSnapshot) -> some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if turn.role == .user { Spacer(minLength: 48) }
                Text(turn.reply)
                    .font(.system(size: bodySize))
                    .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(turn.role == .user ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    )
                if turn.role == .tutor { Spacer(minLength: 48) }
            }
            if turn.correctedText != nil || turn.correctionNote != nil {
                correctionBlock(turn)
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }

    private func correctionBlock(_ turn: TutorTurnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let corrected = turn.correctedText, !corrected.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Better:".t)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(corrected)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            if let note = turn.correctionNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    if turn.correctedText != nil && !turn.correctedText!.isEmpty {
                        Spacer().frame(width: 14)
                    } else {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 4)
    }
}
