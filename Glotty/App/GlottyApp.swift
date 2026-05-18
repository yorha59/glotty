import SwiftUI
import AppKit

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
    private var hotkey: FnLeaderHotkey?
    private var popup: PopupController!
    private var hud: HUDController!
    private let grabber = SelectionGrabber()
    private let permissionsWindow = PermissionsWindowController()
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        dbg("applicationDidFinishLaunching START")
        popup = PopupController()
        hud = HUDController()
        dbg("popup + hud created")
        setupStatusItem()
        dbg("status item created")

        let missing = PermissionCheck.anyMissing()
        dbg("anyMissing = \(missing)")
        if missing {
            // Defer window creation to next runloop tick — creating an NSHostingController
            // from inside applicationDidFinishLaunching with a SwiftUI App lifecycle deadlocks
            // because the SwiftUI scene graph is still initializing.
            DispatchQueue.main.async { [weak self] in
                dbg("calling permissionsWindow.show (deferred)")
                self?.permissionsWindow.show()
                dbg("permissionsWindow.show returned")
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

        dbg("applicationDidFinishLaunching END")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Glotty")
            button.image?.isTemplate = true
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
        hk.onPolishFire = { [weak self] in self?.handleFire(mode: .polish) }
        hk.onShowHUD = { [weak self] in self?.hud.show() }
        hk.onHideHUD = { [weak self] in self?.hud.hide() }
        do {
            try hk.install()
            hotkey = hk
            print("Glotty: Fn → T / Fn → R hotkey installed")
        } catch {
            print("Glotty: hotkey install failed: \(error). Input Monitoring permission likely denied.")
        }
    }

    private func handleFire(mode: PopupMode) {
        Task { @MainActor in
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
