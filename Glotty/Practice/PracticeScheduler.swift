import Foundation
import UserNotifications
import AppKit

/// Proactive practice scheduler. Two timers operate independently:
///
/// 1. **Notification timer** — fires at the user-configured cadence
///    (off / hourly / 4h / daily / weekly). On fire it picks N random
///    questions out of `QuizLibrary` and posts a macOS notification with a
///    "Start Practice" action. No LLM call happens here — delivery is
///    instant.
/// 2. **Generation timer** — runs in the background every ~10 minutes,
///    topping off the library when it falls below `QuizLibrary.targetSize`.
///    One LLM call per generated question.
///
/// Separating the two means notifications never wait on the LLM, and the
/// library acts as a buffer that smooths over slow / failed generation
/// without affecting the user-visible cadence.
@MainActor
final class PracticeScheduler: NSObject, ObservableObject {
    static let shared = PracticeScheduler()

    /// UserDefaults keys + defaults. Interval in minutes; 0 == disabled.
    static let intervalKey          = "glotty.practice.intervalMinutes"
    static let questionCountKey     = "glotty.practice.questionCount"
    static let generatorIntervalKey = "glotty.practice.generatorIntervalMinutes"
    static let defaultIntervalMinutes = 0
    static let defaultQuestionCount   = 5
    static let defaultGeneratorIntervalMinutes = 10

    /// Notification category + action identifiers — tied to handlers in
    /// `AppDelegate`'s `UNUserNotificationCenterDelegate` conformance.
    static let notificationCategory  = "glotty.practice.session"
    static let notificationActionStart = "glotty.practice.start"

    /// Published so SwiftUI can show a progress indicator. The library
    /// count itself comes straight from `QuizLibrary.shared.count` — that
    /// type is its own ObservableObject, so views observe it directly
    /// rather than reading a stale mirror here.
    @Published private(set) var isGenerating: Bool = false

    /// Whatever quiz batch the scheduler most recently picked for delivery.
    /// Drained when the popup opens — so each session uses a fresh batch.
    private(set) var pendingBatch: [QuizQuestion] = []

    private var notificationTimer: Timer?
    private var generatorTimer: Timer?
    /// Tracks the in-flight on-demand fill so the user can cancel mid-loop
    /// from Settings. Nil when nothing is running.
    private var fillTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    var intervalMinutes: Int {
        UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
            ?? Self.defaultIntervalMinutes
    }

    var questionCount: Int {
        UserDefaults.standard.object(forKey: Self.questionCountKey) as? Int
            ?? Self.defaultQuestionCount
    }

    /// Configurable background-generator cadence (minutes between top-off
    /// ticks). Settings → Practice exposes a picker.
    var generatorIntervalMinutes: Int {
        UserDefaults.standard.object(forKey: Self.generatorIntervalKey) as? Int
            ?? Self.defaultGeneratorIntervalMinutes
    }

    /// Kick everything off. Safe to call multiple times — invalidates
    /// existing timers first. Settings UI calls this after the user changes
    /// the interval.
    func start() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        generatorTimer?.invalidate()
        generatorTimer = nil

        // Always run the background generator — it's cheap when the library
        // is full (count check returns immediately) and ensures we have a
        // buffer ready the moment the user enables practice.
        startBackgroundGenerator()

