import Testing
import Foundation
@testable import Glotty

@Suite("DictionarySelection.dictionaryKind — classification priority")
struct DictionaryKindClassifierTests {
    // Each test uses a unique dict id so override state doesn't bleed between
    // tests. Reset after each just in case.
    private static func clearOverride(_ id: String) {
        DictionarySelection.setKindOverride(nil, for: id)
    }

    @Test("Metadata kind beats name heuristic")
    func metadataBeatsHeuristic() {
        // Name heuristic alone ("english" appears once) would say monolingual.
        // But metadata explicitly says bilingual — metadata wins.
        let info = DictionaryLookup.DictionaryInfo(
            id: "test.metadata-wins",
            name: "Some English Reference",
            path: "/Library/Dictionaries/Some.dictionary",
            metadataKind: .bilingual,
            metadataLanguages: ["en", "zh-Hans"]
        )
        #expect(DictionarySelection.dictionaryKind(for: info) == .bilingual)
    }

    @Test("Two indexed languages → bilingual when metadata kind is absent")
    func twoLanguagesImpliesBilingual() {
        let info = DictionaryLookup.DictionaryInfo(
            id: "test.two-langs",
            name: "现代汉语词典",
            path: "/Library/Dictionaries/x.dictionary",
            metadataKind: nil,
            metadataLanguages: ["en", "zh-Hans"]
        )
        #expect(DictionarySelection.dictionaryKind(for: info) == .bilingual)
    }

    @Test("One indexed language → monolingual when metadata kind is absent")
    func oneLanguageImpliesMonolingual() {
        let info = DictionaryLookup.DictionaryInfo(
            id: "test.one-lang",
            name: "Spanish-Sounding Name English Stuff",  // would trip the heuristic
            path: "/x.dictionary",
            metadataKind: nil,
            metadataLanguages: ["es"]
        )
        // Language metadata says one language → monolingual, even though the
        // keyword heuristic might disagree.
        #expect(DictionarySelection.dictionaryKind(for: info) == .monolingual)
    }

    @Test("No metadata + ambiguous name → falls back to keyword heuristic")
    func keywordFallback() {
        let info = DictionaryLookup.DictionaryInfo(
            id: "test.keyword-fallback",
            name: "Chinese English Translator",
            path: "/x.dictionary",
            metadataKind: nil,
            metadataLanguages: []
        )
        // Two language keywords → bilingual per heuristic.
        #expect(DictionarySelection.dictionaryKind(for: info) == .bilingual)
    }

    @Test("No metadata + single-language name → heuristic says monolingual")
    func keywordFallbackMonolingual() {
        let info = DictionaryLookup.DictionaryInfo(
            id: "test.kw-mono",
            name: "Oxford American Writer's Thesaurus",
            path: "/x.dictionary"
        )
        #expect(DictionarySelection.dictionaryKind(for: info) == .monolingual)
    }

    @Test("User override beats all other signals")
    func overrideBeatsMetadata() {
        let id = "test.override-beats"
        DictionarySelection.setKindOverride(.monolingual, for: id)
        defer { Self.clearOverride(id) }

        let info = DictionaryLookup.DictionaryInfo(
            id: id,
            name: "Bilingual Translation Helper",
            path: "/x.dictionary",
            metadataKind: .bilingual,                // metadata says bilingual
            metadataLanguages: ["en", "fr"]          // languages say bilingual
        )
        // Override says monolingual. Override wins.
        #expect(DictionarySelection.dictionaryKind(for: info) == .monolingual)
    }

    @Test("Clearing override restores metadata-driven classification")
    func clearOverrideRestoresMetadata() {
        let id = "test.clear-restore"
        DictionarySelection.setKindOverride(.bilingual, for: id)
        let info = DictionaryLookup.DictionaryInfo(
            id: id, name: "X", path: "/x.dictionary",
            metadataKind: .monolingual, metadataLanguages: ["en"]
        )
        #expect(DictionarySelection.dictionaryKind(for: info) == .bilingual)
        DictionarySelection.setKindOverride(nil, for: id)
        #expect(DictionarySelection.dictionaryKind(for: info) == .monolingual)
    }

    @Test("Override persists across calls until cleared")
    func overridePersists() {
        let id = "test.persists"
        defer { Self.clearOverride(id) }
        DictionarySelection.setKindOverride(.bilingual, for: id)
        #expect(DictionarySelection.kindOverride(for: id) == .bilingual)
        // Round-trip through a second read.
        #expect(DictionarySelection.kindOverride(for: id) == .bilingual)
    }
}
