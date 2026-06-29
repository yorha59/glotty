import Foundation
import CryptoKit

/// On-disk cache of synthesized speech (MP3). Replaying the same text in the
/// same voice/model hits the cache instead of re-calling ElevenLabs — saves the
/// user's quota and makes a repeat instant. Each clip is stored as `<hash>.mp3`
/// plus a `<hash>.json` sidecar (the original text + date) so Settings can list
/// the cached clips for playback. Lives under Caches; clearable from Settings.
enum VoiceCache {
    struct Entry: Identifiable, Hashable {
        let id: String          // content hash
        let text: String
        let date: Date
        var audioURL: URL { VoiceCache.dir.appendingPathComponent(id + ".mp3") }
    }

    fileprivate static var dir: URL {
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("GlottyVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func key(text: String, voice: String, model: String) -> String {
        let digest = SHA256.hash(data: Data("\(model)|\(voice)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(text: String, voice: String, model: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(key(text: text, voice: voice, model: model) + ".mp3"))
    }

    static func store(_ data: Data, text: String, voice: String, model: String) {
        let k = key(text: text, voice: voice, model: model)
        try? data.write(to: dir.appendingPathComponent(k + ".mp3"))
        let meta: [String: String] = [
            "text": text, "voice": voice, "model": model,
            "date": String(Date().timeIntervalSince1970)]
        if let j = try? JSONSerialization.data(withJSONObject: meta) {
            try? j.write(to: dir.appendingPathComponent(k + ".json"))
        }
    }

    /// Cached clips, newest first — for the Settings list.
    static func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Entry] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let m = try? JSONSerialization.jsonObject(with: d) as? [String: String],
                  let text = m["text"], !text.isEmpty else { continue }
            let id = f.deletingPathExtension().lastPathComponent
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(id + ".mp3").path)
            else { continue }
            let date = Date(timeIntervalSince1970: Double(m["date"] ?? "") ?? 0)
            out.append(Entry(id: id, text: text, date: date))
        }
        return out.sorted { $0.date > $1.date }
    }

    static func data(for entry: Entry) -> Data? { try? Data(contentsOf: entry.audioURL) }

    /// Total bytes on disk (audio + sidecars).
    static func sizeBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
