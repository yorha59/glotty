import CryptoKit
import CommonCrypto
import Foundation

/// Password-based encryption for Glotty backups. Backups now carry
/// API keys (read from Keychain), so the on-disk file must be
/// encrypted — never write the plaintext bundle to disk.
///
/// Scheme:
///   - Key derivation: PBKDF2-HMAC-SHA256, 600k iterations (OWASP
///     2023 floor for PBKDF2-SHA256), 16-byte random salt, 32-byte
///     derived key.
///   - Cipher: AES-256-GCM (CryptoKit `AES.GCM`). The sealed box's
///     combined representation (nonce ‖ ciphertext ‖ tag) is what we
///     persist — GCM's tag authenticates both the ciphertext and
///     makes a wrong password fail cleanly (decryption throws)
///     rather than yielding garbage.
///
/// File container is small JSON so it's self-describing and the
/// importer can detect "this is an encrypted Glotty backup" and the
/// KDF parameters without guessing.
enum BackupCrypto {
    static let format = "glotty-backup-encrypted"
    static let version = 1
    static let kdf = "pbkdf2-sha256"
    /// PBKDF2 work factor. High enough to make brute-forcing a weak
    /// password expensive; low enough that a single derive on a
    /// modern Mac stays well under a second. Persisted in the file
    /// so a future bump stays backward-compatible.
    static let iterations = 600_000

    /// Self-describing on-disk envelope. All binary fields base64.
    struct Envelope: Codable {
        let format: String
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: String        // base64, 16 bytes
        let ciphertext: String  // base64, AES-GCM combined box
    }

    enum CryptoError: LocalizedError {
        case emptyPassword
        case notEncryptedBackup
        case unsupported(String)
        case wrongPasswordOrCorrupt
        case kdfFailed

        var errorDescription: String? {
            switch self {
            case .emptyPassword:
                return "A password is required to encrypt the backup."
            case .notEncryptedBackup:
                return "This file isn't an encrypted Glotty backup."
            case .unsupported(let detail):
                return "Unsupported backup encryption: \(detail)"
            case .wrongPasswordOrCorrupt:
                return "Wrong password, or the backup file is corrupt."
            case .kdfFailed:
                return "Couldn't derive the encryption key from the password."
            }
        }
    }

    /// Encrypt arbitrary plaintext (the encoded BackupBundle JSON)
    /// under `password`. Returns the JSON-encoded envelope ready to
    /// write to disk.
    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!) == errSecSuccess
        }
        guard ok else { throw CryptoError.kdfFailed }

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.kdfFailed }

        let envelope = Envelope(
            format: format,
            version: version,
            kdf: kdf,
            iterations: iterations,
            salt: salt.base64EncodedString(),
            ciphertext: combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// True if `data` is an encrypted-backup envelope. Lets the
    /// importer branch between the new encrypted format and legacy
    /// plaintext v1 bundles.
    static func isEncryptedBackup(_ data: Data) -> Bool {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return false }
        return env.format == format
    }

    /// Decrypt an envelope back to the plaintext bundle JSON.
    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.format == format else {
            throw CryptoError.notEncryptedBackup
        }
        guard env.kdf == kdf else {
            throw CryptoError.unsupported("kdf=\(env.kdf)")
        }
        guard let salt = Data(base64Encoded: env.salt),
              let combined = Data(base64Encoded: env.ciphertext) else {
            throw CryptoError.wrongPasswordOrCorrupt
        }

        let key = try deriveKey(password: password, salt: salt, iterations: env.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            // GCM tag mismatch (wrong key) or malformed box both land
            // here — surface as the single user-facing failure.
            throw CryptoError.wrongPasswordOrCorrupt
        }
    }

    // MARK: - KDF

    /// PBKDF2-HMAC-SHA256 → 32-byte SymmetricKey. CryptoKit has no
    /// password-stretching KDF (HKDF isn't one), so we drop to
    /// CommonCrypto for the iteration count.
    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pwData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBuf in
            salt.withUnsafeBytes { saltBuf in
                pwData.withUnsafeBytes { pwBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress!.assumingMemoryBound(to: CChar.self),
                        pwData.count,
                        saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.kdfFailed }
        return SymmetricKey(data: derived)
    }
}
