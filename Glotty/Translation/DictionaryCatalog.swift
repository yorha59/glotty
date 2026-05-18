import Foundation

/// Per-dictionary metadata pulled from the macOS asset catalog. Authoritative
/// alternative to inferring kind / languages from a dict's display name.
struct DictionaryMetadata: Equatable {
    let kind: DictionarySelection.DictionaryKind?  // nil if catalog didn't specify
    let languages: [String]                        // e.g. ["en"], ["en", "zh-Hans"]
}

/// Process-wide cache of dictionary metadata read from `/System/Library/AssetsV2`.
/// Loaded lazily on first call; the disk walk runs once per app lifetime and is
/// shared between `DictionaryLookup` (for kind classification) and `SettingsView`
/// (for the install-dialog library list).
///
/// Nonisolated — `cache` is `nonisolated(unsafe)` because writes only happen on
/// the single completion callback of the lazy loader (gated by `loading`), and
/// reads after that point are stable.
enum DictionaryCatalog {
    nonisolated(unsafe) private static var cache: [DictionaryMetadata.Lookup]?
    nonisolated(unsafe) private static var loading = false

    /// Synchronous read of the cached metadata. Returns nil for a dict if the
    /// cache isn't populated yet OR if no manifest matched the dict.
    static func metadata(for info: DictionaryLookup.DictionaryInfo) -> DictionaryMetadata? {
        guard let cache else { return nil }
        // Match by identifier first (most reliable), then by name, then by path.
        for entry in cache {
            if let id = entry.identifier, id == info.id { return entry.metadata }
        }
        let normalizedTargetName = normalizedName(info.name)
        for entry in cache {
            if let name = entry.normalizedName, name == normalizedTargetName {
                return entry.metadata
            }
        }
        for entry in cache {
            if let path = entry.referencePath, info.path.contains(path) {
                return entry.metadata
            }
        }
        return nil
    }

    /// Kick off the catalog walk in the background. Idempotent — repeated calls
    /// while a load is in-flight are no-ops; calls after success are no-ops too.
    /// `onLoaded` fires once the cache is ready (or immediately if it was already
    /// loaded). Caller is responsible for hopping back to the right actor if needed.
    static func loadIfNeeded(_ onLoaded: (@Sendable () -> Void)? = nil) {
        if cache != nil { onLoaded?(); return }
        if loading { return }
        loading = true
        Task.detached(priority: .utility) {
            let entries = computeCatalog()
            cache = entries
            loading = false
            onLoaded?()
        }
    }

    /// Replace the cache with an externally-loaded list. Used by SettingsView
    /// when its library-dialog code already walked the directory and we want to
    /// avoid a second walk.
    static func seed(with libraryItems: [LibraryItemSnapshot]) {
        let entries = libraryItems.map { item in
            DictionaryMetadata.Lookup(
                identifier: item.identifier,
                normalizedName: item.displayName.map(normalizedName),
                referencePath: item.reference,
                metadata: DictionaryMetadata(
                    kind: item.kind,
                    languages: item.languages
                )
            )
        }
        cache = entries
    }

    /// Snapshot of one library entry — lets callers seed the cache without
    /// having to import the full SettingsView types.
    struct LibraryItemSnapshot {
        let reference: String
        let identifier: String?
        let displayName: String?
        let languages: [String]
        let kind: DictionarySelection.DictionaryKind?
    }

    nonisolated private static func computeCatalog() -> [DictionaryMetadata.Lookup] {
        let root = "/System/Library/AssetsV2"
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: root) else { return [] }

        var entries: [DictionaryMetadata.Lookup] = []
        for case let relativePath as String in enumerator {
            guard relativePath.contains("DictionaryServices"),
                  relativePath.hasSuffix(".xml") else { continue }
            let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(relativePath))
            guard let catalog = NSDictionary(contentsOf: url) as? [String: Any],
                  let assets = catalog["Assets"] as? [[String: Any]] else { continue }

            for asset in assets {
                guard let packageName = asset["DictionaryPackageName"] as? String else { continue }
                let identifier = asset["DictionaryIdentifier"] as? String
                let displayName = asset["DictionaryPackageDisplayName"] as? String
                let languages = (asset["IndexLanguages"] as? [String]) ?? []
                let dictionaryType = (asset["DictionaryType"] as? String)?.lowercased()
                let kind: DictionarySelection.DictionaryKind?
                switch dictionaryType {
                case "bilingual":   kind = .bilingual
                case "monolingual": kind = .monolingual
                default:            kind = nil
                }
                let referenceName = packageName.hasSuffix(".dictionary") || packageName.hasSuffix(".wikipediadictionary")
                    ? packageName
                    : "\(packageName).dictionary"
                entries.append(DictionaryMetadata.Lookup(
                    identifier: identifier,
                    normalizedName: displayName.map(normalizedName),
                    referencePath: referenceName,
                    metadata: DictionaryMetadata(kind: kind, languages: languages)
                ))
            }
        }
        return entries
    }

    nonisolated private static func normalizedName(_ name: String) -> String {
        name
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}

extension DictionaryMetadata {
    /// Internal cache row keyed on multiple identifying fields so we can match a
    /// DictionaryInfo by whichever of identifier / name / path is most reliable.
    struct Lookup {
        let identifier: String?
        let normalizedName: String?
        let referencePath: String?
        let metadata: DictionaryMetadata
    }
}
