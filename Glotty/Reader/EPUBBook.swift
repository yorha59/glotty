import Foundation

/// A parsed EPUB: spine (reading order), table of contents, and metadata.
///
/// On open we extract the whole archive to a temp directory and render chapters
/// as `file://` URLs, so the `WKWebView` resolves each chapter's CSS / images /
/// fonts naturally (with read access scoped to `rootDir`). EPUB is just zipped
/// XHTML, so there's no DRM handling here — DRM'd store books won't open, by
/// design.
struct EPUBBook {
    struct Chapter: Identifiable {
        let id: String          // manifest item id
        let href: String        // path relative to the OPF directory
        let url: URL            // on-disk file URL in the temp extraction
    }
    struct TOCItem: Identifiable {
        let id = UUID()
        let label: String
        let href: String        // may include a #fragment
        let chapterIndex: Int?  // resolved spine index, when matchable
    }

    let title: String
    let author: String
    /// Stable per-book key for persisting reading progress / looked-up words.
    let identifier: String
    let rootDir: URL            // temp extraction root (WKWebView read scope)
    let chapters: [Chapter]
    let toc: [TOCItem]

    enum OpenError: Error { case notAZip, noRootfile, noOPF, emptySpine }

    static func open(_ epubURL: URL) throws -> EPUBBook {
        guard let zip = MiniZip(url: epubURL) else { throw OpenError.notAZip }

        // Extract everything to a fresh temp dir.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlottyReader", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for entry in zip.entries {
            guard let data = zip.data(entry.name) else { continue }
            let dest = root.appendingPathComponent(entry.name)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest)
        }

        // container.xml → OPF path (relative to the zip root).
        guard let containerXML = zip.string("META-INF/container.xml"),
              let opfPath = Self.firstAttribute(
                in: containerXML, element: "rootfile", attribute: "full-path")
        else { throw OpenError.noRootfile }

        guard let opfXML = zip.string(opfPath) else { throw OpenError.noOPF }
        let opfDir = (opfPath as NSString).deletingLastPathComponent   // "" or "OEBPS"

        // Parse the OPF: manifest (id → href + properties + media-type),
        // spine (ordered idrefs), and a little metadata.
        guard let opf = try? XMLDocument(xmlString: opfXML, options: [.nodePreserveWhitespace]) else {
            throw OpenError.noOPF
        }
        var manifest: [String: (href: String, props: String, type: String)] = [:]
        for node in (try? opf.nodes(forXPath: "//*[local-name()='item']")) ?? [] {
            guard let el = node as? XMLElement, let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = (href,
                            el.attribute(forName: "properties")?.stringValue ?? "",
                            el.attribute(forName: "media-type")?.stringValue ?? "")
        }
        var spineIDs: [String] = []
        for node in (try? opf.nodes(forXPath: "//*[local-name()='itemref']")) ?? [] {
            if let el = node as? XMLElement, let idref = el.attribute(forName: "idref")?.stringValue {
                spineIDs.append(idref)
            }
        }
        guard !spineIDs.isEmpty else { throw OpenError.emptySpine }

        func fileURL(forHref href: String) -> URL {
            let rel = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            return root.appendingPathComponent(rel)
        }

        let chapters: [Chapter] = spineIDs.compactMap { id in
            guard let m = manifest[id] else { return nil }
            return Chapter(id: id, href: m.href, url: fileURL(forHref: m.href))
        }
        guard !chapters.isEmpty else { throw OpenError.emptySpine }

        let title = Self.text(opf, "//*[local-name()='title']") ?? (epubURL.deletingPathExtension().lastPathComponent)
        let author = Self.text(opf, "//*[local-name()='creator']") ?? ""
        let identifier = Self.text(opf, "//*[local-name()='identifier']") ?? epubURL.lastPathComponent

        // TOC: prefer the EPUB3 nav document (manifest item with properties
        // "nav"); fall back to the EPUB2 NCX.
        var toc: [TOCItem] = []
        let hrefToIndex: (String) -> Int? = { href in
            let base = href.split(separator: "#").first.map(String.init) ?? href
            return chapters.firstIndex { $0.href == base || $0.href.hasSuffix("/" + base) }
        }
        if let navEntry = manifest.values.first(where: { $0.props.contains("nav") }),
           let navXML = zip.string(opfDir.isEmpty ? navEntry.href : "\(opfDir)/\(navEntry.href)") {
            toc = Self.parseNav(navXML, resolve: hrefToIndex)
        } else if let ncx = manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }),
                  let ncxXML = zip.string(opfDir.isEmpty ? ncx.href : "\(opfDir)/\(ncx.href)") {
            toc = Self.parseNCX(ncxXML, resolve: hrefToIndex)
        }
        if toc.isEmpty {
            // No TOC document — fall back to the spine itself.
            toc = chapters.enumerated().map { i, c in
                TOCItem(label: "Section \(i + 1)", href: c.href, chapterIndex: i)
            }
        }

        return EPUBBook(title: title, author: author, identifier: identifier,
                        rootDir: root, chapters: chapters, toc: toc)
    }

    // MARK: - XML helpers

    private static func text(_ doc: XMLDocument, _ xpath: String) -> String? {
        guard let n = (try? doc.nodes(forXPath: xpath))?.first,
              let s = n.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// Lightweight single-attribute lookup for tiny docs (container.xml) where a
    /// full XMLDocument parse is overkill.
    private static func firstAttribute(in xml: String, element: String, attribute: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: xml, options: []),
              let el = (try? doc.nodes(forXPath: "//*[local-name()='\(element)']"))?.first as? XMLElement
        else { return nil }
        return el.attribute(forName: attribute)?.stringValue
    }

    private static func parseNav(_ xml: String, resolve: (String) -> Int?) -> [TOCItem] {
        guard let doc = try? XMLDocument(xmlString: xml, options: [.documentTidyXML]) else { return [] }
        // The toc nav: <nav epub:type="toc"> … <a href>label</a> …
        let anchors = (try? doc.nodes(forXPath: "//*[local-name()='nav']//*[local-name()='a']")) ?? []
        return anchors.compactMap { node in
            guard let el = node as? XMLElement, let href = el.attribute(forName: "href")?.stringValue else { return nil }
            let label = (el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            return TOCItem(label: label, href: href, chapterIndex: resolve(href))
        }
    }

    private static func parseNCX(_ xml: String, resolve: (String) -> Int?) -> [TOCItem] {
        guard let doc = try? XMLDocument(xmlString: xml, options: []) else { return [] }
        let points = (try? doc.nodes(forXPath: "//*[local-name()='navPoint']")) ?? []
        return points.compactMap { node in
            guard let el = node as? XMLElement,
                  let label = (try? el.nodes(forXPath: ".//*[local-name()='text']"))?.first?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                  let content = (try? el.nodes(forXPath: ".//*[local-name()='content']"))?.first as? XMLElement,
                  let href = content.attribute(forName: "src")?.stringValue
            else { return nil }
            return TOCItem(label: label, href: href, chapterIndex: resolve(href))
        }
    }
}
