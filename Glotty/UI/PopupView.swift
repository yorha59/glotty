import SwiftUI
import AppKit
import Translation
import NaturalLanguage
import AVFoundation
import CoreServices

/// Which Fn-leader command produced this popup. The view branches on this:
/// `.translate` runs Apple's Translation framework (decode: foreign → native,
/// one-line gloss, with phonetics + dict sections). `.explain` runs the LLM
/// for a richer prose explanation in the user's native language — same
/// direction as Translate but verbose and contextual instead of terse. The
/// LLM's output is plain text, streamed token-by-token. `.polish` rewrites
/// the user's own draft, also via LLM.
enum PopupMode: Equatable {
    case translate
    case explain
    case polish
    /// Conversational chat with Glotty. No selection needed — the tutor
    /// opens a natural conversation in the user's target language, gently
    /// correcting mistakes inline. Opened via Fn → C or a proactive reminder.
    case chat
}

/// Visual tokens taken from the Figma design (`Popup - Translate` / `Popup - Polish`
/// frames in the Glotty UI Sync file). Each color is **adaptive** — the Figma value
/// drives the light-mode appearance, and system semantic colors drive dark mode so
/// the popup doesn't blast bright surfaces against a dark desktop.
enum PopupTokens {
    // Surfaces — solid in light mode, semantic / material in dark mode.
    static let surface       = Color.adaptive(
        light: Color(hex: 0xF8F8FA),
        dark:  Color(nsColor: NSColor.windowBackgroundColor)
    )
    static let border        = Color.adaptive(
        light: Color(hex: 0xD8D8DD),
        dark:  Color(nsColor: NSColor.separatorColor)
    )
    static let variantTint   = Color.adaptive(
        light: Color(hex: 0xE8F1FF),
        dark:  Color.accentColor.opacity(0.18)
    )
    static let variantSurface = Color.adaptive(
        light: Color.white,
        dark:  Color(nsColor: NSColor.controlBackgroundColor)
    )

    // Text — Figma greys in light, system label colors in dark so contrast is right.
    static let primaryText   = Color.adaptive(
        light: Color(hex: 0x1D1D1F),
        dark:  Color(nsColor: NSColor.labelColor)
    )
    static let secondaryText = Color.adaptive(
        light: Color(hex: 0x6E6E73),
        dark:  Color(nsColor: NSColor.secondaryLabelColor)
    )
    static let tertiaryText  = Color.adaptive(
        light: Color(hex: 0x9A9AA2),
        dark:  Color(nsColor: NSColor.tertiaryLabelColor)
    )
    /// SwiftUI's accent color is already light/dark adaptive — Apple's macOS blue
    /// reads fine on both surfaces, and matches the Figma `#0A84FF` in light mode.
    static let accent        = Color.accentColor

    // Sizing
    static let containerPadding: CGFloat = 14
    /// Extra top padding so content clears the native macOS
    /// traffic-light buttons (close/minimize) overlaid at the top-left
    /// of the hidden-titlebar, full-size-content popup panel.
    static let trafficLightInset: CGFloat = 22
    static let containerRadius: CGFloat = 16
    static let sectionGap: CGFloat = 10
    static let variantCardPadding: CGFloat = 10
    static let variantCardRadius: CGFloat = 8
    /// Fixed content width for the translate / explain popup. The popup
    /// auto-fits its *height* to the content (via
    /// NSHostingController.preferredContentSize), but width is anchored so
    /// layout is predictable and the panel doesn't jitter on async content
    /// arrival.
    static let translateContentWidth: CGFloat = 460
    /// Polish needs a bit more width for the variant cards (full sentences).
    /// Same auto-fit-height behaviour as translate.
    static let polishContentWidth: CGFloat = 560
    /// Chat reuses the wider polish width so the composer's control
    /// row — Modify-settings toggle, Auto-approve toggle, language
    /// picker — fits on one line without wrapping. At translate's
    /// 460pt, all three plus a multi-character language label
    /// pushed the picker onto a second line on first launch.
    static let chatContentWidth: CGFloat = 560
    /// Uniform font size for every non-source-row element in the translate
    /// popup (section labels, dict names, POS labels, glosses, defs, examples,
    /// translation result). Source row stays at its dedicated large size; the
    /// footer keeps its smaller metadata size.
    static let bodySize: CGFloat = 14
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Build a Color that picks `light` vs `dark` based on the runtime appearance
    /// of whatever view it's resolved in. Uses `NSColor`'s dynamic provider under
    /// the hood, so it tracks system appearance changes without needing to plumb
    /// `@Environment(\.colorScheme)` through every consumer.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }
}

/// Pre-baked content used to restore a popup from `MemoryStore` without
/// re-running the LLM. The Memory tab's click-through path constructs one of
/// these from a stored `MemoryEvent` and passes it into `PopupController`.
/// Old entries that pre-date the richer storage schema map to nil here — the
/// popup falls back to a live re-run in that case.
struct PopupReplayPayload: Equatable {
    /// The MemoryEvent's id, propagated so that subsequent writes from the
    /// popup (notably appending chat turns to a polish run) can target the
    /// same row in MemoryStore via `update(_:)` rather than writing a new
    /// event. Nil when the payload doesn't come from MemoryStore.
    let eventID: UUID?
    let sourceLang: String?
    let targetLang: String?
    let content: Content
    /// Polish-only: previously-saved discussion thread for this run.
    let polishChatThread: [PolishChatTurnSnapshot]?

    enum Content: Equatable {
        case translation(translated: String, backTranslated: String?)
        case explanation(text: String)
        case polish(PolishResultSnapshot)
    }

    static func from(_ event: MemoryEvent) -> PopupReplayPayload? {
        switch event.kind {
        case .translate:
            guard let translated = event.result else { return nil }
            return PopupReplayPayload(
                eventID: event.id,
                sourceLang: event.sourceLang,
                targetLang: event.targetLang,
                content: .translation(translated: translated, backTranslated: event.backTranslation),
                polishChatThread: nil
            )
        case .explain:
            guard let text = event.result else { return nil }
            return PopupReplayPayload(
                eventID: event.id,
                sourceLang: event.sourceLang,
                targetLang: event.targetLang,
                content: .explanation(text: text),
                polishChatThread: event.polishChatThread
            )
        case .polish:
            guard let snap = event.polishSnapshot else { return nil }
            return PopupReplayPayload(
                eventID: event.id,
                sourceLang: event.sourceLang,
                targetLang: event.targetLang,
                content: .polish(snap),
                polishChatThread: event.polishChatThread
            )
        }
    }
}

/// One turn in the Polish-mode discussion thread. The user's prompt is a
/// `.user` turn; the streaming LLM reply is an `.assistant` turn whose `text`
/// fills in as chunks arrive.
struct PolishChatTurn: Identifiable, Equatable {
    enum Role: String, Equatable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// Copy-ready phrasings the model chose to surface, rendered as
    /// click-to-copy chips under the bubble. Nil/empty when it offered none.
    var phrases: [String]? = nil
}

struct PopupView: View {
    let sourceText: String
    let mode: PopupMode
    /// When non-nil, the popup is being restored from MemoryStore — every
    /// `.task` and `.translationTask` no-ops and the @State backing the UI
    /// is pre-populated from this payload in `init`.
    let replay: PopupReplayPayload?
    let onClose: () -> Void
    /// True when this popup was opened by a proactive trigger (chat
    /// reminder notification) rather than the user explicitly hitting
    /// Fn → C. The opening tutor turn leans in harder when this is
    /// true — pitches a specific topic instead of a neutral greeting,
    /// since the user didn't come in with a question of their own.
    let proactive: Bool
    /// True when this chat session was launched from the Welcome
    /// window's onboarding handoff step. The chat-mode runs a
    /// scripted setup conversation (asks display name, pronouns,
    /// native lang, polish target) and applies each answer via
    /// `set_setting` tool calls — see `TutorPrompt.build`.
    let onboarding: Bool
    /// Non-empty when this chat is a practice session — the due "re-attempt
    /// the scenario" cards the tutor drills the user on (see PracticeStore).
    let practiceItems: [PracticeItem]
    /// Fired the first time the user expands the polish chat from the
    /// collapsed pill. Lets `PopupController` grow the panel vertically
    /// so the new chat region doesn't squeeze the polish content above.
    /// `nil` skips the auto-grow (e.g. previews, replay paths where the
    /// chat is already expanded on first paint).
    let onChatExpand: (() -> Void)?
    /// Privacy "hide": orders the popup out and leaves a small floating
    /// bubble at the right screen edge; clicking the bubble brings the
    /// popup back. Deliberately NOT native miniaturize — minimizing the
    /// non-activating agent panel loses the IME candidate binding (see
    /// `PopupController.createPanel`). Hide/restore is a plain
    /// `orderOut`/`orderFront`, the same path the popup uses to first
    /// appear, so the IME stays bound. `nil` hides the button (previews).
    let onHide: (() -> Void)?
    /// Re-register hook for post-dismiss memory extraction. PopupView
    /// calls this on every relevant @State change with a freshly-bound
    /// snapshot-capturing closure; PopupController stores the latest
    /// and invokes it from `dismiss(_:)` so we don't depend on
    /// SwiftUI's `.onDisappear` (which doesn't reliably fire when an
    /// NSPanel is closed via `orderOut`).
    let registerExtractionTrigger: ((@escaping () -> Void) -> Void)?
    /// Fired with the popup's desired window *content height* whenever the
    /// intrinsic content changes (first paint + as a response streams in).
    /// PopupController re-fits the window to it to keep all content visible —
    /// until the user drags an edge.
    let onContentResize: ((CGFloat) -> Void)?
    /// Usable content-height cap for the EXACT screen this popup opens on,
    /// supplied by PopupController (which knows the screen before the window
    /// appears). Used as `maxPanelHeight` so the content's height cap and the
    /// window's height cap always come from the same screen — no `NSScreen.main`
    /// guesswork on multi-display setups.
    let maxContentHeight: CGFloat

    init(sourceText: String,
         mode: PopupMode,
         replay: PopupReplayPayload? = nil,
         proactive: Bool = false,
         onboarding: Bool = false,
         practiceItems: [PracticeItem] = [],
         onClose: @escaping () -> Void,
         onChatExpand: (() -> Void)? = nil,
         onHide: (() -> Void)? = nil,
         registerExtractionTrigger: ((@escaping () -> Void) -> Void)? = nil,
         onContentResize: ((CGFloat) -> Void)? = nil,
         maxContentHeight: CGFloat = 760) {
        self.sourceText = sourceText
        self.mode = mode
        self.replay = replay
        self.proactive = proactive
        self.onboarding = onboarding
        self.practiceItems = practiceItems
        self.onClose = onClose
        self.onChatExpand = onChatExpand
        self.onHide = onHide
        self.registerExtractionTrigger = registerExtractionTrigger
        self.onContentResize = onContentResize
        self.maxContentHeight = maxContentHeight

        // Pre-load @State from the replay payload so the popup renders the
        // stored content on first paint. Using `State(initialValue:)` here is
        // safe because this init runs before the view is mounted.
        if let replay {
            if let target = replay.targetLang, !target.isEmpty {
                _targetLang = State(initialValue: target)
            }
            switch replay.content {
            case .translation(let translated, let backTranslated):
                _translated = State(initialValue: translated)
                _backTranslated = State(initialValue: backTranslated ?? "")
                _status = State(initialValue: .ready)
            case .explanation(let text):
                _explainText = State(initialValue: text)
                _explainStatus = State(initialValue: .ready)
                // Restore the discussion thread (shared field with
                // polish — see MemoryEvent.polishChatThread). If the
                // user had a chat about this explanation before, the
                // popup opens with it already expanded.
                if let storedThread = replay.polishChatThread, !storedThread.isEmpty {
                    let restored = storedThread.map {
                        PolishChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text, phrases: $0.phrases)
                    }
                    _polishChatThread = State(initialValue: restored)
                    _polishChatExpanded = State(initialValue: true)
                }
            case .polish(let snap):
                let variants = snap.variants.map {
                    PolishVariant(text: $0.text, backTranslation: $0.backTranslation)
                }
                let issues = snap.issues.map {
                    GrammarIssue(category: $0.category, original: $0.original, explanation: $0.explanation)
                }
                _polishResult = State(initialValue: PolishResult(variants: variants, issues: issues))
                _polishStatus = State(initialValue: .ready)
                if let storedThread = replay.polishChatThread, !storedThread.isEmpty {
                    let restored = storedThread.map {
                        PolishChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text, phrases: $0.phrases)
                    }
                    _polishChatThread = State(initialValue: restored)
                    _polishChatExpanded = State(initialValue: true)
                }
            }
            _polishEventID = State(initialValue: replay.eventID)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var translated: String = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var status: Status = .working
    @State private var backTranslated: String = ""
    @State private var backConfiguration: TranslationSession.Configuration?
    @State private var polishStatus: Status = .working
    @State private var polishResult: PolishResult = .empty
    @State private var polishProviderName: String = ""
    /// Raw LLM output as it streams. Polish output is JSON, which is unreadable
    /// during the early skeleton-only chunks — so we show it as raw text in a
    /// small terminal-style block while streaming, then crossfade to the
    /// parsed variant cards once the stream finishes.
    @State private var polishRawText: String = ""
    @State private var copiedVariantIndex: Int? = nil
    /// Which discussion-chat phrase chip just flashed "copied" (keyed by text).
    @State private var copiedPhrase: String? = nil
    /// Goes true briefly when the user clicks the translate result to copy
    /// it. Drives the green tint + checkmark confirmation in the same way
    /// `copiedVariantIndex` does for polish variants. Auto-resets after
    /// ~1.4s.
    @State private var translationCopied: Bool = false
    /// Explain mode runs the LLM for a prose explanation in the user's native
    /// language. Text streams in chunk-by-chunk and we render it directly — no
    /// JSON shape, no variant cards.
    @State private var explainText: String = ""
    @State private var explainStatus: Status = .working
    @State private var explainProviderName: String = ""
    // MARK: - Chat (conversational session) state
    /// Full session thread — user + tutor turns, oldest first.
    @State private var tutorThread: [TutorTurn] = []
    /// Composing text for the next user message.
    @State private var tutorInput: String = ""
    /// Overall session status. Starts `.working` while we await the
    /// tutor's opening turn; flips `.ready` once the first reply
    /// lands. Each subsequent submit re-uses the same status field.
    @State private var tutorStatus: Status = .working
    /// Bumps on every user submit so `.task(id:)` re-fires and
    /// `runTutorTurn` runs again. Also bumped once on appear to
    /// kick off the opening tutor turn.
    @State private var tutorRunCounter: Int = 0
    /// Set by Stop; the re-fired `runTutorTurn` sees it and returns early.
    @State private var tutorStopRequested = false
    /// User tapped Stop on a tutor reply — shows a neutral Retry banner.
    @State private var tutorStopped = false
    /// Practice session only: the queue of agenda-item indices still to
    /// be drilled, front-first. The app presents the front item's
    /// scenario card (no LLM); the model only judges the attempt. On a
    /// PASS the item is resolved and leaves the queue; on a MISS it's
    /// recycled to the BOTTOM so the session keeps cycling until every
    /// item has been answered correctly. Seeded once when the session opens.
    @State private var practiceQueue: [Int] = []
    /// Practice pause: after a verdict the app stops auto-advancing and
    /// waits on a "Next" button, so the user can ask follow-ups about the
    /// item they just did before the next scenario appears.
    @State private var practiceAwaitingAdvance = false
    @State private var tutorProviderName: String = ""
    /// User-controlled toggle in the chat header. When ON, the
    /// tutor prompt includes the SettingsRegistry capability block
    /// and the LLM is told it may emit `set_setting` tool calls.
    /// When OFF, the block is omitted entirely — pure conversation,
    /// no risk of the model inventing tool calls.
    /// Defaults to false: the agent flavor is opt-in.
    @AppStorage("glotty.chat.allowSettingsChanges")
    private var chatAllowSettingsChanges: Bool = false
    /// When ON, pending tool calls auto-confirm the moment the LLM
    /// emits them — the user doesn't have to tap the Confirm card.
    /// Rejected tool calls (unknown setting, blocked key, invalid
    /// value) still surface as red badges; only `.pending` outcomes
    /// are auto-approved. Persists across sessions. Defaults to OFF
    /// so the user opts into the looser confirmation flow.
    @AppStorage("glotty.chat.autoApproveTools")
    private var chatAutoApproveTools: Bool = false
    /// Per-user chat reply language. Empty string ⇒ fall back to the
    /// polish output language (preserves the original behavior for
    /// users who never touch this picker). Persists across sessions.
    @AppStorage("glotty.chat.tutorLanguage")
    private var chatTutorLanguage: String = ""
    @FocusState private var tutorInputFocused: Bool
    /// Id of today's `DailyChatThread`. Set on first hydrate; reused
    /// as the `sourceEventID` for memory extraction so suggestion
    /// cards filter to this conversation.
    @State private var tutorThreadID: UUID?
    /// True once we've loaded today's thread from `ChatStore` so we
    /// don't re-hydrate (and re-fire an opening LLM call) on every
    /// SwiftUI body recompute.
    @State private var didHydrateChatToday: Bool = false
    /// One-shot guard so a chat opened on a selection seeds that text as the
    /// opening user message exactly once (see the chat `.task`).
    @State private var didSeedSelection: Bool = false
    /// Polish-mode discussion thread. Triggered by the "Discuss" button under
    /// the polish output — the user keeps chatting in the same popup until
    /// they're satisfied. Each Send appends a `.user` turn, then a `.assistant`
    /// turn that the LLM streams into. State persists for the life of the
    /// popup; closing it discards the thread.
    @State private var polishChatThread: [PolishChatTurn] = []
    @State private var polishChatInput: String = ""
    /// Bound to the chat TextField via `.focused(...)`. When the user taps
    /// in, we use the focus transition as our cue to call `NSApp.activate()`
    /// — that's the moment they signal "I want to type" so even if it
    /// triggers a space-swipe out of a source app's full-screen mode, it's
    /// justified UX. Without that activation, the macOS IME server stays
    /// bound to whatever app owns the full-screen space and CJK candidates
    /// never appear in our field.
    @FocusState private var polishChatInputFocused: Bool
    @State private var polishChatStatus: Status = .ready
    /// Set by Stop; the re-fired `runPolishChat` sees it and returns early
    /// instead of starting another reply.
    @State private var polishChatStopRequested = false
    /// User tapped Stop on a chat reply — surfaces a neutral Retry under the
    /// last user turn (distinct from a `.failed` error retry).
    @State private var polishChatStopped = false
    @State private var polishChatExpanded: Bool = false
    /// Bumped after the user accepts/rejects a suggestion card so
    /// SwiftUI re-reads the pending list from `LearnedMemoryStore`.
    /// The store isn't `ObservableObject`, so changes don't propagate
    /// automatically — bumping this is the cheap forced refresh.
    @State private var suggestionsRefreshToken: Int = 0
    /// Per-card scope draft for inline suggestion approval. Keyed by
    /// memory id so each card holds its picker selection
    /// independently. Cleared once the card is actioned.
    @State private var suggestionScopeDrafts: [UUID: MemoryScope] = [:]
    /// True while a background `MemoryExtractor.extract` call is
    /// in-flight for this popup's source event. Drives a "Glotty
    /// is reviewing…" indicator in the discussion area so the user
    /// knows new suggestions may appear soon.
    @State private var isExtractingMemory: Bool = false
    /// Language the assistant should reply in for the polish chat.
    /// Defaults to the polish target language; the header picker lets
    /// the user switch (e.g. to their native language when they need an
    /// explanation in plain Chinese instead of practice-grade English).
    /// Empty string is "not yet initialized" — populated on first task
    /// run since UserDefaults reads aren't safe at struct init time.
    @State private var polishChatLanguage: String = ""
    @State private var polishChatRunCounter: Int = 0
    /// MemoryEvent.id of the polish run this popup represents. Set when the
    /// initial polish call completes (live mode) or in init (replay mode).
    /// Nil until we have a row in MemoryStore to update.
    @State private var polishEventID: UUID?
    /// Retry tick — bumping this re-fires the polish task, used by the
    /// "retry" icon shown on a failed initial polish call.
    @State private var polishRetryCounter: Int = 0
    /// Same idea for explain: bumped by the retry button on a failed
    /// explanation; included in the explain task id so it re-fires.
    @State private var explainRetryCounter: Int = 0
    // Auto-fit measurement: the content column's and footer's intrinsic
    // heights, summed (+ chrome) into the window content height we ask the
    // controller to grow to. See `reportAutoFit()`.
    @State private var measuredContentHeight: CGFloat = 0
    @State private var measuredFooterHeight: CGFloat = 0
    @State private var detectedSource: NLLanguage?
    // Reader "Mark word": true when this lookup came from the EPUB reader (source
    // matches ReaderMark.pending), so the header offers a deliberate Mark button.
    @State private var readerLookup = false
    @State private var readerMarked = false
    @State private var targetLang: String = "en"
    /// All dict entries that returned content, in the user's configured priority
    /// order (Settings → Dictionaries). Each rendered as its own region so the
    /// priority list is visible end-to-end, not just the first source + first target.
    @State private var dictResults: [DictionaryLookup.SourcedEntry] = []
    /// User preference: show every enabled dict that has content for the
    /// selection, vs. show only the top-priority one in each kind.
    /// Toggle lives in Settings → Dictionaries; also registered in
    /// SettingsRegistry so the chat agent can flip it.
    @AppStorage("glotty.dictionary.showAllMatches")
    private var dictShowAll: Bool = true
    @State private var elapsedMs: Int = 0
    private let startedAt = CFAbsoluteTimeGetCurrent()

