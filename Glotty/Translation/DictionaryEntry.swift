import Foundation
import CoreServices
import Darwin
import NaturalLanguage

// `DCSGetActiveDictionaries` is exported from CoreServices but not declared in any
// public Swift overlay. We bind it via `dlsym` so we can enumerate the user's enabled
// dictionaries and query them one-by-one — that's how we separate the monolingual
// (English) entry from the bilingual (English↔Chinese) one for the same word. Apple
// is unlikely to break this symbol; if they do, multi-dict lookup degrades silently
// to the public single-dict path.
//
// MAS build (`#if MAS`) deliberately omits these `dlsym` bindings: `DCSGetActiveDictionaries`
// is a private symbol and trips App Review static analysis (Guideline 2.5.1). The
// sandbox/App Store variant uses only the public `DCSCopyTextDefinition` single-lookup
// path (see `entry(for:)` / `allSourcedEntries`), losing the per-dict monolingual ↔
// bilingual split but keeping definition lookup working.
#if !MAS
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
#endif

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
        /// Authoritative kind from the macOS asset catalog, if known. nil = the
        /// classifier should fall back to language-count or keyword heuristics.
        let metadataKind: DictionarySelection.DictionaryKind?
        /// Language codes the dict indexes (e.g. ["en"], ["en", "zh-Hans"]).
        /// Empty if metadata wasn't found.
        let metadataLanguages: [String]

        init(id: String,
             name: String,
             path: String,
             metadataKind: DictionarySelection.DictionaryKind? = nil,
             metadataLanguages: [String] = []) {
            self.id = id
            self.name = name
            self.path = path
            self.metadataKind = metadataKind
            self.metadataLanguages = metadataLanguages
        }
    }

    struct SourcedEntry: Equatable {
        let dictionary: DictionaryInfo
        let entry: DictionaryEntry
    }

    static func availableDictionaries() -> [DictionaryInfo] {
        #if MAS
        // Sandbox/App Store: per-dict enumeration needs the private
        // `DCSGetActiveDictionaries`, which we don't link. No dictionary
        // picker on MAS — lookups go through the combined public path.
        return []
        #else
        guard let getDicts = dynDCSGetActiveDictionaries,
              let dictsUnmanaged = getDicts() else { return [] }
        let dictsArray = retainArray(from: dictsUnmanaged)

        var infos: [DictionaryInfo] = []
        for dict in dictsArray {
            let desc = (dict as AnyObject).debugDescription ?? ""
            guard let info = dictionaryInfo(from: desc) else { continue }
            infos.append(enriched(info))
        }
        // Kick off catalog load for next time if not yet populated. Subsequent
        // calls to availableDictionaries() will return enriched results once the
        // background walk completes.
        DictionaryCatalog.loadIfNeeded()
        return infos
        #endif
    }

    /// Attach metadata from the asset catalog if available — turns a bare
    /// `(id, name, path)` into one that knows its kind + languages.
    private static func enriched(_ info: DictionaryInfo) -> DictionaryInfo {
        guard let meta = DictionaryCatalog.metadata(for: info) else { return info }
        return DictionaryInfo(
            id: info.id,
            name: info.name,
            path: info.path,
            metadataKind: meta.kind,
            metadataLanguages: meta.languages
        )
    }

    static func allEntries(for text: String, selectedIDs: [String] = []) -> [DictionaryEntry] {
        allSourcedEntries(for: text, selectedIDs: selectedIDs).map(\.entry)
    }

    static func allSourcedEntries(for text: String, selectedIDs: [String] = []) -> [SourcedEntry] {
        #if MAS
        // Sandbox/App Store: single combined definition from the active
        // dictionaries via the public `DCSCopyTextDefinition`. No per-dict
        // enumeration (that needs the private `DCSGetActiveDictionaries`), so
        // the monolingual/bilingual split degrades to one merged entry.
        guard let entry = entry(for: text), entry.hasContent else { return [] }
        return [SourcedEntry(
            dictionary: DictionaryInfo(id: "system", name: "Dictionary", path: ""),
            entry: entry)]
        #else
        guard let getDicts = dynDCSGetActiveDictionaries,
              let copyDef = dynDCSCopyTextDefinition,
              let dictsUnmanaged = getDicts() else { return [] }
        let dictsArray = retainArray(from: dictsUnmanaged)

        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))

        var activeDictionaries: [(dict: CFTypeRef, info: DictionaryInfo)] = []
        for dict in dictsArray {
            let desc = (dict as AnyObject).debugDescription ?? ""
            guard let info = dictionaryInfo(from: desc) else { continue }
            activeDictionaries.append((dict, info))
        }

        let orderedDictionaries: [(dict: CFTypeRef, info: DictionaryInfo)]
        if selectedIDs.isEmpty {
            orderedDictionaries = activeDictionaries
        } else {
            let byID = Dictionary(uniqueKeysWithValues: activeDictionaries.map { ($0.info.id, $0) })
            orderedDictionaries = selectedIDs.compactMap { byID[$0] }
        }

        var entries: [SourcedEntry] = []
        var seenRaw = Set<String>()

        for item in orderedDictionaries {
            guard let defUnmanaged = copyDef(item.dict, cfText, range) else { continue }
            let raw = defUnmanaged.takeRetainedValue() as String
            guard seenRaw.insert(raw).inserted else { continue }
            let entry = parseEntry(raw)
            if entry.hasContent {
                entries.append(SourcedEntry(dictionary: item.info, entry: entry))
            }
        }
        return entries
        #endif
    }

    private static func retainArray(from unmanaged: Unmanaged<CFArray>) -> [CFTypeRef] {
        unmanaged.takeUnretainedValue() as [CFTypeRef]
    }

    private static func dictionaryInfo(from description: String) -> DictionaryInfo? {
        guard let range = description.range(of: "URL = ", options: .backwards) else { return nil }
        let rawReference = String(description[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "}"))

        if let url = URL(string: rawReference),
           url.isFileURL,
           url.pathExtension == "dictionary" || url.pathExtension == "wikipediadictionary" {
            return dictionaryInfo(for: url)
        }

        let name = rawReference
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return DictionaryInfo(id: name, name: name, path: name)
    }

    private static func dictionaryInfo(for url: URL) -> DictionaryInfo {
        let rawName = url.pathComponents.last?
            .replacingOccurrences(of: ".dictionary", with: "")
            .replacingOccurrences(of: "%20", with: " ")
            .replacingOccurrences(of: "%27", with: "'")
            ?? url.lastPathComponent
        return DictionaryInfo(id: url.path, name: rawName, path: url.path)
    }

    static func sourceAndTarget(for text: String, selectedIDs: [String] = []) -> (source: DictionaryEntry?, target: DictionaryEntry?) {
        let sourced = sourceAndTargetSourced(for: text, selectedIDs: selectedIDs)
        let source = sourced.source?.entry
        let target = sourced.target?.entry
        return (source, target)
    }

    static func sourceAndTargetSourced(for text: String,
                                       selectedIDs: [String] = []) -> (source: SourcedEntry?, target: SourcedEntry?) {
        let entries = allSourcedEntries(for: text, selectedIDs: selectedIDs)
        let source = entries.first { !$0.entry.hasBilingualContent }
        let target = entries.first { $0.entry.hasBilingualContent }
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

enum DictionarySelection {
    enum DictionaryKind {
        case bilingual
        case monolingual

        var label: String {
            switch self {
            case .bilingual: return "Bilingual"
            case .monolingual: return "Monolingual"
            }
        }
    }

    /// Per-pair selection: one ordered priority list per dictionary kind. Splitting
    /// these means the popup's "Source language" region picks from `monolingual` and
    /// the "Bilingual" region picks from `bilingual` — neither can poach the other's
    /// slot, and each kind keeps its own user-defined priority.
    private struct PerKindIDs: Codable, Equatable {
        var monolingual: [String]
        var bilingual: [String]

        init(monolingual: [String] = [], bilingual: [String] = []) {
            self.monolingual = monolingual
            self.bilingual = bilingual
        }
    }

    private struct StoredSelections: Codable {
        var byPair: [String: PerKindIDs]

        init(byPair: [String: PerKindIDs] = [:]) {
            self.byPair = byPair
        }
    }

    private static let defaultsKey = "glotty.dictionarySelectionsByPairAndKind"
    /// Legacy unified-list key. Read once for migration; the new key takes over after
    /// the first save in the new format.
    private static let legacyDefaultsKey = "glotty.dictionarySelectionsByPair"
    private static let noDictionarySelectedID = "__glotty_no_dictionary_selected__"

    /// User-set kind overrides, keyed by dict ID. Beats every other signal — if
    /// the user said "this is bilingual", that's final.
    private static let kindOverridesKey = "glotty.dictionaryKindOverrides"

    static func kindOverride(for dictID: String) -> DictionaryKind? {
        guard let map = UserDefaults.standard.dictionary(forKey: kindOverridesKey) as? [String: String],
              let raw = map[dictID] else { return nil }
        switch raw {
        case "monolingual": return .monolingual
        case "bilingual":   return .bilingual
        default:            return nil
        }
    }

    static func setKindOverride(_ kind: DictionaryKind?, for dictID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: kindOverridesKey) as? [String: String]) ?? [:]
        switch kind {
        case .some(.monolingual): map[dictID] = "monolingual"
        case .some(.bilingual):   map[dictID] = "bilingual"
        case .none:               map.removeValue(forKey: dictID)
        }
        UserDefaults.standard.set(map, forKey: kindOverridesKey)
    }

    /// Classify a dict, in this priority order:
    ///   1. User override (Settings → Dictionaries per-dict menu)
    ///   2. Asset-catalog metadata (`DictionaryType` from Apple's manifest)
    ///   3. Language-count heuristic (2+ indexed languages → bilingual)
    ///   4. Keyword heuristic on the dict name (legacy fallback)
    static func dictionaryKind(for dict: DictionaryLookup.DictionaryInfo) -> DictionaryKind {
        if let override = kindOverride(for: dict.id) { return override }
        if let metaKind = dict.metadataKind { return metaKind }
        if dict.metadataLanguages.count >= 2 { return .bilingual }
        if dict.metadataLanguages.count == 1 { return .monolingual }
        return keywordHeuristicKind(for: dict)
    }

    /// Last-resort keyword heuristic — only used when no metadata is available
    /// (rare; only third-party dicts without proper manifests). Hardcoded to
    /// English keywords; the metadata-first path covers everything else.
    private static func keywordHeuristicKind(for dict: DictionaryLookup.DictionaryInfo) -> DictionaryKind {
        let lowered = "\(dict.name) \(dict.path)".lowercased()
        if lowered.contains("bilingual") || lowered.contains("translation") {
            return .bilingual
        }
        let languageTerms = [
            "arabic", "chinese", "dutch", "english", "french", "german", "hindi",
            "italian", "japanese", "korean", "portuguese", "russian", "spanish",
            "thai", "vietnamese",
        ]
        let hits = languageTerms.filter { lowered.contains($0) }
        return hits.count >= 2 ? .bilingual : .monolingual
    }

    static func effectiveLanguages(sourcePreference: String,
                                   targetPreference: String,
                                   detectedSource: NLLanguage? = nil) -> (source: String, target: String) {
        let source = sourcePreference.isEmpty
            ? (detectedSource?.rawValue ?? "en")
            : sourcePreference
        let target = targetPreference.isEmpty
            ? LanguagePolicy.preferredTarget(for: NLLanguage(rawValue: source))
            : targetPreference
        return (normalizedLanguageCode(source), normalizedLanguageCode(target))
    }

    /// IDs for a specific kind (monolingual or bilingual), in the user's configured
    /// priority order. Falls back to auto-detected dicts of that kind if no override.
    static func selectedIDs(kind: DictionaryKind,
                            sourcePreference: String,
                            targetPreference: String,
                            detectedSource: NLLanguage? = nil,
                            availableDictionaries: [DictionaryLookup.DictionaryInfo]) -> [String] {
        let pair = effectiveLanguages(
            sourcePreference: sourcePreference,
            targetPreference: targetPreference,
            detectedSource: detectedSource
        )
        if let configured = configuredIDs(kind: kind, source: pair.source, target: pair.target) {
            return configured.isEmpty ? [noDictionarySelectedID] : configured
        }
        // No user config yet — default to all language-matching dicts of this kind.
        return matchingDictionaries(
            source: pair.source,
            target: pair.target,
            dictionaries: availableDictionaries
        )
        .filter { dictionaryKind(for: $0) == kind }
        .map(\.id)
    }

    /// Ordered list of dicts of a given kind, applying the user's saved priority
    /// over the language-matching set. Dicts not in the saved order are appended.
    static func orderedDictionaries(kind: DictionaryKind,
                                    source: String,
                                    target: String,
                                    dictionaries: [DictionaryLookup.DictionaryInfo]) -> [DictionaryLookup.DictionaryInfo] {
        let matching = matchingDictionaries(source: source, target: target, dictionaries: dictionaries)
            .filter { dictionaryKind(for: $0) == kind }
        guard let configured = configuredIDs(kind: kind, source: source, target: target) else {
            return matching
        }

        let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
        var ordered = configured.compactMap { byID[$0] }
        let configuredSet = Set(configured)
        ordered.append(contentsOf: matching.filter { !configuredSet.contains($0.id) })
        return ordered
    }

    static func configuredIDs(kind: DictionaryKind, source: String, target: String) -> [String]? {
        let selections = storedSelections()
        let key = pairKey(source: source, target: target)
        let pair = selections.byPair[key]
        switch kind {
        case .monolingual: return pair?.monolingual
        case .bilingual:   return pair?.bilingual
        }
    }

    static func saveSelectedIDs(_ ids: [String],
                                kind: DictionaryKind,
                                source: String,
                                target: String) {
        var selections = storedSelections()
        let key = pairKey(source: source, target: target)
        var pair = selections.byPair[key] ?? PerKindIDs()
        switch kind {
        case .monolingual: pair.monolingual = ids
        case .bilingual:   pair.bilingual = ids
        }
        selections.byPair[key] = pair
        saveSelections(selections)
    }

    static func resetSelection(kind: DictionaryKind, source: String, target: String) {
        var selections = storedSelections()
        let key = pairKey(source: source, target: target)
        guard var pair = selections.byPair[key] else { return }
        switch kind {
        case .monolingual: pair.monolingual = []
        case .bilingual:   pair.bilingual = []
        }
        if pair.monolingual.isEmpty && pair.bilingual.isEmpty {
            selections.byPair.removeValue(forKey: key)
        } else {
            selections.byPair[key] = pair
        }
        saveSelections(selections)
    }

    static func matchingDictionaries(source: String,
                                     target: String,
                                     dictionaries: [DictionaryLookup.DictionaryInfo]) -> [DictionaryLookup.DictionaryInfo] {
        let filters = dictionaryLanguageFilters(source: source, target: target)
        guard !filters.isEmpty else { return dictionaries }
        return dictionaries.filter { dict in
            let haystack = "\(dict.name) \(dict.path)".lowercased()
            switch dictionaryKind(for: dict) {
            case .bilingual:
                return filters.count >= 2 && filters.allSatisfy { matches(filter: $0, in: haystack) }
            case .monolingual:
                return filters.contains { matches(filter: $0, in: haystack) }
            }
        }
    }

    static func pairKey(source: String, target: String) -> String {
        "\(normalizedLanguageCode(source))|\(normalizedLanguageCode(target))"
    }

    private static func dictionaryLanguageFilters(source: String, target: String) -> [[String]] {
        let ids = [source, target]
        var seen = Set<String>()
        return ids.compactMap { id in
            let normalized = normalizedLanguageCode(id)
            guard seen.insert(normalized).inserted else { return nil }
            return languageKeywords(for: normalized)
        }
    }

    private static func matches(filter: [String], in haystack: String) -> Bool {
        filter.contains { haystack.contains($0) }
    }

    private static func normalizedLanguageCode(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }

    private static func languageKeywords(for languageCode: String) -> [String] {
        switch languageCode {
        case "ar": return ["arabic"]
        case "de": return ["german"]
        case "en": return ["english", "american", "british", "oxford"]
        case "es": return ["spanish"]
        case "fr": return ["french"]
        case "hi": return ["hindi"]
        case "it": return ["italian"]
        case "ja": return ["japanese"]
        case "ko": return ["korean"]
        case "nl": return ["dutch"]
        case "pt": return ["portuguese"]
        case "ru": return ["russian"]
        case "th": return ["thai"]
        case "vi": return ["vietnamese"]
        case "yue": return ["cantonese", "chinese"]
        case "zh": return ["chinese", "mandarin", "cantonese", "simplified", "traditional"]
        default:
            if let name = Locale(identifier: "en_US").localizedString(forLanguageCode: languageCode)?.lowercased() {
                return [name]
            }
            return [languageCode.lowercased()]
        }
    }

    private static func storedSelections() -> StoredSelections {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let selections = try? JSONDecoder().decode(StoredSelections.self, from: data) else {
            return StoredSelections(byPair: [:])
        }
        return selections
    }

    private static func saveSelections(_ selections: StoredSelections) {
        guard let data = try? JSONEncoder().encode(selections) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
