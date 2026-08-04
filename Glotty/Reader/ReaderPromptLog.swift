import Foundation
import os

/// Debug aid: records the exact prompt the reader chat sends to the model, so
/// "the answer doesn't seem to use the page" can be checked against what was
/// actually sent (page context included? how long?) rather than guessed.
///
/// Writes the most recent prompt to a fixed file (overwritten each send, so it
/// doesn't accumulate the user's reading history) and a one-line summary to the
/// unified log. Built into both the menu-bar and standalone reader, so it
/// captures whichever process assembled the prompt.
enum ReaderPromptLog {
    private static let log = Logger(subsystem: "com.ruojunye.glotty", category: "ReaderPrompt")

    /// `~/Library/Application Support/Glotty/last-reader-prompt.txt`
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Glotty/last-reader-prompt.txt")
    }

    static func record(_ prompt: String) {
        let marker = "The page the user is currently reading:"
        let hasPage = prompt.contains(marker)
        // Length of the page-context block (text between the marker's opening
        // and closing triple-quote), for a quick "is the context actually there
        // and non-trivial" read.
        let pageLen: Int = {
            guard let m = prompt.range(of: marker),
                  let open = prompt.range(of: "\"\"\"", range: m.upperBound..<prompt.endIndex),
                  let close = prompt.range(of: "\"\"\"", range: open.upperBound..<prompt.endIndex)
            else { return 0 }
            return prompt.distance(from: open.upperBound, to: close.lowerBound)
        }()
        log.debug("reader prompt: \(prompt.count) chars total, pageContext=\(hasPage) (\(pageLen) chars)")

        let header = "=== reader prompt @ \(ISO8601DateFormatter().string(from: Date())) ===\n"
            + "total \(prompt.count) chars · page context present: \(hasPage) (\(pageLen) chars)\n"
            + String(repeating: "-", count: 60) + "\n"
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (header + prompt + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
