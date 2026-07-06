import SwiftUI
import AppKit

/// Hex ↔ SwiftUI `Color` bridging for the reader's background/text color wells.
/// Colors are persisted as `#rrggbb` strings and injected into the chapter CSS.
extension Color {
    init(readerHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255
        let g = Double((v & 0x00FF00) >> 8) / 255
        let b = Double(v & 0x0000FF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    var readerHex: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
