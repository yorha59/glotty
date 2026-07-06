import AppKit
import SwiftUI

/// Standalone window that lists every polish run flagged with a given
/// grammar category. Opened by clicking a row in the Memory tab's "Common
/// mistake types" section. Rows are clickable — they reuse the same
/// `PopupController.shared.show(replay:)` path the History list uses, so
/// each event redraws its original popup with the stored variants/issues.
///
/// One window at a time — clicking another category replaces the contents
/// of the existing window rather than spawning a second one, matching the
/// way SettingsWindowController and PermissionsWindowController behave.
@MainActor
final class MistakeTypeWindowController {
    static let shared = MistakeTypeWindowController()

    private var window: NSWindow?
    /// Token from `AppActivation.register` so the hotkey path can
    /// dismiss this window when a popup is about to open (Raycast-
    /// style — Settings/drill-in goes away before the next popup
    /// appears, keeping the popup in agent mode for IME).
    private var activationToken: UUID?
    private var closeObserver: NSObjectProtocol?
    private let contentWidth: CGFloat = 540
    /// Window is allowed to grow vertically with content up to this cap. The
    /// SwiftUI body itself clamps the inner ScrollView to roughly this
    /// height so long lists scroll instead of taking over the screen.
    static let maxContentHeight: CGFloat = 640

    func show(category: String, range: MemoryTimeRange) {
        Self.diag("show ENTER category='\(category)' range=\(range.rawValue)")
        let view = MistakeTypeView(category: category, range: range) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: view)
        // Auto-fit: the hosting controller asks SwiftUI for its intrinsic
        // size, and AppKit resizes the window to match. Combined with the
        // explicit width frame + `.fixedSize` vertically in the SwiftUI
        // body, this gives "tall enough to show everything (up to the cap),
        // short when there are only a few rows".
        host.sizingOptions = [.preferredContentSize]

        if let window {
            Self.diag("show REUSE existing window")
            window.contentViewController = host
            window.title = "\("Mistake type".t) — \(category)"
            // Already hold an activation slot — just nudge to the front.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let w = NSWindow(contentViewController: host)
        w.title = "\("Mistake type".t) — \(category)"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        host.view.layoutSubtreeIfNeeded()
        let preferred = host.preferredContentSize
        w.setContentSizeClampedToScreen(
            preferred.width > 0 && preferred.height > 0
                ? preferred
                : NSSize(width: contentWidth, height: 320)
        )
        w.contentMinSize = NSSize(width: contentWidth, height: 180)
        w.center()
        // No `.moveToActiveSpace` — see SettingsWindow for the why.
        window = w
        // Become a regular app for the lifetime of this window so it gets
        // proper Dock/⌘-Tab presence. Released on willClose.
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
        Self.diag("show NEW window size=\(w.frame.size) visible=\(w.isVisible)")
        Log.activationSnapshot(window: w, name: "MistakeType", op: "open-mistake-type")
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

    private static func diag(_ msg: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.settings, msg, file: file, line: line)
    }
}

/// SwiftUI body for the mistake-type drill-in. Pulls the matching events
/// out of `MemoryStore` each time `category` or `range` changes. Each row
/// taps through to the standard popup-restore flow.
@MainActor
struct MistakeTypeView: View {
    let category: String
    let range: MemoryTimeRange
    let onClose: () -> Void

    private var events: [MemoryEvent] {
        MemoryStore.shared.eventsForGrammarCategory(category, since: range.since())
    }

    /// Fixed width so AppKit only needs to ask SwiftUI for the *height* —
    /// keeps the auto-fit math 1-dimensional and avoids the window pulsing
    /// wider when long source-text rows are present.
    private let contentWidth: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category)
                        .font(.title3).bold()
                        .lineLimit(2)
                    Text(String(format: "%d polish runs flagged with this category".t,
                                events.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No polish runs in this time range.".t)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            row(event)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { openEvent(event) }
                        }
                    }
                    .padding(16)
                }
                // Let the ScrollView grow with content, but cap it so a long
                // history doesn't force a window taller than the screen.
                // `.fixedSize` on the outer stack then collapses the column to
                // exactly this height (or less, if the content is shorter).
                .frame(maxHeight: MistakeTypeWindowController.maxContentHeight)
            }
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .localizationAware()
    }

    private func openEvent(_ event: MemoryEvent) {
        let replay = PopupReplayPayload.from(event)
        NSApp.activate(ignoringOtherApps: true)
        PopupController.shared.show(sourceText: event.sourceText,
                                    mode: .polish,
                                    replay: replay)
    }

    @ViewBuilder
    private func row(_ event: MemoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Polish".t)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(Color.orange)
                if let lang = event.targetLang {
                    Text(lang.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(event.timestamp, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(event.sourceText)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let result = event.result, !result.isEmpty {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}
