import Foundation
import AppKit

/// Drives export and import of Glotty's settings/data bundle.
/// Stateless; the singleton lives just so SwiftUI views have a
/// stable point to call. All disk I/O happens off the main thread
/// via JSONEncoder/JSONDecoder (cheap; bundles top out in low MBs).
@MainActor
enum BackupService {

    // MARK: - Export

    /// Build a `BackupBundle` snapshot from every Glotty source of
    /// truth on this machine: known UserDefaults keys, learned memories,
    /// memory contexts, daily chat threads, and the activity history.
    static func makeBundle() -> BackupBundle {
        var prefs: [String: BackupPreferenceValue] = [:]
        for key in BackupPreferences.knownKeys {
            if let any = UserDefaults.standard.object(forKey: key),
               let wrapped = BackupPreferenceValue.from(any) {
                prefs[key] = wrapped
            }
        }
        return BackupBundle(
            format: BackupBundle.format,
            version: BackupBundle.currentVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            preferences: prefs,
            memories: LearnedMemoryStore.shared.allMemories(),
            contexts: MemoryContextStore.shared.all(),
            chatThreads: ChatStore.shared.allThreads(),
            historyEvents: MemoryStore.shared.allEvents()
        )
    }

    /// Encode a bundle as pretty-printed JSON. Pretty-printed because
    /// the file is small enough not to matter and a human-readable
    /// backup is nicer when you eventually open it in an editor to
    /// inspect.
    static func encode(_ bundle: BackupBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }

    /// Present a save panel and write the bundle on confirm.
    /// Returns the destination URL on success; nil if the user
    /// cancelled. Throws on encode or write failure.
    @discardableResult
    static func exportInteractive() async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Glotty backup")
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]

        let result = await MainActor.run { panel.runModal() }
        guard result == .OK, let url = panel.url else { return nil }
        let data = try encode(makeBundle())
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case wrongFormat
        case unsupportedVersion(Int)
        case decodeFailed(String)
        var errorDescription: String? {
            switch self {
            case .wrongFormat:
                return "This file isn't a Glotty backup."
            case .unsupportedVersion(let v):
                return "Backup version \(v) isn't supported by this build."
            case .decodeFailed(let msg):
                return "Couldn't read the backup: \(msg)"
            }
        }
    }

    /// Decode a bundle from raw file data. Validates the format
    /// header and version before handing back the bundle.
    static func decode(_ data: Data) throws -> BackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle: BackupBundle
        do {
            bundle = try decoder.decode(BackupBundle.self, from: data)
        } catch {
            throw ImportError.decodeFailed(error.localizedDescription)
        }
        guard bundle.format == BackupBundle.format else {
            throw ImportError.wrongFormat
        }
        guard bundle.version == BackupBundle.currentVersion else {
            throw ImportError.unsupportedVersion(bundle.version)
        }
        return bundle
    }

    /// Apply a decoded bundle in REPLACE mode (the only mode for
    /// v1 — the user explicitly picked "replace existing data" as
    /// the import policy). Each subsystem gets wiped and rebuilt
    /// from the bundle in lock-step so partial failure can't leave
    /// us with mismatched stores.
    static func applyReplacing(_ bundle: BackupBundle) {
        applyPreferences(bundle.preferences)
        applyLearnedMemory(memories: bundle.memories)
        applyContexts(bundle.contexts)
        applyChatThreads(bundle.chatThreads)
        applyHistoryEvents(bundle.historyEvents)
    }

    /// Present an open panel + confirmation alert, then apply.
    /// Returns the imported bundle on success; nil if the user
    /// cancelled either dialog. Throws decode errors so the caller
    /// can surface them in the UI.
    @discardableResult
    static func importInteractive() async throws -> BackupBundle? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Glotty backup")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        let pickResult = await MainActor.run { panel.runModal() }
        guard pickResult == .OK, let url = panel.url else { return nil }

        let data = try Data(contentsOf: url)
        let bundle = try decode(data)

        // Replace is destructive — make sure the user really wants it.
        let confirm = await MainActor.run { confirmReplaceAlert(bundle: bundle) }
        guard confirm else { return nil }

        applyReplacing(bundle)
        return bundle
    }

    // MARK: - Helpers

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "Glotty backup \(f.string(from: Date())).json"
    }

    private static func confirmReplaceAlert(bundle: BackupBundle) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace local data with backup?")
        alert.informativeText = """
        \(String(localized: "This will OVERWRITE existing preferences, memories, contexts, chat history, and activity history on this machine."))

        \(String(localized: "Bundle contents:"))
          \(bundle.preferences.count) \(String(localized: "preferences"))
          \(bundle.memories.count) \(String(localized: "memories")), \(bundle.contexts.count) \(String(localized: "contexts"))
          \(bundle.chatThreads.count) \(String(localized: "days of chat"))
          \(bundle.historyEvents.count) \(String(localized: "activity events"))
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func applyPreferences(_ prefs: [String: BackupPreferenceValue]) {
        // Clear all known keys first so the imported state is a
        // clean overlay — keys absent from the bundle revert to
        // their hard-coded defaults rather than carrying over from
        // the previous install.
        for key in BackupPreferences.knownKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in prefs {
            UserDefaults.standard.set(value.rawValue, forKey: key)
        }
    }

    private static func applyLearnedMemory(memories: [LearnedMemory]) {
        LearnedMemoryStore.shared.replaceAll(with: memories)
    }

    private static func applyContexts(_ contexts: [MemoryContext]) {
        MemoryContextStore.shared.replaceAll(with: contexts)
    }

    private static func applyChatThreads(_ threads: [DailyChatThread]) {
        ChatStore.shared.replaceAll(with: threads)
    }

    private static func applyHistoryEvents(_ events: [MemoryEvent]) {
        MemoryStore.shared.replaceAll(with: events)
    }
}
