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
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        dbg("applicationDidFinishLaunching START")
        popup = .shared
        hud = HUDController()
        dbg("popup + hud created")
        setupStatusItem()
        dbg("status item created")

        // Prime the notifications-status cache so PermissionCheck.anyMissing()
        // can see notification state on the very first check.
        PermissionCheck.refreshNotificationsStatus()

        let missing = PermissionCheck.anyMissing()
        dbg("anyMissing = \(missing)")
        if missing {
            // Open Settings → Permissions tab instead of the legacy standalone
            // window. The permissions UI now lives there. Defer to next runloop
            // tick — creating an NSHostingController inside
            // applicationDidFinishLaunching deadlocks the SwiftUI App scene init.
            DispatchQueue.main.async { [weak self] in
                dbg("opening Settings → Permissions (first-launch missing perms)")
                self?.settingsWindow.show(selecting: .permissions)
            }
        }

        PermissionCheck.registerSilentlyIfMissing()
        dbg("registerSilentlyIfMissing done")

        installHotkey()
        dbg("installHotkey done")

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

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Glotty",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        print("[Glotty] status item created")
    }

    @objc private func openSettings() {
        dbg("openSettings invoked")
        settingsWindow.show()
    }

    private func installHotkey() {
        let hk = FnLeaderHotkey()
        hk.onFire = { [weak self] in self?.handleFire(mode: .translate) }
        hk.onExplainFire = { [weak self] in self?.handleFire(mode: .explain) }
        hk.onPolishFire = { [weak self] in self?.handleFire(mode: .polish) }
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
        // Raycast-style: if Settings or a Mistake-type drill-in is open,
        // close it before showing the popup. Those windows hold an
        // `AppActivation` slot (.regular policy), and a popup launched
        // while we're .regular won't receive IME candidates over a
        // full-screen overlay — reads as a bug to the user.
        // `dismissAllRegistered` runs synchronously and resets the
        // activation policy back to .accessory before this function
        // returns, so the popup below opens in agent mode.
        AppActivation.dismissAllRegistered()
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
                self?.popup?.show(sourceText: "", mode: .chat)
            }
        }
        completionHandler()
    }
}
