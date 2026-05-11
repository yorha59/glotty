import Foundation
import CoreServices
import Darwin

// `DCSGetActiveDictionaries` is exported from CoreServices but not declared in any
// public Swift overlay. We bind it via `dlsym` so we can enumerate the user's enabled
// dictionaries and query them one-by-one — that's how we separate the monolingual
// (English) entry from the bilingual (English↔Chinese) one for the same word. Apple
// is unlikely to break this symbol; if they do, multi-dict lookup degrades silently
// to the public single-dict path.
private typealias DCSGetActiveDictionariesFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias DCSCopyTextDefinitionFn = @convention(c) (CFTypeRef?, CFString, CFRange) -> Unmanaged<CFString>?

private let dynDCSGetActiveDictionaries: DCSGetActiveDictionariesFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "DCSGetActiveDictionaries") else { return nil }
    return unsafeBitCast(sym, to: DCSGetActiveDictionariesFn.self)
}()

private let dynDCSCopyTextDefinition: DCSCopyTextDefinitionFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "DCSCopyTextDefinition") else { return nil }
    return unsafeBitCast(sym, to: DCSCopyTextDefinitionFn.self)
}()

/// Structured dictionary entry parsed from `DCSCopyTextDefinition`.
/// Two formats are handled by the parser:
///   1. **Bilingual** (e.g. macOS Chinese-English dict): single line with `A. noun ...`,
///      `B. exclamation ...` POS markers and `①②③` numbered senses.
///   2. **Oxford-style monolingual**: POS labels on their own lines, `1 ` / `2 ` numbers.
struct DictionaryEntry: Equatable {
    let phonetics: [PhoneticEntry]
    let parts: [PartOfSpeechEntry]

    var hasContent: Bool { !parts.isEmpty || !phonetics.isEmpty }

    /// Does the entry contain any non-Latin script (CJK, Cyrillic, Arabic…)?
    /// Used to detect "this is a monolingual English dict entry that overlaps with
    /// what the translation pipeline gives us anyway" — we hide those to keep the
    /// popup focused on the actual translation.
    var hasBilingualContent: Bool {
        for part in parts {
            for def in part.definitions {
                if Self.containsNonLatinScript(def.text) { return true }
                if let ex = def.example, Self.containsNonLatinScript(ex) { return true }
            }
        }
        return false
    }

    private static func containsNonLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Latin script + common punctuation = "same script as English source".
            // Anything outside these ranges (e.g. CJK 0x4E00–0x9FFF) signals a
            // bilingual entry worth showing.
            switch scalar.value {
            case 0x0000...0x024F: return false  // Latin (Basic + Supplement + Extended A/B)
            case 0x1E00...0x1EFF: return false  // Latin Extended Additional
            case 0x2000...0x206F: return false  // General punctuation
            case 0x2070...0x209F: return false  // Super/sub-scripts
            default: return true
            }
        }
    }

    static let empty = DictionaryEntry(phonetics: [], parts: [])
}

struct PartOfSpeechEntry: Equatable, Hashable {
    let label: String
    let definitions: [Definition]
}

struct Definition: Equatable, Hashable {
    let number: Int?
    let text: String
    let example: String?
}

enum DictionaryLookup {
    static let knownPartsOfSpeech: [String] = [
        "noun", "verb", "adjective", "adverb",
        "exclamation", "interjection", "preposition", "conjunction",
        "pronoun", "determiner", "abbreviation", "phrase",
    ]

