import Foundation

/// Per-install identity. Lets a differently-identified build (the
/// `GlottyLab` sandbox target, used to exercise the destructive
/// backup import without risking the real install) get a fully
/// separate data directory.
///
/// UserDefaults (keyed by bundle id) and Keychain (service == bundle
/// id, see `Keychain.service`) already isolate automatically when the
/// bundle id changes. This closes the third leg — the on-disk stores
/// under Application Support, which were otherwise hardcoded to a
/// shared "Glotty" folder.
enum AppIdentity {
    /// Folder name under `~/Library/Application Support` for this
    /// build's stores (memories, contexts, chat, history, usage,
    /// localization cache, polish categories).
    ///
    /// The production bundle id maps to "Glotty" unchanged, so an
    /// existing install's data is never orphaned. Any other bundle id
    /// (e.g. the lab target's `com.ruojunye.glotty.lab`) gets its own
    /// folder named after the id's last component — so a destructive
    /// import in the lab build writes to `Glotty-lab/`, never the
    /// real `Glotty/`.
    static let supportFolderName: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.ruojunye.glotty"
        if id == "com.ruojunye.glotty" { return "Glotty" }
        let suffix = id.split(separator: ".").last.map(String.init) ?? "alt"
        return "Glotty-\(suffix)"
    }()
}
