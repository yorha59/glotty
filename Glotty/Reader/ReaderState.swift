import SwiftUI

/// Observable state for the EPUB reader window: the open book, current chapter,
/// type settings, and the per-book set of looked-up words (underlined in the
/// text). Reading progress, font, theme, and looked-up words persist across
/// launches — font/theme globally, progress + looked-up words per book id.
@MainActor
final class ReaderState: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case light, sepia, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light: return String(localized: "Light")
            case .sepia: return String(localized: "Sepia")
            case .dark:  return String(localized: "Dark")
            }
        }
    }

    enum ReaderFont: String, CaseIterable, Identifiable {
        case bookDefault, system, newYork, georgia, palatino, charter, times, helvetica
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bookDefault: return String(localized: "Book Default")
            case .system:      return String(localized: "System")
            case .newYork:     return "New York"
            case .georgia:     return "Georgia"
            case .palatino:    return "Palatino"
            case .charter:     return "Charter"
            case .times:       return "Times"
            case .helvetica:   return "Helvetica"
            }
        }
        /// CSS font-family stack, or nil to keep the book's own font.
        var css: String? {
            switch self {
            case .bookDefault: return nil
            case .system:      return "-apple-system, system-ui, sans-serif"
            case .newYork:     return "'New York', ui-serif, Georgia, serif"
            case .georgia:     return "Georgia, 'Times New Roman', serif"
            case .palatino:    return "'Palatino', 'Palatino Linotype', 'Book Antiqua', serif"
            case .charter:     return "'Charter', Georgia, serif"
            case .times:       return "'Times New Roman', Times, serif"
            case .helvetica:   return "'Helvetica Neue', Helvetica, Arial, sans-serif"
            }
        }
    }

    @Published private(set) var book: EPUBBook?
    @Published var chapterIndex: Int = 0 { didSet { saveProgress() } }
    @Published var openError: String?

    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: Self.fontKey) }
    }
    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var font: ReaderFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Self.fontFamilyKey) }
    }
    @Published private(set) var lookedUp: Set<String> = []

    private static let fontKey = "glotty.reader.fontScale"
    private static let themeKey = "glotty.reader.theme"
    private static let fontFamilyKey = "glotty.reader.fontFamily"

    init() {
        let f = UserDefaults.standard.double(forKey: Self.fontKey)
        fontScale = f > 0 ? f : 1.0
        theme = Theme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .light
        font = ReaderFont(rawValue: UserDefaults.standard.string(forKey: Self.fontFamilyKey) ?? "") ?? .bookDefault
    }

    func open(_ url: URL) {
        do {
            let b = try EPUBBook.open(url)
            book = b
            openError = nil
            lookedUp = Self.loadWords(b.identifier)
            chapterIndex = min(max(0, UserDefaults.standard.integer(forKey: Self.progressKey(b.identifier))),
                               b.chapters.count - 1)
        } catch {
            book = nil
            openError = String(format: String(localized: "Couldn't open this book: %@"),
                               String(describing: error))
        }
    }

    var chapterCount: Int { book?.chapters.count ?? 0 }
    func goto(_ index: Int) {
        guard let b = book, b.chapters.indices.contains(index) else { return }
        chapterIndex = index
    }
    func next() { goto(chapterIndex + 1) }
    func prev() { goto(chapterIndex - 1) }
    func adjustFont(_ delta: Double) {
        fontScale = min(2.5, max(0.7, (fontScale + delta * 100).rounded() / 100))
    }

    /// Record a looked-up word (lowercased) so it gets underlined; persists.
    func markLookedUp(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, let b = book else { return }
        guard !lookedUp.contains(w) else { return }
        lookedUp.insert(w)
        UserDefaults.standard.set(Array(lookedUp), forKey: Self.wordsKey(b.identifier))
    }

    // MARK: - Persistence keys

    private static func progressKey(_ id: String) -> String { "glotty.reader.progress.\(id)" }
    private static func wordsKey(_ id: String) -> String { "glotty.reader.words.\(id)" }
    private static func loadWords(_ id: String) -> Set<String> {
        Set((UserDefaults.standard.array(forKey: wordsKey(id)) as? [String]) ?? [])
    }
    private func saveProgress() {
        guard let b = book else { return }
        UserDefaults.standard.set(chapterIndex, forKey: Self.progressKey(b.identifier))
    }
}
