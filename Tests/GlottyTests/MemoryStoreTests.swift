import Testing
import Foundation
@testable import Glotty

@Suite("MemoryStore — recording + aggregation")
@MainActor
struct MemoryStoreTests {
    /// Each test gets a fresh store backed by a temp file so the production
    /// Application Support file is never touched.
    private func makeStore() -> (MemoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glotty-mem-\(UUID().uuidString).jsonl")
        // Ensure recording is enabled even if the dev's host UserDefaults
        // has flipped the toggle off — tests should not depend on host state.
        UserDefaults.standard.set(true, forKey: MemoryStore.recordingEnabledKey)
        return (MemoryStore(fileURL: url), url)
    }

    @Test("Round-trip: recorded event appears in cache and on disk")
    func roundTrip() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(
            kind: .translate,
            sourceText: "schedule",
            sourceLang: "en",
            targetLang: "zh-Hans",
            result: "时间表"
        ))

        #expect(store.count == 1)
        #expect(store.allEvents().first?.sourceText == "schedule")

        // Give the write queue a moment, then re-open and verify persistence.
        try await Task.sleep(nanoseconds: 200_000_000)
        let reopened = MemoryStore(fileURL: url)
        #expect(reopened.count == 1)
        #expect(reopened.allEvents().first?.result == "时间表")
    }

    @Test("Empty sourceText is rejected")
    func emptyTextRejected() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(
            kind: .translate,
            sourceText: "   ",
            sourceLang: "en",
            targetLang: "zh-Hans",
            result: nil
        ))
        #expect(store.count == 0)
    }

    @Test("topLookups counts translate + explain, sorts by frequency")
    func topLookupsCounting() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // "schedule" looked up 3 times, "appointment" 2 — interleaved so
        // record()'s adjacent-dedup (which intentionally collapses the
        // SAME lookup repeated back-to-back into one row) doesn't merge
        // the schedule repeats. This is the realistic shape: a user
        // bounces between a few words.
        store.record(MemoryEvent(kind: .translate, sourceText: "schedule",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "时间表"))
        store.record(MemoryEvent(kind: .explain, sourceText: "appointment",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "约会"))
        store.record(MemoryEvent(kind: .translate, sourceText: "schedule",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "时间表"))
        store.record(MemoryEvent(kind: .explain, sourceText: "appointment",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "约会"))
        store.record(MemoryEvent(kind: .translate, sourceText: "schedule",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "时间表"))
        // Polish event — recorded (non-empty result) but must NOT appear
        // in top-lookups, which only counts translate + explain.
        store.record(MemoryEvent(kind: .polish, sourceText: "i wanna",
                                 sourceLang: "en", targetLang: "en", result: "I want to",
                                 issues: [PolishIssueSnapshot(category: "Register/tone")]))

        let lookups = store.topLookups(limit: 10)
        #expect(lookups.count == 2)
        #expect(lookups[0].key == "schedule")
        #expect(lookups[0].count == 3)
        #expect(lookups[1].key == "appointment")
        #expect(lookups[1].count == 2)
    }

    @Test("Case-insensitive aggregation merges 'Hello' and 'hello'")
    func caseInsensitive() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(kind: .translate, sourceText: "Hello",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "你好"))
        store.record(MemoryEvent(kind: .translate, sourceText: "hello",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "你好"))
        store.record(MemoryEvent(kind: .translate, sourceText: "HELLO",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "你好"))

        let lookups = store.topLookups()
        #expect(lookups.count == 1)
        #expect(lookups[0].count == 3)
    }

    @Test("topGrammarIssues counts mistake categories across polish events")
    func topGrammarIssuesCounting() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(kind: .polish, sourceText: "i wanna go",
                                 sourceLang: "en", targetLang: "en", result: "I want to go",
                                 issues: [
                                    PolishIssueSnapshot(category: "Register/tone"),
                                    PolishIssueSnapshot(category: "Capitalization"),
                                 ]))
        store.record(MemoryEvent(kind: .polish, sourceText: "i wanna eat",
                                 sourceLang: "en", targetLang: "en", result: "I want to eat",
                                 issues: [
                                    PolishIssueSnapshot(category: "Register/tone"),
                                 ]))

        let issues = store.topGrammarIssues()
        #expect(issues.count == 2)
        #expect(issues[0].key == "Register/tone")
        #expect(issues[0].count == 2)
        #expect(issues[1].key == "Capitalization")
        #expect(issues[1].count == 1)
    }

    @Test("Issues with no category are skipped (legacy entries don't aggregate)")
    func issuesWithoutCategorySkipped() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(kind: .polish, sourceText: "some draft",
                                 sourceLang: "en", targetLang: "en", result: "some polished draft",
                                 issues: [
                                    PolishIssueSnapshot(category: nil),
                                    PolishIssueSnapshot(category: "Word choice"),
                                 ]))

        let issues = store.topGrammarIssues()
        #expect(issues.count == 1)
        #expect(issues[0].key == "Word choice")
    }

    @Test("Category aggregation is case-insensitive but preserves display form")
    func categoryCaseInsensitive() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // First-seen casing wins the display label.
        store.record(MemoryEvent(kind: .polish, sourceText: "a",
                                 sourceLang: "en", targetLang: "en", result: "A",
                                 issues: [PolishIssueSnapshot(category: "Verb tense")]))
        store.record(MemoryEvent(kind: .polish, sourceText: "b",
                                 sourceLang: "en", targetLang: "en", result: "B",
                                 issues: [PolishIssueSnapshot(category: "verb tense")]))

        let issues = store.topGrammarIssues()
        #expect(issues.count == 1)
        #expect(issues[0].count == 2)
        #expect(issues[0].key == "Verb tense")  // first-seen casing
    }

    @Test("Recording disabled: record() is a no-op")
    func optOutHonored() {
        let (store, url) = makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.set(true, forKey: MemoryStore.recordingEnabledKey)
        }
        store.isRecordingEnabled = false
        store.record(MemoryEvent(kind: .translate, sourceText: "test",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "测试"))
        #expect(store.count == 0)
    }

    @Test("topLookups respects `since` cutoff — older events filtered out")
    func lookupsSinceFilter() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)

        // `record` drops "unfinished" events (nil/empty result), so each
        // fixture needs a non-empty result to actually be stored — the
        // aggregation below keys off sourceText, not result.
        store.record(MemoryEvent(kind: .translate, sourceText: "recent",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "结果",
                                 timestamp: now))
        store.record(MemoryEvent(kind: .translate, sourceText: "twoDaysOld",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "结果",
                                 timestamp: twoDaysAgo))
        store.record(MemoryEvent(kind: .translate, sourceText: "tenDaysOld",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "结果",
                                 timestamp: tenDaysAgo))

        // 24h cutoff: only "recent" survives.
        let day = MemoryTimeRange.day.since(now: now)
        let day24 = store.topLookups(since: day).map(\.key)
        #expect(day24 == ["recent"])

        // 7d cutoff: recent + twoDaysOld.
        let week = MemoryTimeRange.week.since(now: now)
        let day7 = Set(store.topLookups(since: week).map(\.key))
        #expect(day7 == ["recent", "twodaysold"])  // lowercased

        // All time: every event.
        #expect(store.topLookups(since: nil).count == 3)
    }

    @Test("topGrammarIssues respects `since` cutoff")
    func issuesSinceFilter() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        let oldPolish = now.addingTimeInterval(-40 * 86_400)

        // Non-empty result so `record` keeps the event (see lookups test);
        // topGrammarIssues aggregates off `issues`, not result.
        store.record(MemoryEvent(kind: .polish, sourceText: "recent draft",
                                 sourceLang: "en", targetLang: "en", result: "polished",
                                 issues: [PolishIssueSnapshot(category: "Register/tone")],
                                 timestamp: now))
        store.record(MemoryEvent(kind: .polish, sourceText: "old draft",
                                 sourceLang: "en", targetLang: "en", result: "polished",
                                 issues: [PolishIssueSnapshot(category: "Spelling")],
                                 timestamp: oldPolish))

        let month = MemoryTimeRange.month.since(now: now)
        let recent = store.topGrammarIssues(since: month).map(\.key)
        #expect(recent == ["Register/tone"])

        #expect(store.topGrammarIssues(since: nil).count == 2)
    }

    @Test("MemoryTimeRange.since computes correct cutoff for fixed `now`")
    func timeRangeMath() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = MemoryTimeRange.day.since(now: now)
        #expect(day == now.addingTimeInterval(-86_400))
        let week = MemoryTimeRange.week.since(now: now)
        #expect(week == now.addingTimeInterval(-7 * 86_400))
        let month = MemoryTimeRange.month.since(now: now)
        #expect(month == now.addingTimeInterval(-30 * 86_400))
        #expect(MemoryTimeRange.all.since(now: now) == nil)
    }

    @Test("clearAll wipes cache and file")
    func clearAll() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(MemoryEvent(kind: .translate, sourceText: "x",
                                 sourceLang: "en", targetLang: "zh-Hans", result: "y"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.count == 1)

        store.clearAll()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.count == 0)
        // Re-opening from disk should also be empty (file removed).
        let reopened = MemoryStore(fileURL: url)
        #expect(reopened.count == 0)
    }
}
