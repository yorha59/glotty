import Foundation

/// Storage is injectable so migration failures can be exercised without real keys.
protocol CredentialVaultStorage {
    func read(_ account: String, allowInteraction: Bool) -> CredentialVault.DataResult
    func accounts() -> [String]?
    func save(_ data: Data, account: String) -> Bool
    func delete(_ account: String) -> Bool
    func withExclusiveAccess(_ body: () -> Bool) -> Bool
}

final class CredentialVault {
    static let account = "glotty.credentials.v1"
    enum DataResult { case value(Data), missing, unavailable }
    enum ReadResult { case value(String), missing, locked }
    private struct Document: Codable, Equatable {
        let version: Int
        var keys: [String: String]
        var migratedAccounts: Set<String>?
    }
    private let storage: any CredentialVaultStorage
    private let lock = NSRecursiveLock()
    private var cached: [String: String]?
    private var readBlocked = false
    private var pending: Set<String> = []

    var needsAuthorization: Bool {
        lock.lock(); defer { lock.unlock() }
        return readBlocked || !pending.isEmpty
    }

    init(storage: any CredentialVaultStorage) { self.storage = storage }

    func read(_ account: String) -> ReadResult {
        lock.lock(); defer { lock.unlock() }
        if readBlocked { return .locked }
        if cached == nil {
            var loaded: Document?
            guard storage.withExclusiveAccess({ loaded = self.loadAndMigrate(allowInteraction: false); return loaded != nil }),
                  let loaded else {
                // A denied/failed read must not open a dialog for every caller.
                readBlocked = true
                return .locked
            }
            cached = loaded.keys
        }
        guard let value = cached?[account], !value.isEmpty else {
            return pending.contains(account) ? .locked : .missing
        }
        return .value(value)
    }

    /// Only an explicit user action may raise system authorization dialogs.
    func authorize() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var loaded: Document?
        guard storage.withExclusiveAccess({ loaded = self.loadAndMigrate(allowInteraction: true); return loaded != nil }),
              let loaded else { readBlocked = true; return false }
        cached = loaded.keys
        readBlocked = false
        return pending.isEmpty
    }

    func write(_ value: String, account: String) -> Bool {
        mutate { $0[account] = value }
    }

    func delete(_ account: String) -> Bool {
        mutate { $0.removeValue(forKey: account) }
    }

    private func mutate(_ change: (inout [String: String]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Refresh inside an interprocess lock: a CLI/background writer must not
        // overwrite a key another process added after our cached read.
        let succeeded = storage.withExclusiveAccess {
            guard var doc = self.loadAndMigrate(allowInteraction: false), self.pending.isEmpty else { return false }
            change(&doc.keys)
            guard self.persist(doc) else { return false }
            self.cached = doc.keys
            return true
        }
        if succeeded { readBlocked = false }
        return succeeded
    }

    private func loadAndMigrate(allowInteraction: Bool) -> Document? {
        var doc: Document
        switch storage.read(Self.account, allowInteraction: allowInteraction) {
        case .missing: doc = Document(version: 1, keys: [:], migratedAccounts: [])
        case .unavailable: return nil
        case .value(let data):
            guard let decoded = try? JSONDecoder().decode(Document.self, from: data), decoded.version == 1
            else { return nil } // Never overwrite an unreadable/unknown format.
            doc = decoded
        }
        guard let accounts = storage.accounts() else { return nil }
        let legacy = accounts.filter { $0 != Self.account }
        pending = Set(legacy).subtracting(doc.migratedAccounts ?? [])
        guard !legacy.isEmpty else { return doc }
        // Persist each approved record immediately. Canceling a later dialog
        // must not discard progress and prompt for the same records next time.
        migration: for account in legacy.sorted() {
            // Cleanup can fail or be interrupted. Remember migrated accounts so
            // deleting a key from the vault never resurrects a leftover old item.
            if doc.migratedAccounts?.contains(account) == true {
                _ = storage.delete(account)
                continue
            }
            switch storage.read(account, allowInteraction: allowInteraction) {
            case .value(let data):
                guard let value = String(data: data, encoding: .utf8) else { return nil }
                // The vault wins if a previous migration's cleanup was interrupted.
                if doc.keys[account] == nil { doc.keys[account] = value }
            case .missing: continue
            case .unavailable:
                if allowInteraction { break migration }
                continue
            }
            doc.migratedAccounts = (doc.migratedAccounts ?? []).union([account])
            guard persist(doc) else { return nil }
            pending.remove(account)
            _ = storage.delete(account)
        }
        return doc
    }

    private func persist(_ doc: Document) -> Bool {
        guard let data = try? JSONEncoder().encode(doc), storage.save(data, account: Self.account),
              case .value(let readback) = storage.read(Self.account, allowInteraction: false),
              let verified = try? JSONDecoder().decode(Document.self, from: readback), verified == doc
        else { return false }
        return true
    }
}
