import Testing
import Foundation
@testable import Glotty

/// Backup export/import coverage. Designed to NEVER touch the real
/// Glotty domain or the user's real provider keys:
///   - Crypto / serialization tests use synthetic in-memory data.
///   - The preference-apply test runs against a throwaway
///     UserDefaults suite, removed on completion.
///   - The Keychain test uses a random throwaway account name and
///     deletes it afterward — it never reads or writes a real
///     provider's key.
///   - The real-data test is READ-ONLY: it snapshots current
///     settings via makeBundle(), round-trips through encrypt/
///     decrypt, and asserts fidelity. It never calls any apply*.
@Suite("Backup — encryption, serialization, round-trip")
@MainActor
struct BackupTests {

    // MARK: - Crypto

    @Test("AES-GCM round-trips plaintext under the right password")
    func cryptoRoundTrip() throws {
        let plaintext = Data("the quick brown fox — 你好".utf8)
        let blob = try BackupCrypto.encrypt(plaintext, password: "correct horse")
        #expect(BackupCrypto.isEncryptedBackup(blob))
        let out = try BackupCrypto.decrypt(blob, password: "correct horse")
        #expect(out == plaintext)
    }

    @Test("Wrong password fails cleanly via the GCM auth tag")
    func cryptoWrongPassword() throws {
        let blob = try BackupCrypto.encrypt(Data("secret".utf8), password: "right")
        #expect(throws: BackupCrypto.CryptoError.self) {
            _ = try BackupCrypto.decrypt(blob, password: "wrong")
        }
    }

    @Test("Empty password is rejected on encrypt")
    func cryptoEmptyPassword() {
        #expect(throws: BackupCrypto.CryptoError.self) {
            _ = try BackupCrypto.encrypt(Data("x".utf8), password: "")
        }
    }

    @Test("Tampered ciphertext is rejected")
    func cryptoTamper() throws {
        let blob = try BackupCrypto.encrypt(Data("payload".utf8), password: "pw")
        // Flip a byte in the envelope's ciphertext and confirm decrypt
        // refuses rather than returning garbage.
        var env = try JSONDecoder().decode(BackupCrypto.Envelope.self, from: blob)
        var raw = Data(base64Encoded: env.ciphertext)!
        raw[raw.count - 1] ^= 0xFF
        env = BackupCrypto.Envelope(
            format: env.format, version: env.version, kdf: env.kdf,
            iterations: env.iterations, salt: env.salt,
            ciphertext: raw.base64EncodedString())
        let tampered = try JSONEncoder().encode(env)
        #expect(throws: BackupCrypto.CryptoError.self) {
            _ = try BackupCrypto.decrypt(tampered, password: "pw")
        }
    }

    @Test("Plaintext bundle is not mistaken for an encrypted backup")
    func detectPlaintext() throws {
        let bundle = Self.syntheticBundle()
        let data = try BackupService.encode(bundle)
        #expect(!BackupCrypto.isEncryptedBackup(data))
    }

    // MARK: - Bundle serialization

    @Test("Bundle encodes and decodes with full fidelity, including .data / .plist prefs and apiKeys")
    func bundleRoundTrip() throws {
        let bundle = Self.syntheticBundle()
        let data = try BackupService.encode(bundle)
        let decoded = try BackupService.decode(data)

        #expect(decoded.version == bundle.version)
        #expect(decoded.apiKeys == bundle.apiKeys)
        #expect(decoded.preferences == bundle.preferences)
        // Deterministic re-encode (sortedKeys) proves byte-level fidelity.
        #expect(try BackupService.encode(decoded) == data)
    }

    @Test("v1 bundle without apiKeys still decodes (defaults to empty)")
    func bundleBackwardCompat() throws {
        // Hand-craft a minimal v1 payload missing the apiKeys field.
        let json = """
        {"format":"glotty-backup","version":1,"exportedAt":"2026-01-01T00:00:00Z",
         "appVersion":"0.1.0","preferences":{},"memories":[],"contexts":[],
         "chatThreads":[],"historyEvents":[]}
        """
        let decoded = try BackupService.decode(Data(json.utf8))
        #expect(decoded.apiKeys.isEmpty)
        #expect(decoded.version == 1)
    }

    // MARK: - BackupPreferenceValue

    @Test("Scalar, Data, and container preference values round-trip through from()/rawValue")
    func prefValueRoundTrip() throws {
        // Scalars
        #expect(BackupPreferenceValue.from("hi") == .string("hi"))
        #expect(BackupPreferenceValue.from(42) == .int(42))
        #expect(BackupPreferenceValue.from(true) == .bool(true))

        // Raw Data (customProviders / dictionary selections shape)
        let blob = Data("[{\"id\":\"x\"}]".utf8)
        guard case .data(let d)? = BackupPreferenceValue.from(blob) else {
            Issue.record("Data did not map to .data"); return
        }
        #expect(d == blob)

        // [String:String] container (dictionaryKindOverrides shape)
        let dict: [String: String] = ["a": "bilingual", "b": "monolingual"]
        guard case .plist? = BackupPreferenceValue.from(dict) else {
            Issue.record("dictionary did not map to .plist"); return
        }
        let restored = BackupPreferenceValue.from(dict)!.rawValue as? [String: String]
        #expect(restored == dict)
    }

    // MARK: - Apply (isolated)

    @Test("applyPreferences clears known keys then restores, incl. non-scalars — isolated suite")
    func applyPreferencesIsolated() throws {
        let suiteName = "glotty.backup.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Seed a stale value at a known key to prove clear-then-set
        // wipes pre-existing state not present in the bundle.
        suite.set("STALE", forKey: "glotty.user.displayName")

        let overrides: [String: String] = ["dictX": "bilingual"]
        let prefs: [String: BackupPreferenceValue] = [
            "glotty.targetLang": .string("zh"),
            "glotty.kimi.model": .string("kimi-for-coding"),
            "glotty.dictionaryKindOverrides": .from(overrides)!,
        ]
        BackupService.applyPreferences(prefs, into: suite)

        #expect(suite.string(forKey: "glotty.targetLang") == "zh")
        #expect(suite.string(forKey: "glotty.kimi.model") == "kimi-for-coding")
        #expect(suite.dictionary(forKey: "glotty.dictionaryKindOverrides") as? [String: String] == overrides)
        // displayName wasn't in the bundle → cleared, not left as STALE.
        #expect(suite.string(forKey: "glotty.user.displayName") == nil)
    }

    @Test("applyAPIKeys writes to Keychain — throwaway account, self-cleaning")
    func applyAPIKeysIsolated() {
        let account = "glotty-backup-test-\(UUID().uuidString)"
        defer { _ = Keychain.delete(account: account) }
        BackupService.applyAPIKeys([account: "sk-test-secret"])
        #expect(Keychain.read(account: account) == "sk-test-secret")
    }

    // MARK: - Real-data, READ-ONLY full pipeline

    @Test("makeBundle → encrypt → decrypt → decode preserves the live snapshot (read-only)")
    func realDataReadOnlyRoundTrip() throws {
        // makeBundle reads the real host domain — read-only, no writes.
        let original = BackupService.makeBundle()
        let plaintext = try BackupService.encode(original)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "test-pw-123")
        #expect(BackupCrypto.isEncryptedBackup(encrypted))

        let decryptedPlaintext = try BackupCrypto.decrypt(encrypted, password: "test-pw-123")
        #expect(decryptedPlaintext == plaintext)

        let decoded = try BackupService.decode(decryptedPlaintext)
        #expect(decoded.apiKeys == original.apiKeys)
        #expect(decoded.preferences == original.preferences)
        #expect(decoded.memories.count == original.memories.count)
        #expect(decoded.chatThreads.count == original.chatThreads.count)
        #expect(decoded.historyEvents.count == original.historyEvents.count)
        // Re-encode equality = full byte-level fidelity through the
        // whole export/import serialization path.
        #expect(try BackupService.encode(decoded) == plaintext)
    }

    // MARK: - Fixtures

    private static func syntheticBundle() -> BackupBundle {
        let prefs: [String: BackupPreferenceValue] = [
            "glotty.targetLang": .string("ja"),
            "glotty.practice.intervalMinutes": .int(240),
            "glotty.dictionary.showAllMatches": .bool(true),
            "glotty.customProviders": .data(Data("[{\"id\":\"x\"}]".utf8)),
            "glotty.dictionaryKindOverrides": .from(["d1": "bilingual"])!,
        ]
        return BackupBundle(
            format: BackupBundle.format,
            version: BackupBundle.currentVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "test",
            preferences: prefs,
            memories: [],
            contexts: [],
            chatThreads: [],
            historyEvents: [],
            apiKeys: ["zai": "sk-zai-xxx", "kimi-coding": "sk-kimi-yyy"]
        )
    }
}