    static func entry(for text: String) -> DictionaryEntry? {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfText, range) else { return nil }
        let definition = unmanaged.takeRetainedValue() as String
        return parseEntry(definition)
    }

        struct DictionaryInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let path: String
    }

    static func availableDictionaries() -> [DictionaryInfo] {
        guard let getDicts = dynDCSGetActiveDictionaries,
              let dictsUnmanaged = getDicts() else { return [] }
        let dictsArray = dictsArray(from: dictsUnmanaged)

        var infos: [DictionaryInfo] = []
        for dict in dictsArray {
            let desc = (dict as AnyObject).debugDescription ?? ""
            guard let url = extractURL(from: desc),
                  let lastComponent = url.pathComponents.last else { continue }
            let rawName = lastComponent
                .replacingOccurrences(of: ".dictionary", with: "")
                .replacingOccurrences(of: "%20", with: " ")
                .replacingOccurrences(of: "%27", with: "'")
            let id = url.path
            infos.append(DictionaryInfo(id: id, name: rawName, path: url.path))
        }
        return infos
    }

    static func allEntries(for text: String, selectedIDs: [String] = []) -> [DictionaryEntry] {
        guard let getDicts = dynDCSGetActiveDictionaries,
              let copyDef = dynDCSCopyTextDefinition,
              let dictsUnmanaged = getDicts() else { return [] }
        let dictsArray = dictsArray(from: dictsUnmanaged)

        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))

        var entries: [DictionaryEntry] = []
        var seenRaw = Set<String>()

        let idSet = selectedIDs.isEmpty ? nil : Set(selectedIDs)

        for dict in dictsArray {
            if let idSet {
                let desc = (dict as AnyObject).debugDescription ?? ""
                guard let url = extractURL(from: desc),
                      idSet.contains(url.path) else { continue }
            }

            guard let defUnmanaged = copyDef(dict, cfText, range) else { continue }
            let raw = defUnmanaged.takeRetainedValue() as String
            guard seenRaw.insert(raw).inserted else { continue }
            let entry = parseEntry(raw)
            if entry.hasContent {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func dictsArray(from unmanaged: Unmanaged<CFArray>) -> [CFTypeRef] {
        unmanaged.takeUnretainedValue() as [CFTypeRef]
    }

    private static func extractURL(from description: String) -> URL? {
        guard let range = description.range(of: "URL = ", options: .backwards),
              let endRange = description.range(of: ".dictionary/", options: .backwards) else { return nil }
        let urlString = String(description[range.upperBound..<endRange.upperBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "}"))
        return URL(string: urlString)
    }

    static func sourceAndTarget(for text: String, selectedIDs: [String] = []) -> (source: DictionaryEntry?, target: DictionaryEntry?) {
        let entries = allEntries(for: text, selectedIDs: selectedIDs)
        let source = entries.first { !$0.hasBilingualContent }
        let target = entries.first { $0.hasBilingualContent }
        return (source, target)
    }

    static func parseEntry(_ definition: String) -> DictionaryEntry {
        let phonetics = Pronunciation.parseDictionaryDefinition(definition)
        let parts = parseParts(definition)
        return DictionaryEntry(phonetics: phonetics, parts: parts)
    }

    /// Walk the body (everything after the IPA block) split into POS sections, then
    /// split each section into numbered senses.
    static func parseParts(_ definition: String) -> [PartOfSpeechEntry] {
        let body = bodyAfterIPABlock(definition)
        guard !body.isEmpty else { return [] }

        let posMatches = findPOSMatches(in: body)
        if posMatches.isEmpty {
            // No POS markers found — surface the whole body as a single unlabeled section
            // so the user still sees something useful for less-structured dict formats.
            let defs = parseDefinitions(in: body)
            return defs.isEmpty ? [] : [PartOfSpeechEntry(label: "—", definitions: defs)]
        }

        var parts: [PartOfSpeechEntry] = []
        let nsBody = body as NSString
        for (index, match) in posMatches.enumerated() {
            let sectionStart = match.endLocation
            let sectionEnd = index + 1 < posMatches.count
                ? posMatches[index + 1].startLocation
                : nsBody.length
            guard sectionEnd > sectionStart else { continue }
            let sectionText = nsBody
                .substring(with: NSRange(location: sectionStart, length: sectionEnd - sectionStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let defs = parseDefinitions(in: sectionText)
            if !defs.isEmpty {
                parts.append(PartOfSpeechEntry(label: match.label, definitions: defs))
            }
        }
        return parts
    }

    private struct POSMatch {
        let label: String
        let startLocation: Int
        let endLocation: Int
    }

    /// Find each POS keyword in `body`. Recognizes both bare keywords and the
    /// `A. noun` / `B. verb` letter-prefix style used by bilingual dicts.
    private static func findPOSMatches(in body: String) -> [POSMatch] {
        let alternation = knownPartsOfSpeech.joined(separator: "|")
        let pattern = "(?:^|[\\s,;])(?:[A-Z]\\.\\s+)?(\(alternation))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsBody = body as NSString
        let results = regex.matches(in: body,
                                    range: NSRange(location: 0, length: nsBody.length))
        return results.map { r in
            let labelRange = r.range(at: 1)
            let label = nsBody.substring(with: labelRange)
            return POSMatch(
                label: label,
                startLocation: r.range.location,
                endLocation: r.range.location + r.range.length
            )
        }
    }

    private static let circledNumerals = "①②③④⑤⑥⑦⑧⑨⑩"

    /// Parse one POS section into definitions.
    /// Tries circled numerals first (bilingual dict style), falls back to "1 ", "2 "
    /// (Oxford), and finally treats the whole section as a single unnumbered def.
    static func parseDefinitions(in section: String) -> [Definition] {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let defs = splitByCircledNumerals(trimmed), !defs.isEmpty { return defs }
        if let defs = splitByArabicNumerals(trimmed), !defs.isEmpty { return defs }
        return [splitDefinitionAndExample(text: trimmed, number: nil)]
    }

    private static func splitByCircledNumerals(_ section: String) -> [Definition]? {
        guard let regex = try? NSRegularExpression(pattern: "[①②③④⑤⑥⑦⑧⑨⑩]") else {
            return nil
        }
        let nsSection = section as NSString
        let matches = regex.matches(in: section,
                                    range: NSRange(location: 0, length: nsSection.length))
        guard !matches.isEmpty else { return nil }

        var defs: [Definition] = []
        for (index, match) in matches.enumerated() {
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : nsSection.length
            guard textEnd > textStart else { continue }
            let text = nsSection
                .substring(with: NSRange(location: textStart, length: textEnd - textStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let glyph = nsSection.substring(with: match.range)
            let number = circledIndex(of: glyph)
            defs.append(splitDefinitionAndExample(text: text, number: number))
        }
        return defs
    }

    private static func splitByArabicNumerals(_ section: String) -> [Definition]? {
        // Match digit at start of section or after whitespace, followed by space + content.
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(\\d{1,2})\\s") else {
            return nil
        }
        let nsSection = section as NSString
        let matches = regex.matches(in: section,
                                    range: NSRange(location: 0, length: nsSection.length))
        guard !matches.isEmpty else { return nil }

        var defs: [Definition] = []
        for (index, match) in matches.enumerated() {
            let numberRange = match.range(at: 1)
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : nsSection.length
            guard textEnd > textStart else { continue }
            let text = nsSection
                .substring(with: NSRange(location: textStart, length: textEnd - textStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let number = Int(nsSection.substring(with: numberRange))
            defs.append(splitDefinitionAndExample(text: text, number: number))
        }
        return defs
    }

    private static func circledIndex(of glyph: String) -> Int? {
        guard glyph.count == 1, let ch = glyph.first else { return nil }
        if let idx = circledNumerals.firstIndex(of: ch) {
            return circledNumerals.distance(from: circledNumerals.startIndex, to: idx) + 1
        }
        return nil
    }

    /// `gloss : example.` → split on first `:`. No colon → no example.
    /// Pinyin tokens (Latin tokens carrying Mandarin tone marks like `wènhòu`, `nǐ hǎo`)
    /// are stripped from both gloss and example — they're noise next to the Chinese
    /// they annotate.
    static func splitDefinitionAndExample(text: String, number: Int?) -> Definition {
        let cleaned = stripPinyin(text)
        if let colonIdx = cleaned.firstIndex(of: ":") {
            let glossSlice = cleaned[..<colonIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let exampleSlice = cleaned[cleaned.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedExample = exampleSlice.hasSuffix(".")
                ? String(exampleSlice.dropLast())
                : exampleSlice
            return Definition(number: number,
                              text: glossSlice,
                              example: cleanedExample.isEmpty ? nil : cleanedExample)
        }
        return Definition(number: number, text: cleaned, example: nil)
    }

    /// Tone-marked Mandarin vowels that mark a token as pinyin.
    private static let pinyinToneMarks: Set<Character> = [
        "ā", "á", "ǎ", "à",
        "ē", "é", "ě", "è",
        "ī", "í", "ǐ", "ì",
        "ō", "ó", "ǒ", "ò",
        "ū", "ú", "ǔ", "ù",
        "ǖ", "ǘ", "ǚ", "ǜ", "ü",
    ]

    static func stripPinyin(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        var output: [String] = []
        for token in tokens {
            if token.contains(where: { pinyinToneMarks.contains($0) }) {
                // Pinyin token — drop the letters, but preserve trailing punctuation
                // (`;`, `,`, etc.) by re-attaching it to the previous output token.
                let trailing = String(token.reversed().prefix { !$0.isLetter }.reversed())
                if !trailing.isEmpty {
                    if let last = output.last {
                        output[output.count - 1] = last + trailing
                    } else {
                        output.append(trailing)
                    }
                }
            } else {
                output.append(String(token))
            }
        }
        return output
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bodyAfterIPABlock(_ definition: String) -> String {
        guard let first = definition.firstIndex(of: "|") else { return definition }
        let afterFirst = definition.index(after: first)
        guard let second = definition[afterFirst...].firstIndex(of: "|") else { return "" }
        let afterSecond = definition.index(after: second)
        return String(definition[afterSecond...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchPartOfSpeech(_ line: String) -> String? {
        let lowered = line.lowercased()
        for pos in knownPartsOfSpeech {
            if lowered == pos { return pos }
            if lowered.hasPrefix("\(pos) ") || lowered.hasPrefix("\(pos)(") { return pos }
            if lowered.range(of: "^[a-z]\\.\\s+\(pos)\\b", options: .regularExpression) != nil {
                return pos
            }
        }
        return nil
    }
}
