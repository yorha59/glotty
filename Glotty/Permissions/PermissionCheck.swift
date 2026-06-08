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
            return "Deliver proactive chat reminders so Glotty can check in with you in your target language."
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

    /// `tccutil` service token for permissions whose grant is bound to
    /// the app's *code signature*. These are the ones that collide when
    /// an earlier, differently-signed build with the SAME bundle id
    /// already owns the System Settings toggle (e.g. a debug copy a
    /// tester installed before the Developer ID release): the release
    /// binary reads as not-granted, but the user can't add it because a
    /// same-named row already exists. Resetting by bundle id clears the
    /// stale row so the current signature can register fresh. Nil for
    /// Notifications, which isn't signature-bound and doesn't collide.
    var tccServiceName: String? {
        switch self {
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "ListenEvent"
        case .notifications:   return nil
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
    /// cache. Cheap (system call) and idempotent. The optional completion
    /// runs (on the main queue) once the cache reflects the real status —
    /// callers that need an accurate `anyMissing()` immediately (e.g. the
    /// launch-time permissions auto-open) must wait for it, since the
    /// underlying API is async and the cache defaults to "not granted".
    static func refreshNotificationsStatus(completion: (@MainActor @Sendable () -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            cachedNotificationsGranted = (settings.authorizationStatus == .authorized
                                          || settings.authorizationStatus == .provisional)
            if let completion {
                Task { @MainActor in completion() }
            }
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

    /// Clear this app's TCC decision for `permission` via `tccutil`, then
    /// re-trigger registration so the CURRENT binary re-appears in System
    /// Settings under its own signature. Recovery path for the
    /// "a same-named, differently-signed build already owns the toggle"
    /// problem — the stale entry (keyed by bundle id) is removed and the
    /// running binary registers fresh. Uses `Bundle.main.bundleIdentifier`
    /// so it targets whichever build is running (Glotty or GlottyLab),
    /// never a hard-coded id.
    @discardableResult
    static func resetGrant(for permission: Permission) -> Bool {
        guard let service = permission.tccServiceName,
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", service, bundleID]
        do {
            try proc.run()
            proc.waitUntilExit()
            debugWrite("tccutil reset \(service) \(bundleID) -> status \(proc.terminationStatus)")
        } catch {
            debugWrite("tccutil reset \(service) \(bundleID) FAILED: \(error.localizedDescription)")
            return false
        }
        // Re-register so the current signature lands back in the list /
        // surfaces the system prompt.
        requestRegistration(for: permission)
        return true
    }

    /// One-click recovery for a missing permission, merging the old
    /// "Reset" and "Re-register" actions into a single step:
    ///   - For signature-bound permissions (Accessibility / Input
    ///     Monitoring) it first `tccutil reset`s the bundle id — a
    ///     harmless no-op when nothing's there, and the fix when a
    ///     differently-signed build's stale entry owns the toggle —
    ///     then re-registers so this binary appears under its own
    ///     signature.
    ///   - For Notifications (not signature-bound) it just re-requests.
    /// Either way the user ends up with the current build correctly
    /// registered, whether the row was missing or stale.
    static func resetAndReregister(for permission: Permission) {
        if permission.tccServiceName != nil {
            resetGrant(for: permission)   // tccutil reset + re-register
        } else {
            requestRegistration(for: permission)
        }
    }

    private static func debugWrite(_ msg: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.permissions, msg, file: file, line: line)
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

}
