import Foundation
import AppKit
import ApplicationServices
import IOKit.hid
import UserNotifications

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case notifications

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        case .notifications:    return "Notifications"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            return "Read selected text from the focused application so it can be translated."
        case .inputMonitoring:
            return "Detect the Fn → T hotkey via a low-level event tap."
        case .notifications:
            return "Deliver proactive practice reminders when it's time for a quick quiz on your recent mistakes."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .notifications:
            // macOS routes "Notifications" via its own pane — no per-app
            // deep-link works reliably across versions, so this lands on the
            // Notifications root and the user picks Glotty from the list.
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }

    func isGranted() -> Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrustedWithOptions(nil)
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .notifications:
            // UNUserNotificationCenter's settings API is async — we keep a
            // cached value that PermissionCheck.refreshNotificationsStatus()
            // updates in the background (called on app start + while the
            // Permissions view is visible).
            return PermissionCheck.cachedNotificationsGranted
        }
    }
}

enum PermissionCheck {
    /// Cached notifications-authorized status — UN's settings API is async,
    /// so we read it via `refreshNotificationsStatus()` and stash the result
    /// here for synchronous `Permission.notifications.isGranted()` queries.
    /// Defaults to false: better to show "not granted" briefly on launch
    /// than falsely report success.
    nonisolated(unsafe) static var cachedNotificationsGranted: Bool = false

    /// Read the current notifications authorization status and update the
    /// cache. Cheap (system call) and idempotent.
    static func refreshNotificationsStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            cachedNotificationsGranted = (settings.authorizationStatus == .authorized
                                          || settings.authorizationStatus == .provisional)
        }
    }

    static func anyMissing() -> Bool {
        Permission.allCases.contains { !$0.isGranted() }
    }

    static func summary() -> String {
        Permission.allCases
            .map { "\($0.displayName) \($0.isGranted() ? "✓" : "✗")" }
            .joined(separator: "  ")
    }

    static func openSettings(for permission: Permission) {
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Force macOS to register Glotty for each TCC permission so an entry appears in
    /// System Settings → Privacy & Security. For Input Monitoring this is the *only*
    /// way to get Glotty into the toggle list. For Accessibility this surfaces the
    /// system "Allow / Deny" prompt the first time.
    static func requestRegistration(for permission: Permission) {
        switch permission {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let result = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            debugWrite("AXIsProcessTrustedWithOptions(prompt=true) -> \(result)")
        case .inputMonitoring:
            let result = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            debugWrite("IOHIDRequestAccess(ListenEvent) -> \(result)")
        case .notifications:
            // First-ever call shows the system prompt; subsequent calls are
            // no-ops if the user has already decided. Either way, refresh
            // the cache afterward so the row flips to ✓ without delay.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                cachedNotificationsGranted = granted
                debugWrite("UNUserNotificationCenter.requestAuthorization -> granted=\(granted) err=\(error?.localizedDescription ?? "nil")")
            }
        }
    }

    private static func debugWrite(_ msg: String) {
        let line = "[\(Date())] PermissionCheck: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/glotty-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Only auto-registers permissions that *don't* show an in-app system prompt.
    /// Accessibility's prompt-on-true is annoying because it fires on every launch until
    /// granted; we don't call it here. The user grants via "Open Settings" in the
    /// permissions window instead.
    /// Input Monitoring's `IOHIDRequestAccess` is required to make Glotty appear in the
    /// toggle list at all, so we *do* call that.
    static func registerSilentlyIfMissing() {
        if !Permission.inputMonitoring.isGranted() {
            requestRegistration(for: .inputMonitoring)
        }
        // Notifications: prime the cache and (on first run) trigger the
        // system prompt. Subsequent runs are no-ops if the user already
        // decided, so this is safe to call unconditionally.
        refreshNotificationsStatus()
        if !cachedNotificationsGranted {
            requestRegistration(for: .notifications)
        }
    }

    /// Reset Glotty's TCC entries via the user-facing `tccutil` command. Useful when a
    /// stale ad-hoc-signed identity poisons the cache and the granted toggle no longer
    /// applies to the freshly-built binary.
    static func tccResetCommand() -> String {
        "tccutil reset Accessibility com.ruojunye.glotty && tccutil reset ListenEvent com.ruojunye.glotty"
    }
}