        guard intervalMinutes > 0 else { return }
        scheduleNextNotification()
    }

    func stop() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        generatorTimer?.invalidate()
        generatorTimer = nil
    }

    func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        registerNotificationCategory()
    }

    /// Trigger one notification immediately. Used by the "Send a practice
    /// notification now" button in Settings → Practice and by the
    /// notification timer when it fires.
    ///
    /// If the library has fewer than `questionCount` questions ready, we
    /// generate enough on the spot so the user always sees a banner.
    /// Previously this silently returned for empty libraries — looked like
    /// the button was broken.
    func fireSessionNow() async {
        // Make sure there's at least one question to send. Generate
        // synchronously so the test button always produces a visible result.
        if QuizLibrary.shared.count == 0 {
            await generateOneSync()
        }

        let batch = QuizLibrary.shared.pickRandom(count: questionCount)
        guard !batch.isEmpty else {
            // Generation failed (no LLM provider, network error, etc.). Post
            // a fallback notification so the user knows we tried.
            await postFallbackNotification()
            return
        }
        pendingBatch = batch
        await postNotification(forBatchSize: batch.count)
    }

    /// Synchronous single-question generation for the test-button path.
    /// Sets `isGenerating` so the Settings UI can show a progress spinner.
    private func generateOneSync() async {
        isGenerating = true
        defer { isGenerating = false }
        if let q = await generateOneQuestion() {
            QuizLibrary.shared.add(q)
        }
    }

    /// Kick off an on-demand fill, stored as `fillTask` so the user can stop
    /// it via `cancelFill()`. No-op if a fill is already running.
    func startFillLibrary() {
        guard fillTask == nil, !isGenerating else { return }
        fillTask = Task { @MainActor [weak self] in
            await self?.fillLibraryOnDemand()
            self?.fillTask = nil
        }
    }

    /// Stop an in-flight fill. The current LLM call returns nil on cancel
    /// (its stream throws CancellationError, caught downstream), and the
    /// fill loop sees `Task.isCancelled` on the next iteration and exits.
    func cancelFill() {
        fillTask?.cancel()
        fillTask = nil
    }

    /// Fill the library up to `QuizLibrary.targetSize`. Each question is
    /// generated and persisted as it arrives, so the user sees the count
    /// tick up while this runs. No-op when generation is already in flight
    /// (background tick or another fill). Stops early if a generation call
    /// fails (no provider, network error) or if the surrounding Task is
    /// cancelled via `cancelFill()`.
    func fillLibraryOnDemand() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        while QuizLibrary.shared.count < QuizLibrary.targetSize {
            if Task.isCancelled { return }
            guard let q = await generateOneQuestion() else { return }
            QuizLibrary.shared.add(q)
        }
    }

    /// Drain whatever the scheduler has queued. Returns an empty array if no
    /// batch is pending. The popup calls this when it opens.
    func takePendingBatch() -> [QuizQuestion] {
        let batch = pendingBatch
        pendingBatch = []
        return batch
    }

    // MARK: - Notification timer

    private func scheduleNextNotification() {
        let secs = TimeInterval(intervalMinutes * 60)
        notificationTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fireSessionNow()
                self?.scheduleNextNotification()
            }
        }
    }

    private func postNotification(forBatchSize size: Int) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Practice time"
        content.body  = "Quick \(size)-question quiz on your recent mistakes — ready when you are."
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["kind": "practice-session"]

        let request = UNNotificationRequest(
            identifier: "glotty.practice.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func postFallbackNotification() async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Question library is filling"
        content.body  = "Glotty is generating questions in the background — try again in a minute."
        content.sound = .default
        // Tag with a kind so the click handler in AppDelegate still routes
        // this to the popup (which will open and show its empty / generating
        // state — better than a dead-click on an unresponsive banner).
        content.userInfo = ["kind": "practice-empty"]
        let request = UNNotificationRequest(
            identifier: "glotty.practice.empty.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func registerNotificationCategory() {
        let start = UNNotificationAction(
            identifier: Self.notificationActionStart,
            title: "Start Practice",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.notificationCategory,
            actions: [start],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Background generator

    private func startBackgroundGenerator() {
        // Top off immediately on start (e.g. fresh install or app launch).
        Task { @MainActor in await topOffLibrary() }
        // Then periodically at the user-configured cadence.
        let secs = TimeInterval(generatorIntervalMinutes * 60)
        generatorTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.topOffLibrary() }
        }
    }

    /// Generate up to 2 new questions per tick if the library is below
    /// target. Two is a balance: enough to refill quickly after a session,
    /// not so many that a single tick blocks for minutes.
    private func topOffLibrary() async {
        guard !isGenerating else { return }
        let shortfall = QuizLibrary.targetSize - QuizLibrary.shared.count
        guard shortfall > 0 else { return }
        isGenerating = true
        defer { isGenerating = false }

        let toGenerate = min(2, shortfall)
        for _ in 0..<toGenerate {
            if let q = await generateOneQuestion() {
                QuizLibrary.shared.add(q)
            }
        }
    }

    private func generateOneQuestion() async -> QuizQuestion? {
        guard let provider = LLMRegistry.current() else { return nil }
        let categories = MemoryStore.shared.topGrammarIssues(limit: 5).map(\.key)
        let lang = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "en"
        let prompt = QuizPrompt.build(categories: categories, targetLanguage: lang)

        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.practiceGenerate) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return nil
        }
        return QuizPrompt.parse(raw)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
