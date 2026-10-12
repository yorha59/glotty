import Foundation
import PDFKit

/// Downloads into an owned temporary folder. The caller removes it after
/// copying the validated document into BookLibrary, including on cancellation.
enum ReaderLinkImport {
    struct Download {
        let url: URL
        let directory: URL

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    enum ImportError: LocalizedError {
        case invalidURL, httpStatus(Int), unsupportedDocument

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "Enter a valid HTTP or HTTPS link.")
            case .httpStatus(let status):
                return String(format: String(localized: "Download failed (HTTP %lld)."), Int64(status))
            case .unsupportedDocument:
                return String(localized: "This link did not return a readable PDF or EPUB. Use a direct document link.")
            }
        }
    }

    static func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw ImportError.invalidURL }
        return url
    }

    static func download(_ text: String, session: URLSession = .shared) async throws -> Download {
        let source = try sourceURL(text)
        var request = URLRequest(url: source)
        request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ImportError.unsupportedDocument }
        guard (200..<300).contains(http.statusCode) else { throw ImportError.httpStatus(http.statusCode) }
        guard let finalURL = response.url,
              ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "") else {
            throw ImportError.invalidURL
        }

        // Detect the actual document, not the URL extension or server MIME type:
        // arXiv PDF links end in an identifier such as 2608.25512.
        let ext: String
        if let pdf = PDFDocument(url: temporary), pdf.pageCount > 0 {
            ext = "pdf"
        } else if let epub = try? EPUBBook.open(temporary) {
            try? FileManager.default.removeItem(at: epub.rootDir)
            ext = "epub"
        } else { throw ImportError.unsupportedDocument }
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlottyLinkImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let name = filename(response.suggestedFilename ?? finalURL.lastPathComponent, extension: ext)
            let target = directory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temporary, to: target)
            return Download(url: target, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func filename(_ suggestion: String, extension ext: String) -> String {
        var name = (suggestion as NSString).lastPathComponent
        // Strip known document extensions only, preserving dots in arXiv IDs.
        if ["pdf", "epub"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        name = name.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Document" }
        return String(name.prefix(180)) + "." + ext
    }
}
