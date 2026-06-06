import AppKit
import Foundation

/// Severity for a log line. Rendered as the second column in
/// /tmp/glotty-debug.log so it can be `grep`-filtered cheaply.
enum LogLevel: String {
    case debug = "DEBUG"
    case info  = "INFO "
    case warn  = "WARN "
    case error = "ERROR"
}

/// Subsystem / area-of-the-app the log line is reporting on. Keep
/// this list short and stable — every category becomes a search
/// keyword users (and us) will grep for when investigating a bug
/// report. Add a case only when the new area genuinely doesn't fit
/// any existing bucket.
enum LogCategory: String {
    case app          = "app"
    case activation   = "activation"
    case hotkey       = "hotkey"
    case popup        = "popup"
    case settings     = "settings"
    case permissions  = "permissions"
    case llm          = "llm"
    case memory       = "memory"
    case localization = "localization"
}

/// Glotty's single point of truth for diagnostic logging.
///
/// One file at `/tmp/glotty-debug.log`, one writer queue, one
/// format. Replaces the half-dozen private `dbg()` helpers that
/// each duplicated FileHandle boilerplate and produced their own
/// slightly-different line shapes.
///
/// Line format:
///     2026-06-04T00:15:32.123Z DEBUG [popup] PopupView.swift:1740 op=fn-translate — setup mode=translate
///
/// - Timestamp is ISO-8601 with millisecond precision so support
///   reports can be sorted across machines and time zones.
/// - Level is fixed-width-padded so message columns line up.
/// - Category in square brackets is the area-of-app keyword for
///   grep.
/// - File:line comes from `#fileID` / `#line` at the call site
///   (the wrappers below forward both through `dbg(...)` so the
///   existing call sites don't need to change to gain file/line).
/// - `op=…` is the user-facing operation the line is attributed
///   to, if the caller passed one. Defaults to `-` when unknown.
///   Use this to filter "everything that happened while the user
///   was running Fn → Translate" out of a busy log.
/// - The message is the existing free-form string.
///
/// Storage:
/// - `/tmp/glotty-debug.log` (current). Survives until reboot;
///   we'll move to a more durable location once we need it.
/// - Soft 5 MB cap with single-step rotation to `.1`; older rotated
///   files are dropped. Keeps logs bounded without losing the
///   most-recent window.
enum Log {
    /// `/tmp/glotty-debug.log` for the normal (non-sandboxed) build.
    /// Under the App Sandbox `/tmp` isn't writable, so fall back to the
    /// process's container temp dir — otherwise every write fails
    /// silently and the log never appears. Detected via the sandbox's
    /// own container env var rather than a write probe.
    static let path: String = {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return (NSTemporaryDirectory() as NSString).appendingPathComponent("glotty-debug.log")
        }
        return "/tmp/glotty-debug.log"
    }()

    /// Soft cap. We rotate when the file grows past this; the
    /// previous segment is moved aside to `.1` and overwritten on
    /// the next rotation. 5 MB ≈ ~30k log lines, which is plenty
    /// to capture a session's worth of activity without filling
    /// /tmp.
    private static let maxBytes: Int = 5_000_000

    /// Serial queue so concurrent log calls from popup / hotkey /
    /// LLM threads don't interleave bytes inside a single line.
    /// `.utility` QoS keeps logging off the main scheduler.
    private static let queue = DispatchQueue(
        label: "com.ruojunye.glotty.log",
        qos: .utility
    )

    /// One shared formatter — `ISO8601DateFormatter` is heavy to
    /// allocate, so we keep it long-lived. Threading: serial queue
    /// above is the only writer.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func debug(_ category: LogCategory, _ message: String, op: String = "-",
                      file: String = #fileID, line: Int = #line) {
        write(level: .debug, category: category, message: message, op: op, file: file, line: line)
    }

    static func info(_ category: LogCategory, _ message: String, op: String = "-",
                     file: String = #fileID, line: Int = #line) {
        write(level: .info, category: category, message: message, op: op, file: file, line: line)
    }

    static func warn(_ category: LogCategory, _ message: String, op: String = "-",
                     file: String = #fileID, line: Int = #line) {
        write(level: .warn, category: category, message: message, op: op, file: file, line: line)
    }

    static func error(_ category: LogCategory, _ message: String, op: String = "-",
                      file: String = #fileID, line: Int = #line) {
        write(level: .error, category: category, message: message, op: op, file: file, line: line)
    }

    /// Copy the current + rotated log files to the user's Desktop
    /// under a dated filename, then reveal them in Finder. Returns
    /// the destination URL on success — useful for the Settings
    /// "Export logs" button to surface the path in a confirmation
    /// label.
    @discardableResult
    static func exportToDesktop() -> URL? {
        let fm = FileManager.default
        guard let desktop = try? fm.url(
            for: .desktopDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }

        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.timeZone = TimeZone.current
            return f.string(from: Date())
        }()
        let dest = desktop.appendingPathComponent("glotty-debug-\(stamp).log")
        let primary = URL(fileURLWithPath: path)
        let rotated = URL(fileURLWithPath: path + ".1")

        // Concatenate rotated (older) + primary (newer) so the
        // output is in chronological order regardless of which
        // segments exist.
        try? fm.removeItem(at: dest)
        fm.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else { return nil }
        defer { try? handle.close() }

        for src in [rotated, primary] where fm.fileExists(atPath: src.path) {
            if let data = try? Data(contentsOf: src) {
                handle.write(data)
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
        return dest
    }

    /// One-shot snapshot of the system's focus / activation state at
    /// the moment a managed window opens. Logs the handful of
    /// properties that disagree when a window opens into a bad
    /// activation state (the failure fengchu hit: window visually
    /// front + key, but system frontmost stayed with a full-screen
    /// source app, so keystrokes went elsewhere).
    ///
    /// Read the line by looking for contradictions, e.g.
    /// `windowIsKey=true` together with `frontmost=com.apple.Safari`
    /// and `appIsActive=false` means "we think we own focus, the
    /// system disagrees" — and `frontmostIsFullScreen=true` is why.
    @MainActor
    static func activationSnapshot(window: NSWindow?, name: String, op: String,
                                   file: String = #fileID, line: Int = #line) {
        // Defer one runloop tick: key-window and app-active status are
        // granted asynchronously after makeKeyAndOrderFront, so reading
        // them synchronously always reports false. By the next tick the
        // window manager has settled and the snapshot reflects reality.
        let behavior = window?.collectionBehavior.rawValue ?? 0
        DispatchQueue.main.async { [weak window] in
            let policy = NSApp.activationPolicy().rawValue
            let isActive = NSApp.isActive
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            let fullScreen = frontmostIsFullScreen()
            let isKey = window?.isKeyWindow ?? false
            info(.activation, "opened window=\(name) policy=\(policy) appIsActive=\(isActive) "
                 + "frontmost=\(frontmost) frontmostIsFullScreen=\(fullScreen) "
                 + "windowIsKey=\(isKey) collectionBehavior=\(behavior)",
                 op: op, file: file, line: line)
        }
    }

    /// True if the current frontmost app (not Glotty) has a window in
    /// native full-screen. Mirrors the AppDelegate's private check;
    /// kept self-contained here so the diagnostics module has no
    /// dependency on app internals.
    @MainActor
    private static func frontmostIsFullScreen() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var fsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success,
               let isFull = fsRef as? Bool, isFull {
                return true
            }
        }
        return false
    }

    private static func write(level: LogLevel, category: LogCategory,
                              message: String, op: String,
                              file: String, line: Int) {
        let ts = dateFormatter.string(from: Date())
        // `#fileID` is "ModuleName/Subpath/Foo.swift"; strip to the
        // basename so lines stay readable.
        let basename = (file as NSString).lastPathComponent
        let formatted = "\(ts) \(level.rawValue) [\(category.rawValue)] \(basename):\(line) op=\(op) — \(message)\n"
        queue.async {
            rotateIfNeeded()
            append(formatted)
        }
    }

    /// Append-or-create. Bypasses FileHandle for the create branch
    /// since `FileHandle(forWritingTo:)` errors when the file
    /// doesn't exist yet.
    private static func append(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return }
        let primary = URL(fileURLWithPath: path)
        let rotated = URL(fileURLWithPath: path + ".1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: primary, to: rotated)
    }
}
