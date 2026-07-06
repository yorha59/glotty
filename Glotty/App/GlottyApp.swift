import AppKit
import SwiftUI
import UserNotifications
import NaturalLanguage
#if MAS
import Carbon.HIToolbox
#endif

/// Thin wrapper around `Log.debug(.app, ...)` so existing call
/// sites in this file don't need to be touched to gain the
/// unified format. `#fileID` / `#line` default-init at the
/// caller, so file/line carry the call site, not this wrapper.
private func dbg(_ msg: String, file: String = #fileID, line: Int = #line) {
    Log.debug(.app, msg, file: file, line: line)
}

@main
struct GlottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        dbg("GlottyApp.init")
    }

    var body: some Scene {
        // We host Settings/Permissions/Popup as AppKit windows from the AppDelegate
        // so they surface reliably from the status-bar menu. SwiftUI requires at
        // least one Scene, so we keep `Settings { EmptyView() }` as a placeholder
        // — but the default `.appSettings` command also wires Cmd+, to OPEN that
        // empty window. We replace it so Cmd+, drives our AppKit controller,
        // otherwise pressing Cmd+, (or invoking Settings from elsewhere) produced
        // two Settings windows side by side: the empty SwiftUI one and ours.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        SettingsWindowController.shared.show()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mascot: MenuBarMascot?
    private var hotkey: FnLeaderHotkey?
    #if MAS
    /// MAS global hotkeys (Carbon `RegisterEventHotKey`). Web uses the Fn-leader
    /// event tap instead, so these only exist in the App Store build.
    /// `chatHotkey` = ⌘⌥C (open chat). `leaderHotkey` = ⌥A (command menu).
    private var chatHotkey: CarbonHotkey?
    private var leaderHotkey: CarbonHotkey?
    #endif
    /// Accessed from MemorySettingsSection's drill-in to reopen a popup for
    /// a stored memory event. Internal-not-private so other module code can
    /// route into the same controller without an NSApp dance.
    var popup: PopupController!
    private var hud: HUDController!
    private let grabber = SelectionGrabber()
    private let replacer = SelectionReplacer()
    private var hoverWatcher: SelectionHoverWatcher?
    private let permissionsWindow = PermissionsWindowController()
    private let settingsWindow = SettingsWindowController.shared

    /// Single-instance gate — "new launch wins". Glotty is an LSUIElement
    /// agent, so two copies running at once means two status-bar mascots,
    /// two Fn-leader hotkey handlers fighting for the same key event, and
    /// duplicate proactive notifications. Detect any previously-launched
    /// instance and tell it to quit so this one can take over. Runs in
    /// `willFinishLaunching` so the old instance is gone before we set up
    /// the status item / hotkey / scheduler.
    ///
    /// "New wins" rather than "old wins" because the dev / "rebuild and
    /// relaunch from Xcode" flow needs each new launch to actually run.
    /// For end users, the cost is a brief mascot flicker on a duplicate
    /// launch — there are no documents to save, so a hard takeover is
    /// safe.
    ///
    ///
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restart-into-regular (see SettingsWindowController): if Settings
        // asked us to come up in regular mode, flip the activation policy
        // HERE — before any window exists — which is the only point an
        // LSUIElement process earns a real home Space (so Settings slides
        // a foreign full-screen app away instead of hovering). Done first
        // so the single-instance early-return below can't skip it.
        if UserDefaults.standard.bool(forKey: SettingsWindowController.launchRegularKey) {
            NSApp.setActivationPolicy(.regular)
            dbg("launched in regular mode (Settings home-Space)")
        }

        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        dbg(
            "Found \(others.count) other Glotty instance(s) — terminating so this build can take over."
        )
        for existing in others {
            // `terminate()` is the graceful signal; an LSUIElement agent
            // with no open documents will exit immediately on receipt.
            existing.terminate()
        }
        // Poll briefly for the old instance(s) to actually exit. Without
        // this wait the system can still hold the old status item when
        // we register ours, producing two visible mascots until the old
        // one finally cleans up. Cap at ~500ms; if anything's still
        // around past that we proceed anyway (transient overlap is
        // better than blocking launch).
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
            if still.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dbg("applicationDidFinishLaunching START")
        // Apply the saved appearance (Light / Dark / System) before any
        // window renders so onboarding + popups open in the chosen theme.
        Theme.apply()
        // Write the user's UI-language preference into AppleLanguages
        // before any view renders — Foundation reads it once during
        // bundle resolution on launch.
        SystemLanguageManager.applyAtLaunch()
        // Intercept Bundle.localizedString so LLM-translated UI
        // strings (cached in Application Support) override the
        // bundled catalog. Idempotent — second call no-ops.
        BundleSwizzle.installOnce()
        // Lets the dev / agent trigger the settings snapshotter
        // from outside the app (no Accessibility needed) by posting
        // a distributed notification — see SettingsSnapshotter for
        // the exact name.
        SettingsSnapshotter.installRemoteTriggerObserver()
        PopupController.installReplayObserver()
        // DEBUG-only: warn if a glotty.* setting exists that the backup
        // whitelist doesn't know about (neither backed up nor explicitly
        // excluded). Catches "added a setting, forgot the export list".
        BackupPreferences.auditUnknownKeys()
        popup = .shared
        hud = HUDController.shared
        dbg("popup + hud created")
        setupStatusItem()
        dbg("status item created")

        // Auto-open Settings → Permissions if a permission is genuinely
        // missing — but ONLY after the notifications status has actually
        // loaded. `anyMissing()` reads the notifications cache, which is
        // populated asynchronously and defaults to "not granted"; checking
        // it eagerly falsely reports notifications missing and pops Settings
        // up at launch even when everything is granted (which then sits
        // behind Welcome). So we run the decision inside the refresh
        // completion. Also skipped when this launch is a restart-into-
        // regular for Settings/Welcome (we're only here to reopen THAT
        // window) and while the first-run Welcome flow owns the screen.
        PermissionCheck.refreshNotificationsStatus { [weak self] in
            guard let self else { return }
            let missing = PermissionCheck.anyMissing()
            let welcomeDone = UserDefaults.standard.bool(
                forKey: WelcomeWindowController.userDefaultsKey)
            let isRestartReopen =
                UserDefaults.standard.bool(forKey: SettingsWindowController.reopenSettingsKey)
                || UserDefaults.standard.bool(forKey: WelcomeWindowController.reopenWelcomeKey)
            dbg(
                "anyMissing = \(missing) welcomeDone = \(welcomeDone) restartReopen = \(isRestartReopen)"
            )
            guard missing, welcomeDone, !isRestartReopen,
                !WelcomeWindowController.shared.isShowing
            else { return }
            dbg("opening Settings → Permissions (post-welcome missing perms)")
            self.settingsWindow.show(selecting: .permissions)
        }

        PermissionCheck.registerSilentlyIfMissing()
        dbg("registerSilentlyIfMissing done")

        #if MAS
        // Mac App Store front-end. No global CGEvent tap and no AX hover —
        // both are rejected under Guideline 2.4.5. Selection commands arrive
        // through NSServices (right-click → Services, or the ⌘⌥ default
        // shortcuts); chat (which needs no selection) arrives through a Carbon
        // RegisterEventHotKey combo. Handlers live in the MAS extension
        // (MASFrontend.swift) and route into the same handleFire/handleReplace.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        dbg("MAS Services provider registered")
        installChatHotkey()
        dbg("MAS chat hotkey installed")
        installLeaderHotkey()
        dbg("MAS leader hotkey installed")
        #else
        installHotkey()
        dbg("installHotkey done")

        // Shortcut-free trigger: hover over a selection to pop up the same
        // command menu. Shares the grabber and routes to the same handlers as
        // the hotkeys. Opt-out via Settings (glotty.hover.enabled).
        let watcher = SelectionHoverWatcher(grabber: grabber)
        watcher.onAction = { [weak self] kind in
            switch kind {
            case .translate: self?.handleFire(mode: .translate)
            case .explain:   self?.handleFire(mode: .explain)
            case .polish:    self?.handleFire(mode: .polish)
            case .chat:      self?.handleFire(mode: .chat)
            case .speak:     self?.handleSpeak()
            }
        }
        watcher.start()
        hoverWatcher = watcher
        dbg("hover watcher started")
        #endif

        // First-run walkthrough — no-op if the user has already finished
        // or dismissed it. Runs after permissions / hotkey setup so the
        // user can actually try the hotkey demo it points at.
        WelcomeWindowController.shared.showIfFirstRun()

        let aiStatus = AppleIntelligenceStatus.current()
        dbg(
            "AppleIntelligence: \(aiStatus.displayName)"
                + (aiStatus.fixInstructions.map { " — \($0)" } ?? ""))

        // Warm the dictionary metadata cache so the very first Fn → T popup gets
        // proper kind classification (not the fallback keyword heuristic).
        DictionaryCatalog.loadIfNeeded {
            dbg("DictionaryCatalog: metadata cache loaded")
        }

        // Proactive chat-reminder scheduler — opt-in via Settings. Permission
        // and category registration are idempotent so we always run them; the
        // scheduler itself is a no-op until the user picks a non-zero interval.
        UNUserNotificationCenter.current().delegate = self
        ReminderScheduler.shared.requestNotificationPermissionIfNeeded()
        ReminderScheduler.shared.start()

        // Honor the "reopen chat after relaunch" flag set by the
        // settings-via-chat relaunch button (see SystemLanguageManager).
        // We consume + clear the flag before opening so a crash during
        // chat hydration doesn't trigger an open loop next launch.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SystemLanguageManager.reopenChatOnLaunchKey) {
            defaults.removeObject(forKey: SystemLanguageManager.reopenChatOnLaunchKey)
            dbg("relaunch flag found — reopening chat popup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.handleFire(mode: .chat)
            }
        }

        // If this launch was the "restart into regular mode" triggered by
        // opening Settings, reopen Settings now (we're regular, so it
        // slides). Consume the flag so a normal relaunch doesn't reopen it.
        if defaults.bool(forKey: SettingsWindowController.reopenSettingsKey) {
            defaults.removeObject(forKey: SettingsWindowController.reopenSettingsKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.settingsWindow.show()
            }
        }
        if defaults.bool(forKey: WelcomeWindowController.reopenWelcomeKey) {
            defaults.removeObject(forKey: WelcomeWindowController.reopenWelcomeKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WelcomeWindowController.shared.show()
            }
        }

        dbg("applicationDidFinishLaunching END")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Custom mascot from Assets.xcassets/StatusItemIcon (+ Active for
            // the hover frame). Falls back to the SF Symbol globe if assets
            // are missing during dev. The MenuBarMascot controller installs a
            // tracking area on the button and cycles between frames while the
            // cursor is hovering.
            let defaultImage = NSImage(named: "StatusItemIcon")
            let activeImage = NSImage(named: "StatusItemIconActive")
            // NB: MenuBarMascot overrides these sizes on init to drive the
            // hover "grow" effect (14pt resting → 22pt active). Setting them
            // here just gives us a sensible fallback if the controller fails.
            defaultImage?.isTemplate = true
            activeImage?.isTemplate = true

            if let defaultImage, let activeImage {
                self.mascot = MenuBarMascot(
                    button: button,
                    defaultImage: defaultImage,
                    activeImage: activeImage
                )
            } else {
                button.image = NSImage(
                    systemSymbolName: "globe", accessibilityDescription: "Glotty")
                button.image?.isTemplate = true
            }
            button.toolTip = "Glotty"
        } else {
            dbg("WARNING: status item has no button — menu bar may be full")
        }
        dbg(
            "status item — visible=\(statusItem.isVisible) length=\(statusItem.length) hasButton=\(statusItem.button != nil)"
        )

        let menu = NSMenu()
        // Rebuild the menu lazily on each open so the Context
        // submenu reflects the current store/active state (contexts
        // may have been added/renamed/deleted since last open).
        menu.delegate = self
        statusItem.menu = menu

        rebuildStatusMenu(menu)
        dbg("status item created")
    }

    @objc private func openSettings() {
        dbg("openSettings invoked")
        settingsWindow.show()
    }

    @objc private func openChat() {
        dbg("openChat invoked (menu bar)")
        handleFire(mode: .chat)
    }

    @objc private func openReader() {
        dbg("openReader invoked (menu bar)")
        ReaderWindowController.shared.openBook()
    }

    /// Finder "Open With → Glotty" (or opening / dropping a .epub) routes here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let doc = urls.first(where: { ["epub", "pdf"].contains($0.pathExtension.lowercased()) })
        else { return }
        dbg("application(open:) — \(doc.lastPathComponent)")
        ReaderWindowController.shared.open(url: doc)
    }

    /// Open the chat as a spaced-repetition practice session over the due
    /// polish mistakes. No selection involved — the agenda comes from
    /// PracticeStore.
    @objc private func startPractice() {
        let items = PracticeStore.shared.dueSession()
        dbg("startPractice invoked — \(items.count) due items")
        guard !items.isEmpty else {
            HUDController.shared.toast(
                String(localized: "Nothing to practice right now."),
                systemImage: "checkmark.circle")
            return
        }
        // Same teardown the other chord/menu actions do so the popup opens in
        // agent mode (IME over full-screen).
        AppActivation.dismissAllRegistered()
        popup.show(sourceText: "", mode: .chat, practiceItems: items)
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let entry = SettingsRegistry.find(id: "model") else { return }
        dbg("setModel invoked (menu bar) -> \(id)")
        entry.write(id)
    }

    @objc private func openMemorySettings() {
        settingsWindow.show(selecting: .memory)
    }

    @objc private func setActiveContext(_ sender: NSMenuItem) {
        // representedObject is either a UUID (specific context) or
        // nil (selecting "None — Global only"). Both are encoded the
        // same way the active-context store expects.
        let id = sender.representedObject as? UUID
        MemoryContextStore.shared.activeContextID = id
    }

    /// Rebuild the status-bar menu in place. Called on every menu
    /// open so the Context submenu reflects current state — adding a
    /// new context in Settings should show up the next time the user
    /// clicks the mascot, without an app restart.
    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // All items get a matching SF Symbol so the leading edge of
        // every row sits at the same x. Without icons the rows were
        // visually ragged — Settings had no icon, the submenu chevron
        // shifted Context inward, and Quit's ⌘Q badge made it loom
        // larger than the rest.
        //
        // Title strings drop the trailing "…" Apple convention since
        // a user explicitly called it out as noise: "设置的三个。。。
        // 也不需要".

        let settings = NSMenuItem(
            title: "Settings".t,
            action: #selector(openSettings),
            keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let chat = NSMenuItem(
            title: "Chat with Glotty".t,
            action: #selector(openChat),
            keyEquivalent: "")
        chat.target = self
        chat.image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        menu.addItem(chat)

        // Practice mistakes — a spaced-repetition drill on past polish mistakes
        // that are due, run in the chat. Shows the due count; disabled when none.
        let dueCount = PracticeStore.shared.dueCount()
        let practiceTitle = dueCount > 0
            ? String(format: String(localized: "Practice mistakes (%d due)"), dueCount)
            : String(localized: "Practice mistakes")
        let practice = NSMenuItem(
            title: practiceTitle, action: #selector(startPractice), keyEquivalent: "")
        practice.target = self
        practice.isEnabled = dueCount > 0
        practice.image = NSImage(
            systemSymbolName: "checkmark.rectangle.stack", accessibilityDescription: nil)
        menu.addItem(practice)

        // Reader — open a (DRM-free) EPUB in Glotty's own reader, where tapping
        // a word runs the explain popup and looked-up words get underlined.
        let reader = NSMenuItem(
            title: "Read a book…".t, action: #selector(openReader), keyEquivalent: "")
        reader.target = self
        reader.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        menu.addItem(reader)

        // Model submenu — switch the active provider's model inline (built from
        // the same registry the chat's set_setting uses). Omitted when the
        // active provider has no enumerated model list (custom / on-device).
        if let modelEntry = SettingsRegistry.find(id: "model"),
            case .enumeration(let options, let display) = modelEntry.kind, !options.isEmpty {
            let current = modelEntry.read()
            let currentLabel = current.map { modelEntry.displayValue?($0) ?? $0 } ?? "—"
            let modelItem = NSMenuItem(
                title: "\("Model".t): \(currentLabel)", action: nil, keyEquivalent: "")
            modelItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
            let modelSub = NSMenu()
            for opt in options {
                let it = NSMenuItem(
                    title: display[opt] ?? opt, action: #selector(setModel(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = opt
                it.state = (opt == current) ? .on : .off
                modelSub.addItem(it)
            }
            modelItem.submenu = modelSub
            menu.addItem(modelItem)
        }

        // Memory submenu — shows the active memory context inline and
        // lets the user switch with one click. Labelled "Memory" in
        // the user-facing chrome (matches the rest of the app); the
        // internal `MemoryContext` type and code paths keep their
        // "context" naming because that's the technical concept the
        // chat prompt uses for short-term scoping.
        let contexts = MemoryContextStore.shared.all()
        let activeID = MemoryContextStore.shared.activeContextID
        let memoryLabel = "Memory".t
        let activeContextName: String
        if let active = contexts.first(where: { $0.id == activeID }) {
            activeContextName = active.name
        } else {
            activeContextName = "Global only".t
        }
        let memoryTitle = "\(memoryLabel): \(activeContextName)"
        let memoryItem = NSMenuItem(title: memoryTitle, action: nil, keyEquivalent: "")
        memoryItem.image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
        let memorySubmenu = NSMenu()
        let noneItem = NSMenuItem(
            title: "Global only (no context)".t,
            action: #selector(setActiveContext(_:)),
            keyEquivalent: "")
        noneItem.target = self
        noneItem.state = activeID == nil ? .on : .off
        memorySubmenu.addItem(noneItem)
        if !contexts.isEmpty {
            memorySubmenu.addItem(.separator())
            for ctx in contexts {
                let item = NSMenuItem(
                    title: ctx.name,
                    action: #selector(setActiveContext(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = ctx.id
                item.state = ctx.id == activeID ? .on : .off
                memorySubmenu.addItem(item)
            }
        }
        memorySubmenu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Manage memory".t,
            action: #selector(openMemorySettings),
            keyEquivalent: "")
        manage.target = self
        memorySubmenu.addItem(manage)
        memoryItem.submenu = memorySubmenu
        menu.addItem(memoryItem)

        let welcome = NSMenuItem(
            title: "Show welcome".t,
            action: #selector(showWelcome),
            keyEquivalent: "")
        welcome.target = self
        welcome.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(welcome)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Glotty".t,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    /// Re-open the first-run walkthrough on demand. Useful for users
    /// who skipped it on first launch and want a refresher.
    @objc private func showWelcome() {
        WelcomeWindowController.shared.show()
    }

    #if !MAS
    private func installHotkey() {
        let hk = FnLeaderHotkey()
        hk.onFire = { [weak self] in self?.handleFire(mode: .translate) }
        hk.onExplainFire = { [weak self] in self?.handleFire(mode: .explain) }
        hk.onPolishFire = { [weak self] in self?.handleFire(mode: .polish) }
        hk.onChatFire = { [weak self] in self?.handleFire(mode: .chat) }
        hk.onReplaceFire = { [weak self] in self?.handleReplace() }
        hk.onSpeakFire = { [weak self] in self?.handleSpeak() }
        hk.onShowHUD = { [weak self] in self?.hud.show() }
        hk.onHideHUD = { [weak self] in self?.hud.hide() }
        do {
            try hk.install()
            hotkey = hk
            dbg("Fn → T / Fn → E / Fn → P hotkey installed")
        } catch {
            dbg("hotkey install failed: \(error). Input Monitoring permission likely denied.")
        }
    }
    #else
    /// MAS chat trigger: ⌘⌥C. Carbon `RegisterEventHotKey` — system-wide, no
    /// Accessibility/Input-Monitoring permission, so it's App-Store legal.
    private func installChatHotkey() {
        let hk = CarbonHotkey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey,
                              signature: 0x474C_5443 /* 'GLTC' */, id: 1)
        hk.onFire = { [weak self] in self?.handleFire(mode: .chat) }
        do {
            try hk.install()
            chatHotkey = hk
            dbg("chat hotkey (⌘⌥C) installed")
        } catch {
            dbg("chat hotkey install failed: \(error)")
        }
    }

    /// MAS leader: ⌥A. Opens a command menu (Translate / Explain / Polish /
    /// Chat) — the App-Store-legal stand-in for the web build's Fn-leader HUD.
    /// The chosen action runs on the CLIPBOARD, since the sandbox can't read
    /// the live selection (no AX). Flow: select → ⌘C → ⌥A → tap a letter.
    /// (Right-click → Services still acts on the true selection.)
    private func installLeaderHotkey() {
        let hk = CarbonHotkey(keyCode: kVK_ANSI_A, modifiers: optionKey,
                              signature: 0x474C_544C /* 'GLTL' */, id: 2)
        hk.onFire = { [weak self] in self?.showLeaderMenu() }
        do {
            try hk.install()
            leaderHotkey = hk
            dbg("leader hotkey (⌥A) installed")
        } catch {
            dbg("leader hotkey install failed: \(error)")
        }
    }

    /// Native popup menu as the MAS "HUD". An `NSMenu` runs its own event loop
    /// and captures the key/click selection itself — no focus steal, no global
    /// key monitor (which would need permission + trip 2.4.5). Single letters
    /// pick the command.
    private func showLeaderMenu() {
        let menu = NSMenu(title: "Glotty")
        addLeaderItem(menu, String(localized: "Translate"), "t", #selector(leaderTranslate))
        addLeaderItem(menu, String(localized: "Explain"),   "e", #selector(leaderExplain))
        addLeaderItem(menu, String(localized: "Polish"),    "p", #selector(leaderPolish))
        addLeaderItem(menu, String(localized: "Chat"),      "c", #selector(leaderChat))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addLeaderItem(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = []   // bare letter selects
        item.target = self
        menu.addItem(item)
    }

    @objc private func leaderTranslate() { runLeader(.translate) }
    @objc private func leaderExplain()   { runLeader(.explain) }
    @objc private func leaderPolish()    { runLeader(.polish) }
    @objc private func leaderChat()      { runLeader(.chat) }

    /// Run a leader command on the current clipboard text (nil if empty, which
    /// lets `handleFire` surface its own "nothing to act on" hint).
    private func runLeader(_ mode: PopupMode) {
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (clip?.isEmpty == false) ? clip : nil
        handleFire(mode: mode, providedText: text)
    }
    #endif

    /// `providedText` is the seam between the web and MAS front-ends. Web passes
    /// nil → we pull the selection via the Accessibility grabber (Fn-leader / hover).
    /// MAS passes the text the system handed us through an NSService, so no AX read
    /// and no permission are needed.
    func handleFire(mode: PopupMode, providedText: String? = nil) {
        // Welcome flow takes precedence over real Fn-leader actions.
        // During first-launch onboarding the user hasn't configured a
        // provider / polish target / dictionary selection — running
        // the real pipeline would either fail or behave incorrectly.
        // Route to a tutorial popup with pre-calculated content so
        // the user sees what each chord produces, without touching
        // any of their (not-yet-existing) configuration.
        if WelcomeWindowController.shared.isShowing {
            Task { @MainActor in
                WelcomeWindowController.shared.revealResult(for: mode)
            }
            return
        }
        // LLM setup gate. Explain / Polish / Chat are entirely LLM-driven,
        // so firing them before a provider is configured would open a
        // popup that can do nothing but show "No LLM provider configured"
        // — which reads as "the popup is broken / doesn't display". Per
        // the rule that LLM features must not trigger before LLM setup,
        // hint the user which piece is missing and take them straight to
        // the relevant setting instead of opening a dead popup. Translate
        // is excluded: it still produces useful output (Apple Translation
        // + dictionaries) without an LLM.
        if mode != .translate, LLMRegistry.current() == nil {
            HUDController.shared.toast(
                String(
                    localized:
                        "No Language Model set up yet — add one in Settings → Language Model."),
                systemImage: "sparkles")
            settingsWindow.show(selecting: .languageModel)
            return
        }
        // Dictionary setup gate for Translate. Many users don't know
        // they have to enable dictionaries through macOS first — the
        // Dictionary.app menu (Window → Open Dictionaries) or
        // Glotty's Settings → Dictionaries pane. Without any
        // activated dictionary, Translate still works (Apple
        // Translation + LLM gloss), but the dictionary section the
        // popup is designed around is empty and the user thinks the
        // feature is broken. Show a two-stage guidance card: stage
        // 1 explains and offers a button to Settings → Dictionaries;
        // when the card detects dictionaries have been activated it
        // morphs to stage 2 with a sample word the user can highlight
        // and translate to verify the feature works end-to-end. The
        // card's controller owns the "guidance shown" flag and only
        // flips it on dismiss, so the gate fires at most once.
        #if !MAS
        // Web only: the dictionary-onboarding guide hinges on enumerating the
        // user's activated macOS dictionaries. The MAS build can't enumerate
        // them (no private `DCSGetActiveDictionaries`), so `availableDictionaries()`
        // is always empty there — showing this guide every time would be wrong.
        if mode == .translate,
            !UserDefaults.standard.bool(forKey: TranslateGuideWindowController.userDefaultsKey),
            DictionaryLookup.availableDictionaries().isEmpty
        {
            TranslateGuideWindowController.shared.show()
            return
        }
        #endif
        // A popup's IME candidate window over another app's full-screen
        // Space works ONLY in agent (.accessory) mode — a regular-mode
        // app's panel has candidates suppressed there (still true on
        // macOS 26; the earlier "regular works" claim was wrong). But
        // Settings/Welcome run in REGULAR mode (restart-into-regular for
        // the slide), and one process can't be both at once. So before
        // showing a popup, tear down any open managed window and drop the
        // process back to .accessory — otherwise Settings stays open, the
        // app stays regular, and the popup's IME is dead.
        AppActivation.dismissAllRegistered()
        Task { @MainActor in
            // Chat picks up the current selection when there is one — selecting
            // text and opening chat means "let's talk about this". With nothing
            // selected it opens the normal tutor chat (empty source text).
            if mode == .chat {
                let raw: String?
                if let providedText { raw = providedText } else { raw = await grabber.grab() }
                let sel = raw?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                popup.show(sourceText: sel, mode: .chat)
                return
            }
            let started = CFAbsoluteTimeGetCurrent()
            let grabbed: String?
            if let providedText { grabbed = providedText } else { grabbed = await grabber.grab() }
            guard let text = grabbed,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                // Don't fail silently — a no-op here reads as "the app is
                // broken" (the user pressed the hotkey and nothing
                // happened). Surface a hint pointing them at the missing
                // step: highlight some text first, then fire the leader.
                dbg("no selection available")
                // Fold the hint into the leader HUD (bottom row) rather
                // than popping a separate toast window — reads as one
                // surface, and the command list above reminds the user
                // what each chord does.
                HUDController.shared.showHint(
                    String(
                        format: String(localized: "Select some text first, then press %@."),
                        Keycode.currentLeader().label)
                )
                return
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            dbg(
                "grabbed \(text.count) chars in \(String(format: "%.0f", elapsed))ms (mode=\(mode))"
            )
            popup.show(sourceText: text, mode: mode)
        }
    }

    /// Fn → R — spell-correct the selected word in place. Local + instant via
    /// `NSSpellChecker` (no LLM). Single suggestion → replace directly; multiple
    /// → float a clickable candidate list at the word and replace on pick.
    /// Word-scoped: a multi-word selection is rejected with a hint.
    /// Fn → V — speak the current selection aloud (text-to-speech). No popup:
    /// grabs the selection, detects its language for the right voice, and hands
    /// it to the shared synthesizer. Empty selection → a hint, not silence.
    func handleSpeak(providedText: String? = nil) {
        Task { @MainActor in
            let grabbed: String?
            if let providedText { grabbed = providedText } else { grabbed = await grabber.grab() }
            let text = (grabbed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                dbg("speak — no selection available")
                HUDController.shared.showHint(
                    String(
                        format: String(localized: "Select some text first, then press %@."),
                        Keycode.currentLeader().label)
                )
                return
            }
            Speaker.shared.speak(text, language: Self.speakVoiceLanguage(for: text))
        }
    }

    /// Map the detected language to a BCP-47 voice locale that
    /// `AVSpeechSynthesisVoice` resolves. Most NLLanguage codes (en, ja, ko,
    /// es…) match directly; the script-tagged Chinese ones need a region.
    private static func speakVoiceLanguage(for text: String) -> String? {
        guard let raw = LanguagePolicy.detectSourceLanguage(text)?.rawValue else { return nil }
        switch raw {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default:        return raw
        }
    }

    func handleReplace(providedText: String? = nil) {
        SpellCandidateController.shared.dismiss()
        AppActivation.dismissAllRegistered()
        Task { @MainActor in
            let grabbed: String?
            if let providedText { grabbed = providedText } else { grabbed = await grabber.grab() }
            guard let raw = grabbed else {
                dbg("replace — no selection available")
                HUDController.shared.showHint(
                    String(
                        format: String(localized: "Select some text first, then press %@."),
                        Keycode.currentLeader().label)
                )
                return
            }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch SpellCorrection.check(word) {
            case .notAWord:
                HUDController.shared.toast(
                    String(localized: "Select a single word to spell-check."),
                    systemImage: "character.cursor.ibeam")
            case .correct(let alternatives):
                // Already correct — don't auto-change anything. If the checker
                // has alternatives, offer them in the list so the user can pick;
                // otherwise just confirm it's spelled right.
                if alternatives.isEmpty {
                    HUDController.shared.toast(
                        String(format: String(localized: "“%@” is spelled correctly."), word),
                        systemImage: "checkmark.circle", duration: 1.6)
                } else {
                    self.presentCandidates(alternatives)
                }
            case .corrections(let guesses):
                guard !guesses.isEmpty else {
                    // Local checker had nothing — try the LLM fallback for badly
                    // mangled words (only if a provider is configured).
                    if LLMRegistry.current() != nil {
                        HUDController.shared.toast(
                            String(localized: "Checking spelling…"),
                            systemImage: "sparkles", duration: 20)
                        let llm = await SpellCorrection.llmGuesses(for: word)
                        if llm.count == 1 {
                            await self.replaceSelection(with: llm[0])
                        } else if llm.count > 1 {
                            self.presentCandidates(llm)
                        } else {
                            HUDController.shared.toast(
                                String(format: String(localized: "No suggestions for “%@”."), word),
                                systemImage: "questionmark.circle")
                        }
                    } else {
                        HUDController.shared.toast(
                            String(format: String(localized: "No suggestions for “%@”."), word),
                            systemImage: "questionmark.circle")
                    }
                    return
                }
                // A single correction is unambiguous — apply it straight away.
                // Multiple → let the user choose from the list.
                if guesses.count == 1 {
                    await self.replaceSelection(with: guesses[0])
                } else {
                    self.presentCandidates(guesses)
                }
            }
        }
    }

    /// Float the candidate list anchored at the selected word; replace the
    /// selection when the user picks one.
    private func presentCandidates(_ candidates: [String]) {
        let rect = grabber.selectionScreenRect()
        SpellCandidateController.shared.show(candidates: candidates, nearAXRect: rect) {
            [weak self] picked in
            Task { @MainActor in await self?.replaceSelection(with: picked) }
        }
    }

    /// Write `word` over the current selection, with a confirming toast. If
    /// nothing editable accepts it, drop the correction on the clipboard rather
    /// than losing it.
    private func replaceSelection(with word: String) async {
        let outcome = await replacer.replace(with: word)
        switch outcome {
        case .accessibility, .paste:
            dbg("spell replace ok (\(outcome)) → “\(word)”")
            HUDController.shared.toast(
                String(format: String(localized: "Replaced with “%@”."), word),
                systemImage: "checkmark.circle", duration: 1.3)
        case .failed:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(word, forType: .string)
            dbg("spell replace — no editable target; copied to clipboard")
            HUDController.shared.toast(
                String(localized: "Can't edit here — correction copied to clipboard."),
                systemImage: "doc.on.clipboard", duration: 2.6)
        }
    }

}

// MARK: - Status menu rebuild

extension AppDelegate: NSMenuDelegate {
    /// Rebuild the status-bar menu just before it opens so the
    /// Context submenu always reflects the latest state — contexts
    /// added/renamed/deleted in Settings show up immediately.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        rebuildStatusMenu(menu)
    }
}

// MARK: - Reminder notification handling

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the notification banner even when Glotty is frontmost — the user
    /// might be deep in a polish session and we still want them to see the
    /// nudge. Without this, banners are suppressed for the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        dbg(
            "notification willPresent — id=\(notification.request.identifier) userInfo=\(notification.request.content.userInfo)"
        )
        completionHandler([.banner, .sound])
    }

    /// User clicked the notification (or the "Chat" action button).
    /// Open the chat popup. We always open it on any reminder
    /// notification so the click is never a dead-end. Posting to the
    /// main queue ensures the popup opens
    /// even when the system has just woken the app from a background state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo["kind"] as? String
        let actionId = response.actionIdentifier
        dbg(
            "notification didReceive — kind=\(kind ?? "nil") action=\(actionId) id=\(response.notification.request.identifier)"
        )
        let isReminder =
            (kind == "reminder-session")
            || actionId == ReminderScheduler.notificationActionStart
        if isReminder {
            // Hop to the main queue explicitly — UN delegate callbacks come
            // from a worker thread, and `popup` is main-actor-isolated.
            DispatchQueue.main.async { [weak self] in
                self?.popup?.show(sourceText: "", mode: .chat, proactive: true)
            }
        }
        completionHandler()
    }
}
