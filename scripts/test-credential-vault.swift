// swiftc -parse-as-library Glotty/LLM/{CredentialVault,Keychain}.swift \
//   scripts/test-credential-vault.swift -o /tmp/test-credential-vault
import Foundation

final class FakeStorage: CredentialVaultStorage {
    var items: [String: Data] = [:]
    var denied: Set<String> = []
    var requiresAuthorization: Set<String> = []
    var interactiveReads = 0
    var failSave = false
    var failVerification = false
    var failDelete = false
    var reads = 0
    var deletes = 0
    func read(_ account: String, allowInteraction: Bool) -> CredentialVault.DataResult {
        reads += 1
        if allowInteraction { interactiveReads += 1 }
        if denied.contains(account) { return .unavailable }
        if !allowInteraction && requiresAuthorization.contains(account) { return .unavailable }
        if failVerification && account == CredentialVault.account && items[account] != nil { return .value(Data("bad".utf8)) }
        return items[account].map { .value($0) } ?? .missing
    }
    func accounts() -> [String]? { Array(items.keys) }
    func save(_ data: Data, account: String) -> Bool {
        if failSave { return false }; items[account] = data; return true
    }
    func delete(_ account: String) -> Bool {
        deletes += 1
        if failDelete { return false }; items.removeValue(forKey: account); return true
    }
    func withExclusiveAccess(_ body: () -> Bool) -> Bool { body() }
}

@main struct Checks {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name); checks += 1; print("ok: " + name)
    }
    static func value(_ vault: CredentialVault, _ account: String) -> String? {
        if case .value(let v) = vault.read(account) { return v }; return nil
    }
    static func legacy() -> FakeStorage {
        let s = FakeStorage()
        for a in ["gemini", "kimi-coding", "deepseek", "zai"] { s.items[a] = Data(("fixture-" + a).utf8) }
        return s
    }
    static func main() {
        if CommandLine.arguments.count == 4 {
            let vault = CredentialVault(storage: SystemCredentialStorage(service: CommandLine.arguments[1]))
            for i in 0..<10 {
                precondition(vault.write("fixture-\(i)", account: CommandLine.arguments[2]))
            }
            return
        }
        let s = legacy(); let v = CredentialVault(storage: s)
        check(value(v,"gemini") == "fixture-gemini", "migration preserves value")
        check(s.items.count == 1 && s.items[CredentialVault.account] != nil, "four old records become one")
        let reads = s.reads
        check(value(v,"zai") == "fixture-zai" && s.reads == reads, "reads share one cached authorization")
        check(v.write("custom-fixture", account:"custom-id"), "custom provider write")
        check(v.delete("deepseek") && value(v,"deepseek") == nil, "delete only the requested key")
        check(value(v,"gemini") == "fixture-gemini", "delete preserves other providers")
        let reloaded = CredentialVault(storage:s)
        check(value(reloaded,"custom-id") == "custom-fixture", "new process reloads JSON vault")
        check(reloaded.write("changed",account:"zai"), "second writer updates vault")
        check(v.write("new",account:"another") && value(CredentialVault(storage:s),"zai") == "changed", "stale writer refreshes before update")

        let denied = legacy(); denied.denied.insert("zai"); let blocked = CredentialVault(storage:denied)
        check(value(blocked,"gemini") == "fixture-gemini" && denied.items["zai"] != nil,
              "denial preserves inaccessible original and approved migration progress")
        let deniedReads = denied.reads
        _ = blocked.read("kimi-coding")
        check(denied.reads == deniedReads, "denial does not repeatedly prompt")
        denied.denied.removeAll()
        check(blocked.write("retry",account:"gemini"), "explicit save retries after denial")

        let interactive = legacy()
        interactive.requiresAuthorization = Set(interactive.items.keys)
        let quiet = CredentialVault(storage: interactive)
        check(value(quiet,"zai") == nil && interactive.interactiveReads == 0 && quiet.needsAuthorization,
              "startup never raises authorization dialogs")
        interactive.denied.insert("kimi-coding")
        check(!quiet.authorize() && interactive.items["deepseek"] == nil && interactive.items["gemini"] == nil,
              "explicit migration saves approved records before cancellation")
        interactive.denied.removeAll()
        check(quiet.authorize() && interactive.items.count == 1 && !quiet.needsAuthorization,
              "explicit retry resumes only remaining migration")

        let failed = legacy(); failed.failSave = true
        check(value(CredentialVault(storage:failed),"zai") == nil && failed.deletes == 0, "failed migration write never deletes originals")
        let verification = legacy(); verification.failVerification = true
        check(value(CredentialVault(storage:verification),"zai") == nil && verification.deletes == 0, "failed readback never deletes originals")
        let corrupt = FakeStorage(); corrupt.items[CredentialVault.account] = Data("corrupt".utf8)
        check(!CredentialVault(storage:corrupt).write("new",account:"zai") && corrupt.items[CredentialVault.account] == Data("corrupt".utf8), "corrupt vault never overwritten")

        let cleanup = legacy(); cleanup.failDelete = true; let c = CredentialVault(storage:cleanup)
        check(value(c,"zai") == "fixture-zai", "cleanup failure retains readable merged vault")
        check(c.delete("zai") && value(CredentialVault(storage:cleanup),"zai") == nil, "leftover legacy item cannot resurrect deleted key")
        cleanup.failDelete = false
        _ = CredentialVault(storage:cleanup).read("gemini")
        check(cleanup.items.count == 1, "next launch finishes interrupted cleanup")
        let before = s.items[CredentialVault.account]
        s.failSave = true
        check(!v.write("lost",account:"gemini") && s.items[CredentialVault.account] == before, "failed update preserves existing vault")

        // Exercise Security.framework against a unique service with fixture keys.
        let real = SystemCredentialStorage(service:"com.ruojunye.glotty.vault-tests." + UUID().uuidString)
        defer { _ = real.delete(CredentialVault.account); _ = real.delete("old-fixture") }
        check(real.save(Data("sandbox-only".utf8), account:"old-fixture"), "isolated real keychain legacy fixture")
        let actual = CredentialVault(storage:real)
        check(value(actual,"old-fixture") == "sandbox-only", "real keychain migration")
        check(real.accounts() == [CredentialVault.account], "real keychain contains one record")
        check(actual.write("second-fixture",account:"new-fixture") && actual.delete("old-fixture"), "real keychain update and delete")
        check(value(CredentialVault(storage:real),"new-fixture") == "second-fixture", "real keychain persistence")
        let sharedService = "com.ruojunye.glotty.vault-tests." + UUID().uuidString
        let shared = SystemCredentialStorage(service: sharedService)
        defer { _ = shared.delete(CredentialVault.account) }
        let processes = ["writer-a", "writer-b"].map { account -> Process in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = [sharedService, account, "writer"]
            try! p.run()
            return p
        }
        for p in processes { p.waitUntilExit() }
        check(processes.allSatisfy { $0.terminationStatus == 0 }, "parallel keychain writers finish")
        let sharedVault = CredentialVault(storage:shared)
        check(value(sharedVault,"writer-a") == "fixture-9" && value(sharedVault,"writer-b") == "fixture-9",
              "interprocess lock preserves both writers' keys")
        print("\(checks)/\(checks) passed; production credentials untouched")
    }
}
