import Foundation
import Security

/// Tiny Keychain wrapper for storing per-provider API keys.
/// Service = our bundle ID; account = the provider's `id` (e.g. "zai").
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.ruojunye.glotty"

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete any existing item so write is idempotent.
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        if case .value(let v) = readResult(account: account) { return v }
        return nil
    }

    /// Why a read didn't return a usable value. `locked` is the one worth
    /// telling apart: a locked (or otherwise inaccessible) login keychain reads
    /// exactly like a missing key through `read()`, which is how "needs an API
    /// key" gets shown when the key is really there but unreadable.
    enum ReadResult { case value(String), missing, locked }

    /// Read the key, and if the keychain is locked, raise the system unlock
    /// dialog and try once more. Glotty runs as an agent (LSUIElement), so a
    /// locked keychain doesn't auto-prompt on `SecItemCopyMatching` the way it
    /// does for a foreground app — it just returns `interactionNotAllowed`. So
    /// we trigger the prompt ourselves and re-read; the stored key comes back
    /// once the user types their login password.
    static func readResult(account: String) -> ReadResult {
        switch copy(account: account) {
        case .locked:
            // usePassword:false → SecurityAgent shows the standard "unlock
            // login keychain" panel. Deprecated API, but the only way to
            // summon that dialog; nil keychain = the default (login) one.
            SecKeychainUnlock(nil, 0, nil, false)
            return copy(account: account)
        case let other:
            return other
        }
    }

    private static func copy(account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data, let value = String(data: data, encoding: .utf8),
               !value.isEmpty { return .value(value) }
            return .missing
        // Item is there but its data can't be read: keychain locked, or the OS
        // won't let this (agent) process prompt to unlock it.
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecInteractionRequired:
            return .locked
        default:
            return .missing
        }
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
