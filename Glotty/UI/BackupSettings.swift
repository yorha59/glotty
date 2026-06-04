import SwiftUI

/// Settings → Backup tab. One section with Export… / Import… buttons,
/// a short description of what's included, and a live status line
/// after the most recent action. Heavy lifting (file dialogs +
/// JSON encode/decode + applying replaced data) lives in
/// `BackupService`.
struct BackupSettingsSection: View {
    /// Last-action status — shown under the buttons so the user
    /// gets immediate feedback that something happened. Cleared
    /// when the user kicks off the next action.
    enum Status: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }
    @State private var status: Status = .idle

    var body: some View {
        Group {
            actionsSection
            includedSection
        }
    }

    private var actionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Export\u{2026}", systemImage: "square.and.arrow.up")
                }
                .controlSize(.large)
                .disabled(isWorking)

                Button {
                    Task { await runImport() }
                } label: {
                    Label("Import\u{2026}", systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .disabled(isWorking)

                Spacer()
            }
            statusLine
        } header: {
            Text("Backup & restore")
        } footer: {
            Text("**Export** writes a single password-encrypted file with your settings, API keys, learned memories, chat threads, and activity history. You'll choose a password — keep it; it's the only way to restore. **Import** on another machine (or this one, after a wipe) asks for that password, then REPLACES local data after a confirmation prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var includedSection: some View {
        Section {
            includedRow(icon: "gearshape", label: "Preferences",
                        detail: "Profile, persona, languages, hotkeys, memory mode, polish, translation & dictionary settings.")
            includedRow(icon: "cpu", label: "LLM settings",
                        detail: "Selected provider, endpoints, models, custom providers.")
            includedRow(icon: "key.fill", label: "API keys",
                        detail: "Every provider key, read from Keychain. The reason the file is encrypted.")
            includedRow(icon: "brain", label: "Memories & contexts",
                        detail: "Accepted memories with scope, pending suggestions, your defined contexts.")
            includedRow(icon: "bubble.left.and.bubble.right", label: "Chat history",
                        detail: "All past daily chat threads with corrections.")
            includedRow(icon: "clock.arrow.circlepath", label: "Activity history",
                        detail: "Every translate / explain / polish event, with its discussion thread.")
            excludedRow(icon: "chart.bar", label: "Token usage",
                        detail: "Local to this machine.")
        } header: {
            Text("What's in the bundle")
        }
    }

    private func includedRow(icon: String, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.t).font(.callout.bold())
                Text(detail.t)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func excludedRow(icon: String, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label.t).font(.callout.bold())
                    Text("(excluded)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(detail.t)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let msg):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        case .success(let msg):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failure(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    private func runExport() async {
        status = .working("Writing backup\u{2026}")
        do {
            if let url = try await BackupService.exportInteractive() {
                status = .success("Exported to \(url.lastPathComponent).")
            } else {
                status = .idle
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func runImport() async {
        status = .working("Reading backup\u{2026}")
        do {
            if let bundle = try await BackupService.importInteractive() {
                let counts = "\(bundle.memories.count) memor\(bundle.memories.count == 1 ? "y" : "ies"), \(bundle.chatThreads.count) chat day\(bundle.chatThreads.count == 1 ? "" : "s"), \(bundle.historyEvents.count) activity event\(bundle.historyEvents.count == 1 ? "" : "s")"
                status = .success("Imported: \(counts).")
            } else {
                status = .idle
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
