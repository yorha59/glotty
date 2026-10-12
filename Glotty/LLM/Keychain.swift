import Foundation
import Security
import Darwin

/// All provider keys share one keychain item; the public account API stays stable.
enum Keychain {
    private static let vault = CredentialVault(storage: SystemCredentialStorage(
        service: Bundle.main.bundleIdentifier ?? "com.ruojunye.glotty"))
    typealias ReadResult = CredentialVault.ReadResult

    @discardableResult
    static func write(_ value: String, account: String) -> Bool { vault.write(value, account: account) }
    static func read(account: String) -> String? {
        if case .value(let value) = readResult(account: account) { return value }
        return nil
    }
    static func readResult(account: String) -> ReadResult { vault.read(account) }
    static var needsAuthorization: Bool { vault.needsAuthorization }
    static func authorizeSavedKeys() -> Bool { vault.authorize() }
    @discardableResult
    static func delete(account: String) -> Bool { vault.delete(account) }
}

struct SystemCredentialStorage: CredentialVaultStorage {
    let service: String
    private static let interactionLock = NSRecursiveLock()

    /// Legacy login-keychain ACLs do not consistently honor the SecItem query's
    /// authentication-UI flag. Gate their process-wide interaction switch too.
    private func withInteraction<T>(_ allowed: Bool, failure: T, _ body: () -> T) -> T {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { return failure }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(_ account: String, allowInteraction: Bool) -> CredentialVault.DataResult {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        if !allowInteraction { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = withInteraction(allowInteraction, failure: errSecInteractionNotAllowed) {
            SecItemCopyMatching(q as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unavailable }
            return .value(data)
        case errSecItemNotFound: return .missing
        default: return .unavailable
        }
    }

    func accounts() -> [String]? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true]
        var silentQuery = q
        silentQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = withInteraction(false, failure: errSecInteractionNotAllowed) {
            SecItemCopyMatching(silentQuery as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return nil }
        let names = rows.compactMap { $0[kSecAttrAccount as String] as? String }
        return names.count == rows.count ? names.sorted() : nil
    }

    func save(_ data: Data, account: String) -> Bool {
        withInteraction(false, failure: false) { saveWithoutInteraction(data, account: account) }
    }

    private func saveWithoutInteraction(_ data: Data, account: String) -> Bool {
        var q = query(account)
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let attrs = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var added = query(account)
        added[kSecValueData as String] = data
        added[kSecAttrLabel as String] = "Glotty API Keys"
        let result = SecItemAdd(added as CFDictionary, nil)
        if result == errSecDuplicateItem {
            return SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        return result == errSecSuccess
    }

    func delete(_ account: String) -> Bool {
        var q = query(account)
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = withInteraction(false, failure: errSecInteractionNotAllowed) {
            SecItemDelete(q as CFDictionary)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func withExclusiveAccess(_ body: () -> Bool) -> Bool {
        // The lock contains no credentials. flock releases even if a process dies.
        let safeName = service.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(safeName) + ".credentials.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