    enum Status {
        case working
        case ready
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    private var isSingleWord: Bool {
        LanguagePolicy.isSingleWord(sourceText)
    }

    /// Show the Translation section unless source and target are the *same
    /// language* AND the framework returned the input unchanged (e.g. Chinese
    /// sentence translated into Chinese is a no-op). Cross-language pairs like
    /// en→zh or zh→en always render — even if the text happens to match (rare
    /// edge case for single tokens like "OK"), the result is still meaningful
    /// because it crossed a language boundary. `.working` / `.failed` always
    /// render so the spinner / error stays visible.
    private var shouldShowTranslationSection: Bool {
        switch status {
        case .working, .failed:
            return true
        case .ready:
            let tgt = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tgt.isEmpty else { return false }

            // Compare language roots — "zh-Hans" and "zh-Hant" both share root
            // "zh", so a Simplified ↔ Traditional pass that happens to no-op
            // still gets suppressed. Cross-language never suppresses.
            let srcRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
            let tgtRoot = targetLang.split(separator: "-").first.map(String.init)
            let sameLanguage = (srcRoot != nil) && srcRoot == tgtRoot
            guard sameLanguage else { return true }

            let src = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            return tgt != src
        }
    }

    private var sourcePronunciation: [PhoneticEntry] {
        isSingleWord ? Pronunciation.pronounce(sourceText, language: detectedSource) : []
    }

    /// First monolingual (source-language) dict in priority order that returned
    /// content. Classification uses `DictionarySelection.dictionaryKind` (name-based)
    /// not the script-content heuristic — that was misclassifying monolingual English
    /// dicts whose entries happened to contain IPA or typographic glyphs outside the
    /// Latin Unicode ranges.
    /// Monolingual dicts with content, in priority order. Honors
    /// the `dictShowAll` toggle: when off, only the top-priority
    /// dict that returned content is included.
    private var monolingualDictResults: [DictionaryLookup.SourcedEntry] {
        let matches = dictResults.filter {
            $0.entry.hasContent
                && DictionarySelection.dictionaryKind(for: $0.dictionary) == .monolingual
        }
        return dictShowAll ? matches : Array(matches.prefix(1))
    }

    /// Same as above for bilingual dicts.
    private var bilingualDictResults: [DictionaryLookup.SourcedEntry] {
        let matches = dictResults.filter {
            $0.entry.hasContent
                && DictionarySelection.dictionaryKind(for: $0.dictionary) == .bilingual
        }
        return dictShowAll ? matches : Array(matches.prefix(1))
    }

    // Translation phonetics removed per design — translation row stays single-line.

    var body: some View {
        outerLayout
            // Decorative background. Non-hit-tested so clicks fall through
            // to the interactive content. The panel is `.resizable`, so the
            // window's own edges/corners handle drag-to-resize; we must NOT
            // lay a `mouseDownCanMoveWindow` view over the whole popup or it
            // swallows the edge-resize gesture (turning every edge drag into
            // a window move). Background-move is still available via the
            // panel's `isMovableByWindowBackground`.
            .background(containerBackground.allowsHitTesting(false))
            .localizationAware()
            .onAppear { setupConfiguration() }
            .task(id: mode == .polish ? "polish-\(sourceText)-\(polishRetryCounter)" : "") {
                guard mode == .polish, replay == nil else { return }
                await runPolish()
            }
            // Explain calls the LLM for a prose explanation — same direction as
            // Translate (output in user's native language) but verbose and
            // contextual. The id includes targetLang so changing the target via
            // the footer menu re-fires the LLM.
            .task(id: mode == .explain ? "explain-\(sourceText)-\(targetLang)-\(explainRetryCounter)" : "") {
                guard mode == .explain, replay == nil else { return }
                await runExplain()
            }
            // Chat (tutor): hydrate today's thread once on open;
            // fire opening LLM turn only when the day's thread is
            // genuinely empty. Each Send bumps `tutorRunCounter`,
            // re-firing this task to drive the next exchange.
            .task(id: mode == .chat ? "tutor-\(tutorRunCounter)" : "") {
                guard mode == .chat else { return }
                if !didHydrateChatToday {
                    didHydrateChatToday = true
                    // Onboarding chats are ephemeral: they ALWAYS start
                    // from a fresh "Hello" and don't share the daily
                    // thread with normal chats. Skipping hydrate keeps
                    // `tutorThread` empty so `runTutorTurn` fires the
                    // scripted opener; `persistTutorTurn` separately
                    // refuses to write onboarding turns to ChatStore,
                    // so today's real thread stays untouched.
                    // Practice sessions are ephemeral drills — start fresh,
                    // never merge with (or write to) today's saved chat thread.
                    if !onboarding && practiceItems.isEmpty {
                        hydrateTodayChat()
                    }
                }
                // On the very first .task fire (counter == 0) we only
                // produce an opening turn when there's no prior chat
                // for today. Otherwise the user is resuming an
                // existing conversation and we should just show it.
                if tutorRunCounter == 0 {
                    let seed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seed.isEmpty, !didSeedSelection, !onboarding {
                        // Opened on a selection — seed it as the opening user
                        // message so the tutor responds about that text (works
                        // whether or not today's thread already has history).
                        didSeedSelection = true
                        let userTurn = TutorTurn(role: .user, reply: seed)
                        tutorThread.append(userTurn)
                        persistTutorTurn(userTurn)
                        await runTutorTurn()
                    } else if !practiceItems.isEmpty, tutorThread.isEmpty {
                        // Practice opener is purely mechanical — seed the
                        // queue with every agenda item and present the first
                        // scenario (the user's draft + what they meant) as a
                        // card with NO LLM call, then wait for their
                        // re-attempt. The model only enters once the user
                        // replies, to judge it (see TutorPrompt.practicePrompt).
                        practiceQueue = Array(practiceItems.indices)
                        if let front = practiceQueue.first {
                            let item = practiceItems[front]
                            let card = practicePresentation(
                                item, remaining: practiceQueue.count)
                            tutorThread.append(TutorTurn(
                                role: .tutor, reply: card,
                                practice: PracticeCardInfo(
                                    draft: item.draft, meaning: item.meaning,
                                    remaining: practiceQueue.count)))
                        }
                        tutorStatus = .ready
                    } else if tutorThread.isEmpty {
                        await runTutorTurn()
                    } else {
                        tutorStatus = .ready
                    }
                } else {
                    await runTutorTurn()
                }
            }
            // Polish / explain discussion: re-fires on each Send. The
            // thread state lives in `polishChatThread`; this task only
            // kicks off the LLM call. The same chat affordance is
            // available under both polish and explain — `runPolishChat`
            // switches on `mode` to feed the right context.
            .task(id: (mode == .polish || mode == .explain)
                  ? "discuss-chat-\(polishChatRunCounter)"
                  : "") {
                guard mode == .polish || mode == .explain else { return }
                guard polishChatRunCounter > 0 else { return }
                await runPolishChat()
            }
            // Apple Translation only powers decode (`.translate`). Explain and
            // Polish are both LLM-driven (handled by the task modifiers above).
            .translationTask(mode == .translate ? configuration : nil) { session in
                await translate(using: session)
            }
            .translationTask(mode == .translate ? backConfiguration : nil) { session in
                await backTranslate(using: session)
            }
            // No `.onKeyPress(.escape)` here — the panel handles ESC via
            // `PopupPanel.cancelOperation`, which defers to the active IME
            // when CJK input candidates are showing. SwiftUI's hook would
            // run before the IME and close the popup mid-composition.
            // Keep PopupController's extraction trigger up to date.
            // Each render binds a fresh function value that captures
            // the latest @State — re-register on every relevant change
            // so when the controller invokes the trigger at dismiss
            // time, it sees the current chat thread and event id.
            // `.onAppear` covers the initial bind.
            .onAppear { registerExtractionTrigger?({ triggerMemoryExtractionIfApplicable() }) }
            .onChange(of: polishChatThread) { _, _ in
                registerExtractionTrigger?({ triggerMemoryExtractionIfApplicable() })
            }
            .onChange(of: polishEventID) { _, _ in
                registerExtractionTrigger?({ triggerMemoryExtractionIfApplicable() })
            }
            .onChange(of: explainText) { _, _ in
                registerExtractionTrigger?({ triggerMemoryExtractionIfApplicable() })
            }
            .onChange(of: tutorThread) { _, _ in
                registerExtractionTrigger?({ triggerMemoryExtractionIfApplicable() })
            }
            // Auto-refresh + status indicator when extraction starts /
            // ends / writes to the store. Filtered to this popup's
            // event so we don't flash the indicator for popups whose
            // chat isn't being processed.
            .onReceive(NotificationCenter.default.publisher(for: MemoryExtractor.didStartNotification)) { note in
                guard isOwnEvent(note) else { return }
                isExtractingMemory = true
            }
            .onReceive(NotificationCenter.default.publisher(for: MemoryExtractor.didFinishNotification)) { note in
                guard isOwnEvent(note) else { return }
                isExtractingMemory = false
                suggestionsRefreshToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: LearnedMemoryStore.didChangeNotification)) { _ in
                // Store mutated (could be accept/reject from any UI).
                // Cheap to refresh the cards either way.
                suggestionsRefreshToken &+= 1
            }
    }

    /// True when an extractor notification refers to this popup's
    /// source event. Untyped userInfo dance because Notification's
    /// dictionary is typed `[AnyHashable: Any]?`.
    private func isOwnEvent(_ note: Notification) -> Bool {
        guard let id = note.userInfo?["eventID"] as? UUID else { return false }
        return id == polishEventID
    }

