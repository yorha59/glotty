import AppKit
import SwiftUI
import CoreGraphics

/// Debug helper that walks every `SettingsTab`, shows the real
/// Settings window with that tab selected, captures the window
/// pixels via `CGWindowListCreateImage`, and writes a PNG per
/// tab to `/tmp/glotty-screenshots/`. Lets the developer (or the
/// agent assisting them) audit which strings still need
/// localization without manually clicking every tab.
///
/// We reuse `SettingsWindowController.show(selecting:)` (which
/// already supports rebuilding the window with a chosen initial
/// tab) rather than mounting an offscreen NSHostingController —
/// the latter crashes with EXC_BAD_ACCESS because SwiftUI's
/// NavigationSplitView needs a fully visible window to render.
@MainActor
enum SettingsSnapshotter {
    static let outputDirectory: URL = URL(fileURLWithPath: "/tmp/glotty-screenshots")

    /// Distributed-notification name the agent can post from bash
    /// (`swift -e 'DistributedNotificationCenter.default().post(...)'`)
    /// to trigger a capture without needing Accessibility to drive
    /// the UI. Listener installed by AppDelegate on launch.
    ///
    /// `userInfo` keys (optional, all may be omitted to capture
    /// everything):
    ///   - `"tabs"`: comma-separated list of `SettingsTab` raw
    ///     values to capture (e.g. `"polish,profile"`). Unknown tab
    ///     names are skipped with a debug log line.
    ///   - `"includeHUD"`: pass `"false"` to skip the Fn-leader HUD
    ///     capture (it's included by default).
    /// Examples:
    ///   - All tabs + HUD: post with no userInfo
    ///   - Polish only: `userInfo = ["tabs": "polish", "includeHUD": "false"]`
    static let captureNotificationName = Notification.Name("com.ruojunye.glotty.captureAllSettingsTabs")

    /// One-time install — call from AppDelegate. The handler hops
    /// to MainActor and routes the notification's userInfo into
    /// `capture(tabs:includeHUD:)`. Logs to /tmp/glotty-debug.log so
    /// we can confirm the observer is wired when notifications don't
    /// seem to fire.
    nonisolated static func installRemoteTriggerObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: captureNotificationName,
            object: nil,
            queue: .main,
            using: { note in
                writeLog("SettingsSnapshotter: notification received userInfo=\(note.userInfo ?? [:])")
                let (tabs, includeHUD) = parseTrigger(userInfo: note.userInfo)
                Task { @MainActor in
                    await SettingsSnapshotter.capture(tabs: tabs, includeHUD: includeHUD)
                    writeLog("SettingsSnapshotter: capture done — tabs=\(tabs.map(\.rawValue)) hud=\(includeHUD)")
                }
            }
        )
        writeLog("SettingsSnapshotter: observer installed for \(captureNotificationName.rawValue)")
    }

    /// Pull `tabs` + `includeHUD` out of the notification's
    /// `userInfo`. Both are optional; defaults to "all tabs + HUD"
    /// so existing all-tab triggers keep working.
    nonisolated private static func parseTrigger(userInfo: [AnyHashable: Any]?)
    -> (tabs: [SettingsTab], includeHUD: Bool) {
        var tabs: [SettingsTab] = SettingsTab.allCases
        var includeHUD = true

        if let raw = userInfo?["tabs"] as? String {
            let requested = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var matched: [SettingsTab] = []
            var seen = Set<String>()
            for token in requested {
                if let tab = SettingsTab(rawValue: token), seen.insert(token).inserted {
                    matched.append(tab)
                } else if !seen.contains(token) {
                    writeLog("SettingsSnapshotter: ignoring unknown tab '\(token)'")
                }
            }
            tabs = matched
        }
        if let raw = userInfo?["includeHUD"] as? String {
            includeHUD = !["false", "0", "no"].contains(raw.lowercased())
        }
        return (tabs, includeHUD)
    }

    nonisolated private static func writeLog(_ message: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.settings, message, file: file, line: line)
    }

    /// Capture an arbitrary subset of Settings tabs (plus optionally
    /// the Fn HUD). The all-tabs trigger that used to be the only
    /// entry point is now just `capture(tabs: SettingsTab.allCases)`.
    /// Output dir is wiped before each run so old captures from a
    /// previous request don't linger and confuse the audit.
    static func capture(tabs: [SettingsTab],
                        includeHUD: Bool = true) async {
        try? FileManager.default.removeItem(at: outputDirectory)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        let controller = SettingsWindowController.shared
        for tab in tabs {
            // Re-show the window with the desired tab. show() with
            // a non-nil tab tears down the existing host and builds
            // a fresh one whose @State selection is the requested
            // tab — exactly what we need per iteration.
            controller.show(selecting: tab)

            // Give SwiftUI a moment to lay out + paint the new
            // detail view. Two ticks: one for the .task / state
            // settle, one for the resulting paint.
            for _ in 0..<3 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            captureFrontmostSettingsWindow(named: "\(tab.rawValue).png")
        }

        if includeHUD {
            await captureHUD()
        }

        // Reveal in Finder when done so the user sees the output.
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
    }

    private static func captureHUD() async {
        let hud = HUDController.shared
        hud.show()
        for _ in 0..<3 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let panel = hud.currentPanel, let view = panel.contentView {
            let bounds = view.bounds
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let url = outputDirectory.appendingPathComponent("hud.png")
                    try? png.write(to: url)
                }
            }
        }
        hud.hide()
    }

    /// Capture the Settings window's content view via AppKit's
    /// bitmap API. Caveat: does NOT include the title bar (not part
    /// of contentView) and the NavigationSplitView sidebar's
    /// `Label` text isn't always cached by this path. Sidebar tab
    /// labels DO go through `.t` wrapping in `SettingsView.body`
    /// so they translate at runtime — they just don't show up in
    /// these audit screenshots.
    private static func captureFrontmostSettingsWindow(named filename: String) {
        guard let window = SettingsWindowController.shared.currentWindow,
              let view = window.contentView else { return }
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = outputDirectory.appendingPathComponent(filename)
        try? png.write(to: url)
    }
}
