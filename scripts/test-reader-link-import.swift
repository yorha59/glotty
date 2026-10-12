// Run from the repo root (requires only macOS Command Line Tools):
// swiftc -sdk "$(xcrun --show-sdk-path)" -parse-as-library \
//   Glotty/Reader/{ReaderLinkImport,EPUBBook,MiniZip,BookLibrary,ReaderStore}.swift \
//   scripts/test-reader-link-import.swift -o /tmp/test-reader-link-import
// /tmp/test-reader-link-import [https://arxiv.org/pdf/2608.25512]
import Foundation
import PDFKit

@main
struct LinkImportChecks {
    enum Failure: Error { case check(String) }

    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.check(message) }
        print("ok: " + message)
    }

    @MainActor
    static func main() async throws {
        let root = ReaderStore.useSandbox()
        defer { ReaderStore.tearDownSandbox(root) }
        try check(ReaderStore.isSandboxed, "isolated library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        try check(pdf.write(to: root.appendingPathComponent("paper.pdf")), "PDF fixture")

        // A real local HTTP server exercises URLSession's downloads, redirects,
        // status handling and cancellation without depending on public hosts.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
import http.server, os, sys, time, zipfile
os.chdir(sys.argv[1])
with zipfile.ZipFile('book.epub', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
    z.writestr('book.opf', '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Link Test</dc:title><dc:identifier>link-test</dc:identifier></metadata><manifest><item id="c" href="chapter.xhtml"/></manifest><spine><itemref idref="c"/></spine></package>')
    z.writestr('chapter.xhtml', '<html><body>Chapter</body></html>')
with zipfile.ZipFile('unsafe.epub', 'w') as z:
    z.writestr('../escaped.txt', 'must not escape')
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/2608.25512'); self.end_headers(); return
        if self.path == '/slow':
            time.sleep(2); self.path = '/2608.25512'
        if self.path == '/2608.25512':
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream'); self.end_headers()
            try: self.wfile.write(open('paper.pdf', 'rb').read())
            except BrokenPipeError: pass
            return
        if self.path == '/html.pdf':
            self.send_response(200); self.end_headers(); self.wfile.write(b'<html>Login required</html>'); return
        super().do_GET()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
""", root.path]
        let pipe = Pipe()
        server.standardOutput = pipe
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "http://127.0.0.1:" + port

        for invalid in ["", "not a link", "file:///tmp/paper.pdf", "ftp://example.com/paper.pdf",
                        "https://", "https://user:secret@example.com/paper.pdf"] {
            do { _ = try ReaderLinkImport.sourceURL(invalid); throw Failure.check("accepted invalid URL") }
            catch ReaderLinkImport.ImportError.invalidURL { }
        }
        try check(try ReaderLinkImport.sourceURL("  https://arxiv.org/pdf/2608.25512\n").host == "arxiv.org",
                  "trim pasted link and reject invalid URLs")
        try check(ReaderLinkImport.filename("2608.25512", extension: "pdf") == "2608.25512.pdf",
                  "preserve arXiv identifier")
        try check(ReaderLinkImport.filename("../../book.PDF", extension: "pdf") == "book.pdf",
                  "safe filename")

        let download = try await ReaderLinkImport.download(base + "/2608.25512")
        try check(download.url.lastPathComponent == "2608.25512.pdf", "extensionless PDF with generic MIME type")
        let stored = try BookLibrary.importDocument(download.url)
        let same = try BookLibrary.importDocument(download.url)
        try check(stored == same, "repeat import reuses library copy")
        download.remove()
        try check(!FileManager.default.fileExists(atPath: download.directory.path), "download cleanup")
        try check(PDFDocument(url: stored)?.pageCount == 1, "library copy survives download cleanup")

        let redirected = try await ReaderLinkImport.download(base + "/redirect")
        try check(PDFDocument(url: redirected.url)?.pageCount == 1, "HTTP redirect")
        redirected.remove()

        let epub = try await ReaderLinkImport.download(base + "/book.epub")
        let storedEPUB = try BookLibrary.importDocument(epub.url)
        epub.remove()
        let book = try EPUBBook.open(storedEPUB)
        try check(book.title == "Link Test" && book.chapters.count == 1, "EPUB persists after download cleanup")
        try? FileManager.default.removeItem(at: book.rootDir)

        for path in ["/html.pdf", "/unsafe.epub"] {
            do {
                let unexpected = try await ReaderLinkImport.download(base + path)
                unexpected.remove()
                throw Failure.check("accepted invalid document: " + path)
            } catch ReaderLinkImport.ImportError.unsupportedDocument { }
        }
        try check(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("GlottyReader/escaped.txt").path), "reject EPUB path traversal")
        do {
            let unexpected = try await ReaderLinkImport.download(base + "/missing")
            unexpected.remove()
            throw Failure.check("accepted HTTP 404")
        } catch ReaderLinkImport.ImportError.httpStatus(let status) {
            try check(status == 404, "HTTP error status")
        }
        let task = Task { try await ReaderLinkImport.download(base + "/slow") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            let unexpected = try await task.value
            unexpected.remove()
            throw Failure.check("cancelled import completed")
        } catch is CancellationError {
            print("ok: cancellation")
        } catch let error as URLError where error.code == .cancelled {
            print("ok: cancellation")
        }

        if let link = CommandLine.arguments.dropFirst().first {
            let real = try await ReaderLinkImport.download(link)
            defer { real.remove() }
            let imported = try BookLibrary.importDocument(real.url)
            try check((PDFDocument(url: imported)?.pageCount ?? 0) > 0, "live PDF link imports into isolated library")
            print("pages: \(PDFDocument(url: imported)?.pageCount ?? 0)")
        }
        print("All link import checks passed")
    }
}
