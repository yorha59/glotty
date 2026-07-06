import AppKit
import SwiftUI

/// String lookup that explicitly uses the user's macOS preferred
/// language, ignoring Glotty's own UI-language override (Settings
/// → Profile → Glotty's UI language). The Welcome window uses this
/// because:
///
///   - First-time users may not realise Glotty even HAS a UI-language
///     picker, so the welcome should match the language they see
///     elsewhere on the OS.
///   - Devs / curious users who re-open Welcome after switching
///     Glotty's UI language to something else still see Welcome in
///     their OS language — predictable behavior.
///
/// We bypass `Bundle.localizedString` (which the localization
/// swizzle wraps + routes through Glotty's LLM-cache layer keyed by
/// AppleLanguages) by calling `glotty_localizedString` directly —
/// after method exchange that's the un-swizzled Foundation
/// implementation. The locale comes from the matching `.lproj`
/// bundle, not from AppleLanguages.
@MainActor
private enum OSLocalizer {
    /// Bundle for the OS-preferred language. Cached on first access.
    /// Returns nil when no matching lproj is present (e.g. the OS
    /// is in a language we don't ship translations for); the
    /// fallback path resolves via `Bundle.main` which falls back
    /// to the source language (English).
    ///
    /// We read OS preferences via `CFPreferencesCopyAppValue` with
    /// `kCFPreferencesAnyApplication` — that's the true global
    /// setting, bypassing Glotty's own per-app `AppleLanguages`
    /// override. `Locale.preferredLanguages` mixes those layers and
    /// would happily return `en` when the user had overridden
    /// Glotty's UI language but the OS itself is `zh-Hans`.
    static let bundle: Bundle? = {
        let preferred = osPreferredLanguage()
        // Try the full identifier first, then progressively shorter
        // prefixes (`zh-Hans-CN` → `zh-Hans` → `zh`) so a fully-
        // qualified OS locale still finds a matching lproj.
        let parts = preferred.split(separator: "-")
        for n in stride(from: parts.count, through: 1, by: -1) {
            let candidate = parts.prefix(n).joined(separator: "-")
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let b = Bundle(path: path) {
                return b
            }
        }
        return nil
    }()

    /// Read the OS-wide first preferred language, skipping any
    /// per-app `AppleLanguages` override. Returns `"en"` when the
    /// global value is missing or malformed.
    static func osPreferredLanguage() -> String {
        let value = CFPreferencesCopyAppValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication
        )
        if let arr = value as? [String], let first = arr.first {
            return first
        }
        return "en"
    }

    /// Two-segment BCP-47 prefix Glotty's tutorial content is keyed
    /// by (`"zh-Hans-CN"` → `"zh-Hans"`, `"en-US"` → `"en"`). Drops
    /// region tags but keeps the script. Used by
    /// `TutorialPopupContent` to pick the right per-language sample.
    static func osPreferredContentKey() -> String {
        osPreferredLanguage().split(separator: "-").prefix(2).joined(separator: "-")
    }

    /// Look up `key` in the OS-preferred language. Resolution order:
    ///
    /// 1. Record the key as encountered so Settings → System →
    ///    Refresh translations covers Welcome strings alongside the
    ///    rest of the UI.
    /// 2. Return the source verbatim for English-OS users (no work).
    /// 3. LLM cache hit (per-OS-language) — fast path for strings the
    ///    user previously triggered a refresh on.
    /// 4. Bundle lookup against the matching `.lproj`. If the build
    ///    shipped a translation, use it.
    /// 5. Otherwise queue the key for on-demand LLM fill (LocaleCache
    ///    debounces a batch translation) and return the source — the
    ///    Welcome view's `.localizationAware()` rebuilds when the
    ///    fill notification fires.
    static func string(_ key: String) -> String {
        let lang = osPreferredContentKey()

        // Always record — `Refresh translations` reads the encountered
        // set, so this is how Welcome strings get included in the
        // user-triggered re-translation pass.
        LocalizationCache.shared.recordEncountered(key)

        // English source language doesn't need translation.
        guard lang != "en", !lang.hasPrefix("en-") else {
            return key
        }

        // 1. LLM cache.
        if let cached = LocalizationCache.shared.translation(for: key, language: lang) {
            return cached
        }

        // 2. Shipped lproj catalog.
        let target = bundle ?? Bundle.main
        let resolved = target.glotty_localizedString(forKey: key, value: key, table: nil)
        if resolved != key {
            return resolved
        }

        // 3. Queue for on-demand LLM fill. Returning the source key
        //    means the user sees English until the fill lands; the
        //    `.localizationAware()` modifier on WelcomeView reruns
        //    the body once the cache update notification fires.
        LocalizationCache.shared.queueMissingForTranslation(key, language: lang)
        return resolved
    }
}

/// Interactive first-run walkthrough. Shown once on the very first launch
/// (gated by the `welcomeShown` UserDefaults flag) and re-openable later
/// from the menu-bar mascot menu. Stepped layout: welcome → hotkey demo →
/// provider setup → done.
@MainActor
final class WelcomeWindowController: ObservableObject {
    static let shared = WelcomeWindowController()

    /// Which demo modes the user has triggered the Fn chord for and
    /// thus "revealed" the result inline. SwiftUI body observes
    /// this via `@ObservedObject` and re-renders the corresponding
    /// demo step to show the result card under the source.
    @Published var revealedDemos: Set<DemoMode> = []

    enum DemoMode: Hashable {
        case translate, polish, explain
    }

    /// Set to true when the user finishes or dismisses the walkthrough.
    /// Reading is the cheapest possible "has this user seen onboarding"
    /// signal — preferred over schema-guessing against MemoryStore.
    static let userDefaultsKey = "glotty.welcomeShown"
    /// Set when we relaunch into regular mode to show Welcome; the fresh
    /// instance reopens it at launch. See SettingsWindowController.
    static let reopenWelcomeKey = "glotty.welcome.reopenOnLaunch"

    private var window: NSWindow?
    /// Hosting controller (typed-erased to `NSViewController` so we
    /// don't leak `WelcomeView`'s private struct into the
    /// controller's public storage). Retained alongside the window
    /// since `window.contentViewController` already holds it, but
    /// having a named field documents the intent.
    private var host: NSViewController?

    /// True while the Welcome window is on screen. The Fn-leader
    /// hotkey checks this and routes to `showTutorialPopup(for:)`
    /// instead of running the real translate / polish / explain
    /// flow — those flows depend on user config (provider, polish
    /// target, dictionary selection) which the user hasn't set up
    /// yet on first launch.
    var isShowing: Bool { window != nil }

