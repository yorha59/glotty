import Foundation
import Compression

/// Minimal read-only ZIP reader for EPUB files. EPUB is a ZIP of XHTML/CSS/
/// images, so we only need to enumerate entries and extract them — no writing,
/// no ZIP64, no encryption. Self-contained (no SPM dependency) and sandbox-safe
/// (pure `Compression` framework, no shelling out to `unzip`). Handles the only
/// two storage methods EPUBs use: stored (0) and raw DEFLATE (8).
struct MiniZip {
    struct Entry {
        let name: String
        let method: Int
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.bytes = [UInt8](d)
        guard let e = Self.centralDirectory(bytes) else { return nil }
        self.entries = e
    }

    /// Decompressed bytes for `name`, or nil if missing / an unsupported method.
    func data(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let lo = e.localOffset
        // Local file header is 30 bytes + filename + extra; the actual data
        // follows. The central-directory name/extra lengths can differ from the
        // local header's, so re-read them here.
        guard bytes.count >= lo + 30, Self.u32(bytes, lo) == 0x04034b50 else { return nil }
        let start = lo + 30 + Self.u16(bytes, lo + 26) + Self.u16(bytes, lo + 28)
        guard bytes.count >= start + e.compSize else { return nil }
        let comp = Array(bytes[start..<(start + e.compSize)])
        switch e.method {
        case 0: return Data(comp)
        case 8: return Self.inflate(comp, expected: e.uncompSize)
        default: return nil
        }
    }

    func string(_ name: String) -> String? {
        data(name).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Internals

    private static func inflate(_ comp: [UInt8], expected: Int) -> Data? {
        if expected == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: expected)
        // ZIP method 8 is *raw* DEFLATE (RFC 1951); Apple's COMPRESSION_ZLIB
        // decodes exactly that (not the RFC-1950 zlib wrapper).
        let n = compression_decode_buffer(&dst, expected, comp, comp.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return nil }
        return Data(dst[0..<n])
    }

    private static func centralDirectory(_ b: [UInt8]) -> [Entry]? {
        guard b.count >= 22 else { return nil }
        // Find the End Of Central Directory record by scanning back from the end
        // (its variable-length comment field is almost always empty).
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65_536)
        while i >= stop {
            if b[i] == 0x50, b[i+1] == 0x4b, b[i+2] == 0x05, b[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(b, eocd + 10)
        var p = u32(b, eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x02014b50 else { break }
            let method = u16(b, p + 10)
            let cs = u32(b, p + 20), us = u32(b, p + 24)
            let nl = u16(b, p + 28), el = u16(b, p + 30), cl = u16(b, p + 32)
            let lo = u32(b, p + 42)
            let name = String(bytes: b[(p + 46)..<(p + 46 + nl)], encoding: .utf8) ?? ""
            if !name.hasSuffix("/") {   // skip directory entries
                out.append(Entry(name: name, method: method, compSize: cs, uncompSize: us, localOffset: lo))
            }
            p += 46 + nl + el + cl
        }
        return out
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o+1]) << 8) }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | (Int(b[o+1]) << 8) | (Int(b[o+2]) << 16) | (Int(b[o+3]) << 24)
    }
}
