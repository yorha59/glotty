import Foundation

/// One user-defined OpenAI-compatible provider. Same wire format as the stock
/// presets — just with user-supplied endpoint / model / display name. Stored
/// as JSON in UserDefaults so the config survives across launches.
struct CustomProviderConfig: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var endpoint: String
    var model: String

    /// Stable provider id used as the keychain account and the UsageStore
    /// row key. Prefixed with `custom-` so it can't collide with a stock
    /// preset id like `zai` or `openai`.
    var providerID: String { "custom-\(id.uuidString)" }
}

/// JSON-encoded array of `CustomProviderConfig` persisted in UserDefaults.
/// Notifications fire on every mutation so Settings and the registry can
/// refresh without a full app restart.
enum CustomProviderStore {
    private static let userDefaultsKey = "glotty.customProviders"

    /// Posted after `upsert(_:)` / `delete(id:)` so UI can refresh.
    static let didChangeNotification = Notification.Name("glotty.customProviders.didChange")

    static func all() -> [CustomProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CustomProviderConfig].self, from: data)) ?? []
    }

    static func find(id: UUID) -> CustomProviderConfig? {
        all().first { $0.id == id }
    }

    /// Insert or replace by id. Used by the Settings "Save" button.
    static func upsert(_ config: CustomProviderConfig) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.id == config.id }) {
            list[idx] = config
        } else {
            list.append(config)
        }
        persist(list)
    }

    /// Remove by id and wipe the matching keychain entry so a future provider
    /// with the same UUID can't accidentally reuse the old key. (UUIDs don't
    /// collide in practice, but defensive cleanup is cheap.)
    static func delete(id: UUID) {
        var list = all()
        guard let removed = list.first(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        Keychain.delete(account: removed.providerID)
        persist(list)
    }

    private static func persist(_ list: [CustomProviderConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
