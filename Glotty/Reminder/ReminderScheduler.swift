import Foundation
import UserNotifications
import AppKit

/// Proactive chat-reminder scheduler. Posts a "Time to chat with Glotty"
/// notification at the user-configured cadence (off / hourly / 4h /
/// daily / weekly). The notification's Start action opens the
/// conversational chat popup (the same Fn → C surface).
@MainActor
final class ReminderScheduler: NSObject, ObservableObject {
    static let shared = ReminderScheduler()

    /// UserDefaults key + default. Interval in minutes; 0 == disabled.
    static let intervalKey            = "glotty.reminder.intervalMinutes"
    static let defaultIntervalMinutes = 0

    /// Notification category + action identifiers — tied to handlers in
    /// `AppDelegate`'s `UNUserNotificationCenterDelegate` conformance.
    static let notificationCategory    = "glotty.reminder.session"
    static let notificationActionStart = "glotty.reminder.start"

    private var notificationTimer: Timer?

    private override init() { super.init() }

    var intervalMinutes: Int {
        UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
            ?? Self.defaultIntervalMinutes
    }

    /// Kick the timer. Safe to call multiple times — invalidates any
    /// existing timer first. Settings UI calls this after the user
    /// changes the interval.
    func start() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        guard intervalMinutes > 0 else { return }
        scheduleNextNotification()
    }

    func stop() {
        notificationTimer?.invalidate()
        notificationTimer = nil
    }

    func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        registerNotificationCategory()
    }

    /// Post one reminder banner immediately. Used by the "Send a
    /// reminder now" button in Settings → Chat as a test path,
    /// and by the notification timer when it fires on schedule.
    func fireSessionNow() async {
        await postNotification()
    }

    // MARK: - Notification timer

    /// Latest "reference instant" the scheduler waits one full
    /// interval after. Bumped to `now` whenever:
    ///   - a notification is successfully posted (next nudge waits
    ///     a full interval from then),
    ///   - a fire is skipped because the chat is open (pretend
    ///     activity just happened so the next try also waits a full
    ///     interval, instead of busy-spinning while the user sits
    ///     idle inside an open chat).
    /// `ChatStore.lastActivity()` is consulted as a fallback so
    /// real chat activity since app launch also pushes the schedule.
    private var lastReferenceTime: Date?

    private func currentReferenceTime() -> Date {
        let storeActivity = ChatStore.shared.lastActivity()
        switch (lastReferenceTime, storeActivity) {
        case (nil, nil):           return Date()
        case (let r?, nil):        return r
        case (nil, let a?):        return a
        case (let r?, let a?):     return max(r, a)
        }
    }

    /// Schedule the next fire for exactly `intervalMinutes` after the
    /// latest reference instant (real chat activity OR the last
    /// successful/skipped fire). User explicitly asked: "always use
    /// the setting value, wait 1 hour after chat is inactive" — no
    /// short-interval re-check floor.
    private func scheduleNextNotification() {
        let intervalSec = TimeInterval(intervalMinutes * 60)
        let reference = currentReferenceTime()
        let fireAt = reference.addingTimeInterval(intervalSec)
        // 60s minimum prevents the timer firing in the past (which
        // some Timer implementations no-op on). Doesn't compromise
        // "always wait the full interval": this branch only kicks
        // in when `fireAt` already elapsed, which means we're past
        // the desired schedule anyway.
        let delay = max(fireAt.timeIntervalSince(Date()), 60)
        notificationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.tickAndMaybeFire() }
        }
    }

    /// Run once when the timer fires. Re-checks both preconditions
    /// (chat closed, idle long enough) before posting, then re-arms
    /// the timer either way.
    private func tickAndMaybeFire() async {
        defer { scheduleNextNotification() }

        // Precondition 1: user must not be actively chatting.
        // Interrupting a live conversation reads as a bug. Bump
        // the reference so the next attempt waits a full interval
        // — the user is presumably going to keep chatting.
        if PopupController.shared.hasOpenChatPopup() {
            lastReferenceTime = Date()
            return
        }

        // Precondition 2: real idle time must exceed the user's
        // interval setting. Belt-and-suspenders — scheduling
        // already accounts for this; this catches activity that
        // landed between scheduling and firing.
        let intervalSec = TimeInterval(intervalMinutes * 60)
        if let lastActivity = ChatStore.shared.lastActivity(),
           Date().timeIntervalSince(lastActivity) < intervalSec {
            return
        }

        await fireSessionNow()
        lastReferenceTime = Date()
    }

    private func postNotification() async {
        let persona = GlottyPersona.current()
        let hook = await generateHook(persona: persona)

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = persona.name
        content.body  = hook
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["kind": "reminder-session"]

        let request = UNNotificationRequest(
            identifier: "glotty.reminder.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Build the notification body. Asks the LLM for a one-sentence
    /// hook in the user's target language that picks up on something
    /// from their accepted memories (a project, a recurring topic).
    /// Falls back to a friendly generic line if the LLM is unavailable
    /// or returns nothing usable — notifications must always post.
    private func generateHook(persona: GlottyPersona) async -> String {
        let fallback = "I was just thinking about you \u{2014} got a minute to chat?"
        guard let provider = LLMRegistry.current() else { return fallback }
        let rawTarget = UserDefaults.standard.string(forKey: "glotty.polishLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = rawTarget.isEmpty ? "en" : rawTarget
        let targetName = PolishPrompt.englishName(for: target)
        // contextBlock returns "About the user:\n…" — pass through any
        // source text we know the user is likely thinking about. There's
        // none at notification time, so an empty string still pulls in
        // profile-style memories (always-on facts/preferences/projects).
        // The proactive nudge is the Fn+C tutor chat, just scheduler-initiated —
        // so `.chatOnly` memories belong here too.
        let userContext = LearnedMemoryStore.shared.contextBlock(for: "", purpose: .chat)
        // Topics Glotty has already pitched in the last few days. The
        // notification hook needs this filter too — without it the
        // hook gravitates to whatever's most prominent in memory and
        // pitches the same project every day. Same `recentTopics`
        // source the chat-thread prompt uses.
        let recentTopics = ChatStore.shared.recentTopics()
        let recentTopicsBlock: String
        if recentTopics.isEmpty {
            recentTopicsBlock = ""
        } else {
            let bullets = recentTopics.map { "  - \($0)" }.joined(separator: "\n")
            recentTopicsBlock = """

            RECENT TOPICS — these came up in the last week's chats. DO NOT tie the hook to any of them; the user will find it repetitive ("how's that project going?" twice in a row reads as a CRM ping, not a friend). Pick a fresh angle.
            \(bullets)
            """
        }
        let prompt = """
        You are \(persona.name), a \(persona.manner.promptHint) chat partner. Write ONE friendly, casual sentence in \(targetName) inviting the user to open a chat with you — like a text from a friend who wants to catch up.

        Guidelines:
        - One sentence. No greeting like "Hi!" — go straight to the hook.
        - Default to a generic warm opener (weather, time of day, random thought, simple curiosity about their day). Only tie to a known topic if it is NEW (not in the recent-topics list below) AND you have something concrete and fresh to ask — never a generic "how's [project] going" check-in on something you already pitched recently.
        - Do NOT mention that you've been "tracking", "noticing", or "saved notes". Speak like a friend who remembers from a previous conversation.
        - Output ONLY the sentence — no quotes, no preamble, no extra text.

        \(userContext.isEmpty ? "(No prior notes about the user yet.)" : userContext)
        \(recentTopicsBlock)
        """

        var raw = ""
        do {
            try await UsageContext.$mode.withValue(.chat) {
                for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                    raw = chunk
                }
            }
        } catch {
            return fallback
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}\u{2018}\u{2019}"))
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func registerNotificationCategory() {
        let start = UNNotificationAction(
            identifier: Self.notificationActionStart,
            title: "Chat",
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
}
