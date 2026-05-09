import Foundation
import AppKit
import ApplicationServices
import IOKit.hid

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            return "Read selected text from the focused application so it can be translated."
        case .inputMonitoring:
            return "Detect the Fn → T hotkey via a low-level event tap."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    func isGranted() -> Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrustedWithOptions(nil)
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }
}

enum PermissionCheck {
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
    }

    /// Reset Glotty's TCC entries via the user-facing `tccutil` command. Useful when a
    /// stale ad-hoc-signed identity poisons the cache and the granted toggle no longer
    /// applies to the freshly-built binary.
    static func tccResetCommand() -> String {
        "tccutil reset Accessibility com.ruojunye.glotty && tccutil reset ListenEvent com.ruojunye.glotty"
    }
}
