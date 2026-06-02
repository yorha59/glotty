import SwiftUI
import AppKit
import UserNotifications

private func dbg(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/glotty-debug.log")) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/glotty-debug.log"))
        }
    }
}

@main
struct GlottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        dbg("GlottyApp.init")
    }

    var body: some Scene {
        // No SwiftUI scene — we host Settings/Permissions/Popup as AppKit windows from
        // the AppDelegate so they surface reliably from the status-bar menu.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mascot: MenuBarMascot?
    private var hotkey: FnLeaderHotkey?
    /// Accessed from MemorySettingsSection's drill-in to reopen a popup for
    /// a stored memory event. Internal-not-private so other module code can
    /// route into the same controller without an NSApp dance.
    var popup: PopupController!
    private var hud: HUDController!
    private let grabber = SelectionGrabber()
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        dbg("Found \(others.count) other Glotty instance(s) — terminating so this build can take over.")
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
        popup = .shared
        hud = HUDController.shared
        dbg("popup + hud created")
        setupStatusItem()
        dbg("status item created")

        // Prime the notifications-status cache so PermissionCheck.anyMissing()
        // can see notification state on the very first check.
        PermissionCheck.refreshNotificationsStatus()

        let missing = PermissionCheck.anyMissing()
        let welcomeDone = UserDefaults.standard.bool(forKey: WelcomeWindowController.userDefaultsKey)
        dbg("anyMissing = \(missing) welcomeDone = \(welcomeDone)")
        if missing && welcomeDone {
            // Only auto-open Settings → Permissions AFTER the user has
            // finished the Welcome flow. While Welcome is showing for
            // the first time, no other window should pop up and
            // distract — the Welcome flow owns the screen. The user
            // can revisit Permissions later via the menu bar or
            // Settings → Permissions tab.
            DispatchQueue.main.async { [weak self] in
                dbg("opening Settings → Permissions (post-welcome missing perms)")
                self?.settingsWindow.show(selecting: .permissions)
            }
        }

        PermissionCheck.registerSilentlyIfMissing()
        dbg("registerSilentlyIfMissing done")

        installHotkey()
        dbg("installHotkey done")

        // First-run walkthrough — no-op if the user has already finished
        // or dismissed it. Runs after permissions / hotkey setup so the
        // user can actually try the hotkey demo it points at.
        WelcomeWindowController.shared.showIfFirstRun()

        let aiStatus = AppleIntelligenceStatus.current()
        dbg("AppleIntelligence: \(aiStatus.displayName)" + (aiStatus.fixInstructions.map { " — \($0)" } ?? ""))

        // Warm the dictionary metadata cache so the very first Fn → T popup gets
        // proper kind classification (not the fallback keyword heuristic).
        DictionaryCatalog.loadIfNeeded {
            dbg("DictionaryCatalog: metadata cache loaded")
        }

        // Proactive practice scheduler — opt-in via Settings. Permission and
        // category registration are idempotent so we always run them; the
        // scheduler itself is a no-op until the user picks a non-zero interval.
        UNUserNotificationCenter.current().delegate = self
        PracticeScheduler.shared.requestNotificationPermissionIfNeeded()
        PracticeScheduler.shared.start()

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
                button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Glotty")
                button.image?.isTemplate = true
            }
            button.toolTip = "Glotty"
        } else {
            print("[Glotty] WARNING: status item has no button — menu bar may be full")
        }
        dbg("status item — visible=\(statusItem.isVisible) length=\(statusItem.length) hasButton=\(statusItem.button != nil)")

        let menu = NSMenu()
        // Rebuild the menu lazily on each open so the Context
        // submenu reflects the current store/active state (contexts
        // may have been added/renamed/deleted since last open).
        menu.delegate = self
        statusItem.menu = menu

        rebuildStatusMenu(menu)
        print("[Glotty] status item created")
    }

    @objc private func openSettings() {
        dbg("openSettings invoked")
        settingsWindow.show()
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

        let settings = NSMenuItem(title: "Settings".t,
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

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
        let noneItem = NSMenuItem(title: "Global only (no context)".t,
                                  action: #selector(setActiveContext(_:)),
                                  keyEquivalent: "")
        noneItem.target = self
        noneItem.state = activeID == nil ? .on : .off
        memorySubmenu.addItem(noneItem)
        if !contexts.isEmpty {
            memorySubmenu.addItem(.separator())
            for ctx in contexts {
                let item = NSMenuItem(title: ctx.name,
                                      action: #selector(setActiveContext(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ctx.id
                item.state = ctx.id == activeID ? .on : .off
                memorySubmenu.addItem(item)
            }
        }
        memorySubmenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage memory".t,
                                action: #selector(openMemorySettings),
                                keyEquivalent: "")
        manage.target = self
        memorySubmenu.addItem(manage)
        memoryItem.submenu = memorySubmenu
        menu.addItem(memoryItem)

        menu.addItem(.separator())

        let welcome = NSMenuItem(title: "Show welcome".t,
                                 action: #selector(showWelcome),
                                 keyEquivalent: "")
        welcome.target = self
        welcome.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(welcome)

        let quit = NSMenuItem(title: "Quit Glotty".t,
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

    /// True if the currently-frontmost app has at least one window
    /// in full-screen mode (kAXFullScreenAttribute). Detection is
    /// best-effort: apps that don't expose AX or hide the attribute
    /// return false, which biases us toward NOT closing Settings —
    /// matching the user preference "only close when other apps
    /// hold the space". Worst case of a false negative: the IME bug
    /// returns for that one popup; the user can dismiss Settings
    /// manually if they need to.
    private static func frontmostAppHasFullScreenWindow() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        // Glotty itself can't be in true full-screen (it's an agent
        // app). If we're frontmost, the user is interacting with
        // Settings or a popup and there's no other-space conflict.
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier { return false }

        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            var fullscreenRef: CFTypeRef?
            // `AXFullScreen` isn't in the public AX constants header
            // but is widely supported by AppKit windows. Apps that
            // don't expose it just produce a not-supported error and
            // we move on.
            let attr = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef)
            if attr == .success, let isFull = fullscreenRef as? Bool, isFull {
                return true
            }
        }
        return false
    }

    private func installHotkey() {
        let hk = FnLeaderHotkey()
        hk.onFire = { [weak self] in self?.handleFire(mode: .translate) }
        hk.onExplainFire = { [weak self] in self?.handleFire(mode: .explain) }
        hk.onPolishFire = { [weak self] in self?.handleFire(mode: .polish) }
        hk.onChatFire = { [weak self] in self?.handleFire(mode: .chat) }
        hk.onShowHUD = { [weak self] in self?.hud.show() }
        hk.onHideHUD = { [weak self] in self?.hud.hide() }
        do {
            try hk.install()
            hotkey = hk
            print("Glotty: Fn → T / Fn → E / Fn → P hotkey installed")
        } catch {
            print("Glotty: hotkey install failed: \(error). Input Monitoring permission likely denied.")
        }
    }

    private func handleFire(mode: PopupMode) {
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
        if mode == .translate,
           !UserDefaults.standard.bool(forKey: TranslateGuideWindowController.userDefaultsKey),
           DictionaryLookup.availableDictionaries().isEmpty {
            TranslateGuideWindowController.shared.show()
            return
        }
        // Raycast-style auto-close: when the popup is about to overlay
        // another app's full-screen space, Settings/drill-in windows
        // need to come down first so the app drops back to .accessory
        // — otherwise the popup launches in .regular and the IME
        // candidate window is suppressed (the original full-screen
        // IME bug). On regular desktops there's no such conflict and
        // we leave Settings alone, so the user can keep referencing
        // it alongside a popup.
        if Self.frontmostAppHasFullScreenWindow() {
            AppActivation.dismissAllRegistered()
        }
        Task { @MainActor in
            // Chat mode doesn't need a selection — it pulls practice topics
            // from MemoryStore instead, so the popup opens with an empty
            // source text.
            if mode == .chat {
                popup.show(sourceText: "", mode: mode)
                return
            }
            let started = CFAbsoluteTimeGetCurrent()
            guard let text = await grabber.grab() else {
                print("Glotty: no selection available")
                return
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print("Glotty: grabbed \(text.count) chars in \(String(format: "%.0f", elapsed))ms (mode=\(mode))")
            popup.show(sourceText: text, mode: mode)
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

// MARK: - Practice notification handling

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the notification banner even when Glotty is frontmost — the user
    /// might be deep in a polish session and we still want them to see the
    /// nudge. Without this, banners are suppressed for the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        dbg("notification willPresent — id=\(notification.request.identifier) userInfo=\(notification.request.content.userInfo)")
        completionHandler([.banner, .sound])
    }

    /// User clicked the notification (or the "Start Practice" action button).
    /// Open the chat popup; it'll pick up the scheduler's pending batch.
    /// We always open the popup on any practice notification — including
    /// the fallback "library is filling" notification — so the click is
    /// never a dead-end. Posting to the main queue ensures the popup opens
    /// even when the system has just woken the app from a background state.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo["kind"] as? String
        let actionId = response.actionIdentifier
        dbg("notification didReceive — kind=\(kind ?? "nil") action=\(actionId) id=\(response.notification.request.identifier)")
        let isPractice = (kind == "practice-session")
            || (kind == "practice-empty")
            || actionId == PracticeScheduler.notificationActionStart
        if isPractice {
            // Hop to the main queue explicitly — UN delegate callbacks come
            // from a worker thread, and `popup` is main-actor-isolated.
            DispatchQueue.main.async { [weak self] in
                self?.popup?.show(sourceText: "", mode: .chat, proactive: true)
            }
        }
        completionHandler()
    }
}