    /// Reveal the pre-calculated demo result on the current Welcome
    /// step. Called from `AppDelegate.handleFire` whenever a Fn-leader
    /// chord fires while Welcome is on screen. No popup opens — the
    /// result appears inline on the same Welcome page (under the
    /// source card), so the user stays in the onboarding flow
    /// instead of getting yanked into a separate window.
    func revealResult(for mode: PopupMode) {
        switch mode {
        case .translate: revealedDemos.insert(.translate)
        case .polish:    revealedDemos.insert(.polish)
        case .explain:   revealedDemos.insert(.explain)
        case .chat:      break   // chat tutorial is step 5's handoff button
        }
    }

    /// Show the walkthrough on first run only. Cheap no-op if the flag is
    /// set. Safe to call from `applicationDidFinishLaunching`; defers to
    /// the next runloop tick to avoid the SwiftUI App-scene init deadlock
    /// that bit the permissions opener.
    func showIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else { return }
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    /// Force-show the walkthrough — used by the menu-bar "Show welcome…"
    /// item so curious users can revisit it.
    func show() {
        // Like Settings: an agent process can't slide a foreign full-screen
        // app away (no home Space), so relaunch into regular mode and
        // reopen Welcome there. Once regular, fall through and show normally.
        if NSApp.activationPolicy() != .regular {
            SettingsWindowController.relaunchIntoRegularMode(reopenKey: Self.reopenWelcomeKey)
            return
        }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = WelcomeView(
            onClose: { [weak self] in self?.dismiss(markShown: true) },
            onStartOnboardingChat: { [weak self] in
                // Step 5 hand-off: close Welcome (marking it done) and
                // hand the user over to the chat popup in onboarding
                // mode. Chat takes over from here — asks setup
                // questions and emits `set_setting` tool calls to
                // record the answers.
                self?.dismiss(markShown: true)
                Task { @MainActor in
                    PopupController.shared.show(sourceText: "",
                                                mode: .chat,
                                                onboarding: true)
                }
            }
        )
        let host = NSHostingController(rootView: view)
        // Do NOT set `host.sizingOptions = [.preferredContentSize]`.
        // Tried it twice: SwiftUI's NSHostingView resyncs the window
        // size inside the Core Animation display-cycle observer, and
        // when a step transition changes the content's intrinsic
        // height (especially around the polish demo's revealed
        // result), AppKit asserts:
        //     NSGenericException in -[NSWindow _postWindowNeedsUpdateConstraints]
        // Reproduced on macOS 26.5 — the "fixed in macOS 26" claim
        // in the prior comment was wrong; three crash reports
        // confirmed it on 2026-05-31. Stay with a fixed window size
        // generous enough to hold the tallest step; accept a little
        // wasted space on the smaller intro steps as the trade-off.
        self.host = host

        let w = NSWindow(contentViewController: host)
        w.title = OSLocalizer.string("Welcome to Glotty")
        // `.resizable` is the fallback for the screen-clamp below: if the
        // auto-chosen size still doesn't suit the user's display, they can
        // drag any edge to resize. The ScrollView + pinned footer keep the
        // layout intact at any size.
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        // Fixed size large enough for the tallest step (provider form +
        // feature demos with revealed result cards). If a future step
        // needs more vertical room, bump this — don't reach for
        // preferredContentSize sync again without a verified fix.
        //
        // CLAMP TO SCREEN: 700pt + title bar is taller than the usable
        // height of small displays (older 13"/11" Intel laptops, big
        // Dock, no "More Space" scaling). When that happened the footer
        // — Back/Next — fell below the screen edge with no way to reach
        // it. The footer is pinned outside the ScrollView in
        // `WelcomeView`, so capping the window to the screen keeps
        // Back/Next on-screen and the ScrollView absorbs the overflow
        // on short displays.
        w.setContentSizeClampedToScreen(NSSize(width: 520, height: 700))
        w.contentMinSize = NSSize(width: 420, height: 320)
        w.center()
        // NO `.moveToActiveSpace`: in regular mode (restart) Welcome lives
        // on its own home Space and macOS slides a foreign full-screen app
        // away to it. `.moveToActiveSpace` would instead drag it onto the
        // foreign Space (hover, with input going to the wrong app).
        window = w

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss(markShown: true) }
        }

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func dismiss(markShown: Bool) {
        if markShown {
            UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        }
        window?.orderOut(nil)
        window = nil
        host = nil
        revealedDemos = []
        // Welcome was shown in regular mode (we relaunched into it). Drop
        // back to agent — hide the Dock icon now and clear the launch flag
        // so the next launch is agent. (The onboarding-chat hand-off also
        // needs agent mode for the popup's IME over full-screen.)
        UserDefaults.standard.set(false, forKey: SettingsWindowController.launchRegularKey)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Stepped SwiftUI body. Each step is a small struct holding the title,
/// body, and an optional embedded view (the hotkey grid, the "Open
/// Settings" button). Bottom bar shows page dots + Back/Next so the
/// user can flip through at their own pace.
private struct WelcomeView: View {
    let onClose: () -> Void
    let onStartOnboardingChat: () -> Void

    /// Drives the inline result reveal — when the user presses
    /// Fn → T / P / E while Welcome is up, `AppDelegate.handleFire`
    /// asks the controller to insert into `revealedDemos`, and
    /// SwiftUI re-renders the current demo step with the result
    /// card showing under the source.
    @ObservedObject private var controller = WelcomeWindowController.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var step: Int = 0

    private static let contentWidth: CGFloat = 460

    private var stepCount: Int {
        #if MAS
        7
        #else
        // welcome, permissions, Translate, Refine, Explain, Speak, Correct,
        // AI setup, get-to-know.
        9
        #endif
    }

    /// The inline LLM-provider step, which embeds a Form (tighter spacing).
    private var isLLMStep: Bool {
        #if MAS
        step == 5
        #else
        step == 7
        #endif
    }

    /// Ticks every second while the welcome window is up so the
    /// permissions step re-renders as the user grants access in
    /// System Settings. `isGranted()` is a cheap syscall for AX /
    /// IOHID; refreshing notifications happens in the background
    /// and lands in the cache that the readers see on next render.
    @State private var permissionsTick: Int = 0

    /// Status line under the "Import config" button on step 0. nil
    /// until the user attempts an import; holds an error message if
    /// the import fails (success relaunches, so no success message).
    @State private var importStatus: String?
    /// Disables the import button while an import is mid-flight.
    @State private var importing = false

    /// User's UI-language locale identifier (e.g. "zh-Hans"). Used to
    /// pick the demo translation output in step 1.1 so the example
    /// shows what the user would actually see when they translate
    /// English into their own language.
    private var displayLanguageID: String {
        let raw = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String
        return raw?.split(separator: "-").prefix(2).joined(separator: "-") ?? "en"
    }

    var body: some View {
        // Footer pinned OUTSIDE the ScrollView so Back/Next stay
        // reachable even when the step content is taller than the
        // window — which happens on small displays where the controller
        // had to clamp the window height below 700pt. Previously the
        // footer was the last child of a single non-scrolling VStack, so
        // a window shorter than the content (or a window taller than the
        // screen) pushed Back/Next off the bottom edge with no recovery.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    mascotHeader

                    VStack(alignment: .leading, spacing: titleBodySpacing) {
                        Text(currentTitle)
                            .font(.title2.weight(.semibold))
                        Text(currentBody)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        currentExtra
                            .padding(.top, extraTopPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        // Fill whatever size the window gave us — the controller has
        // already chosen a fixed size that accommodates every step.
        // Letting SwiftUI drive height via `.fixedSize` here caused
        // a mid-display-cycle resize crash; see the controller's
        // `host.sizingOptions` comment.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Onboarding canvas follows the theme: pure white in light mode (the
        // black mascot sits straight on it, no tile), the window background
        // in dark mode (where the mascot picks up a white tile below).
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white)
        // Re-render when `LocalizationCache` lands new translations.
        // OSLocalizer queues missing OS-language translations into
        // the LLM filler; once the filler returns and posts
        // `didUpdateNotification`, this modifier flips an internal
        // id and SwiftUI rebuilds the body. Strings that were
        // showing the English source while the fill was in flight
        // pick up the freshly-cached OS-language translation here.
        .localizationAware()
    }

    // MARK: - Step-aware spacing
    //
    // The LLM provider step (4) embeds a Form inside the welcome
    // window. The default spacing that suits the prose-heavy
    // earlier steps reads as a lot of empty air between the body
    // paragraph and the Form's first row. Tightening it on step 4
    // brings the config flush with the explanation above.

    private var titleBodySpacing: CGFloat {
        isLLMStep ? 5 : 10
    }

    private var extraTopPadding: CGFloat {
        isLLMStep ? 0 : 4
    }

    // MARK: - Header

    /// Big mascot at the top — uses the same status-bar icon asset as the
    /// menu so the user starts to associate the face with Glotty before
    /// they ever see the live mascot.
    private var mascotHeader: some View {
        HStack {
            Spacer()
            Group {
                if let mascot = Self.mascotArtwork {
                    Image(nsImage: mascot)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                }
            }
            // Black-on-transparent artwork. In light mode it sits straight on
            // the white canvas (no tile). In dark mode the black body would
            // vanish, so seat it on a white squircle.
            .frame(width: colorScheme == .dark ? 60 : 72,
                   height: colorScheme == .dark ? 60 : 72)
            .padding(colorScheme == .dark ? 11 : 0)
            .background {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white)
                }
            }
            Spacer()
        }
    }

    /// The mascot as its real black+white artwork rather than a tinted
    /// template mask. `StatusItemIcon` is flagged `template-rendering-intent
    /// = template` for the menu bar, which makes SwiftUI flatten it to a
    /// single-colour silhouette (losing the eyes / fangs and reading as a
    /// soft blob). We copy the cached image — never mutate the shared named
    /// instance the menu bar relies on — and clear the template flag.
    private static let mascotArtwork: NSImage? = {
        guard let copy = NSImage(named: "StatusItemIcon")?.copy() as? NSImage else { return nil }
        copy.isTemplate = false
        return copy
    }()

    // MARK: - Step content

    // Note: each title/body literal is passed inline to
    // OSLocalizer.string("…") (rather than via a `key` variable) so
    // scripts/extract-strings.sh can find it and add it to the
    // bundled catalog — otherwise these welcome strings only get
    // translated by the runtime LLM fill, which a fresh install
    // (no cache, maybe no API key) can't do, leaving them English.
    private var currentTitle: String {
        switch step {
        case 0: return OSLocalizer.string("Welcome to Glotty")
        case 1:
            #if MAS
            // MAS has no permissions step — the App Store build triggers via
            // the Services menu / shortcuts, which need no TCC grants.
            return OSLocalizer.string("1. How Glotty works")
            #else
            return OSLocalizer.string("1. Grant permissions")
            #endif
        case 2:
            #if MAS
            return OSLocalizer.string("2.1 Translate (⌘⌥T)")
            #else
            return OSLocalizer.string("2.1 Translate (Fn → T)")
            #endif
        // Use "Refine" instead of "Polish" as the verb here. Earlier
        // "Polish" was being preserved by the LLM as a proper-noun
        // brand name (and could also read as "Polish, the language"),
        // so even "Polish your draft" came back as "用 Polish 润色草稿"
        // — Chinese with the English word awkwardly preserved.
        // "Refine your draft" is unambiguously a verb-noun phrase and
        // translates cleanly to "润色你的草稿". The user-facing action
        // chord (Fn → P / ⌘⌥P) still points at the same Polish feature.
        case 3:
            #if MAS
            return OSLocalizer.string("2.2 Refine your draft (⌘⌥P)")
            #else
            return OSLocalizer.string("2.2 Refine your draft (Fn → P)")
            #endif
        case 4:
            #if MAS
            return OSLocalizer.string("2.3 Explain a word or phrase (⌘⌥E)")
            #else
            return OSLocalizer.string("2.3 Explain a word or phrase (Fn → E)")
            #endif
        case 5:
            #if MAS
            return OSLocalizer.string("3. Set up your AI provider")
            #else
            return OSLocalizer.string("2.4 Hear it aloud (Fn → V)")
            #endif
        #if !MAS
        case 6:
            return OSLocalizer.string("2.5 Correct spelling (Fn → R)")
        case 7:
            return OSLocalizer.string("3. Set up your AI provider")
        #endif
        default: return OSLocalizer.string("4. Let's get to know each other")
        }
    }

    private var currentBody: String {
        switch step {
        case 0:
            #if MAS
            return OSLocalizer.string("Glotty is a language tutor that lives in your menu bar. We'll tour the three core actions, set up an LLM, and chat briefly so I know how to address you.")
            #else
            return OSLocalizer.string("Glotty is a language tutor that lives in your menu bar. We'll start with the permissions Glotty needs, then tour the three core actions, set up an LLM, and chat briefly so I know how to address you.")
            #endif
        case 1:
            #if MAS
            return OSLocalizer.string("Glotty adds Translate, Explain, and Polish to the system Services menu — no special permissions needed. Select text in any app, then right-click → Services, or press the matching ⌘⌥ shortcut. Chat opens anywhere with ⌘⌥C.")
            #else
            return OSLocalizer.string("Glotty reads the text you've selected, listens for the Fn-leader chord, and sends you the occasional chat reminder. The OS keeps these behind dedicated permission switches — grant each one in System Settings and the status here will update automatically.")
            #endif
        case 2:
            #if MAS
            return OSLocalizer.string("Decode foreign text into a chosen language. Select any text, then press ⌘⌥T (or right-click → Services → Translate with Glotty). A popup shows the translation; press Esc to dismiss. Runs locally via Apple's translation — no LLM required.")
            #else
            return OSLocalizer.string("Decode foreign text into a chosen language. Highlight any text, hold Fn, then within 600ms tap T. A popup shows the translation; press Esc to dismiss. Runs locally via Apple's translation — no LLM required.")
            #endif
        case 3:
            #if MAS
            return OSLocalizer.string("Rewrite your own writing in idiomatic form. Select a draft, then press ⌘⌥P. Glotty returns 1–3 polished rewrites plus a list of grammar / word-choice issues. Press Esc to dismiss.")
            #else
            return OSLocalizer.string("Rewrite your own writing in idiomatic form. Highlight a draft, hold Fn, tap P. Glotty returns 1–3 polished rewrites plus a list of grammar / word-choice issues. Press Esc to dismiss.")
            #endif
        case 4:
            #if MAS
            return OSLocalizer.string("Deeper explanation in your native language — meaning, tone, usage, and how it shifts across contexts. Select a word, idiom, or sentence, then press ⌘⌥E. Glotty streams a four-section explanation. Press Esc to dismiss.")
            #else
            return OSLocalizer.string("Deeper explanation in your native language — meaning, tone, usage, and how it shifts across contexts. Highlight a word, idiom, or sentence, hold Fn, tap E. Glotty streams a four-section explanation. Press Esc to dismiss.")
            #endif
        case 5:
            #if MAS
            return OSLocalizer.string("Polish, Explain, and Chat call out to an LLM, so Glotty needs at least one provider configured before they work. Pick a stock provider — OpenAI, Google Gemini, Z.AI, DeepSeek, Kimi — or paste any OpenAI-compatible endpoint and API key. Come back when you're done.")
            #else
            return OSLocalizer.string("Hear any text read aloud — great for checking pronunciation. Highlight a word or sentence, hold Fn, tap V. Glotty reads it with the built-in macOS voice: offline, free, no LLM required. Add an ElevenLabs key in Voice settings for a more natural voice.")
            #endif
        #if !MAS
        case 6:
            return OSLocalizer.string("Fix spelling and typos without leaving your document. Highlight the text, hold Fn, tap R. Glotty replaces it in place with the corrected spelling — no popup. Runs on-device — no LLM required.")
        case 7:
            return OSLocalizer.string("Polish, Explain, and Chat call out to an LLM, so Glotty needs at least one provider configured before they work. Pick a stock provider — OpenAI, Google Gemini, Z.AI, DeepSeek, Kimi — or paste any OpenAI-compatible endpoint and API key. Come back when you're done.")
        #endif
        default:
            return OSLocalizer.string("Last step — Glotty will open a short chat to learn how you'd like to be addressed. Your answers automatically configure the relevant settings; you can change anything later from the menu bar.")
        }
    }

    /// Step-specific embedded content. Step 1 shows the permissions
    /// checklist; the feature steps show pre-prepared input → result demos
    /// so the user understands what each action produces. Translate / Refine
    /// / Explain reveal live on the Fn chord; Speak and Correct are
    /// illustrative (they play audio / replace in place, so there's no popup
    /// to reveal). The last two steps are the LLM-setup form and the
    /// chat-handoff button (see `llmSetupForm` / `getToKnowButton`).
    @ViewBuilder
    private var currentExtra: some View {
        switch step {
        case 0:
            importConfigCard
        case 1:
            #if MAS
            masServicesCard
            #else
            permissionsChecklist
            #endif
        case 2:
            #if MAS
            // No Fn chord on MAS to trigger the live demo, so reveal the
            // pre-baked result as soon as the step appears.
            translateDemo.onAppear { controller.revealedDemos.insert(.translate) }
            #else
            translateDemo
            #endif
        case 3:
            #if MAS
            polishDemo.onAppear { controller.revealedDemos.insert(.polish) }
            #else
            polishDemo
            #endif
        case 4:
            #if MAS
            explainDemo.onAppear { controller.revealedDemos.insert(.explain) }
            #else
            explainDemo
            #endif
        case 5:
            #if MAS
            llmSetupForm
            #else
            // Web: Speak (Fn → V). No live result to reveal (it plays audio),
            // so show an illustrative popup card.
            speakDemo
            #endif
        #if !MAS
        case 6:
            // Web: Correct spelling (Fn → R). Replaces in place with no popup,
            // so this is an illustrative before → after card.
            correctDemo
        case 7:
            llmSetupForm
        #endif
        default:
            getToKnowButton
        }
    }

    /// Inline LLM provider setup embedded in the welcome flow so the user
    /// configures a provider without a detour to Settings.
    ///
    /// `.columns` style (instead of `.grouped`) aligns labels flush to the
    /// leading edge so they sit on the same x coordinate as the step title
    /// above the form.
    private var llmSetupForm: some View {
        Form {
            LanguageModelSettingsSection(showChrome: false)
        }
        .formStyle(.columns)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 320)
    }

    /// Final step's primary action: open the get-to-know chat.
    private var getToKnowButton: some View {
        Button {
            onStartOnboardingChat()
        } label: {
            Label(OSLocalizer.string("Hi, I'm Glotty. Nice to meet you!"),
                  systemImage: "bubble.left.and.text.bubble.right")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Step 0 affordance: returning users who already configured
    /// Glotty on another Mac can restore everything from an encrypted
    /// backup instead of walking the whole onboarding. A successful
    /// import applies the config, marks onboarding done, and relaunches
    /// — so the remaining welcome steps are skipped entirely.
    private var importConfigCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await runImport() }
                } label: {
                    Label(OSLocalizer.string("Import a backup…"),
                          systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .disabled(importing)
                if importing {
                    ProgressView().controlSize(.small)
                }
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(OSLocalizer.string("Already set up Glotty on another Mac? Import its encrypted backup to restore your settings, API keys, memories, and history — then you can skip the rest of this setup."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Run the interactive import. On success the imported config is
    /// already applied (preferences, keychain, stores), so we mark
    /// onboarding complete and relaunch to let UI language / provider
    /// selection / etc. take effect cleanly — which also dismisses the
    /// welcome flow. On failure we surface the message and stay put.
    @MainActor
    private func runImport() async {
        importStatus = nil
        importing = true
        defer { importing = false }
        do {
            guard try await BackupService.importInteractive() != nil else {
                return  // user cancelled the open panel / password / confirm
            }
            // Onboarding is unnecessary for an imported install.
            UserDefaults.standard.set(true, forKey: WelcomeWindowController.userDefaultsKey)
            SystemLanguageManager.relaunch()
        } catch {
            importStatus = error.localizedDescription
        }
    }

    #if MAS
    /// MAS replacement for the permissions checklist. The App Store build needs
    /// no TCC grants — it works through the system Services menu and ⌘⌥
    /// shortcuts — so step 1 just shows how to trigger each action.
    private var masServicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            masTriggerRow("textformat", OSLocalizer.string("Translate"), "⌘⌥T")
            masTriggerRow("wand.and.stars", OSLocalizer.string("Polish"), "⌘⌥P")
            masTriggerRow("character.book.closed", OSLocalizer.string("Explain"), "⌘⌥E")
            masTriggerRow("bubble.left.and.text.bubble.right", OSLocalizer.string("Chat"), "⌘⌥C")
            Text(OSLocalizer.string("Select text in any app, then choose Glotty from the Services menu (right-click → Services) or press the shortcut. Translate / Explain / Polish shortcuts are rebindable in System Settings → Keyboard → Keyboard Shortcuts → Services."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func masTriggerRow(_ symbol: String, _ label: String, _ shortcut: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.tint)
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
    #endif

    /// One row per system permission Glotty needs, with current
    /// status + an "Open System Settings" deep link to the right
    /// pane. The `id(permissionsTick)` modifier on the outer VStack
    /// forces a re-read every second so the row flips from "needed"
    /// to "granted" without the user having to navigate away and
    /// back.
    private var permissionsChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Permission.allCases) { perm in
                permissionRow(perm)
            }
            // System dependency row — not a permission, but the same
            // "is this prerequisite in place?" check. Translate's
            // dictionary lookup needs Apple's Dictionary.app to
            // populate the catalog Glotty reads from.
            dictionaryAppRow
            if PermissionCheck.anyMissing() {
                Text(OSLocalizer.string("You can grant the missing ones now or skip this step and come back from the menu bar → Settings → Permissions later. The Translate/Polish/Explain demos in the next steps won't work until Accessibility and Input Monitoring are on."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .id(permissionsTick)
        .task {
            // Lightweight timer — refresh once a second while this step
            // is on screen so granting in System Settings reflects back
            // here in roughly real time.
            while !Task.isCancelled {
                PermissionCheck.refreshNotificationsStatus()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                permissionsTick &+= 1
            }
        }
    }

    /// First existing Dictionary.app on disk, or nil. macOS ships it
    /// at /System/Applications on modern releases; /Applications is
    /// the fallback some restored systems use. The result is
    /// re-evaluated each render (via the body's `id(permissionsTick)`)
    /// so the row flips from missing→present the moment a system
    /// update or Migration Assistant restores it.
    private static func dictionaryAppURL() -> URL? {
        for path in ["/System/Applications/Dictionary.app",
                     "/Applications/Dictionary.app"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Dictionary.app presence row — shown in the same list as the
    /// system permissions because it's the same shape of question:
    /// "is this prerequisite in place?" Three visual states:
    ///   - present: green check + "Installed" badge
    ///   - missing: orange triangle + "Software Update" link
    /// We deliberately do NOT offer an "install" button — Dictionary.app
    /// ships with macOS and can't be installed from the App Store.
    private var dictionaryAppRow: some View {
        let url = Self.dictionaryAppURL()
        let present = url != nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: present
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(present ? .green : .orange)
                .font(.system(size: 16))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(OSLocalizer.string("Dictionary.app"))
                    .font(.system(size: 13, weight: .semibold))
                Text(OSLocalizer.string(present
                     ? "Apple's built-in Dictionary app — Glotty reads its catalog to power offline dictionary lookups during Translate."
                     : "Required for offline dictionary lookups. Ships with macOS; can't be reinstalled from the App Store. Run Software Update or use Migration Assistant to restore it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if present {
                Text(OSLocalizer.string("Installed"))
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button {
                    if let su = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") {
                        NSWorkspace.shared.open(su)
                    }
                } label: {
                    Text(OSLocalizer.string("Software Update"))
                        .font(.caption)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(present ? 0.05 : 0.10))
        )
    }

    private func permissionRow(_ perm: Permission) -> some View {
        let granted = perm.isGranted()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 16))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(OSLocalizer.string(perm.displayName))
                    .font(.system(size: 13, weight: .semibold))
                Text(OSLocalizer.string(perm.purpose))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted, let url = perm.settingsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(OSLocalizer.string("Open Settings"))
                        .font(.caption)
                }
                .controlSize(.small)
            } else if granted {
                Text(OSLocalizer.string("Granted"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(granted ? 0.05 : 0.10))
        )
    }

    // MARK: - Pre-prepared demos
    //
    // Each demo shows the input the user would have selected (Source)
    // and the output Glotty would have produced (Result). The result
    // text is in the user's display language so the demo feels real
    // — a Chinese-locale user sees a Chinese translation; an English-
    // locale user sees... well, English, with the demo wrapping
    // appropriately.

    private var translateDemo: some View {
        let data = TutorialPopupContent.translateData()
        return demoStep(
            sourceLabel: OSLocalizer.string("Source"),
            source: TutorialPopupContent.source(for: .translate),
            chord: "Fn → T",
            revealed: controller.revealedDemos.contains(.translate)
        ) {
            translateResultCard(data)
        }
    }

    private var polishDemo: some View {
        let data = TutorialPopupContent.polishData()
        return demoStep(
            sourceLabel: OSLocalizer.string("Source (rough draft)"),
            source: TutorialPopupContent.source(for: .polish),
            chord: "Fn → P",
            revealed: controller.revealedDemos.contains(.polish)
        ) {
            polishResultCard(data)
        }
    }

    private var explainDemo: some View {
        demoStep(
            sourceLabel: OSLocalizer.string("Source (idiom)"),
            source: TutorialPopupContent.source(for: .explain),
            chord: "Fn → E",
            revealed: controller.revealedDemos.contains(.explain)
        ) {
            markdownSectionCard(label: OSLocalizer.string("Explanation"),
                                text: TutorialPopupContent.explainResult())
        }
    }

    // Speak + Correct are illustrative (auto-revealed): Speak plays audio with
    // no result popup, and Correct replaces text in place with no popup — so
    // neither fits the press-chord-to-reveal model the three core demos use.
    // Both still teach the Fn-leader gesture through the step body copy.

    private var speakDemo: some View {
        demoStep(
            sourceLabel: OSLocalizer.string("Source"),
            source: "aurora borealis",
            chord: "Fn → V",
            revealed: true,
            headerIcon: "speaker.wave.2.fill"
        ) {
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    Capsule().fill(Color.accentColor)
                        .frame(width: 3, height: CGFloat(5 + (i % 5) * 4))
                }
                Spacer(minLength: 6)
                Image(systemName: "waveform").foregroundStyle(.tint)
            }
        }
    }

    private var correctDemo: some View {
        demoStep(
            sourceLabel: OSLocalizer.string("Source (with typos)"),
            source: "definately recieve",
            chord: "Fn → R",
            revealed: true,
            headerIcon: "pencil"
        ) {
            HStack(spacing: 8) {
                Text(verbatim: "definately recieve")
                    .font(.system(size: 14)).strikethrough()
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(verbatim: "definitely receive")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
    }

    /// One tutorial step: shows the source + a "press Fn → X" prompt
    /// when result isn't revealed yet, swaps to source + caller-
    /// supplied `resultContent` once the user has pressed the chord.
    /// Each demo passes a different result renderer — translate gets
    /// a phonetics-and-definition card, polish gets variant cards +
    /// issues block, explain gets the markdown-section card — each
    /// shaped to mirror the corresponding real popup region.
    private func demoStep<Result: View>(
        sourceLabel: String,
        source: String,
        chord: String,
        revealed: Bool,
        headerIcon: String = "speaker.wave.2.fill",
        @ViewBuilder resultContent: () -> Result
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sourceLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            // The popup Glotty shows for that selection — same chrome as the
            // real popup (rounded material card, source header + speak glyph,
            // divider, then the result once the chord is pressed).
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(source)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: headerIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider()
                if revealed {
                    resultContent()
                } else {
                    chordPrompt(chord: chord)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5))
            .shadow(radius: 10, y: 3)
        }
        .animation(.easeInOut(duration: 0.2), value: revealed)
    }

    // MARK: - Polish result card
    //
    // Mirrors the real polish popup: variant cards on top (first
    // one tinted as the primary), then an Issues region with each
    // issue showing its quoted original in orange + the explanation
    // underneath — same shapes PopupView's `polishVariantsSection`
    // and `polishIssuesSection` produce.

    private func polishResultCard(_ data: TutorialPopupContent.PolishDemoData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.polishedLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(data.variants.enumerated()), id: \.offset) { idx, variant in
                        polishVariantCard(text: variant, isPrimary: idx == 0)
                    }
                }
            }
            if !data.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.issuesLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(data.issues.enumerated()), id: \.offset) { _, issue in
                            polishIssueRow(issue)
                        }
                    }
                }
            }
        }
    }

    private func polishVariantCard(text: String, isPrimary: Bool) -> some View {
        Text(text)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPrimary
                          ? Color.accentColor.opacity(0.10)
                          : Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isPrimary
                                          ? Color.accentColor.opacity(0.25)
                                          : Color.secondary.opacity(0.18),
                                          lineWidth: 1)
                    )
            )
    }

    private func polishIssueRow(_ issue: TutorialPopupContent.PolishIssueDemo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(issue.category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.12))
                    )
                Text("\u{201C}\(issue.original)\u{201D}")
                    .font(.callout.italic())
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
            }
            Text(issue.fix)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
    }

    // MARK: - Translate result card
    //
    // Mirrors what the translate popup shows when content is rich:
    // phonetics row at the top, the translation big and bold, then
    // an optional definition + usage example block — the same kind
    // of layered information density a real selection would surface.

    private func translateResultCard(_ data: TutorialPopupContent.TranslateDemoData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let phonetics = data.phonetics {
                HStack(spacing: 8) {
                    Text(phonetics)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let pos = data.partOfSpeech {
                        Text(pos)
                            .font(.caption.italic())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(data.translationLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(data.translation)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .textSelection(.enabled)
            }
            if let definition = data.definition {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.definitionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(definition)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let example = data.example {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.exampleLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(example)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
                )
        )
    }

    /// Result card that parses `## Title\nBody\n\n## …` sections and
    /// renders each one with a styled subheading + body paragraph.
    /// Mirrors PopupView's `explainSections` parser shape so the
    /// welcome demo looks like a miniature of the real explain popup.
    private func markdownSectionCard(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(parseMarkdownSections(text).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 2) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PopupTokens.accent)
                        }
                        if !section.body.isEmpty {
                            Text(section.body)
                                .font(.system(.callout))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
                    )
            )
        }
    }

    /// Split a `## Title\nBody\n\n## …` blob into titled sections.
    /// Blocks separated by blank lines; within each block the first
    /// line is the title (with `## ` stripped) and the rest is the
    /// body paragraph. Blocks without a `## ` marker render as
    /// body-only so partial / malformed input doesn't drop content.
    private func parseMarkdownSections(_ text: String) -> [(title: String, body: String)] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let newlineRange = trimmed.range(of: "\n") {
                let firstLine = trimmed[..<newlineRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = trimmed[newlineRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if firstLine.hasPrefix("## ") {
                    return (String(firstLine.dropFirst(3)), rest)
                }
                if firstLine.hasPrefix("##") {
                    return (String(firstLine.dropFirst(2))
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                            rest)
                }
                return ("", trimmed)
            }
            if trimmed.hasPrefix("## ") {
                return (String(trimmed.dropFirst(3)), "")
            }
            return ("", trimmed)
        }
    }

    /// Inline keyboard prompt row — "Press Fn → T to see the result".
    /// Shown until the user actually fires the chord.
    private func chordPrompt(chord: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(OSLocalizer.string("Press"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(chord)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                )
            Text(OSLocalizer.string("to see the result"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            pageIndicator

            Spacer()

            if step > 0 {
                Button(OSLocalizer.string("Back")) { step -= 1 }
                    .controlSize(.large)
            }
            // Last step's primary action is the inline "Start
            // onboarding chat" button (see `currentExtra`), so the
            // footer button on that page is a low-key "Skip"
            // instead — lets a user who'd rather configure later
            // close the window without doing the chat. Earlier
            // steps just advance.
            if step == stepCount - 1 {
                Button(OSLocalizer.string("Skip for now")) {
                    onClose()
                }
                .controlSize(.large)
            } else {
                Button(OSLocalizer.string("Next")) {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { idx in
                Circle()
                    .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

/// Pre-calculated tutorial content for each Fn-leader action. Used
/// by `WelcomeWindowController.showTutorialPopup` to drive the real
/// PopupView through its `replay` path with hardcoded source +
/// result, so the user sees what each chord produces without
/// triggering the actual pipeline (which would depend on provider
/// config, language pair, dictionary selection, etc.).
@MainActor
private enum TutorialPopupContent {
    /// Translate-demo source words per OS display language. Source
    /// is in the user's native language, target is always English
    /// — matches the "learning English from your native language"
    /// shape the welcome teaches. English-display users get a
    /// Spanish fallback (English→English would be a no-op).
    private static let translateSources: [String: String] = [
        "en":      "ubicuo",       // Spanish fallback for English-display
        "zh-Hans": "无处不在",
        "zh-Hant": "無處不在",
        "ja":      "至る所にある",
        "ko":      "어디에나 있는",
        "es":      "ubicuo",
        "fr":      "omniprésent",
        "de":      "allgegenwärtig",
        "it":      "ubiquo",
        "pt":      "ubíquo",
        "ru":      "вездесущий",
        "ar":      "موجود في كل مكان",
        "hi":      "सर्वव्यापी",
        "vi":      "ở khắp mọi nơi",
        "th":      "อยู่ทุกหนทุกแห่ง",
    ]

    /// Explain-demo explanation text per OS display language. The
    /// idiom source ("throw in the towel") stays English; the
    /// explanation localizes to the user's display language so the
    /// tutorial reads naturally. Format mirrors what the real
    /// explain pipeline emits — `## Title\nBody\n\n## …` — so the
    /// popup's section parser renders it identically.
    private static let explanationsByLang: [String: String] = [
        "en": """
        ## Direct meaning
        To give up after a long, difficult effort. Used both literally and figuratively to mean "I'm done trying."

        ## Implication
        Carries a faint note of resignation rather than defeat — the speaker has made a real effort and is choosing to stop. Common in conversational English; safe for most casual + professional contexts.

        ## Example
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."

        ## Other contexts
        Originated in boxing — a fighter's corner literally threw a towel into the ring to stop the fight. The phrase carries that "the people around you are calling it" feel even in modern figurative use.
        """,
        "zh-Hans": """
        ## 字面意思
        在经过长时间艰苦努力后选择放弃,既可以字面理解,也可以引申为「我不打算再试了」。

        ## 言外之意
        带有「认输」的意味,不像「彻底失败」那么强烈 —— 说话人付出了真实的努力,然后主动选择停下来。日常英语中常用,休闲和职场场合都适用。

        ## 例句
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."(调试这个 build 错误调了三周,我快要放弃了。)

        ## 其他语境
        源自拳击 —— 拳手的助手会真的把毛巾扔进擂台来中止比赛。现在的比喻用法仍保留了「身边的人都在劝你停下来」的味道。
        """,
        "ja": """
        ## 直接の意味
        長く苦しい努力の末に諦めること。文字通りにも比喩的にも使われ、「もう試すのをやめる」という意味になります。

        ## 含意
        完全な敗北というより、自ら身を引くニュアンスがあります。話し手は本当に努力した上で、止める決断をしたという感じです。日常英語でよく使われ、カジュアルでも職場でも安全に使えます。

        ## 例文
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."

        ## その他の文脈
        ボクシングが語源 —— 試合を止めるために、選手のセコンドが文字通りリングにタオルを投げ込んだことに由来します。今の比喩的な用法にも「周りの人たちが止めようと言っている」感覚が残っています。
        """,
        "es": """
        ## Significado directo
        Rendirse después de un esfuerzo largo y difícil. Se usa tanto literal como figuradamente, con el sentido de "ya no voy a intentarlo más."

        ## Implicación
        Tiene un matiz de resignación más que de derrota — la persona realmente lo intentó y decide parar. Común en inglés conversacional, apropiado en contextos casuales y profesionales.

        ## Ejemplo
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."

        ## Otros contextos
        Viene del boxeo — el equipo del boxeador literalmente lanzaba una toalla al ring para detener la pelea. El uso figurado moderno mantiene esa sensación de "la gente a tu alrededor está pidiendo que pares".
        """,
        "fr": """
        ## Sens direct
        Abandonner après un long et difficile effort. S'emploie au sens propre et figuré pour dire "je n'essaie plus."

        ## Implication
        Évoque la résignation plutôt que la défaite — la personne a vraiment fait des efforts et choisit d'arrêter. Très courant en anglais oral; convient aux contextes décontractés et professionnels.

        ## Exemple
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."

        ## Autres contextes
        Vient de la boxe — le coin du boxeur jetait littéralement une serviette sur le ring pour arrêter le combat. L'usage figuré garde cette sensation de "les gens autour de toi disent stop".
        """,
        "de": """
        ## Direkte Bedeutung
        Nach langer, mühsamer Anstrengung aufgeben. Wird wörtlich und übertragen verwendet im Sinne von „ich versuche es nicht mehr".

        ## Implikation
        Klingt eher resigniert als geschlagen — der Sprecher hat sich wirklich angestrengt und entscheidet sich zu stoppen. Im gesprochenen Englisch verbreitet, passt in lockere wie professionelle Kontexte.

        ## Beispiel
        "After three weeks of debugging that build error, I'm about ready to throw in the towel."

        ## Andere Kontexte
        Kommt aus dem Boxsport — die Ecke des Boxers warf buchstäblich ein Handtuch in den Ring, um den Kampf zu beenden. Die übertragene Bedeutung trägt dieses „die Leute um dich rufen zum Aufhören" weiter mit sich.
        """,
    ]

    /// The "selected" sample text the tutorial popup pretends the
    /// user had highlighted before pressing the chord.
    static func source(for mode: PopupMode) -> String {
        switch mode {
        case .translate:
            return translateSources[OSLocalizer.osPreferredContentKey()] ?? translateSources["en"]!
        case .polish:    return "I want know if you can sending me the file on yesterday meeting."
        case .explain:   return "throw in the towel"
        case .chat:      return ""
        }
    }

    // MARK: - Inline result data
    //
    // The welcome page reveals these inline once the user fires the
    // matching Fn chord. Structured types (rather than markdown
    // strings) so the welcome's custom result cards can mirror the
    // real popup's region structure — variants and issues split
    // for polish, phonetics + translation + definition for
    // translate.

    /// Structured payload for the translate demo. Mirrors what the
    /// real translate popup surfaces: phonetics, translation,
    /// dictionary-style definition, usage example. All non-source
    /// fields adapt to the user's display language; the translation
    /// itself is always English (target).
    struct TranslateDemoData {
        let phonetics: String?
        let partOfSpeech: String?
        let translationLabel: String
        let translation: String
        let definitionLabel: String
        let definition: String?
        let exampleLabel: String
        let example: String?
    }

    static func translateData() -> TranslateDemoData {
        let key = OSLocalizer.osPreferredContentKey()
        let labels: [String: (translation: String, definition: String, example: String, pos: String)] = [
            "en":      ("Translation", "Definition", "Example",  "adjective"),
            "zh-Hans": ("翻译", "释义", "例句", "形容词"),
            "zh-Hant": ("翻譯", "釋義", "例句", "形容詞"),
            "ja":      ("訳", "意味", "例文", "形容詞"),
            "ko":      ("번역", "뜻", "예문", "형용사"),
            "es":      ("Traducción", "Definición", "Ejemplo", "adjetivo"),
            "fr":      ("Traduction", "Définition", "Exemple", "adjectif"),
            "de":      ("Übersetzung", "Bedeutung", "Beispiel", "Adjektiv"),
        ]
        let definitions: [String: String] = [
            "en":      "present, appearing, or found everywhere.",
            "zh-Hans": "普遍存在的;无处不在的。",
            "zh-Hant": "普遍存在的;無處不在的。",
            "ja":      "どこにでも存在する、遍在する。",
            "ko":      "어디에나 있는, 도처에 존재하는.",
            "es":      "que está presente, parece estar o se encuentra en todas partes.",
            "fr":      "présent, qui apparaît ou se trouve partout.",
            "de":      "überall vorhanden, allgegenwärtig.",
        ]
        let l = labels[key] ?? labels["en"]!
        return TranslateDemoData(
            phonetics: "/juːˈbɪkwɪtəs/",
            partOfSpeech: l.pos,
            translationLabel: l.translation,
            translation: "ubiquitous",
            definitionLabel: l.definition,
            definition: definitions[key] ?? definitions["en"],
            exampleLabel: l.example,
            example: "\u{201C}Mobile phones have become ubiquitous in modern life.\u{201D}"
        )
    }

    /// Polish result: mirrors the real polish popup — multiple
    /// Structured payload for the polish demo. Mirrors the real
    /// polish popup: a list of polished variants on top, an Issues
    /// region underneath with each issue's category + quoted
    /// original + fix. Welcome's `polishResultCard` renders these
    /// with the same visual shape (variant cards + orange-quoted
    /// issue rows) as `PopupView.polishBlock`.
    struct PolishDemoData {
        let polishedLabel: String
        let variants: [String]
        let issuesLabel: String
        let issues: [PolishIssueDemo]
    }

    struct PolishIssueDemo {
        let category: String
        let original: String
        let fix: String
    }

    static func polishData() -> PolishDemoData {
        let key = OSLocalizer.osPreferredContentKey()
        struct Labels {
            let polished: String
            let alternative: String
            let issueModal: (cat: String, original: String, fix: String)
            let issueVerb: (cat: String, original: String, fix: String)
            let issuePrep: (cat: String, original: String, fix: String)
        }
        let table: [String: Labels] = [
            "en": Labels(
                polished: "Polished",
                alternative: "Alternative",
                issueModal: ("Issue · Modal verb",
                             "I want know",
                             "Use \"I'd like to know\" or \"Could you\" — softer and grammatical."),
                issueVerb:  ("Issue · Verb form",
                             "can sending",
                             "After a modal (\"can\"), use the bare infinitive: \"can send\"."),
                issuePrep:  ("Issue · Preposition",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\" — possessive + \"from\" for source.")
            ),
            "zh-Hans": Labels(
                polished: "润色后",
                alternative: "另一种说法",
                issueModal: ("问题 · 情态动词",
                             "I want know",
                             "应改为 \"I'd like to know\" 或 \"Could you\",更地道、合语法。"),
                issueVerb:  ("问题 · 动词形式",
                             "can sending",
                             "情态动词 \"can\" 后应接动词原形:\"can send\"。"),
                issuePrep:  ("问题 · 介词",
                             "on yesterday meeting",
                             "应改为 \"from yesterday's meeting\":用「所有格 + from」表示来源。")
            ),
            "zh-Hant": Labels(
                polished: "潤色後",
                alternative: "另一種說法",
                issueModal: ("問題 · 情態動詞",
                             "I want know",
                             "應改為 \"I'd like to know\" 或 \"Could you\",更地道、合語法。"),
                issueVerb:  ("問題 · 動詞形式",
                             "can sending",
                             "情態動詞 \"can\" 後應接動詞原形:\"can send\"。"),
                issuePrep:  ("問題 · 介詞",
                             "on yesterday meeting",
                             "應改為 \"from yesterday's meeting\":用「所有格 + from」表示來源。")
            ),
            "ja": Labels(
                polished: "改善後",
                alternative: "別の言い方",
                issueModal: ("指摘 · 助動詞",
                             "I want know",
                             "\"I'd like to know\" や \"Could you\" の方が自然で文法的に正しい。"),
                issueVerb:  ("指摘 · 動詞の形",
                             "can sending",
                             "助動詞 \"can\" の後は原形を使う:\"can send\"。"),
                issuePrep:  ("指摘 · 前置詞",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\" にする。所有格 + \"from\" で出所を表す。")
            ),
            "ko": Labels(
                polished: "다듬은 표현",
                alternative: "다른 표현",
                issueModal: ("지적 · 조동사",
                             "I want know",
                             "\"I'd like to know\" 또는 \"Could you\"가 더 자연스럽고 문법적입니다."),
                issueVerb:  ("지적 · 동사 형태",
                             "can sending",
                             "조동사 \"can\" 뒤에는 동사원형: \"can send\"."),
                issuePrep:  ("지적 · 전치사",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\"으로 — 소유격 + \"from\"으로 출처를 표시.")
            ),
            "es": Labels(
                polished: "Pulido",
                alternative: "Alternativa",
                issueModal: ("Problema · Verbo modal",
                             "I want know",
                             "Mejor \"I'd like to know\" o \"Could you\" — más suave y gramatical."),
                issueVerb:  ("Problema · Forma verbal",
                             "can sending",
                             "Tras un modal (\"can\"), usa el infinitivo: \"can send\"."),
                issuePrep:  ("Problema · Preposición",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\" — posesivo + \"from\" para la fuente.")
            ),
            "fr": Labels(
                polished: "Version polie",
                alternative: "Variante",
                issueModal: ("Problème · Modal",
                             "I want know",
                             "Préférer \"I'd like to know\" ou \"Could you\" — plus doux et grammatical."),
                issueVerb:  ("Problème · Forme verbale",
                             "can sending",
                             "Après un modal (\"can\"), utiliser l'infinitif nu : \"can send\"."),
                issuePrep:  ("Problème · Préposition",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\" — possessif + \"from\" pour indiquer la source.")
            ),
            "de": Labels(
                polished: "Korrigiert",
                alternative: "Alternative",
                issueModal: ("Problem · Modalverb",
                             "I want know",
                             "Besser \"I'd like to know\" oder \"Could you\" — höflicher und grammatisch."),
                issueVerb:  ("Problem · Verbform",
                             "can sending",
                             "Nach einem Modalverb (\"can\") steht der Infinitiv: \"can send\"."),
                issuePrep:  ("Problem · Präposition",
                             "on yesterday meeting",
                             "\"from yesterday's meeting\" — Possessiv + \"from\" für die Quelle.")
            ),
        ]
        let l = table[key] ?? table["en"]!
        let issuesLabels: [String: String] = [
            "en": "Issues",
            "zh-Hans": "问题",
            "zh-Hant": "問題",
            "ja": "指摘",
            "ko": "지적 사항",
            "es": "Problemas",
            "fr": "Problèmes",
            "de": "Probleme",
        ]
        return PolishDemoData(
            polishedLabel: l.polished,
            variants: [
                "Could you send me the file from yesterday's meeting?",
                "Mind sharing the file from yesterday's meeting?",
            ],
            issuesLabel: issuesLabels[key] ?? issuesLabels["en"]!,
            issues: [
                PolishIssueDemo(category: l.issueModal.cat,
                                original: l.issueModal.original,
                                fix: l.issueModal.fix),
                PolishIssueDemo(category: l.issueVerb.cat,
                                original: l.issueVerb.original,
                                fix: l.issueVerb.fix),
                PolishIssueDemo(category: l.issuePrep.cat,
                                original: l.issuePrep.original,
                                fix: l.issuePrep.fix),
            ]
        )
    }

    /// Explain result: per-display-language explanation of "throw
    /// in the towel". Falls back to English when the user's
    /// locale isn't shipped with a translation.
    static func explainResult() -> String {
        let key = OSLocalizer.osPreferredContentKey()
        return explanationsByLang[key] ?? explanationsByLang["en"]!
    }
}
