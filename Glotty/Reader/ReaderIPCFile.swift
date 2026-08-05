import Foundation

/// A drop box for the one IPC payload that outgrew a distributed notification:
/// the chat prompt. Distributed-notification `userInfo` silently drops oversized
/// values, and once the prompt carries page context it runs to tens of KB — so
/// the reader writes it here (a file both apps reach — same non-sandboxed
/// Application Support) keyed by request id, and the notification carries only
/// the id. Glotty reads it once and deletes it.
enum ReaderIPCFile {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let d = base.appendingPathComponent("Glotty/ipc", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ id: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension("prompt")
    }

    static func writePrompt(_ prompt: String, id: String) {
        pruneStale()
        try? prompt.write(to: url(id), atomically: true, encoding: .utf8)
    }

    /// Read-and-remove: the prompt is consumed exactly once by the server.
    static func readPrompt(id: String) -> String? {
        let u = url(id)
        defer { try? FileManager.default.removeItem(at: u) }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    /// Drop any prompt a server never picked up (Glotty was down and never
    /// launched, say) so unique-id files don't pile up. Cheap: the dir holds at
    /// most a handful at a time.
    private static func pruneStale() {
        let cutoff = Date().addingTimeInterval(-300)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }
}
