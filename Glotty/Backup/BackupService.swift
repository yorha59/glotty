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
        var keys: [String: String] = [:]
        for account in knownKeychainAccounts() {
            if let secret = Keychain.read(account: account), !secret.isEmpty {
                keys[account] = secret
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
            historyEvents: MemoryStore.shared.allEvents(),
            apiKeys: keys
        )
    }

    /// Every Keychain account that holds a provider API key:
    /// the four OpenAI-compatible stock presets (account == preset
    /// id), the two native providers, and one per user-defined
    /// custom provider. Custom providers are enumerated live so the
    /// list tracks whatever the user has configured.
    private static func knownKeychainAccounts() -> [String] {
        var accounts = OpenAIStockPresets.all.map { $0.id }
        accounts.append(DeepSeekProvider.keychainAccount)
        accounts.append(KimiCodingProvider.keychainAccount)
        accounts.append(contentsOf: CustomProviderStore.all().map { $0.providerID })
        return accounts
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

    /// Prompt for an encryption password, present a save panel, and
    /// write the AES-GCM-encrypted bundle on confirm. Returns the
    /// destination URL on success; nil if the user cancelled the
    /// password prompt or the save panel. Throws on encode/encrypt/
    /// write failure.
    ///
    /// The bundle now carries API keys, so the plaintext is encrypted
    /// before it ever touches disk — there is no unencrypted export
    /// path.
    @discardableResult
    static func exportInteractive() async throws -> URL? {
        guard let password = await MainActor.run(body: {
            promptForPassword(
                title: String(localized: "Encrypt backup"),
                message: String(localized: "This backup includes your API keys. Choose a password — you'll need it to restore on another machine."),
                confirm: true
            )
        }) else { return nil }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Glotty backup")
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]

        let result = await MainActor.run { panel.runModal() }
        guard result == .OK, let url = panel.url else { return nil }
        let plaintext = try encode(makeBundle())
        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        try encrypted.write(to: url, options: .atomic)
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
        guard BackupBundle.supportedVersions.contains(bundle.version) else {
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
        applyAPIKeys(bundle.apiKeys)
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

        let fileData = try Data(contentsOf: url)

        // Encrypted backups (the current format) need a password to
        // decrypt; legacy v1 plaintext bundles import directly.
        let bundleData: Data
        if BackupCrypto.isEncryptedBackup(fileData) {
            guard let password = await MainActor.run(body: {
                promptForPassword(
                    title: String(localized: "Decrypt backup"),
                    message: String(localized: "Enter the password this backup was encrypted with."),
                    confirm: false
                )
            }) else { return nil }
            bundleData = try BackupCrypto.decrypt(fileData, password: password)
        } else {
            bundleData = fileData
        }

        let bundle = try decode(bundleData)

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

    /// Restore provider API keys into the Keychain. Only writes the
    /// accounts present in the bundle — accounts absent from the
    /// backup keep whatever's already on this machine rather than
    /// being wiped, so importing a settings-only backup doesn't
    /// clobber keys the user already entered here.
    private static func applyAPIKeys(_ keys: [String: String]) {
        for (account, secret) in keys where !secret.isEmpty {
            _ = Keychain.write(secret, account: account)
        }
    }

    /// Modal password prompt built on NSAlert + a secure text field.
    /// When `confirm` is true a second "verify" field is shown and
    /// the two must match (export, to avoid locking the user out of
    /// their own backup with a typo). Returns nil if the user
    /// cancels; loops on mismatch / empty input.
    private static func promptForPassword(title: String, message: String, confirm: Bool) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirm
                            ? String(localized: "Encrypt")
                            : String(localized: "Decrypt"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let width: CGFloat = 240
            let pw = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            pw.placeholderString = String(localized: "Password")
            if confirm {
                let verify = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                verify.placeholderString = String(localized: "Confirm password")
                let stack = NSStackView(views: [pw, verify])
                stack.orientation = .vertical
                stack.spacing = 6
                stack.frame = NSRect(x: 0, y: 0, width: width, height: 54)
                alert.accessoryView = stack
                alert.window.initialFirstResponder = pw

                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                let p = pw.stringValue
                if p.isEmpty {
                    warn(String(localized: "Password can't be empty."))
                    continue
                }
                if p != verify.stringValue {
                    warn(String(localized: "Passwords don't match. Try again."))
                    continue
                }
                return p
            } else {
                alert.accessoryView = pw
                alert.window.initialFirstResponder = pw
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                let p = pw.stringValue
                if p.isEmpty {
                    warn(String(localized: "Password can't be empty."))
                    continue
                }
                return p
            }
        }
    }

    private static func warn(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "OK"))
        a.runModal()
    }
}
