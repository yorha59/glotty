import Foundation
import CoreGraphics

/// One inline translation anchored under a text selection in a PDF. Persisted
/// per document so the translations reappear on reopen. Bounds are stored as
/// four scalars (CGRect isn't `Codable` on its own) in PDF **page coordinates**
/// (origin bottom-left) so they survive scroll/zoom — the view converts them to
/// screen space at render time.
struct ReaderTranslation: Codable, Identifiable, Equatable {
    var id = UUID()
    let page: Int
    let bx: Double, by: Double, bw: Double, bh: Double
    let source: String
    let translation: String

    var bounds: CGRect { CGRect(x: bx, y: by, width: bw, height: bh) }

    init(page: Int, bounds: CGRect, source: String, translation: String) {
        self.page = page
        self.bx = bounds.minX; self.by = bounds.minY
        self.bw = bounds.width; self.bh = bounds.height
        self.source = source
        self.translation = translation
    }
}

/// UserDefaults-backed store, keyed by the PDF's filename (mirrors how reading
/// progress and marks are keyed).
enum ReaderTranslationStore {
    private static func key(_ url: URL) -> String {
        "glotty.reader.pdftrans.\(url.lastPathComponent)"
    }

    static func load(_ url: URL) -> [ReaderTranslation] {
        guard let data = UserDefaults.standard.data(forKey: key(url)),
              let items = try? JSONDecoder().decode([ReaderTranslation].self, from: data)
        else { return [] }
        return items
    }

    static func save(_ items: [ReaderTranslation], for url: URL) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key(url))
    }
}