    /// All modes open auto-fitted to their content (the controller drives
    /// the opening size from `idealWidth` × the content's natural height via
    /// `sizingOptions = .preferredContentSize`) and are user-resizable from
    /// any edge — the panel carries `.resizable` in its styleMask and this
    /// view lets its frame stretch to the panel size (`maxWidth` / `maxHeight`
    /// = `.infinity`). Once the user drags an edge the controller releases
    /// auto-fit so the manual size sticks.
    private var outerLayout: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            scrollableContent
            footerForMode
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    measuredFooterHeight = newHeight
                    reportAutoFit()
                }
        }
        .padding(PopupTokens.containerPadding)
        // Top inset clears the native traffic-light buttons (top-left) and
        // the hide button (top-right) so content doesn't sit under them.
        .padding(.top, PopupTokens.trafficLightInset)
        .frame(
            minWidth: contentWidth,
            idealWidth: contentWidth,
            // All modes are user-resizable: let the content stretch to fill
            // whatever size the user drags the window to. `idealWidth`
            // (contentWidth) still drives the auto-fit opening size; once the
            // user drags an edge the controller releases auto-fit so the
            // manual size sticks (see PopupController's didResize observer).
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        // Cap the outer height at the screen so the panel can't grow
        // past it. We dropped `.fixedSize(vertical:)` from this layer:
        // it was reporting the FULL intrinsic content height (e.g.
        // 1500pt) as the panel's preferredContentSize, then telling
        // SwiftUI to render at that size while the panel was clamped
        // at maxPanelHeight — which left the ScrollView with content
        // pinned to the bottom rather than scrollable from the top.
        // Without `.fixedSize`, SwiftUI renders at the size AppKit
        // actually gives it (maxPanelHeight), and the inner ScrollView
        // naturally lets the user scroll the overflow.
        .frame(maxHeight: maxPanelHeight)
        // Hide-to-bubble button at the top-right, mirroring the native
        // close button at the top-left. Sits in the trafficLightInset
        // strip so it doesn't overlap content.
        .overlay(alignment: .topTrailing) { topRightControls }
    }

    /// Top-right controls strip: a Regenerate button (LLM modes) to the LEFT of
    /// the hide-to-bubble button, both tucked in the trafficLightInset strip so
    /// they don't overlap content.
    @ViewBuilder
    private var topRightControls: some View {
        HStack(spacing: 6) {
            if canRegenerate {
                circleIconButton(systemName: "arrow.clockwise", action: regenerate)
                    .help("Regenerate")
            }
            // Privacy "hide" affordance. Tucks the popup away behind a small
            // bubble (`PopupController.hideToBubble`) so nobody glancing at the
            // screen sees the translation/chat; a click on the bubble restores
            // it. The eye-slash icon reads as "hide from view" rather than a
            // second close button.
            if let onHide {
                circleIconButton(systemName: "eye.slash", action: onHide)
                    .help("Hide from view — click the bubble to bring it back")
            }
        }
        .padding(.top, 5)
        .padding(.trailing, 8)
    }

    private func circleIconButton(systemName: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PopupTokens.tertiaryText)
                .frame(width: 20, height: 20)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(PopupTokens.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Regenerate is offered only for the LLM single-shot answers (Explain,
    /// Polish) once they're ready. Translate is deterministic (Apple
    /// Translation) so re-running yields the same output; chat has its own
    /// per-turn retry affordance.
    private var canRegenerate: Bool {
        switch mode {
        case .explain: if case .ready = explainStatus { return true }; return false
        case .polish:  if case .ready = polishStatus  { return true }; return false
        default:       return false
        }
    }

    /// Re-fire the current LLM mode's task by bumping its retry counter (same
    /// mechanism the failure "Retry" buttons use), so the user gets a fresh
    /// answer without re-selecting the text.
    private func regenerate() {
        switch mode {
        case .explain:
            explainStatus = .working
            explainText = ""
            explainRetryCounter &+= 1
        case .polish:
            polishStatus = .working
            polishRawText = ""
            polishResult = .empty
            polishRetryCounter &+= 1
        default:
            break
        }
    }

    /// Wrap the content column in a ScrollView for non-chat modes
    /// so a long selection scrolls inside the cap. The cap itself
    /// lives on the outer VStack (see `outerLayout`); this just
    /// hosts the scrollable surface.
    ///
    /// `.fixedSize(horizontal: false, vertical: true)` on the inner
    /// `contentColumn` is required: ScrollView in SwiftUI does NOT
    /// propagate its content's intrinsic height up the layout chain
    /// unless the content has a fixed vertical size. Without it,
    /// the outer `.fixedSize` sees ScrollView's ideal as undefined.
    @ViewBuilder
    private var scrollableContent: some View {
        if mode == .chat {
            contentColumn
        } else {
            // Force the scroll position to the source text on first
            // paint. Without this, having a TextField anywhere in the
            // content (the polish/explain Discuss chat input) causes
            // macOS to auto-promote it to first responder when the
            // panel becomes key, which auto-scrolls the ScrollView to
            // bring the input into view — pushing the source text +
            // section headers off the top of the panel.
            //
            // We do TWO things:
            //   1. `defaultScrollAnchor(.top)` — SwiftUI 5+ initial
            //      anchor hint.
            //   2. ScrollViewReader + a small retry loop — macOS's
            //      first-responder auto-scroll fires AFTER the first
            //      layout pass, so a one-shot `scrollTo` in `.onAppear`
            //      doesn't reliably win. Repeating a few times over
            //      ~600ms guarantees the final position is the top.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    contentColumn
                        .fixedSize(horizontal: false, vertical: true)
                        .id("popup-top")
                }
                .defaultScrollAnchor(.top)
                .onAppear {
                    for tick in 0..<6 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick) * 0.1) {
                            proxy.scrollTo("popup-top", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    /// Upper bound for the content frame's height — comes straight from the
    /// controller, which computed it from the EXACT screen this popup opens on
    /// (the one under the cursor) before the window appeared. So the content's
    /// height cap and the window's height cap always agree, even when the popup
    /// is on the secondary of two displays. (Using `NSScreen.main` here was the
    /// old bug: on multi-display setups the content got capped to the primary
    /// screen while the window was built for a different one.)
    private var maxPanelHeight: CGFloat { maxContentHeight }

    /// Chat doesn't have a source language to display — the question came from
    /// the LLM, not a selection. Show just the practice target language and
    /// elapsed time instead of the usual "src → tgt" footer.
    @ViewBuilder
    private var footerForMode: some View {
        if mode == .chat {
            HStack(spacing: 6) {
                Text("Chat")
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.tertiaryText)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.tertiaryText)
                Text(footerTargetLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.tertiaryText)
                Spacer()
                Text(String(format: "%dms · Esc".t, elapsedMs))
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.tertiaryText)
            }
        } else {
            footerBar
        }
    }

    /// Polish wants a wider content column (variant cards hold full sentences);
    /// translate, explain, and chat stay at the original 460pt.
    private var contentWidth: CGFloat {
        switch mode {
        case .polish:                return PopupTokens.polishContentWidth
        case .chat:                  return PopupTokens.chatContentWidth
        case .translate, .explain:   return PopupTokens.translateContentWidth
        }
    }

    /// All section blocks above the footer. Extracted so both layouts can
    /// reuse it. `.chat` short-circuits to a dedicated conversation block
    /// instead of the source-row + dict/translate flow.
    @ViewBuilder
    private var contentColumn: some View {
        Group {
            if mode == .chat {
                chatBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                translateExplainPolishColumn
            }
        }
        // Report the column's intrinsic height so the controller can auto-fit
        // the window to it (on first paint + as content arrives). The column
        // has `.fixedSize(vertical: true)` in the scroll, so this is the
        // natural unscrolled height — independent of the window size, so
        // measuring it here is not circular.
        //
        // `.onGeometryChange` (not `.background(GeometryReader) +
        // onPreferenceChange`) is deliberate: the translation result and the
        // LLM explanation arrive ASYNC, often a couple hundred ms after the
        // dictionaries have already settled the layout. The preference path
        // missed those late growth events (the window stayed sized to the
        // pre-result content and the result clipped just below the fold);
        // `onGeometryChange` fires reliably on every geometry change.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            measuredContentHeight = newHeight
            reportAutoFit()
        }
    }

    /// Sum the measured content + footer heights with the fixed chrome
    /// (traffic-light inset + top/bottom container padding + the gap between
    /// the scroll area and the footer) and hand the controller the window
    /// content height that would show everything. Deferred off the SwiftUI
    /// update pass before it touches the window.
    private func reportAutoFit() {
        guard measuredContentHeight > 0 else { return }
        let chrome = PopupTokens.trafficLightInset
            + PopupTokens.containerPadding * 2
            + PopupTokens.sectionGap
        let total = measuredContentHeight + measuredFooterHeight + chrome
        DispatchQueue.main.async { onContentResize?(total) }
    }

    private var translateExplainPolishColumn: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            sourceBlock

            if mode == .translate, !sourcePronunciation.isEmpty {
                regionDivider
                sectionLabel("Phonetics".t)
                phoneticView(text: sourceText,
                             fallbackLanguage: detectedSource?.rawValue,
                             entries: sourcePronunciation)
            }

            // Two regions, each rendering every enabled dict that
            // returned content in the user's configured priority
            // order. Monolingual first, bilingual second — within
            // each kind, the order matches Settings → Dictionaries.
            if mode == .translate, !monolingualDictResults.isEmpty {
                regionDivider
                sectionLabel("Source language explanation".t)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(monolingualDictResults.enumerated()), id: \.offset) { _, entry in
                        dictionaryView(result: entry)
                    }
                }
            }
            if mode == .translate, !bilingualDictResults.isEmpty {
                regionDivider
                sectionLabel("Bilingual dictionary".t)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(bilingualDictResults.enumerated()), id: \.offset) { _, entry in
                        dictionaryView(result: entry)
                    }
                }
            }

            // Hide the whole Translation section (label + body + divider
            // above) when the translation is identical to the source —
            // happens when the user picks a Chinese sentence and the
            // target is also Chinese, so the framework returns the input
            // unchanged. Polish mode always shows; its variants are
            // rewrites, not identity.
            if mode == .polish || mode == .explain || shouldShowTranslationSection {
                regionDivider
                switch mode {
                case .translate:
                    sectionLabel("Translation".t)
                    translationBlock
                case .explain:
                    sectionLabel(explainSectionLabel)
                    explainBlock
                    // Same discussion affordance as polish — only show
                    // once the explanation stream has finished. Reuses
                    // `polishDiscussionSection`; `runPolishChat` is
                    // mode-aware so the LLM context matches.
                    if case .ready = explainStatus {
                        regionDivider
                        polishDiscussionSection
                    }
                case .polish:
                    sectionLabel("Polished".t + (polishProviderName.isEmpty ? "" : " · \(polishProviderName)"))
                    polishBlock
                case .chat:
                    EmptyView()   // chat short-circuits at contentColumn — unreachable here
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regionDivider: some View {
        Rectangle()
            .fill(PopupTokens.border)
            .frame(height: 1)
    }

    /// Container background: flat Figma surface in light mode, translucent
    /// `.regularMaterial` in dark mode (the previous design — readable against a
    /// dark desktop without the harshness of a solid pale surface).
    @ViewBuilder
    private var containerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: PopupTokens.containerRadius, style: .continuous)
        if colorScheme == .dark {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(PopupTokens.border.opacity(0.6), lineWidth: 0.5))
        } else {
            shape
                .fill(PopupTokens.surface)
                .overlay(shape.strokeBorder(PopupTokens.border, lineWidth: 1))
        }
    }

    /// Section header — same body size as content per user request, but weight +
    /// color keep it distinguishable as a label.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PopupTokens.bodySize, weight: .semibold))
            .foregroundStyle(PopupTokens.tertiaryText)
    }

    /// Bottom-of-popup footer per Figma: `source → target  [spacer]  142ms · Esc`.
    /// All 11pt regular tertiary. The target name is a Menu (per-popup override).
    private var footerBar: some View {
        HStack(spacing: 6) {
            Text(footerSourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
            Text("→")
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
            Menu {
                ForEach(LanguageOptions.all) { option in
                    let id = option.id
                    Button {
                        changeTarget(to: id)
                    } label: {
                        if id == targetLang {
                            Label(LanguageOptions.localizedName(for: id), systemImage: "checkmark")
                        } else {
                            Text(LanguageOptions.localizedName(for: id))
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(footerTargetLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Text("\(elapsedMs)ms · Esc")
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
        }
    }

    /// Footer label for the source language. Use the language code (e.g. `en`)
    /// for the source — matches Figma's `en → Chinese (Simplified)`.
    private var footerSourceLabel: String {
        detectedSource?.rawValue ?? "auto"
    }

    /// Footer label for the target language. The comma → paren
    /// reshape that matches Figma's `Chinese (Simplified)` style
    /// happens inside `LanguageOptions.localizedName`.
    private var footerTargetLabel: String {
        LanguageOptions.localizedName(for: targetLang)
    }

    private func titledRegion<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Source headword. Figma: 34pt bold for single-word translate/explain,
    /// 24pt for sentence translate/explain, 26pt for polish (longer source text).
    private var sourceBlock: some View {
        let size: CGFloat
        switch mode {
        case .translate, .explain: size = isSingleWord ? 34 : 24
        case .polish:              size = 26
        case .chat:                size = 24   // sourceBlock isn't rendered for chat, but the compiler needs exhaustiveness
        }
        // Single-word selections (translate/explain) cap at 2 lines —
        // a "word" that wraps more than that is almost certainly a
        // mis-selection of trailing whitespace, and shrinking it to
        // 2 keeps the popup compact. Everything else — sentences,
        // paragraphs, polish drafts — has NO cap: the user's
        // selection must be fully visible. Overflow scrolls via the
        // outer ScrollView in `scrollableContent`.
        let limit: Int? = ((mode == .translate || mode == .explain) && isSingleWord) ? 2 : nil
        return HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(sourceText)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(PopupTokens.primaryText)
                .textSelection(.enabled)
                .lineLimit(limit)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Speak the source aloud (system voice, or ElevenLabs if configured).
            speakButton(text: sourceText, language: detectedSource?.rawValue)
                .font(.system(size: 17))
            if readerLookup {
                markButton(word: sourceText)
                    .font(.system(size: 17))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { readerLookup = (ReaderMark.pending == sourceText) }
    }

    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.system(size: PopupTokens.bodySize))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .ready:
                translationCard
            case .failed(let message):
                // Apple Translation is on-device but can still fail
                // (language pack not downloaded, transient error) — give
                // the user a retry instead of a dead end.
                failureWithRetry(message) { rebuildConfiguration() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Click-to-copy card for the translate result. Mirrors `variantCard`
    /// so the gesture and visual confirmation pattern match polish.
    /// No `.textSelection(.enabled)` on the inner Text — text selection
    /// captures clicks before they reach the card's `onTapGesture`,
    /// breaking the copy behavior. The whole card is the copy target.
    private var translationCard: some View {
        let copied = translationCopied
        let backgroundColor: Color = copied ? Color.green.opacity(0.12) : PopupTokens.variantSurface
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(translated)
                .font(.system(size: PopupTokens.bodySize, weight: .medium))
                .foregroundStyle(PopupTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(PopupTokens.variantCardPadding)
        .background(
            RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                        .strokeBorder(PopupTokens.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { copyTranslation() }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
        .help("Click to copy the translation")
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    /// Copy the translated text to the system pasteboard and flash a
    /// green confirmation on the card for ~1.4s. Resets the indicator
    /// only if no later copy has overwritten it, so back-to-back clicks
    /// don't prematurely clear the most recent confirmation.
    private func copyTranslation() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(translated, forType: .string)
        Self.dbg("copied translation (\(translated.count) chars)")
        translationCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if translationCopied { translationCopied = false }
        }
    }

    /// "Explanation in English · Anthropic Claude" — the section label shown
    /// above the streaming explanation block. Mirrors the polish label format
    /// so the provider attribution stays consistent across modes.
    private var explainSectionLabel: String {
        let base = String(format: "Explanation in %@".t, footerTargetLabel)
        return explainProviderName.isEmpty ? base : "\(base) · \(explainProviderName)"
    }

    /// Working-state spinner label for polish (single mode now — explain has
    /// its own dedicated block).
    private var polishWorkingLabel: String {
        let provider = polishProviderName.isEmpty ? "LLM" : polishProviderName
        return "Polishing into \(footerTargetLabel) via \(provider)…"
    }

    /// The Explain mode body — prose that streams in token by token. The
    /// prompt asks the LLM for three titled sections (`## Title\nBody`); we
    /// split on blank lines, peel off the title line from each block, and
    /// render title and body in a vertical stack so each section is visually
    /// distinct.
    private var explainBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch explainStatus {
            case .working where explainText.isEmpty:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(explainWorkingLabel)
                        .font(.system(size: PopupTokens.bodySize))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .working, .ready:
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(explainSections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.system(size: PopupTokens.bodySize, weight: .semibold))
                                    .foregroundStyle(PopupTokens.accent)
                            }
                            if !section.body.isEmpty {
                                Text(section.body)
                                    .font(.system(size: PopupTokens.bodySize))
                                    .foregroundStyle(PopupTokens.primaryText)
                                    .textSelection(.enabled)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .failed(let message):
                failureWithRetry(message) {
                    explainStatus = .working
                    explainRetryCounter &+= 1
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One parsed section from the streamed explanation. Either field may be
    /// empty mid-stream (e.g. the title has arrived but no body yet).
    private struct ExplainSection {
        let title: String
        let body: String
    }

    /// Split the streamed explanation into titled sections. Blocks separated
    /// by blank lines; within each block the first line is the title (stripped
    /// of `## ` or `**…**` markdown) and the remaining lines are the body.
    /// During streaming the last block may have just a title with no body —
    /// that's fine, it'll render title-only and the body fills in as chunks
    /// arrive.
    private var explainSections: [ExplainSection] {
        explainText
            .components(separatedBy: "\n\n")
            .compactMap { block -> ExplainSection? in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                // Split first line vs rest.
                if let newlineRange = trimmed.range(of: "\n") {
                    let firstLine = trimmed[..<newlineRange.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let rest = trimmed[newlineRange.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let (title, isTitle) = Self.parseTitleLine(firstLine)
                    if isTitle {
                        return ExplainSection(title: title, body: rest)
                    }
                    // No title marker on the first line — render the whole
                    // block as body-only so we don't lose content if the LLM
                    // skips the `##` prefix.
                    return ExplainSection(title: "", body: trimmed)
                }

                // Single-line block (mid-stream, before the body starts).
                let (title, isTitle) = Self.parseTitleLine(trimmed)
                if isTitle {
                    return ExplainSection(title: title, body: "")
                }
                return ExplainSection(title: "", body: trimmed)
            }
    }

    /// Strip a leading title marker from `line`. Returns `(title, isTitle)`:
    /// `## Foo` → `("Foo", true)`; `**Foo**` → `("Foo", true)`; anything else →
    /// `(line, false)`.
    private static func parseTitleLine(_ line: String) -> (String, Bool) {
        if line.hasPrefix("## ") {
            return (String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        if line.hasPrefix("##") {
            return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count >= 4 {
            let inner = line.dropFirst(2).dropLast(2)
            return (String(inner).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        return (line, false)
    }

    private var explainWorkingLabel: String {
        let provider = explainProviderName.isEmpty ? "LLM" : explainProviderName
        return "Asking \(provider) to explain in \(footerTargetLabel)…"
    }

    /// Chat mode body — conversational tutor. Shows a chat thread plus a
    /// composer; corrections land inline under each tutor turn.
    private var chatBlock: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            tutorHeader
            tutorThreadView    // flexible — expands to fill, scrolls internally
            tutorComposer      // fixed — stays pinned at the bottom, always visible
                // Win the layout: the composer always gets its full height,
                // the flexible thread above absorbs the remainder. Prevents
                // the input row from being clipped off the bottom when the
                // panel is short or the composer is tall.
                .layoutPriority(1)
        }
        // Fill the panel height so the flexible thread above can take the
        // middle and the composer pins to the bottom edge.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tutorHeader: some View {
        let personaName = GlottyPersona.current().name
        return HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(PopupTokens.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Chat with %@".t, personaName))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PopupTokens.primaryText)
                if !tutorProviderName.isEmpty {
                    Text(tutorProviderName)
                        .font(.caption)
                        .foregroundStyle(PopupTokens.tertiaryText)
                }
            }
            Spacer()
        }
    }

    /// Switch-style toggle that controls whether Glotty's chat can
    /// change settings on the user's behalf. ON ⇒ capability block
    /// is included in the next prompt; the LLM may emit `set_setting`
    /// tool calls (still require Confirm). OFF ⇒ purely conversational.
    /// Takes effect on the next message; a pending card from a prior
    /// turn still works.
    ///
    /// Uses SwiftUI's native switch toggle — the rounded slider users
    /// already recognise from macOS Settings — so the state and the
    /// affordance are both unambiguous.
    /// Per-chat language picker. "Use polish target" tag (empty
    /// string) means follow `glotty.polishLang`; an explicit pick
    /// overrides for this chat (and future chats until cleared).
    /// Same shape as the polish-discussion reply picker so the
    /// chat header has a consistent affordance across modes.
    private var tutorLanguagePicker: some View {
        // The picker only shows real languages — no "follow system"
        // sentinel. When the user hasn't explicitly picked one
        // (`chatTutorLanguage` empty), the binding presents the system
        // language as the highlighted option, so the picker always
        // reflects the language Glotty will actually reply in (matching
        // `tutorReplyLanguage()` + Settings → Chat). Picking writes the
        // BCP-47 code directly.
        Picker("Reply in", selection: Binding<String>(
            get: { chatTutorLanguage.isEmpty ? LanguageOptions.systemDefault() : chatTutorLanguage },
            set: { chatTutorLanguage = $0 }
        )) {
            ForEach(LanguageOptions.all) { option in
                Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Language Glotty replies in for this chat.")
    }

    private var tutorToolsToggle: some View {
        // Inline switch + label, no chip background. The switch itself
        // surfaces on/off state; the chip styling was visual noise
        // that made the toggle taller than the adjacent language
        // picker. `.controlSize(.small)` matches the picker height.
        Toggle(isOn: $chatAllowSettingsChanges) {
            HStack(spacing: 3) {
                Image(systemName: "wand.and.stars")
                    .imageScale(.small)
                Text("Modify settings")
                    .font(.caption)
            }
            .foregroundStyle(chatAllowSettingsChanges
                             ? PopupTokens.accent
                             : .secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(chatAllowSettingsChanges
              ? "Glotty can request setting changes (you still confirm each one)."
              : "Glotty stays purely conversational. Turn on to let it propose setting changes.")
    }

    /// Auto-approve toggle. Only meaningful when "Modify settings" is
    /// on (otherwise no tool calls fire), so we hide it when the
    /// parent toggle is off to keep the composer row uncluttered.
    private var tutorAutoApproveToggle: some View {
        Toggle(isOn: $chatAutoApproveTools) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal")
                    .imageScale(.small)
                Text("Auto-approve")
                    .font(.caption)
            }
            .foregroundStyle(chatAutoApproveTools
                             ? PopupTokens.accent
                             : .secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(chatAutoApproveTools
              ? "Tool calls auto-confirm without showing the Confirm card. Rejected calls still surface as red badges."
              : "Pending tool calls wait for your tap on Confirm. Turn on to skip the confirmation step.")
    }

    @ViewBuilder
    private var tutorThreadView: some View {
        Group {
            if tutorThread.isEmpty && tutorStatus.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening a session\u{2026}")
                        .font(.system(size: PopupTokens.bodySize))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if case .failed(let message) = tutorStatus, tutorThread.isEmpty {
                tutorErrorBanner(message)
            } else if tutorStopped, tutorThread.isEmpty {
                tutorStoppedBanner()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(tutorThread) { turn in
                            tutorBubble(turn)
                        }
                        if practiceAwaitingAdvance, !tutorStatus.isWorking {
                            practiceAdvanceButton
                        }
                        if case .working = tutorStatus, !tutorThread.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Glotty is thinking\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(PopupTokens.tertiaryText)
                            }
                            .padding(.leading, 4)
                        }
                        if case .failed(let message) = tutorStatus, !tutorThread.isEmpty {
                            tutorErrorBanner(message)
                        }
                        if tutorStopped, !tutorThread.isEmpty {
                            tutorStoppedBanner()
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Flexible height (fill whatever the panel offers) rather
                // than a fixed 480 cap. With a fixed cap, header + thread +
                // composer could exceed the panel and push the composer off
                // the bottom (the user had to scroll to reach the input).
                // Low min so the thread yields space to the composer when
                // the panel is short (or the composer grows with the tools
                // row / multi-line input) — the composer keeps its size and
                // stays visible; only the thread scrolls.
                .frame(minHeight: 60, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func tutorBubble(_ turn: TutorTurn) -> some View {
        if turn.role == .system {
            tutorSystemBubble(turn)
        } else if let practice = turn.practice {
            practiceCard(practice)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
                HStack {
                    if turn.role == .user { Spacer(minLength: 32) }
                    VStack(alignment: .leading, spacing: 4) {
                        Self.markdownText(turn.reply)
                            .font(.system(size: PopupTokens.bodySize))
                            .foregroundStyle(turn.role == .user
                                             ? Color.white
                                             : PopupTokens.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(turn.role == .user
                                  ? PopupTokens.accent
                                  : PopupTokens.variantSurface)
                    )
                    if turn.role == .tutor { Spacer(minLength: 32) }
                }
                if turn.correctedText != nil || turn.correctionNote != nil {
                    tutorCorrectionBlock(turn)
                }
                if turn.role == .tutor, turn.toolCall != nil {
                    toolCallCard(for: turn)
                }
            }
            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
        }
    }

    /// The practice scenario rendered as a structured card — far more
    /// scannable than the plain-text bubble. Count pill in the header, the
    /// draft and meaning in separate labelled inset boxes, and an accent
    /// footer prompting the re-attempt. The same info still lives in
    /// `turn.reply` as text for the LLM's context.
    @ViewBuilder
    private func practiceCard(_ info: PracticeCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopupTokens.accent)
                Text("Practice".t)
                    .font(.system(size: PopupTokens.bodySize, weight: .semibold))
                    .foregroundStyle(PopupTokens.primaryText)
                Spacer(minLength: 8)
                Text(String(format: "%d left".t, info.remaining))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PopupTokens.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PopupTokens.accent.opacity(0.14)))
            }
            practiceField("You wrote".t, info.draft)
            if let meaning = info.meaning, !meaning.isEmpty {
                practiceField("You meant".t, meaning)
            }
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 11, weight: .semibold))
                Text("Say it naturally — type your version below".t)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(PopupTokens.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PopupTokens.variantTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PopupTokens.accent.opacity(0.20), lineWidth: 1)
        )
    }

    /// One labelled field inside the practice card — small uppercase label
    /// over the value in its own inset box.
    private func practiceField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(PopupTokens.secondaryText)
            Text(value)
                .font(.system(size: PopupTokens.bodySize))
                .foregroundStyle(PopupTokens.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopupTokens.variantSurface.opacity(0.75))
        )
    }

    /// "Next question" affordance shown while a practice session is paused
    /// after a verdict — the user advances when they've finished asking
    /// follow-ups. Replaces the old auto-jump to the next scenario.
    private var practiceAdvanceButton: some View {
        Button(action: advancePractice) {
            HStack(spacing: 6) {
                Text("Next question".t)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(PopupTokens.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(PopupTokens.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// System bubble — app-injected status (tool-call outcomes etc.).
    /// Subtle gear icon + secondary text, no avatar, centered-ish so
    /// it reads as scaffolding rather than dialogue.
    private func tutorSystemBubble(_ turn: TutorTurn) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(turn.reply)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Tool-call confirmation card. Renders one of three states:
    ///   - `.pending`: shows current → proposed value with Confirm /
    ///     Cancel buttons.
    ///   - `.confirmed`: collapsed green badge "✓ Applied".
    ///   - `.declined`: collapsed gray badge "✗ Declined".
    ///   - `.rejected`: red badge with the validator's reason.
    @ViewBuilder
    private func toolCallCard(for turn: TutorTurn) -> some View {
        if let call = turn.toolCall {
            switch call.outcome {
            case .pending:
                toolCallPendingCard(call: call, turnID: turn.id)
            case .confirmed:
                let entry = SettingsRegistry.find(id: call.args["key"] ?? "")
                toolCallBadge(
                    systemImage: "checkmark.circle.fill",
                    color: .green,
                    text: toolCallSummary(call, prefix: "Applied"),
                    relaunchAction: (entry?.requiresRelaunch == true)
                        ? { SystemLanguageManager.relaunch(reopenChatOnLaunch: true) }
                        : nil
                )
            case .declined:
                toolCallBadge(
                    systemImage: "xmark.circle",
                    color: .secondary,
                    text: toolCallSummary(call, prefix: "Declined")
                )
            case .rejected:
                toolCallBadge(
                    systemImage: "exclamationmark.triangle.fill",
                    color: .red,
                    text: call.rejectionReason ?? "Tool call rejected."
                )
            }
        }
    }

    @ViewBuilder
    private func toolCallPendingCard(call: PendingToolCall, turnID: UUID) -> some View {
        // `open_settings_tab` is an action ("take me there"), not a
        // values-change with a current → new comparison. Render it as
        // a single tappable card-button so the whole surface invites
        // a click — the standard Confirm / Cancel button row is the
        // wrong vocabulary for "navigate to a page". The Skip link
        // below provides a quiet opt-out without competing for
        // attention with the primary action.
        if call.name == "open_settings_tab" {
            openSettingsPendingCard(call: call, turnID: turnID)
        } else {
            standardPendingCard(call: call, turnID: turnID)
        }
    }

    /// Tap-to-open card for the `open_settings_tab` tool call. Used
    /// during onboarding step 8 (dictionary activation) and any other
    /// place the LLM proposes navigating to a Settings tab.
    private func openSettingsPendingCard(call: PendingToolCall, turnID: UUID) -> some View {
        let header = pendingCardHeader(for: call)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                confirmToolCall(on: turnID)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: header.icon)
                        .font(.body)
                        .foregroundStyle(PopupTokens.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(PopupTokens.primaryText)
                        Text("Tap to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PopupTokens.accent.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(PopupTokens.accent.opacity(0.40), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                Spacer()
                Button("Skip") { declineToolCall(on: turnID) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Standard Confirm / Cancel pending card. Used for every tool
    /// call EXCEPT `open_settings_tab` — settings changes have a
    /// current → new comparison the user should read before
    /// confirming, so the explicit button row is the right
    /// affordance there.
    private func standardPendingCard(call: PendingToolCall, turnID: UUID) -> some View {
        let header: (icon: String, title: String) = pendingCardHeader(for: call)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: header.icon)
                    .font(.caption)
                    .foregroundStyle(PopupTokens.accent)
                Text(header.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PopupTokens.primaryText)
                Spacer()
            }
            pendingCardBody(for: call)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { declineToolCall(on: turnID) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Confirm") { confirmToolCall(on: turnID) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopupTokens.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PopupTokens.accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// Header icon + title for a pending tool-call card. Different
    /// tools get different icons so the card is visually identifiable
    /// at a glance (gear for setting changes, sliders for "open Settings").
    private func pendingCardHeader(for call: PendingToolCall) -> (icon: String, title: String) {
        switch call.name {
        case "set_setting":
            let key = call.args["key"] ?? ""
            let name = SettingsRegistry.find(id: key)?.displayName ?? key
            return ("gearshape.fill", name)
        case "open_settings_tab":
            let tab = call.args["tab"] ?? ""
            let label = SettingsTab(rawValue: tab)?.label ?? tab
            return ("slider.horizontal.3", String(format: "Open Settings → %@".t, label))
        default:
            return ("questionmark.circle", call.name)
        }
    }

    /// Body row of a pending tool-call card. For `set_setting` we show
    /// `current → new`; for `open_settings_tab` we show the tab name.
    @ViewBuilder
    private func pendingCardBody(for call: PendingToolCall) -> some View {
        switch call.name {
        case "set_setting":
            let key = call.args["key"] ?? ""
            let value = call.args["value"] ?? ""
            let entry = SettingsRegistry.find(id: key)
            let current = entry?.read() ?? ""
            let renderedCurrent = entry?.displayValue?(current) ?? current
            let renderedNew = entry?.displayValue?(value) ?? value
            HStack(spacing: 6) {
                Text(renderedCurrent.isEmpty ? "(unset)" : renderedCurrent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(renderedNew)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PopupTokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        case "open_settings_tab":
            // Header line already names the tab; body is intentionally
            // empty (no current-vs-new comparison to show for an open
            // action). The Confirm button alone is enough context.
            EmptyView()
        default:
            EmptyView()
        }
    }

    private func toolCallBadge(
        systemImage: String,
        color: Color,
        text: String,
        relaunchAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let relaunchAction {
                Button {
                    relaunchAction()
                } label: {
                    Label("Relaunch", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    /// Human-readable one-liner used in the collapsed badge text.
    private func toolCallSummary(_ call: PendingToolCall, prefix: String) -> String {
        switch call.name {
        case "set_setting":
            let key = call.args["key"] ?? ""
            let value = call.args["value"] ?? ""
            let entry = SettingsRegistry.find(id: key)
            let displayName = entry?.displayName ?? key
            let rendered = entry?.displayValue?(value) ?? value
            return "\(prefix): \(displayName) → \(rendered)"
        case "open_settings_tab":
            let tab = call.args["tab"] ?? ""
            let label = SettingsTab(rawValue: tab)?.label ?? tab
            return "\(prefix): open Settings → \(label)"
        default:
            return "\(prefix): \(call.name)"
        }
    }

    /// Inline correction shown under a tutor turn — the natural rewrite
    /// of the user's most recent message plus a brief note in the
    /// user's native language explaining what was off. Visually
    /// distinct from the chat bubbles (orange accent, smaller text)
    /// so the user can ignore it when they don't want a lesson.
    private func tutorCorrectionBlock(_ turn: TutorTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let corrected = turn.correctedText, !corrected.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Better:")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(corrected)
                            .font(.system(size: 12))
                            .foregroundStyle(PopupTokens.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            if let note = turn.correctionNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    // Left-spacer aligns the note with the corrected text
                    // when both are shown (icon column = ~14pt).
                    if turn.correctedText != nil && !turn.correctedText!.isEmpty {
                        Spacer().frame(width: 14)
                    } else {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 4)
    }

    /// Failure row for translate / explain with a Retry button.
    /// LLM/translation calls can fail transiently (network blip, rate
    /// limit, provider hiccup); without a retry the user's only option
    /// is to close the popup and re-trigger the whole Fn-chord. The
    /// `retry` closure re-fires the relevant task.
    private func failureWithRetry(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.system(size: PopupTokens.bodySize))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tutorErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") {
                tutorStatus = .working
                tutorRunCounter &+= 1
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    /// Neutral counterpart to `tutorErrorBanner` — shown after the user stops a
    /// reply, with a Retry that re-runs the last user turn.
    private func tutorStoppedBanner() -> some View {
        HStack(spacing: 8) {
            Text("Stopped.")
                .font(.system(size: 12))
                .foregroundStyle(PopupTokens.secondaryText)
            Spacer()
            Button("Retry") { retryTutor() }
                .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopupTokens.variantSurface)
        )
    }

    private func retryTutor() {
        tutorStopped = false
        tutorStatus = .working
        tutorRunCounter &+= 1
    }

    private var tutorComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Tools toggle + reply-language picker float just above
            // the input row. Both controls modify the *next* message
            // (the toggle changes prompt capabilities; the picker
            // changes the language the LLM replies in). Sit in their
            // own row but visually attached to the composer via the
            // tight 4pt spacing.
            HStack(spacing: 8) {
                tutorToolsToggle
                // Auto-approve is meaningful whenever tool calls can
                // fire: either the user explicitly toggled "Modify
                // settings" ON, or we're in onboarding (which forces
                // tool calls ON regardless of the toggle — see
                // `allowToolCalls: chatAllowSettingsChanges || onboarding`
                // in runTutorTurn). Hiding it during onboarding made
                // the user think the toggle was missing.
                if chatAllowSettingsChanges || onboarding {
                    tutorAutoApproveToggle
                }
                // Practice has fixed languages — you reply in the item's
                // language and the tutor's feedback is always in your native
                // language — so the "reply in" picker does nothing here and
                // only confuses (it showed e.g. English beside Chinese
                // feedback). Hide it during a practice session.
                if practiceItems.isEmpty {
                    tutorLanguagePicker
                }
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("Reply in your target language\u{2026}",
                          text: $tutorInput,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .lineLimit(1...6)
                    .focused($tutorInputFocused)
                    .onChange(of: tutorInputFocused) { _, gained in
                        Log.debug(.popup,
                            "chat composer focus → \(gained) keyWindow=\(NSApp.keyWindow?.title ?? "nil")",
                            op: "chat-input")
                        guard gained else { return }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    // Return-key handling has to coexist with IME
                    // composition (Pinyin, Kana, etc.) where Return
                    // is supposed to COMMIT the current candidate,
                    // not submit the message. `.onKeyPress` fires
                    // even during composition, but `.onSubmit` is
                    // IME-aware: the system suppresses it while marked
                    // text is being edited and only fires when there's
                    // no active composition. So:
                    //   - Plain Return → handled by `.onSubmit` only,
                    //     returning `.ignored` from onKeyPress so the
                    //     IME / system gets the keypress first. During
                    //     pinyin composition, IME consumes the Return
                    //     to commit; only after composition ends does
                    //     `.onSubmit` actually fire.
                    //   - Shift+Return → handled directly in
                    //     onKeyPress (insert newline). Composition
                    //     interaction is rare here and acceptable.
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) {
                            tutorInput += "\n"
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit { submitTutor() }
                // While a reply streams the button becomes Stop (cancel the
                // in-flight turn); otherwise it's Send.
                Button(tutorStatus.isWorking ? "Stop" : "Send") {
                    if tutorStatus.isWorking { stopTutor() } else { submitTutor() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tutorStatus.isWorking
                              && (tutorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || tutorThread.isEmpty))
            }
            // Key-shortcut hint. Uses the Return (⏎) and Shift (⇧)
            // glyphs so it reads compactly without prose, and sits
            // right under the input where users look while typing.
            HStack {
                Text("⏎ Send · ⇧⏎ New line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    /// One question of the session. Header shows progress + category, body
    /// shows the question + options, feedback area appears after an answer.
    // MARK: - Polish discussion

    /// Collapsed-by-default panel under the polish output. Lets the user
    /// continue chatting with the LLM about their draft — ask why a fix was
    /// suggested, request a different rewrite tone, etc. — without leaving
    /// the popup.
    @ViewBuilder
    private var polishDiscussionSection: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            if polishChatExpanded {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(PopupTokens.accent)
                    Text("Discuss with Glotty")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PopupTokens.primaryText)
                    Spacer()
                    Picker("Reply in", selection: $polishChatLanguage) {
                        ForEach(chatLanguageOptions(), id: \.id) { option in
                            Text(LanguageOptions.localizedName(for: option.id)).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    // Lock the reply language once the conversation is
                    // underway — mid-thread switching would leave half
                    // the bubbles in one language and the rest in
                    // another, which reads as a model glitch rather
                    // than a user choice.
                    .disabled(!polishChatThread.isEmpty)
                    .help(polishChatThread.isEmpty
                          ? "Language Glotty replies in for this chat."
                          : "Locked once the conversation has started.")
                    Button {
                        polishChatExpanded = false
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PopupTokens.tertiaryText)
                }
                .task {
                    // Initialize once on first appear. Picker bindings need
                    // a non-empty value that exists in the options list, or
                    // SwiftUI logs a warning and the selection ghosts blank.
                    if polishChatLanguage.isEmpty {
                        polishChatLanguage = defaultChatLanguage()
                    }
                }

                // Always reserve room for a few messages when the chat is
                // open, even before the user has sent anything. An empty
                // chat that's just a single text field reads as cramped;
                // the placeholder + minHeight here makes it obvious the
                // area is for an unfolding conversation.
                Group {
                    if polishChatThread.isEmpty {
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 22))
                                .foregroundStyle(PopupTokens.tertiaryText.opacity(0.45))
                            Text("Ask a follow-up — replies will appear here.")
                                .font(.system(size: 12))
                                .foregroundStyle(PopupTokens.tertiaryText)
                                .multilineTextAlignment(.center)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        // Render every turn inline — no nested ScrollView.
                        // The OUTER scroll in `scrollableContent` handles
                        // overflow for the whole popup; a nested ScrollView
                        // here was eating scroll gestures, locking the
                        // outer scroll at whatever position SwiftUI started
                        // at, and hiding the source text at the top + the
                        // chat input at the bottom.
                        polishChatTurnsList
                    }
                }
                .frame(minHeight: 180, alignment: .topLeading)

                suggestionCards

                HStack(spacing: 8) {
                    TextField("Not satisfied? Ask a follow-up…",
                              text: $polishChatInput,
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        // Single-line floor so the placeholder and
                        // cursor sit centered in the rounded-border
                        // chrome (a 2-line floor would top-align them).
                        // `.controlSize(.large)` gives the row roughly
                        // double the default height; the field still
                        // grows to 6 lines as the user types longer
                        // follow-ups before its own scroll engages.
                        .controlSize(.large)
                        .lineLimit(1...6)
                        .focused($polishChatInputFocused)
                        .onChange(of: polishChatInputFocused) { _, gainedFocus in
                            guard gainedFocus else { return }
                            Self.dbg("polishChat focus gained — activating app (active=\(NSApp.isActive))")
                            // Use the legacy `ignoringOtherApps:true` variant
                            // unconditionally — the new macOS 14 `activate()`
                            // is too conservative to force a space switch
                            // out of a source app's full-screen mode. The
                            // deprecation warning is fine; the older API is
                            // what actually behaves like "yank our app to
                            // the front, even from a full-screen space".
                            NSApp.activate(ignoringOtherApps: true)
                            Self.dbg("polishChat post-activate — active=\(NSApp.isActive)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                polishChatInputFocused = true
                            }
                        }
                        // Mirror the tutor (Fn → C) composer's Return
                        // handling: plain Return submits, Shift+Return
                        // inserts a newline. Direct binding append
                        // because a SwiftUI vertical TextField won't
                        // fall through to NSTextView's default newline
                        // when this handler returns `.ignored`.
                        .onKeyPress(keys: [.return]) { press in
                            if press.modifiers.contains(.shift) {
                                polishChatInput += "\n"
                                return .handled
                            }
                            submitPolishChat()
                            return .handled
                        }
                    // While a reply streams the button becomes Stop (cancel the
                    // in-flight turn); otherwise it's Send.
                    Button(polishChatStatus.isWorking ? "Stop" : "Send") {
                        if polishChatStatus.isWorking { stopPolishChat() }
                        else { submitPolishChat() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!polishChatStatus.isWorking
                                  && polishChatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Text("⏎ Send · ⇧⏎ New line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                Button {
                    polishChatExpanded = true
                    // Ask the controller to grow the panel so the new
                    // chat region has room without crowding the polish
                    // content above. Fires on every expand transition —
                    // PopupController only grows the first time so a
                    // user who collapses and re-expands doesn't get a
                    // runaway window.
                    onChatExpand?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("Not satisfied? Discuss with Glotty")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(PopupTokens.tertiaryText)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(PopupTokens.variantSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(PopupTokens.border, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(PopupTokens.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Small "Extract memories" button shown below the chat input.
    /// Always available when extraction is enabled (auto OR manual
    /// mode) so the user can re-run on demand — manual triggers
    /// bypass the cooldown. Hidden in Off mode (no point pretending
    /// extraction can happen). Disabled while the thread is empty
    /// or an extraction is already in flight.
    @ViewBuilder
    private var manualExtractButton: some View {
        let mode = MemoryExtractor.mode
        if mode != .off {
            HStack(spacing: 4) {
                Spacer()
                Button {
                    triggerMemoryExtractionIfApplicable(manual: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text(isExtractingMemory ? "Reviewing\u{2026}" : "Extract memories")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(PopupTokens.tertiaryText)
                .disabled(polishChatThread.isEmpty || isExtractingMemory)
                .help(mode == .auto
                      ? "Extraction also runs automatically after each reply. Click to extract now."
                      : "Extraction is set to manual — click to pull memories from this chat now.")
            }
        }
    }

    /// Cards for pending memory suggestions extracted from this
    /// conversation. Rendered between the chat thread and the input
    /// row so the user reviews them in the same context that
    /// produced them. Each card has Accept (with a scope picker) and
    /// Reject — once actioned, the store changes status and the card
    /// disappears via `suggestionsRefreshToken`.
    @ViewBuilder
    private var suggestionCards: some View {
        let pending = pendingSuggestionsForThisEvent()
        if !pending.isEmpty || isExtractingMemory {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isExtractingMemory ? "ellipsis.bubble" : "lightbulb")
                        .foregroundStyle(.yellow)
                    Text(isExtractingMemory && pending.isEmpty
                         ? "Glotty is reviewing this chat\u{2026}"
                         : "Glotty noticed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PopupTokens.secondaryText)
                    if isExtractingMemory {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                ForEach(pending) { memory in
                    suggestionCard(memory)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func suggestionCard(_ memory: LearnedMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(memory.kind.label.t)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(suggestionKindColor(memory.kind).opacity(0.18)))
                    .foregroundStyle(suggestionKindColor(memory.kind))
                if let term = memory.term {
                    Text(term).font(.callout.bold())
                }
                Spacer()
            }
            Text(memory.content)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Accept") {
                    let scope = suggestionScopeDrafts[memory.id] ?? defaultSuggestionScope(for: memory.kind)
                    LearnedMemoryStore.shared.accept(id: memory.id, scope: scope)
                    suggestionScopeDrafts[memory.id] = nil
                    suggestionsRefreshToken &+= 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                suggestionScopePicker(for: memory)

                Button("Reject") {
                    LearnedMemoryStore.shared.reject(id: memory.id)
                    suggestionScopeDrafts[memory.id] = nil
                    suggestionsRefreshToken &+= 1
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private func suggestionScopePicker(for memory: LearnedMemory) -> some View {
        let current = suggestionScopeDrafts[memory.id] ?? defaultSuggestionScope(for: memory.kind)
        let contexts = MemoryContextStore.shared.all()
        return Picker("Save to", selection: Binding<MemoryScope>(
            get: { current },
            set: { suggestionScopeDrafts[memory.id] = $0 }
        )) {
            Text("Global").tag(MemoryScope.global)
            ForEach(contexts) { ctx in
                Text(ctx.name).tag(MemoryScope.context(ctx.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    /// Kind-aware default scope. Same rule the Settings card used:
    /// facts default to global (persistent), other kinds default to
    /// the active context if one's selected, else global. Duplicated
    /// here rather than shared so PopupView doesn't import the
    /// settings-section internals.
    private func defaultSuggestionScope(for kind: LearnedMemoryKind) -> MemoryScope {
        if kind == .fact { return .global }
        if let id = MemoryContextStore.shared.activeContextID { return .context(id) }
        return .global
    }

    private func suggestionKindColor(_ kind: LearnedMemoryKind) -> Color {
        switch kind {
        case .glossary:   return .blue
        case .preference: return .purple
        case .fact:       return .green
        case .project:    return .orange
        }
    }

    /// Pending suggestions tied to this popup's source event. For
    /// chat mode the event id is today's chat thread id; for
    /// polish / explain it's the persisted MemoryEvent id.
    /// Reading `suggestionsRefreshToken` makes the array recompute
    /// after each accept/reject.
    private func pendingSuggestionsForThisEvent() -> [LearnedMemory] {
        _ = suggestionsRefreshToken
        let id: UUID? = (mode == .chat) ? tutorThreadID : polishEventID
        return LearnedMemoryStore.shared.pending(forEventID: id)
    }

    /// Boolean shortcut for the bubble retry pill — only the failure case
    /// shows the inline "Retry" affordance.
    private var polishChatFailed: Bool {
        if case .failed = polishChatStatus { return true }
        return false
    }

    /// The bubbled chat turns. Lives in its own view so the polish discussion
    /// section can switch between "inline VStack" (≤3 turns, fully visible)
    /// and "ScrollView wrapped" (>3 turns) without duplicating the body.
    @ViewBuilder
    private var polishChatTurnsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(polishChatThread.enumerated()), id: \.element.id) { idx, turn in
                polishChatBubble(
                    turn,
                    showRetry: turn.role == .user
                        && idx == polishChatThread.count - 1
                        && (polishChatFailed || polishChatStopped)
                )
            }
        }
    }

    @ViewBuilder
    private func polishChatBubble(_ turn: PolishChatTurn, showRetry: Bool) -> some View {
        let isUser = turn.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack {
                if isUser { Spacer(minLength: 24) }
                Group {
                    if turn.role == .assistant && turn.text.isEmpty && polishChatStatus.isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.secondaryText)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Self.markdownText(turn.text)
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.primaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            // Copy-ready phrasing buttons live inside the same
                            // bubble so the reply reads as one message.
                            if let phrases = turn.phrases, !phrases.isEmpty {
                                phraseChips(phrases)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isUser ? PopupTokens.accent.opacity(0.15) : PopupTokens.variantSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PopupTokens.border, lineWidth: isUser ? 0 : 1)
                        )
                )
                if !isUser { Spacer(minLength: 24) }
            }
            if showRetry {
                HStack(spacing: 6) {
                    if case .failed(let message) = polishChatStatus {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if polishChatStopped {
                        Text("Stopped.")
                            .font(.caption2)
                            .foregroundStyle(PopupTokens.tertiaryText)
                    }
                    Button {
                        retryPolishChat()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(polishChatStopped ? PopupTokens.accent : .red)
                }
            }
        }
    }

    /// Thrown by `withChatTimeout` when an LLM stream stalls (never terminates).
    private struct ChatTimeoutError: Error {}

    /// Run `operation`, throwing `ChatTimeoutError` if it hasn't finished within
    /// `seconds`. Breaks a stalled stream that never closes; the caller turns the
    /// throw into a "stalled — tap Retry" state. Cancelling the surrounding task
    /// (e.g. a new Send bumping the `.task(id:)`) also tears the stream down.
    @MainActor
    private static func withChatTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChatTimeoutError()
            }
            guard let result = try await group.next() else { throw ChatTimeoutError() }
            group.cancelAll()
            return result
        }
    }

    /// Stop the in-flight polish-chat reply: cancels the stream (via the
    /// `.task(id:)` counter bump) and the re-fired `runPolishChat` returns early.
    private func stopPolishChat() {
        guard polishChatStatus.isWorking else { return }
        polishChatStopRequested = true
        polishChatRunCounter += 1
    }

    private func submitPolishChat() {
        let trimmed = polishChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending even while a turn is in flight: bumping the run counter
        // below supersedes the in-flight (possibly stalled) turn via `.task(id:)`,
        // so a hung stream can't leave Send permanently disabled.
        guard !trimmed.isEmpty else { return }
        polishChatStopped = false
        polishChatThread.append(PolishChatTurn(role: .user, text: trimmed))
        polishChatInput = ""
        polishChatRunCounter += 1
    }

    /// Marker the discussion model wraps copy-ready phrasings in. The reply text
    /// shown in the bubble is everything BEFORE it; the lines inside become chips.
    private static let phrasesMarker = "<phrases>"

    /// While streaming, show only the prose up to a (possibly partially typed)
    /// `<phrases>` marker so the raw markup never flashes in the bubble.
    static func proseForStreaming(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let r = lower.range(of: phrasesMarker) {
            return String(raw[raw.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Trailing partial marker, e.g. "...<phra"
        for n in stride(from: phrasesMarker.count - 1, through: 1, by: -1) {
            if lower.hasSuffix(String(phrasesMarker.prefix(n))) {
                return String(raw.dropLast(n))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw
    }

    /// Split a finished reply into (prose, phrases). Phrases live between
    /// `<phrases>` and `</phrases>`, one per line; bullets are stripped.
    static func splitPhrases(_ raw: String) -> (prose: String, phrases: [String]) {
        let lower = raw.lowercased()
        guard let open = lower.range(of: phrasesMarker) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let prose = String(raw[raw.startIndex..<open.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var block = String(raw[open.upperBound...])
        if let close = block.lowercased().range(of: "</phrases>") {
            block = String(block[block.startIndex..<close.lowerBound])
        }
        let phrases = block
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for bullet in ["- ", "* ", "• ", "– "] where s.hasPrefix(bullet) {
                    s = String(s.dropFirst(bullet.count))
                }
                // Drop surrounding quotes the model sometimes adds.
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return (prose, Array(phrases.prefix(6)))
    }

    /// LLM call backing the discussion thread under polish or explain.
    /// Builds a prompt that primes the model with the relevant context
    /// for the current mode — for polish that's the draft + top variant
    /// + issues; for explain it's the source text + the explanation
    /// Glotty already produced — plus the full conversation so far,
    /// then streams the reply into the trailing assistant turn.
    private func runPolishChat() async {
        // Stop was tapped (or a new turn superseded this one) → don't start
        // another reply; just settle back to ready.
        if polishChatStopRequested {
            polishChatStopRequested = false
            // The cancelled run left its in-flight assistant placeholder (empty
            // or partially streamed) at the tail — drop it so the thread ends on
            // the user's turn and the neutral Retry affordance shows.
            if let last = polishChatThread.last, last.role == .assistant {
                polishChatThread.removeLast()
            }
            polishChatStopped = true
            polishChatStatus = .ready
            return
        }
        guard let provider = LLMRegistry.current() else {
            polishChatStatus = .failed("No LLM provider configured. Add one in Settings → Language Model.")
            return
        }
        polishChatStopped = false
        polishChatStatus = .working
        // Reserve an empty assistant turn that the stream will fill in. The
        // bubble renderer shows "Thinking…" until the first chunk lands.
        polishChatThread.append(PolishChatTurn(role: .assistant, text: ""))
        let assistantIndex = polishChatThread.count - 1

        // User-selected chat language (via the header picker) — falls
        // back to the resolved default if the picker hasn't initialized
        // yet (e.g. first message sent before the header `.task` runs).
        let language = polishChatLanguage.isEmpty ? defaultChatLanguage() : polishChatLanguage
        // Skip the placeholder assistant turn we just appended when rendering
        // history — it has no content yet.
        let history = polishChatThread
            .dropLast()
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")

        let contextBlock: String
        let roleDescription: String
        switch mode {
        case .explain:
            roleDescription = "a language tutor who just explained the following text to a learner"
            contextBlock = """
            User asked about:
            \(sourceText)

            Your earlier explanation:
            \(explainText)
            """
        case .polish, .translate, .chat:
            // Polish is the primary case here; translate/chat fall
            // through to the polish-style prompt because the
            // discussion section is only rendered for polish/explain.
            let topVariant = polishResult.variants.first?.text ?? "(no variant)"
            let issuesList = polishResult.issues
                .compactMap { issue -> String? in
                    let parts = [issue.category, issue.original.map { "“\($0)”" }, issue.explanation]
                        .compactMap { $0 }
                    return parts.isEmpty ? nil : "- " + parts.joined(separator: " — ")
                }
                .joined(separator: "\n")
            roleDescription = "a writing tutor helping a user polish their \(PolishPrompt.englishName(for: language)) text"
            contextBlock = """
            User's original draft:
            \(sourceText)

            Your top suggested rewrite:
            \(topVariant)

            Issues you flagged:
            \(issuesList.isEmpty ? "(none)" : issuesList)
            """
        }

        // Language the copy-ready phrasings are written in — the language the
        // user is actually writing (polish target / the text being explained),
        // not necessarily the chat reply language.
        let draftLangName: String = {
            switch mode {
            case .explain:
                return PolishPrompt.englishName(for: detectedSource?.rawValue ?? polishTargetLanguage())
            case .polish, .translate, .chat:
                return PolishPrompt.englishName(for: polishTargetLanguage())
            }
        }()

        let body = """
        You are \(roleDescription). Reply concisely (2-5 sentences) in \(PolishPrompt.englishName(for: language)) unless the user asks otherwise. Reference the earlier context when relevant.

        The <phrases> block is OFF by default — the large majority of turns must NOT include it. Emit it in EXACTLY TWO cases, and NO others: (1) the user explicitly asks how to IMPROVE or better phrase the writing, or (2) the user explicitly asks how to EXPRESS or SAY something. If the message is not plainly one of those two requests, do NOT emit it. When you do, put 2-4 concrete, ready-to-use phrasings at the very END of your reply inside a <phrases>…</phrases> block, one per line, written in \(draftLangName), and do NOT repeat them in your prose. Example ending:
        <phrases>
        first natural option
        second natural option
        </phrases>

        NEVER emit the block when the user is asking to UNDERSTAND rather than to write — any question about grammar, usage, meaning, or WHY the text is the way it is. That includes "why is it 'estimates' / why the -s", "why this tense / number / form", "what does X mean", "the difference between X and Y", and any why / what / how question about the existing wording. There is nothing to copy in those cases: answer in prose ONLY, with no <phrases> block. When unsure, omit it.

        \(contextBlock)

        Conversation so far:
        \(history)

        Continue the conversation by responding to the user's most recent message.
        """

        // Prepend the user-memory context block (notes + relevant
        // glossary + profile facts) so the chat assistant inherits
        // the same personalization polish/explain get.
        let prompt = PolishPrompt.prependedWithUserContext(body, sourceText: sourceText)

        do {
            let raw = try await Self.withChatTimeout(seconds: 90) { @MainActor in
                var local = ""
                try await UsageContext.$mode.withValue(.chat) {
                    for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                        local = chunk
                        // Hide the trailing <phrases> block (even partially typed)
                        // while streaming; it turns into copy chips once finished.
                        polishChatThread[assistantIndex].text = Self.proseForStreaming(chunk)
                    }
                }
                return local
            }
            let (prose, phrases) = Self.splitPhrases(raw)
            polishChatThread[assistantIndex].text = prose
            polishChatThread[assistantIndex].phrases = phrases.isEmpty ? nil : phrases
            polishChatStatus = .ready
            persistPolishChatThread()
            // Fire memory extraction now so cards appear in-dialog
            // without waiting for dismissal. The extractor enforces
            // its own cooldown so back-to-back replies won't all
            // call the LLM.
            triggerMemoryExtractionIfApplicable()
        } catch is ChatTimeoutError {
            // No chunks within the timeout window — the stream stalled. Drop the
            // empty/partial placeholder and show the failed banner so the user
            // can Retry.
            if polishChatThread.indices.contains(assistantIndex),
               polishChatThread[assistantIndex].text.isEmpty {
                polishChatThread.remove(at: assistantIndex)
            }
            polishChatStatus = .failed("The response stalled. Tap Retry.")
        } catch {
            // Superseded by a newer send (the run-counter task id changed and
            // SwiftUI cancelled this turn) — the new run owns the thread/status.
            if Task.isCancelled { return }
            // Drop the now-empty assistant placeholder on error so retry can
            // re-fire from the same user turn without an empty bubble in the
            // middle of the thread.
            if polishChatThread.indices.contains(assistantIndex),
               polishChatThread[assistantIndex].text.isEmpty {
                polishChatThread.remove(at: assistantIndex)
            }
            polishChatStatus = .failed(error.localizedDescription)
        }
    }

    /// Write the current chat thread back onto the parent polish event in
    /// MemoryStore. Runs after every successful chat exchange so closing
    /// and reopening the popup later restores the full conversation. No-op
    /// when we don't have an event id yet (live polish hasn't completed) or
    /// the parent event has gone missing.
    private func persistPolishChatThread() {
        guard let eventID = polishEventID else { return }
        guard let existing = MemoryStore.shared.allEvents().first(where: { $0.id == eventID }) else { return }
        let snapshot = polishChatThread.map { turn in
            PolishChatTurnSnapshot(
                role: turn.role == .user ? .user : .assistant,
                text: turn.text,
                phrases: turn.phrases
            )
        }
        let updated = MemoryEvent(
            kind: existing.kind,
            sourceText: existing.sourceText,
            sourceLang: existing.sourceLang,
            targetLang: existing.targetLang,
            result: existing.result,
            issues: existing.issues,
            backTranslation: existing.backTranslation,
            polishSnapshot: existing.polishSnapshot,
            polishChatThread: snapshot.isEmpty ? nil : snapshot,
            timestamp: existing.timestamp,
            id: existing.id
        )
        MemoryStore.shared.update(updated)
    }

    /// Re-fire the most recent user turn after a network failure. Drops any
    /// failed-status state and bumps the run counter so `.task(id:)` kicks
    /// off a fresh `runPolishChat` against the existing user turn (which
    /// stayed in the thread).
    private func retryPolishChat() {
        guard polishChatFailed || polishChatStopped else { return }
        polishChatStopped = false
        polishChatStatus = .ready
        polishChatRunCounter += 1
    }

    private var polishBlock: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            switch polishStatus {
            case .working where polishRawText.isEmpty:
                // Pre-first-chunk: tiny header spinner so the user knows we're
                // waiting for the model. Flips to the terminal as soon as any
                // text arrives.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(polishWorkingLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .working:
                polishStreamingTerminal
                    .transition(.opacity)
            case .ready:
                Group {
                    if !polishResult.variants.isEmpty {
                        polishVariantsSection
                    }
                    if !polishResult.issues.isEmpty {
                        regionDivider
                        sectionLabel("Issues".t)
                        polishIssuesSection
                    }
                    regionDivider
                    polishDiscussionSection
                }
                .transition(.opacity)
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        // Bump the polish task id so `.task(id:)` re-fires.
                        polishStatus = .working
                        polishRawText = ""
                        polishResult = .empty
                        polishRetryCounter += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Retry polish")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: isPolishReady)
    }

    /// SwiftUI .animation needs a `Hashable` value to compare. Boolean shortcut
    /// for "are we showing the terminal or the final cards" — flips exactly
    /// once per polish run, which is when the crossfade should happen.
    private var isPolishReady: Bool {
        if case .ready = polishStatus { return true }
        return false
    }

    /// Terminal-style block shown while the LLM streams raw JSON. Dark surface,
    /// monospace text, blinking cursor — visually distinct from the popup so
    /// the user knows "this is in-progress output, not the final result".
    private var polishStreamingTerminal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(String(format: "Streaming from %@…".t,
                            polishProviderName.isEmpty ? "LLM" : polishProviderName))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                Spacer()
            }
            Text(polishRawText + "▍")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.88, green: 0.92, blue: 0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.22), lineWidth: 0.5)
                )
        )
    }

    /// Figma: "Issues" label (rendered by sectionLabel above) + body text
    /// 13pt regular `#6E6E73`. Issue spans (if present) are quoted with
    /// orange tint to stay distinguishable.
    private var polishIssuesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(polishResult.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 1) {
                    if let original = issue.original, !original.isEmpty {
                        Text("“\(original)”")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.orange)
                            .textSelection(.enabled)
                    }
                    Text(issue.explanation)
                        .font(.system(size: 13))
                        .foregroundStyle(PopupTokens.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Figma: variants rendered as rounded cards. First variant has a light blue
    /// tint (`#E8F1FF`), the rest are white. Border `#D8D8DD`, 8pt radius, 10pt
    /// padding. Each card contains `text` (15pt medium) + `Back: …` (11pt regular
    /// secondary). Click to copy; brief green tint as confirmation.
    private var polishVariantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(polishResult.variants.enumerated()), id: \.offset) { idx, variant in
                variantCard(index: idx, variant: variant)
            }
        }
    }

    private func variantCard(index idx: Int, variant: PolishVariant) -> some View {
        let copied = copiedVariantIndex == idx
        let baseTint: Color = idx == 0 ? PopupTokens.variantTint : PopupTokens.variantSurface
        let backgroundColor: Color = copied ? Color.green.opacity(0.12) : baseTint
        // No `.textSelection(.enabled)` on inner Text — text selection captures
        // mouse clicks before they reach the card's `onTapGesture`, breaking the
        // click-to-copy behavior. The whole card is the copy target instead.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(variant.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PopupTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            if let back = variant.backTranslation, !back.isEmpty {
                Text(back)
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopupTokens.variantCardPadding)
        .background(
            RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                        .strokeBorder(PopupTokens.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { copyVariant(variant.text, index: idx) }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
        .help("Click to copy the polished version (native-language translation shown below for reference)")
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    /// Copy-ready phrasing buttons, styled like the Polish variant cards: just
    /// the text, click to copy, brief green tint + checkmark as confirmation.
    /// No leading icon — the whole card is the button.
    @ViewBuilder
    private func phraseChips(_ phrases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(phrases, id: \.self) { phrase in
                let copied = copiedPhrase == phrase
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // No `.textSelection` — it would capture the click and
                    // break tap-to-copy (same reason as variantCard).
                    Text(phrase)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PopupTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if copied {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PopupTokens.variantCardPadding)
                .background(
                    RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                        .fill(copied ? Color.green.opacity(0.12) : PopupTokens.variantTint)
                        .overlay(
                            RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                                .strokeBorder(PopupTokens.border, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture { copyPhrase(phrase) }
                .help("Click to copy")
                .animation(.easeOut(duration: 0.15), value: copied)
            }
        }
    }

    private func copyPhrase(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Self.dbg("copied chat phrase (\(text.count) chars)")
        copiedPhrase = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedPhrase == text { copiedPhrase = nil }
        }
    }

    private func copyVariant(_ text: String, index: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Self.dbg("copied variant #\(index + 1) (\(text.count) chars)")
        copiedVariantIndex = index
        // Auto-clear after a short delay so the green confirmation fades away.
        let target = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedVariantIndex == target { copiedVariantIndex = nil }
        }
    }

    @ViewBuilder
    private func phoneticView(text: String,
                              fallbackLanguage: String?,
                              entries: [PhoneticEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.self) { entry in
                    HStack(spacing: 6) {
                        if let label = entry.label {
                            Text(label)
                                .font(.system(size: PopupTokens.bodySize, design: .rounded).weight(.semibold))
                                .foregroundStyle(PopupTokens.tertiaryText)
                                .frame(width: 36, alignment: .leading)
                        }
                        Text(entry.value)
                            .font(.system(size: PopupTokens.bodySize, design: .serif))
                            .foregroundStyle(PopupTokens.secondaryText)
                            .textSelection(.enabled)
                        Button {
                            Speaker.shared.speak(text,
                                                 language: entry.voiceLocale ?? fallbackLanguage)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(entry.voiceLocale.map { "Pronounce (\($0))" } ?? "Pronounce")
                    }
                }
            }
        }
    }

    private func dictionaryView(result: DictionaryLookup.SourcedEntry) -> some View {
        // Cap to the first 2 POS sections and 2 senses each — keeps the popup tight.
        // Figma: dict name 12pt semibold accent blue; bilingual gloss 20pt semibold;
        // monolingual defs 14pt regular.
        let isBilingual = DictionarySelection
            .dictionaryKind(for: result.dictionary) == .bilingual
        return VStack(alignment: .leading, spacing: 6) {
            Text(result.dictionary.name)
                .font(.system(size: PopupTokens.bodySize, weight: .semibold))
                .foregroundStyle(PopupTokens.accent)
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(Array(result.entry.parts.prefix(2).enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(part.label)
                        .font(.system(size: PopupTokens.bodySize, design: .rounded).italic())
                        .foregroundStyle(PopupTokens.tertiaryText)
                        .frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(part.definitions.prefix(2), id: \.self) { def in
                            definitionRow(def, prominentGloss: isBilingual)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func definitionRow(_ def: Definition, prominentGloss: Bool = false) -> some View {
        let segments = splitDefinition(def.text)
        // Uniform body size — bilingual vs monolingual differ only by weight.
        let glossFont: Font = prominentGloss
            ? .system(size: PopupTokens.bodySize, weight: .semibold)
            : .system(size: PopupTokens.bodySize)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let n = def.number {
                Text("\(n).")
                    .font(.system(size: PopupTokens.bodySize, design: .rounded).weight(.semibold))
                    .foregroundStyle(PopupTokens.tertiaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if segment.isExample {
                            Text("▸")
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.tertiaryText)
                        }
                        Text(segment.text)
                            .font(segment.isExample
                                  ? .system(size: PopupTokens.bodySize)
                                  : glossFont)
                            .foregroundStyle(segment.isExample
                                             ? PopupTokens.secondaryText
                                             : PopupTokens.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Break a definition into renderable lines.
    /// - `;` and `；` (full-width) split distinct glosses (each → its own line).
    /// - `▸` separates a gloss from its example sentence (example marked separately
    ///   so the row renders with a `▸` prefix and dimmer color).
    private func splitDefinition(_ text: String) -> [(text: String, isExample: Bool)] {
        var result: [(String, Bool)] = []
        let glossSegments = text.split(whereSeparator: { $0 == ";" || $0 == "；" })
        for gloss in glossSegments {
            let trimmed = gloss.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "▸", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                let cleaned = part.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty else { continue }
                result.append((cleaned, i > 0))
            }
        }
        return result
    }

    private func speakButton(text: String, language: String?) -> some View {
        Button {
            Speaker.shared.speak(text, language: language)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Pronounce")
    }

    /// Reader-only: underline this word in the EPUB reader (deliberate marking).
    private func markButton(word: String) -> some View {
        Button {
            ReaderWindowController.shared.state.markLookedUp(word)
            ReaderMark.pending = nil
            readerMarked = true
        } label: {
            Image(systemName: readerMarked ? "bookmark.fill" : "bookmark")
                .foregroundStyle(readerMarked ? PopupTokens.accent : .secondary)
        }
        .buttonStyle(.plain)
        .help(readerMarked ? "Marked — underlined in the reader"
                           : "Mark word — underline it in the reader")
    }

    private func setupConfiguration() {
        // Chat has no source text or translation/dict flow — `runChat()`
        // pulls topics from MemoryStore and generates a question on its own.
        if mode == .chat {
            targetLang = polishTargetLanguage()
            return
        }

        // Replay path: state was already pre-loaded in init. We still want
        // `detectedSource` populated so the footer shows the right language,
        // and the translate dict lookup can still run (it's local and cheap),
        // but we DO NOT call `rebuildConfiguration()` — leaving
        // `configuration` nil prevents `.translationTask` from firing.
        if let replay {
            detectedSource = replay.sourceLang.flatMap { NLLanguage(rawValue: $0) }
                ?? LanguagePolicy.detectSourceLanguage(sourceText)
            if mode == .translate, LanguagePolicy.isSingleWord(sourceText) {
                runDictLookup()
            }
            Self.dbg("setup (replay) — mode=\(mode) text='\(sourceText)' target=\(targetLang)")
            return
        }

        let savedSource = UserDefaults.standard.string(forKey: "glotty.sourceLang")
        let savedTarget = UserDefaults.standard.string(forKey: "glotty.targetLang")

        // Detection runs for all modes — for `.explain` it's purely cosmetic
        // (footer label only); the LLM call doesn't depend on it. The selection
        // language might be anything the user picked, and the explanation goes
        // out in their native language regardless.
        let detected: NLLanguage? = LanguagePolicy.detectSourceLanguage(sourceText)
        detectedSource = detected

        let target: String
        switch mode {
        case .translate:
            // Default direction: saved target (or preferred fallback) for the
            // source language. Bilateral flip: when source language matches
            // target language (e.g. saved target is zh-Hans and the user picks
            // Chinese text), translate in the opposite direction instead — so
            // zh source → en. Without this flip the only sensible outcome would
            // be suppressing the row, which loses information.
            var initial = (savedTarget?.isEmpty == false
                           ? savedTarget!
                           : LanguagePolicy.preferredTarget(for: detected))
            let srcRoot = detected?.rawValue.split(separator: "-").first.map(String.init)
            let tgtRoot = initial.split(separator: "-").first.map(String.init)
            if let srcRoot, srcRoot == tgtRoot {
                // First try the saved source preference as the new target — that
                // gives the user explicit control over the other half of the pair.
                let savedSourcePref = UserDefaults.standard.string(forKey: "glotty.sourceLang")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let pref = savedSourcePref, !pref.isEmpty,
                   pref.split(separator: "-").first.map(String.init) != srcRoot {
                    initial = pref
                } else {
                    // Otherwise fall back to the heuristic — preferredTarget(.chinese)
                    // returns "en", preferredTarget(.english) returns user-locale
                    // or zh-Hans.
                    initial = LanguagePolicy.preferredTarget(for: detected)
                }
            }
            target = initial
        case .explain:
            // Explain output language is driven directly by the
            // user's Native language (Profile → Native language /
            // onboarding Q3). This is intentionally NOT the
            // Translation default target — those are two different
            // ideas: "what should Fn-T translate INTO" can legitimately
            // differ from "what language do I want long-form
            // explanations in" (the latter is almost always your
            // most-comfortable reading language). `userNativeLanguage()`
            // already handles its own fallback to the system locale.
            target = userNativeLanguage()
        case .polish:
            // Polish output language: user pref → fallback to English (the most
            // common "I want this in idiomatic <X>" case for our audience).
            target = polishTargetLanguage()
        case .chat:
            // Unreachable — chat early-returns above. Compiler exhaustiveness.
            target = polishTargetLanguage()
        }
        targetLang = target

        // Dictionary lookup is decode-mode only (`.translate`). Explain reads
        // a single prose block from the LLM; polish has no dict section.
        if mode == .translate, LanguagePolicy.isSingleWord(sourceText) {
            runDictLookup()
        }

        Self.dbg("setup — mode=\(mode) text='\(sourceText)' detected=\(detected?.rawValue ?? "nil") target=\(target)")
        rebuildConfiguration()
    }

    /// Pull dictionary entries for the current source text using the user's
    /// preferred priority order. Local (Apple Dictionary), so safe to call
    /// from both the live-run path and the replay path.
    private func runDictLookup() {
        let savedSource = UserDefaults.standard.string(forKey: "glotty.sourceLang") ?? ""
        let savedTarget = UserDefaults.standard.string(forKey: "glotty.targetLang") ?? ""
        let available = DictionaryLookup.availableDictionaries()
        let monoIDs = DictionarySelection.selectedIDs(
            kind: .monolingual,
            sourcePreference: savedSource,
            targetPreference: savedTarget,
            detectedSource: detectedSource,
            availableDictionaries: available
        )
        let biIDs = DictionarySelection.selectedIDs(
            kind: .bilingual,
            sourcePreference: savedSource,
            targetPreference: savedTarget,
            detectedSource: detectedSource,
            availableDictionaries: available
        )
        let monoResults = DictionaryLookup.allSourcedEntries(for: sourceText, selectedIDs: monoIDs)
        let biResults   = DictionaryLookup.allSourcedEntries(for: sourceText, selectedIDs: biIDs)
        dictResults = monoResults + biResults
        Self.dbg("dict — mono=[\(monoResults.map(\.dictionary.name).joined(separator: ", "))] " +
                 "bi=[\(biResults.map(\.dictionary.name).joined(separator: ", "))]")
    }

    private func changeTarget(to newLang: String) {
        guard newLang != targetLang else { return }
        targetLang = newLang
        // Per-translation override only — Settings panel owns the persistent default.
        rebuildConfiguration()
    }

    private func rebuildConfiguration() {
        // Explain doesn't use the Apple Translation pipeline — re-firing the
        // LLM on target change is handled by the `.task(id: "explain-…")`
        // modifier in `body` (the id contains `targetLang`).
        if mode == .explain { return }

        translated = ""
        backTranslated = ""
        backConfiguration = nil

        // Skip the translation pass entirely when source and target are the same
        // language — the result would just duplicate the source row. Marking the
        // status `.ready` with empty `translated` lets `shouldShowTranslationSection`
        // hide the row without ever flashing a spinner.
        let srcRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
        let tgtRoot = targetLang.split(separator: "-").first.map(String.init)
        if let srcRoot, srcRoot == tgtRoot {
            status = .ready
            configuration = nil
            Self.dbg("translate skipped — source language matches target (\(targetLang))")
            return
        }

        status = .working
        configuration = TranslationSession.Configuration(
            source: detectedSource.map { Locale.Language(identifier: $0.rawValue) },
            target: Locale.Language(identifier: targetLang)
        )
    }

    private func translate(using session: TranslationSession) async {
        Self.dbg("translate begin — text='\(sourceText)' target=\(targetLang)")
        do {
            let response = try await session.translate(sourceText)
            translated = Self.flattenWhitespace(response.targetText)
            status = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("translate ok — '\(sourceText)' → '\(response.targetText)' in \(elapsedMs)ms")

            // Recording moves to the end of `backTranslate(using:)` so the
            // event has both halves of the round-trip. For pairs where the
            // back-translation won't run (same language, empty target), we
            // record here directly with backTranslation = nil. The branch
            // below sets backConfiguration only when back-translation IS
            // expected — so we mirror that condition.
            let willBackTranslate = (detectedSource?.rawValue != nil
                                     && detectedSource!.rawValue != targetLang
                                     && !response.targetText.isEmpty)
            if !willBackTranslate {
                recordTranslateEvent()
            }

            // Bilateral: kick off a back-translation (target → source) so the user
            // can see what the translation "means" in their source language and
            // verify the round-trip preserved their intent. Skip when source and
            // target match (identity round-trip). Only `.translate` triggers
            // back-translation — Explain and Polish are LLM-driven and don't
            // use the Apple Translation pipeline.
            if mode == .translate,
               let sourceLang = detectedSource?.rawValue,
               sourceLang != targetLang,
               !response.targetText.isEmpty {
                backTranslated = ""
                backConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: targetLang),
                    target: Locale.Language(identifier: sourceLang)
                )
            }
        } catch {
            Self.dbg("translate FAIL — '\(sourceText)' err=\(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    private func backTranslate(using session: TranslationSession) async {
        let textToReverse = translated
        guard !textToReverse.isEmpty else { return }
        Self.dbg("back-translate begin — '\(textToReverse)' target=\(detectedSource?.rawValue ?? "?")")
        do {
            let response = try await session.translate(textToReverse)
            backTranslated = Self.flattenWhitespace(response.targetText)
            Self.dbg("back-translate ok — '\(textToReverse)' → '\(response.targetText)'")
        } catch {
            // Don't fail the whole popup — bilateral is best-effort, the forward
            // translation has already succeeded by this point.
            Self.dbg("back-translate FAIL — err=\(error.localizedDescription)")
        }
        // Record the full round-trip so Memory's click-through can restore
        // both halves. If back-translate errored, backTranslated stays empty
        // and we still persist the forward result.
        recordTranslateEvent()
    }

    /// Persist a single .translate MemoryEvent capturing both forward and
    /// back-translation. Called either at the end of `translate(using:)`
    /// (when no back-translation is expected) or at the end of
    /// `backTranslate(using:)`.
    private func recordTranslateEvent() {
        MemoryStore.shared.record(MemoryEvent(
            kind: .translate,
            sourceText: sourceText,
            sourceLang: detectedSource?.rawValue,
            targetLang: targetLang,
            result: translated,
            backTranslation: backTranslated.isEmpty ? nil : backTranslated
        ))
    }

    /// Record a polish/explain result as a new History entry — or, if this
    /// popup already recorded one this session (i.e. the user hit Regenerate),
    /// replace that entry in place via its id, so History always reflects the
    /// latest answer instead of stacking a duplicate and orphaning the first.
    /// `make` receives the id to stamp onto the event.
    private func recordOrUpdateEvent(_ make: (UUID) -> MemoryEvent) {
        let existingID = polishEventID.flatMap { id in
            MemoryStore.shared.allEvents().contains { $0.id == id } ? id : nil
        }
        let event = make(existingID ?? UUID())
        if existingID != nil {
            MemoryStore.shared.update(event)
        } else {
            MemoryStore.shared.record(event)
        }
        polishEventID = event.id
    }

    /// Explain calls the LLM with the explain prompt (prose, no JSON) and
    /// streams the accumulated text into `explainText` chunk by chunk so the
    /// popup fills in live.
    private func runExplain() async {
        guard let provider = LLMRegistry.current() else {
            explainStatus = .failed("No LLM provider configured. Add one in Settings → Language Model.")
            return
        }
        let outputLanguage = targetLang
        explainStatus = .working
        explainText = ""
        explainProviderName = provider.displayName

        Self.dbg("explain begin — text='\(sourceText)' target=\(outputLanguage) provider=\(provider.id)")
        do {
            try await UsageContext.$mode.withValue(.explain) {
                for try await snapshot in provider.explainStream(sourceText, targetLanguage: outputLanguage) {
                    explainText = snapshot
                }
            }
            explainStatus = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("explain ok — \(explainText.count) chars in \(elapsedMs)ms")

            // Record (or, after Regenerate, replace) this explanation in
            // History. The captured id also lets a follow-up chat under this
            // explanation persist its thread onto the same event.
            recordOrUpdateEvent { id in
                MemoryEvent(
                    kind: .explain,
                    sourceText: sourceText,
                    sourceLang: detectedSource?.rawValue,
                    targetLang: outputLanguage,
                    result: explainText,
                    id: id
                )
            }
        } catch {
            Self.dbg("explain FAIL — err=\(error.localizedDescription)")
            explainStatus = .failed(error.localizedDescription)
        }
    }

    /// Chat session bootstrap. Opens a conversational tutor turn; the
    /// opening turn is generated by the LLM whether the chat was opened
    /// manually (Fn → C) or via a proactive reminder notification.
    /// Submit the user's typed message and kick off the next tutor
    /// turn. No-op if the input is empty or a turn is already
    /// in flight.
    /// Stop the in-flight tutor reply: cancels the stream (via the `.task(id:)`
    /// counter bump) and the re-fired `runTutorTurn` returns early.
    private func stopTutor() {
        guard tutorStatus.isWorking else { return }
        tutorStopRequested = true
        tutorRunCounter &+= 1
    }

    private func submitTutor() {
        let trimmed = tutorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending even while a previous turn is in flight: bumping
        // `tutorRunCounter` below changes the `.task(id:)` id, so SwiftUI
        // cancels the in-flight (possibly stalled) turn and starts a fresh
        // one. Without this, a hung/slow stream left Send permanently disabled.
        guard !trimmed.isEmpty else { return }
        tutorStopped = false
        let userTurn = TutorTurn(role: .user, reply: trimmed)
        tutorThread.append(userTurn)
        persistTutorTurn(userTurn)
        tutorInput = ""
        tutorRunCounter &+= 1
    }

    /// Load today's chat thread from `ChatStore` into the popup
    /// state. Called once on chat-mode open. The thread id is
    /// captured into `tutorThreadID` so memory-extraction
    /// suggestions get tied to this conversation.
    private func hydrateTodayChat() {
        let today = ChatStore.shared.todayThread()
        tutorThreadID = today.id
        tutorThread = today.turns.map { snap in
            let role: TutorTurn.Role
            switch snap.role {
            case .user:   role = .user
            case .tutor:  role = .tutor
            case .system: role = .system
            }
            return TutorTurn(
                role: role,
                reply: snap.reply,
                correctedText: snap.correctedText,
                correctionNote: snap.correctionNote,
                toolCall: snap.toolCall
            )
        }
    }

    /// Append one turn to today's `DailyChatThread` on disk. Called
    /// after every user message and every tutor reply so closing
    /// and reopening the popup mid-day always restores the live
    /// conversation. Also updates `tutorThreadID` because the first
    /// turn of the day is what creates the thread row in the store.
    private func persistTutorTurn(_ turn: TutorTurn) {
        // Onboarding chats are ephemeral — they shouldn't end up in
        // today's saved thread, otherwise the user's first real chat
        // of the day would open with the setup Q&A still showing.
        // Re-opening Welcome later also restarts onboarding fresh.
        // Practice drills are ephemeral too — keep them out of the daily thread.
        if onboarding || !practiceItems.isEmpty { return }
        let snapRole: TutorTurnSnapshot.Role
        switch turn.role {
        case .user:   snapRole = .user
        case .tutor:  snapRole = .tutor
        case .system: snapRole = .system
        }
        let snap = TutorTurnSnapshot(
            role: snapRole,
            reply: turn.reply,
            correctedText: turn.correctedText,
            correctionNote: turn.correctionNote,
            toolCall: turn.toolCall
        )
        let id = ChatStore.shared.appendToToday(snap)
        if tutorThreadID == nil { tutorThreadID = id }
    }

    /// Validate a tool call from the LLM against the SettingsRegistry.
    /// Returns nil when the LLM emitted no tool call. Returns a
    /// `.pending` PendingToolCall when validation passes (UI will
    /// show a Confirm card). Returns a `.rejected` PendingToolCall
    /// with `rejectionReason` populated when validation fails — the
    /// caller appends a system turn so the LLM sees the rejection
    /// in the next round.
    private static func resolveToolCall(_ call: PendingToolCall?) -> PendingToolCall? {
        guard let call else { return nil }
        switch call.name {
        case "set_setting":
            return resolveSetSetting(call)
        case "open_settings_tab":
            return resolveOpenSettingsTab(call)
        default:
            return PendingToolCall(
                name: call.name,
                args: call.args,
                outcome: .rejected,
                rejectionReason: "Unknown tool `\(call.name)`. Available: set_setting, open_settings_tab."
            )
        }
    }

    private static func resolveSetSetting(_ call: PendingToolCall) -> PendingToolCall {
        guard let key = call.args["key"], let value = call.args["value"] else {
            return PendingToolCall(name: call.name, args: call.args, outcome: .rejected,
                                   rejectionReason: "`set_setting` requires both `key` and `value` args.")
        }
        let (_, validation) = SettingsRegistry.validate(id: key, value: value)
        switch validation {
        case .ok:
            return PendingToolCall(name: call.name, args: call.args, outcome: .pending, rejectionReason: nil)
        case .unknownSetting:
            return PendingToolCall(name: call.name, args: call.args, outcome: .rejected,
                                   rejectionReason: "Unknown setting id `\(key)`.")
        case .blocked(let reason), .invalidValue(let reason):
            return PendingToolCall(name: call.name, args: call.args, outcome: .rejected,
                                   rejectionReason: reason)
        }
    }

    private static func resolveOpenSettingsTab(_ call: PendingToolCall) -> PendingToolCall {
        guard let raw = call.args["tab"] else {
            return PendingToolCall(name: call.name, args: call.args, outcome: .rejected,
                                   rejectionReason: "`open_settings_tab` requires a `tab` arg.")
        }
        guard SettingsTab(rawValue: raw) != nil else {
            let valid = SettingsTab.allCases.map(\.rawValue).joined(separator: ", ")
            return PendingToolCall(name: call.name, args: call.args, outcome: .rejected,
                                   rejectionReason: "Unknown tab `\(raw)`. Valid tabs: \(valid).")
        }
        return PendingToolCall(name: call.name, args: call.args, outcome: .pending, rejectionReason: nil)
    }

    /// Append an app-injected status note into the live thread. Used
    /// to record tool-call outcomes so the LLM sees them on the
    /// next round. Rendered with a subtle background in the chat
    /// view; persisted to disk like any other turn.
    private func appendSystemTurn(_ text: String) {
        let turn = TutorTurn(role: .system, reply: text)
        tutorThread.append(turn)
        persistTutorTurn(turn)
    }

    /// User tapped Confirm on a `set_setting` card. Applies the
    /// change via the registry's write closure, flips the card's
    /// outcome to `.confirmed`, persists, and drops a system turn
    /// into the thread so the LLM knows it stuck.
    private func confirmToolCall(on turnID: UUID) {
        guard let idx = tutorThread.firstIndex(where: { $0.id == turnID }),
              var call = tutorThread[idx].toolCall,
              case .pending = call.outcome else { return }
        switch call.name {
        case "set_setting":
            applySetSetting(call: &call, at: idx)
        case "open_settings_tab":
            applyOpenSettingsTab(call: &call, at: idx)
        default:
            // Resolver should have caught this; defend anyway.
            call.outcome = .rejected
            call.rejectionReason = "Tool no longer supported."
            tutorThread[idx].toolCall = call
            persistToolCallUpdate(at: idx)
        }
    }

    private func applySetSetting(call: inout PendingToolCall, at idx: Int) {
        let key = call.args["key"] ?? ""
        let value = call.args["value"] ?? ""
        guard let entry = SettingsRegistry.find(id: key) else {
            call.outcome = .rejected
            call.rejectionReason = "Setting disappeared from the registry."
            tutorThread[idx].toolCall = call
            persistToolCallUpdate(at: idx)
            return
        }
        entry.write(value)
        call.outcome = .confirmed
        tutorThread[idx].toolCall = call
        persistToolCallUpdate(at: idx)
        let pretty = entry.displayValue?(value) ?? value
        var message = "Applied: \(entry.displayName) → \(pretty)."
        if let note = entry.postApplyNote, !note.isEmpty {
            message += " " + note
        }
        appendSystemTurn(message)
        // No auto-fire here — the onboarding prompt instructs the
        // model to bundle "acknowledgement + next question" into the
        // same turn as the `set_setting` tool_call. So when the user
        // confirms, the next question is already on screen waiting
        // for their answer. Auto-firing here would produce a third
        // turn that either re-asks the same question (the original
        // duplicate-question bug) or sits silently. The exception is
        // `open_settings_tab` (step 8) — that one DOES auto-fire,
        // because the user goes to Settings and the wrap-up needs to
        // appear without further user input.
    }

    private func applyOpenSettingsTab(call: inout PendingToolCall, at idx: Int) {
        let raw = call.args["tab"] ?? ""
        guard let tab = SettingsTab(rawValue: raw) else {
            call.outcome = .rejected
            call.rejectionReason = "Tab disappeared."
            tutorThread[idx].toolCall = call
            persistToolCallUpdate(at: idx)
            return
        }
        SettingsWindowController.shared.show(selecting: tab)
        call.outcome = .confirmed
        tutorThread[idx].toolCall = call
        persistToolCallUpdate(at: idx)
        appendSystemTurn("Opened Settings → \(tab.label).")
        // Same auto-continue rule as set_setting during onboarding —
        // step 8 (dictionary setup via open_settings_tab) needs the
        // chat to advance to the wrap-up turn after the user confirms
        // the tab open. Without this the thread sits quiet after
        // Settings appears.
        if onboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                tutorRunCounter &+= 1
            }
        }
    }

    /// User tapped Cancel. Marks the card declined and tells the LLM.
    private func declineToolCall(on turnID: UUID) {
        guard let idx = tutorThread.firstIndex(where: { $0.id == turnID }),
              var call = tutorThread[idx].toolCall,
              case .pending = call.outcome else { return }
        call.outcome = .declined
        tutorThread[idx].toolCall = call
        persistToolCallUpdate(at: idx)
        let summary: String
        switch call.name {
        case "set_setting":
            let key = call.args["key"] ?? ""
            summary = "the change to \(SettingsRegistry.find(id: key)?.displayName ?? key)"
        case "open_settings_tab":
            let tab = call.args["tab"] ?? ""
            let label = SettingsTab(rawValue: tab)?.label ?? tab
            summary = "opening Settings → \(label)"
        default:
            summary = "the request"
        }
        // During onboarding the chat needs to keep driving the
        // conversation after any decline — otherwise the thread sits
        // quiet. The system-note phrasing varies by tool: set_setting
        // declines should re-ask the same question (user disagreed
        // with the proposed value), while open_settings_tab declines
        // should simply advance to the next step (user skipped the
        // guided action — no point retrying it).
        if onboarding {
            switch call.name {
            case "set_setting":
                let key = call.args["key"] ?? ""
                let prettyKey = SettingsRegistry.find(id: key)?.displayName ?? key
                appendSystemTurn("User declined the proposed value for \(prettyKey). Re-ask the SAME question (the one tied to `\(key)`) with a fresh, gentler phrasing and clarifying angle — do NOT advance to the next question.")
            case "open_settings_tab":
                let tab = call.args["tab"] ?? ""
                appendSystemTurn("User skipped opening Settings → \(SettingsTab(rawValue: tab)?.label ?? tab). Advance to the next step — do NOT re-offer the same tab.")
            default:
                appendSystemTurn("User declined \(summary).")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                tutorRunCounter &+= 1
            }
        } else {
            appendSystemTurn("User declined \(summary).")
        }
    }

    /// Round-trip the updated tool-call to ChatStore so the resolved
    /// card state survives popup close + relaunch. `turnIndex` in
    /// `tutorThread` lines up with the same index on disk because
    /// hydrate + append both go in order.
    private func persistToolCallUpdate(at index: Int) {
        guard let threadID = tutorThreadID else { return }
        ChatStore.shared.updateTurn(
            threadID: threadID,
            turnIndex: index,
            toolCall: tutorThread[index].toolCall
        )
    }

    /// Compose the scenario card for `item` — the prompt the user
    /// re-attempts, built by the app with NO LLM round-trip. Shows what
    /// they originally wrote and what they meant (the reference answer is
    /// deliberately withheld), then asks for a fresh attempt. `remaining`
    /// is the number of items still in the queue (including this one), so
    /// the header reflects progress as items resolve and recycle.
    private func practicePresentation(_ item: PracticeItem, remaining: Int) -> String {
        var lines: [String] = []
        lines.append(String(format: "Practice — %d left".t, remaining))
        lines.append("")
        lines.append(String(format: "You wrote: %@".t, item.draft))
        if let meaning = item.meaning, !meaning.isEmpty {
            lines.append(String(format: "You meant: %@".t, meaning))
        }
        lines.append("")
        lines.append("Say it naturally now — type your new version below.".t)
        return lines.joined(separator: "\n")
    }

    /// Present the next practice scenario after the user taps "Next" — the
    /// deferred advance that replaces the old auto-jump, so they control when
    /// to move on. No LLM call (the app drives presentation).
    private func advancePractice() {
        practiceAwaitingAdvance = false
        guard let front = practiceQueue.first else { return }
        let item = practiceItems[front]
        let card = practicePresentation(item, remaining: practiceQueue.count)
        tutorThread.append(TutorTurn(
            role: .tutor, reply: card,
            practice: PracticeCardInfo(
                draft: item.draft, meaning: item.meaning,
                remaining: practiceQueue.count)))
    }

    /// Drive one round of the tutor conversation. On the very first
    /// call (counter == 0, thread empty), this produces the opening
    /// turn — no user message yet. Subsequent calls produce a tutor
    /// reply to whatever the user just sent.
    private func runTutorTurn() async {
        // Stop tapped (or superseded) → don't start another reply.
        if tutorStopRequested {
            tutorStopRequested = false
            // The tutor appends its turn only after a full parse, so a cancelled
            // stream leaves no orphan bubble — the thread already ends on the
            // user's turn. Just surface the neutral Retry banner.
            tutorStopped = true
            tutorStatus = .ready
            return
        }
        guard let provider = LLMRegistry.current() else {
            tutorStatus = .failed("No LLM provider configured. Add one in Settings → Language Model.")
            return
        }
        tutorStopped = false
        tutorStatus = .working
        tutorProviderName = provider.displayName

        let target = tutorReplyLanguage()
        let native = userNativeLanguage()
        // Build the memory/context block for the user's first
        // message — picks up profile + glossary + memories so the
        // tutor knows what topics to pull from.
        let contextSource = tutorThread.last?.reply ?? ""
        // Fn+C tutor chat — the one place `.chatOnly` memories inject.
        let userContext = LearnedMemoryStore.shared.contextBlock(for: contextSource, purpose: .chat)
        // System turns (tool-call outcomes) are surfaced to the LLM
        // as bracketed status notes so the model knows what the app
        // confirmed / declined in the prior round.
        let history: [(role: String, text: String)] = tutorThread.map { turn in
            switch turn.role {
            case .user:   return ("User", turn.reply)
            case .tutor:  return ("Tutor", turn.reply)
            case .system: return ("System", "[\(turn.reply)]")
            }
        }
        let isFirstTurn = tutorThread.isEmpty
        // Cross-day topic memory: prior threads' extracted tags get
        // injected so the opening turn doesn't keep re-pitching the
        // same things. See TopicExtractor for how the tag list gets
        // populated (lazy, background, one LLM call per closed thread).
        let recentTopics = ChatStore.shared.recentTopics()
        if isFirstTurn {
            // Best moment to backfill missing topics on closed
            // threads — user just opened the popup so they'll
            // naturally wait a beat for our opening turn anyway,
            // and we want the LLM to have the freshest possible
            // "already discussed" list. Backgrounded — doesn't
            // block the prompt build below.
            TopicExtractor.extractPendingInBackground()
        }
        // Onboarding chat (launched from Welcome step 3) forces tool
        // calls ON regardless of the user's toggle — the whole point
        // of this chat is to collect setup answers and emit
        // `set_setting` calls. The prompt also gets the onboarding
        // flag so TutorPrompt can switch to its scripted setup
        // script instead of free conversation.
        let prompt = TutorPrompt.build(
            history: history,
            targetLanguage: target,
            nativeLanguage: native,
            userContextBlock: userContext,
            isFirstTurn: isFirstTurn,
            proactive: isFirstTurn && proactive,
            recentTopics: recentTopics,
            allowToolCalls: chatAllowSettingsChanges || onboarding,
            onboarding: onboarding,
            practiceItems: practiceItems,
            practiceAwaitingAdvance: practiceAwaitingAdvance
        )

        let raw: String
        do {
            raw = try await Self.withChatTimeout(seconds: 90) { @MainActor in
                var local = ""
                try await UsageContext.$mode.withValue(.chat) {
                    for try await chunk in provider.chatCompletionStream(prompt: prompt) {
                        local = chunk
                    }
                }
                return local
            }
        } catch is ChatTimeoutError {
            tutorStatus = .failed("The response stalled. Tap Retry.")
            return
        } catch {
            // A newer Send superseded this turn (SwiftUI cancelled it when the
            // run-counter task id changed) — don't clobber the new run's status.
            if Task.isCancelled { return }
            tutorStatus = .failed(error.localizedDescription)
            return
        }
        if Task.isCancelled { return }
        Self.dbg("tutor raw=\(raw.prefix(800))")

        guard let parsed = TutorPrompt.parse(raw) else {
            tutorStatus = .failed("Couldn't parse the tutor's reply. Tap Retry.")
            return
        }
        Self.dbg("tutor parsed — reply=\(parsed.reply.count)chars toolCalls=\(parsed.toolCalls.count)")
        // Validate at most one tool call. `set_setting` is the only
        // tool today; anything else gets rejected on the spot so the
        // LLM is told (via system turn next round) to use the right
        // name. Validation also catches blocked / unknown / invalid
        // settings so the user never sees a Confirm card for a
        // change that wouldn't apply.
        let resolvedToolCall = Self.resolveToolCall(parsed.toolCalls.first)
        let newTurn = TutorTurn(
            role: .tutor,
            reply: parsed.reply,
            correctedText: parsed.correctedText,
            correctionNote: parsed.correctionNote,
            toolCall: resolvedToolCall
        )
        tutorThread.append(newTurn)
        persistTutorTurn(newTurn)
        // Practice session — the app drives presentation, so the item under
        // judgment is always the FRONT of the queue; the model only supplies
        // the ✓/✗ verdict. The verdict also feeds the spaced-repetition
        // schedule (✓ → longer interval, ✗ → back in ~a day). A PASS resolves
        // the item and drops it from the queue; a MISS recycles it to the
        // BOTTOM so it comes back around later this session. We then present
        // the new front card (again, no LLM). A turn with no verdict (e.g. the
        // user asked a question instead of attempting) leaves the queue as-is
        // so the same card stays up.
        if !practiceItems.isEmpty, !practiceAwaitingAdvance,
           let verdict = parsed.practiceOutcomes.first,
           let front = practiceQueue.first {
            PracticeStore.shared.recordOutcome(
                eventID: practiceItems[front].eventID, correct: verdict.correct)
            Self.dbg("practice outcome — item \(front + 1) correct=\(verdict.correct) queue=\(practiceQueue)")
            practiceQueue.removeFirst()
            if !verdict.correct {
                // Missed — send it to the bottom to re-attempt later.
                practiceQueue.append(front)
            }
            if practiceQueue.isEmpty {
                // Queue cleared — every item answered correctly. The model
                // can't see the queue, so the app posts the wrap-up itself.
                tutorThread.append(TutorTurn(
                    role: .tutor,
                    reply: "All done — you cleared every practice item. Nice work! 🎉".t))
            } else {
                // Don't jump straight to the next card. Pause on a "Next"
                // button so the user can ask follow-ups about what they just
                // did; advancePractice() presents the next scenario on tap.
                // While paused the prompt switches to "between items" mode and
                // this block is gated off (no judging), so questions just get
                // answered.
                practiceAwaitingAdvance = true
            }
        }
        // If the tool call resolved as immediately rejected (unknown
        // / blocked / invalid), append a system turn so the LLM sees
        // the rejection on the next round and doesn't loop.
        if let call = resolvedToolCall, case .rejected = call.outcome,
           let reason = call.rejectionReason {
            appendSystemTurn("Tool call `\(call.name)` rejected: \(reason)")
        }
        tutorStatus = .ready
        // Auto-approve: if the user has the toggle on and the call
        // resolved as `.pending` (i.e. validator passed), confirm it
        // automatically. Small delay so the card is visible briefly
        // before flipping to the applied state — gives the user a
        // visible record of what was confirmed on their behalf.
        //
        // EXCLUDES `open_settings_tab` — that tool's whole purpose is
        // to invite a deliberate user tap (the big tap-to-open card
        // used in onboarding step 8 and elsewhere). Auto-confirming
        // would flash the card for 0.35s and then yank the user to
        // Settings before they could read what's about to happen.
        // The set_setting auto-approve covers the values-change
        // friction, which is the actual ask behind the toggle.
        if chatAutoApproveTools, let call = resolvedToolCall,
           case .pending = call.outcome,
           call.name != "open_settings_tab" {
            let pendingTurnID = newTurn.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                confirmToolCall(on: pendingTurnID)
            }
        }
        // Same in-dialog extraction trigger used by polish/explain
        // chats. Respects the user's mode toggle + cooldown.
        triggerMemoryExtractionIfApplicable()
    }

    private func runPolish() async {
        guard let provider = LLMRegistry.current() else {
            polishStatus = .failed("No LLM provider configured.")
            return
        }
        let outputLanguage = polishTargetLanguage()
        targetLang = outputLanguage
        polishStatus = .working
        polishResult = .empty
        polishProviderName = provider.displayName

        // Mode = proofread when source language ≈ output language (e.g. en source +
        // en target → "fix my English"); otherwise = variants (cross-language).
        let detectedRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
        let outputRoot = outputLanguage.split(separator: "-").first.map(String.init)
        let native = userNativeLanguage()
        // Skip back-translation when native == output (would be a no-op).
        let nativeForPrompt: String? = (native == outputLanguage) ? nil : native
        let mode: PolishMode = (detectedRoot != nil && detectedRoot == outputRoot)
            ? .proofreadAndPolish(target: outputLanguage, nativeLanguage: nativeForPrompt)
            : .variants(target: outputLanguage, nativeLanguage: nativeForPrompt)

        Self.dbg("polish begin — text='\(sourceText)' target=\(outputLanguage) native=\(nativeForPrompt ?? "(none)") provider=\(provider.id) mode=\(mode)")
        do {
            // Stream the **raw** text via chatCompletionStream — the same
            // transport Explain uses — and only parse the JSON once the stream
            // finishes. Why not the structured polishStream? Polish output is
            // JSON, so the partial parser yields nothing useful until the
            // first variant text appears, leading to a perceived "stuck" beat.
            // Showing raw text in the terminal block gives instant feedback;
            // the structured cards take over at the end.
            polishRawText = ""
            // Lazy bootstrap: if the user got here without going through
            // Settings → Polish output language (where pre-warm runs),
            // we fire the same one-shot LLM call now so this polish
            // ships with a real suggestion list. No-op once the cache
            // is warm; silent on failure (prompt falls back to the
            // "no suggestions" branch).
            if PolishCategoryBootstrap.cached(for: outputLanguage) == nil {
                _ = await PolishCategoryBootstrap.bootstrap(for: outputLanguage)
            }
            let prompt = PolishPrompt.build(text: sourceText, mode: mode)
            try await UsageContext.$mode.withValue(.polish) {
                for try await accumulated in provider.chatCompletionStream(prompt: prompt) {
                    polishRawText = accumulated
                }
            }
            polishResult = PolishResult.parse(polishRawText)
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

            // Detect a parse-failure fallback: the LLM returned text that
            // didn't conform to our JSON schema, so the parser surfaced it
            // as a single fake variant. Treat this as a failure so the user
            // gets the retry icon — re-running often produces a parseable
            // response since LLM output is non-deterministic.
            if polishResult.isFallback {
                Self.dbg("polish — parser returned fallback, surfacing as failure for retry")
                polishStatus = .failed("Couldn't parse the model's response. The output may be malformed JSON.")
                return
            }

            polishStatus = .ready
            Self.dbg("polish ok — variants=\(polishResult.variants.count) issues=\(polishResult.issues.count) in \(elapsedMs)ms")

            // Record the polish run + categories of the issues the LLM
            // flagged so the Memory tab can surface recurring mistake types.
            // Only the category is persisted — the user's literal phrasing
            // (`original`) stays in the popup but never on disk.
            do {
                let issueSnapshots = polishResult.issues
                    .compactMap { PolishIssueSnapshot(category: $0.category) }
                // Full snapshot persists variants + per-issue category/original/
                // explanation so the Memory click-through can rebuild the polish
                // window verbatim. Aggregate `issues` field above is kept for
                // backwards compatibility with old "Common mistake types" rollups.
                let snapshot = PolishResultSnapshot(
                    variants: polishResult.variants.map {
                        .init(text: $0.text, backTranslation: $0.backTranslation)
                    },
                    issues: polishResult.issues.map {
                        .init(category: $0.category, original: $0.original, explanation: $0.explanation)
                    }
                )
                // Record (or, after Regenerate, replace) this polish run in
                // History so it reflects the latest answer, not a duplicate.
                recordOrUpdateEvent { id in
                    MemoryEvent(
                        kind: .polish,
                        sourceText: sourceText,
                        sourceLang: detectedSource?.rawValue,
                        targetLang: outputLanguage,
                        result: polishResult.variants.first?.text,
                        issues: issueSnapshots.isEmpty ? nil : issueSnapshots,
                        polishSnapshot: snapshot,
                        id: id
                    )
                }
            }
        } catch {
            Self.dbg("polish FAIL — err=\(error.localizedDescription)")
            polishStatus = .failed(error.localizedDescription)
        }
    }

    /// User's saved native language (from the Profile tab). Empty defaults to the
    /// system locale, falling back to English.
    private func userNativeLanguage() -> String {
        let raw = UserDefaults.standard.string(forKey: "glotty.user.nativeLanguage")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Post-dismiss hook into `MemoryExtractor`. Snapshots the chat
    /// thread, builds the right `Source` for the popup mode, and
    /// fires the extractor as a detached task so dismissal isn't
    /// blocked by an LLM call. No-ops for translate / chat modes
    /// (they don't have a discussion thread) and for empty threads.
    @MainActor
    private func triggerMemoryExtractionIfApplicable(manual: Bool = false) {
        let modeStr = String(describing: mode)
        let turnCount = mode == .chat ? tutorThread.count : polishChatThread.count
        Self.dbg("triggerMemoryExtraction ENTER — popupMode=\(modeStr) turns=\(turnCount) eventID=\(polishEventID?.uuidString ?? "nil") manual=\(manual)")
        guard mode == .polish || mode == .explain || mode == .chat else {
            Self.dbg("triggerMemoryExtraction SKIP — mode not polish/explain/chat")
            return
        }
        let snapshot: [PolishChatTurnSnapshot]
        let source: MemoryExtractor.Source
        switch mode {
        case .polish:
            guard !polishChatThread.isEmpty else {
                Self.dbg("triggerMemoryExtraction SKIP — empty polish thread")
                return
            }
            snapshot = polishChatThread.map {
                PolishChatTurnSnapshot(role: $0.role == .user ? .user : .assistant, text: $0.text)
            }
            source = .polish(sourceText: sourceText,
                             topVariant: polishResult.variants.first?.text)
        case .explain:
            guard !polishChatThread.isEmpty else {
                Self.dbg("triggerMemoryExtraction SKIP — empty explain thread")
                return
            }
            snapshot = polishChatThread.map {
                PolishChatTurnSnapshot(role: $0.role == .user ? .user : .assistant, text: $0.text)
            }
            source = .explain(sourceText: sourceText, explanation: explainText)
        case .chat:
            // Tutor session — pull from tutorThread. Only the user's
            // and tutor's textual exchange is relevant to memory
            // extraction; corrections are tutor scaffolding, not
            // user-volunteered signal, so skip them.
            guard !tutorThread.isEmpty else {
                Self.dbg("triggerMemoryExtraction SKIP — empty tutor thread")
                return
            }
            snapshot = tutorThread.map {
                PolishChatTurnSnapshot(role: $0.role == .user ? .user : .assistant, text: $0.reply)
            }
            source = .tutor
        default:
            return
        }
        // For chat mode, the source event id is today's chat thread
        // id (so suggestion cards filter to this conversation). For
        // polish/explain it stays the original `polishEventID`.
        let eventID: UUID? = (mode == .chat) ? tutorThreadID : polishEventID
        Self.dbg("triggerMemoryExtraction FIRE — dispatching to MemoryExtractor.extract")
        Task { @MainActor in
            await MemoryExtractor.extract(
                thread: snapshot,
                source: source,
                sourceEventID: eventID,
                trigger: manual ? .manual : .auto
            )
        }
    }

    private func polishTargetLanguage() -> String {
        let savedPolish = UserDefaults.standard.string(forKey: "glotty.polishLang")
        return (savedPolish?.isEmpty == false ? savedPolish! : "en")
    }

    /// Language the tutor chat replies in. Honors the per-user override
    /// set in Settings → Chat or the chat composer picker
    /// (`glotty.chat.tutorLanguage`); empty / unset falls back to the
    /// system language. Chat is conversational reading, so the user's
    /// most-comfortable language is the right default.
    private func tutorReplyLanguage() -> String {
        chatTutorLanguage.isEmpty ? LanguageOptions.systemDefault() : chatTutorLanguage
    }

    /// Options shown in the polish-chat "Reply in" picker. Mirrors the
    /// global Polish output language list in Settings so the two stay
    /// in sync — change `PolishPrompt.outputLanguageOptions` to add or
    /// remove languages everywhere at once. Returns `(id, name)` tuples
    /// so the menu can show full names ("Chinese (Simplified)") while
    /// the selection binds to BCP-47 codes ("zh-Hans").
    func chatLanguageOptions() -> [(id: String, name: String)] {
        PolishPrompt.outputLanguageOptions
    }

    /// Default chat reply language: the user's native language if it's
    /// in the picker's supported list, otherwise the polish target,
    /// finally "en" as a guaranteed-supported floor. We prefer native
    /// because chat questions are usually meta ("explain this", "why
    /// did you suggest X?") — answers in the user's own language are
    /// easier to read. The user can switch to the target language via
    /// the header picker if they want to practice instead.
    private func defaultChatLanguage() -> String {
        let supported = Set(PolishPrompt.outputLanguageOptions.map { $0.id.lowercased() })
        let native = userNativeLanguage()
        if supported.contains(native.lowercased()) { return native }
        let target = polishTargetLanguage()
        if supported.contains(target.lowercased()) { return target }
        return "en"
    }

    /// Apple's `Translation` framework sometimes returns multi-line output even
    /// for single-line input (especially when the source selection contained
    /// line breaks from a wrapped paragraph). Collapse any whitespace run —
    /// `\r\n`, `\n`, `\r`, tab, multiple spaces — into a single space so the
    /// Translation row stays a clean inline string.
    static func flattenWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Render `raw` as Markdown — bold (`**…**`), italic (`*…*`), inline
    /// code (`` `…` ``), and links all show up styled instead of as
    /// literal asterisks/backticks. Uses `inlineOnlyPreservingWhitespace`
    /// so paragraph breaks and indentation in chat replies stay intact;
    /// block-level constructs (headers, lists, fenced code blocks) render
    /// inline rather than as separate visual blocks, which is fine for the
    /// short prose answers Glotty's chat / Q&A returns. Falls back to a
    /// plain Text if parsing fails — defensive only; the
    /// `returnPartiallyParsedIfPossible` policy means even mid-stream
    /// fragments parse successfully.
    static func markdownText(_ raw: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let attr = try? AttributedString(markdown: raw, options: options) {
            return Text(attr)
        }
        return Text(raw)
    }

    private static func dbg(_ msg: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.popup, msg, file: file, line: line)
    }
}

struct PhoneticEntry: Hashable {
    let label: String?       // "BrE", "AmE", or nil for single-variant / transliteration
    let value: String        // e.g. "/ˈʃɛdjuːl/" or "fān yì"
    let voiceLocale: String? // "en-GB", "en-US", etc. — drives the speak button voice
}

/// Best-effort pronunciation:
/// - CJK: transliterate via CFStringTransform (pinyin / romaji / hangul-latin).
/// - Latin scripts: parse IPA from the macOS Dictionary entry (DCSCopyTextDefinition).
enum Pronunciation {
    static func pronounce(_ text: String, language: NLLanguage?) -> [PhoneticEntry] {
        if let translit = transliterate(text, from: language) {
            return [PhoneticEntry(label: nil, value: translit, voiceLocale: language?.rawValue)]
        }
        return ipa(for: text)
    }

    static func transliterate(_ text: String, from lang: NLLanguage?) -> String? {
        guard let lang else { return nil }
        let transform: CFString?
        switch lang {
        case .simplifiedChinese, .traditionalChinese:
            transform = kCFStringTransformMandarinLatin
        case .japanese, .korean:
            transform = kCFStringTransformToLatin
        default:
            transform = nil
        }
        guard let transform else { return nil }

        let mut = NSMutableString(string: text)
        guard CFStringTransform(mut, nil, transform, false) else { return nil }
        let result = mut as String
        return result == text ? nil : result
    }

    /// Look up the macOS Dictionary entry for `text` and parse out its IPA block.
    /// The actual parsing is in `parseDictionaryDefinition` so it can be unit-tested
    /// without hitting `DCSCopyTextDefinition` (which depends on the user's enabled
    /// dictionaries and is awkward to mock).
    static func ipa(for text: String) -> [PhoneticEntry] {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfText, range) else { return [] }
        let definition = unmanaged.takeRetainedValue() as String
        return parseDictionaryDefinition(definition)
    }

    /// Parse the first `|…|` block out of a dictionary definition string.
    /// Two formats are supported:
    ///   1. **Dialect-labeled**: `BrE x, y, AmE z, w` (Chinese-English bilingual dicts).
    ///      Returns the FIRST IPA per dialect.
    ///   2. **Comma-separated alternates**: `ˈʃɛdjuːl, ˈskɛdʒuːl` (Oxford-style).
    ///      Treats first as BrE, second as AmE. Single-variant returns one unlabeled.
    static func parseDictionaryDefinition(_ definition: String) -> [PhoneticEntry] {
        guard let first = definition.firstIndex(of: "|") else { return [] }
        let afterFirst = definition.index(after: first)
        guard let second = definition[afterFirst...].firstIndex(of: "|") else { return [] }

        let block = String(definition[afterFirst..<second])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if block.range(of: #"\bBrE\b"#, options: .regularExpression) != nil ||
           block.range(of: #"\bAmE\b"#, options: .regularExpression) != nil {
            return parseDialectLabeledBlock(block)
        }
        return parseAlternatesBlock(block)
    }

    /// "BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ" → first BrE + first AmE.
    static func parseDialectLabeledBlock(_ block: String) -> [PhoneticEntry] {
        var bre: String?
        var ame: String?
        var current: String? // "BrE" | "AmE" | nil

        for raw in block.split(separator: ",") {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("BrE ") {
                current = "BrE"
                token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if token.hasPrefix("AmE ") {
                current = "AmE"
                token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !token.isEmpty else { continue }
            switch current {
            case "BrE" where bre == nil: bre = token
            case "AmE" where ame == nil: ame = token
            default: break
            }
        }

        var entries: [PhoneticEntry] = []
        if let bre {
            entries.append(PhoneticEntry(label: "BrE", value: "/\(bre)/", voiceLocale: "en-GB"))
        }
        if let ame {
            entries.append(PhoneticEntry(label: "AmE", value: "/\(ame)/", voiceLocale: "en-US"))
        }
        return entries
    }

    /// Oxford-style: `ˈʃɛdjuːl, ˈskɛdʒuːl` → BrE+AmE; single variant → unlabeled.
    static func parseAlternatesBlock(_ block: String) -> [PhoneticEntry] {
        let raw = block
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let unique = raw.filter { variant in
            let key = variant
                .components(separatedBy: .whitespacesAndNewlines).joined()
                .precomposedStringWithCanonicalMapping
            return seen.insert(key).inserted
        }

        let capped = Array(unique.prefix(2))

        switch capped.count {
        case 0: return []
        case 1:
            return [PhoneticEntry(label: nil, value: "/\(capped[0])/", voiceLocale: nil)]
        default:
            return [
                PhoneticEntry(label: "BrE", value: "/\(capped[0])/", voiceLocale: "en-GB"),
                PhoneticEntry(label: "AmE", value: "/\(capped[1])/", voiceLocale: "en-US"),
            ]
        }
    }
}

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    /// Speak `text`. Uses ElevenLabs cloud TTS when the user has configured it
    /// (Settings → Voice); otherwise — or if the ElevenLabs request fails —
    /// the on-device system voice, so it always works offline and out of the box.
    func speak(_ text: String, language: String?) {
        if ElevenLabsTTS.isConfigured {
            synthesizer.stopSpeaking(at: .immediate)
            ElevenLabsTTS.shared.speak(text) { [weak self] in
                self?.speakSystem(text, language: language)
            }
        } else {
            // Enabled but no key saved → the user expects the cloud voice and
            // would otherwise silently get the system one. Say so once.
            if UserDefaults.standard.bool(forKey: ElevenLabsTTS.enabledDefaultsKey) {
                Task { @MainActor in
                    HUDController.shared.toast(
                        String(localized: "ElevenLabs is on but no API key is saved — using the system voice. Add your key in Settings → Voice."),
                        systemImage: "key", duration: 4)
                }
            }
            speakSystem(text, language: language)
        }
    }

    private func speakSystem(_ text: String, language: String?) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utt = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) {
            utt.voice = voice
        }
        synthesizer.speak(utt)
    }
}
