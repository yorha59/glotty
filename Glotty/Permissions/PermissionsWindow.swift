import AppKit
import SwiftUI
import Combine

@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?

    func show() {
        let line = "[\(Date())] PermissionsWindowController.show() called\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/glotty-debug.log")) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: "/tmp/glotty-debug.log"))
            }
        }
        NSLog("[Glotty] PermissionsWindowController.show() called")

        // Always rebuild from scratch — defends against any stale window state from a
        // previous close. Cheap enough for a spike, removes a whole class of bugs.
        if let existing = window {
            existing.orderOut(nil)
            window = nil
        }

        let view = PermissionsView(onClose: { [weak self] in
            self?.window?.orderOut(nil)
        })

        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Glotty — Permissions"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 480, height: 460))
        w.center()
        w.level = .floating
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive — picking one.
        w.collectionBehavior = [.moveToActiveSpace]

        window = w

        // `NSApp.activate` is unreliable for LSUIElement apps. orderFrontRegardless does
        // the right thing without needing a Dock icon.
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        let endLine = "[\(Date())] window shown — frame=\(w.frame) visible=\(w.isVisible) onScreen=\(w.screen?.localizedName ?? "nil")\n"
        if let d = endLine.data(using: .utf8), let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/glotty-debug.log")) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        }
        NSLog("[Glotty] PermissionsWindowController shown — frame=\(w.frame), visible=\(w.isVisible)")
    }
}

struct PermissionsView: View {
    let onClose: () -> Void

    @State private var refreshToken = 0
    @State private var timer: Timer?
    @State private var showStaleHelp = false

    private var diagnosticText: Text {
        let bundleID = Bundle.main.bundleIdentifier ?? "—"
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let ax = Permission.accessibility.isGranted() ? "true" : "false"
        let im = Permission.inputMonitoring.isGranted() ? "true" : "false"
        return Text("""
        bundle: \(bundleID)
        path:   \(bundlePath)
        pid:    \(pid)
        AXIsProcessTrustedWithOptions(nil) = \(ax)
        IOHIDCheckAccess(ListenEvent) granted = \(im)
        """)
    }

    var body: some View {
        Group {
            if PermissionCheck.anyMissing() {
                permissionsStage
            } else {
                readyStage
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    refreshToken &+= 1
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var readyStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glotty is ready!").font(.title2).bold()
                    Text("Both permissions granted. Try it out below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("How to translate")
                    .font(.headline)

                stepRow(number: "1", text: "Highlight any text in another app (browser, PDF, Notes, etc.).")
                stepRow(number: "2", text: "Press the **Fn** key, then within 600ms press **T**.")
                stepRow(number: "3", text: "A popup appears with the translation, no focus stolen.")
            }

            Spacer(minLength: 0)

            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text("Glotty lives in your menu bar — click 🌐 for options.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(.callout, design: .rounded).bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glotty needs these permissions").font(.title3).bold()
                Text("Status updates live. Grant in System Settings — this window refreshes automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, refreshToken: refreshToken)
                }
            }

            DisclosureGroup(isExpanded: $showStaleHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Granted but Glotty still says ✗?")
                        .font(.callout).bold()
                    Text("Dev builds are ad-hoc signed, so each rebuild has a different code signature. macOS's TCC tracks per-signature — your previous grant may belong to an older build. Two things to try:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("1. In System Settings → Accessibility, click the (–) minus button to remove every Glotty entry, then relaunch Glotty and grant fresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("2. From Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(PermissionCheck.tccResetCommand())
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                        .textSelection(.enabled)
                    Text("Then quit & relaunch Glotty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)

                    Text("Diagnostic info")
                        .font(.callout).bold()
                    diagnosticText
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 6)
            } label: {
                Text("Troubleshooting").font(.callout)
            }

            Spacer(minLength: 0)

            HStack {
                Image(systemName: PermissionCheck.anyMissing()
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.seal.fill")
                    .foregroundStyle(PermissionCheck.anyMissing() ? .orange : .green)
                Text(PermissionCheck.anyMissing()
                     ? "Some permissions missing — Fn → T won't work yet."
                     : "All set. Quit & relaunch if you just granted permissions.")
                    .font(.callout)
                Spacer()
                Button("Re-register Missing") {
                    for p in Permission.allCases where !p.isGranted() {
                        PermissionCheck.requestRegistration(for: p)
                    }
                    refreshToken &+= 1
                }
                .help("Re-trigger macOS's registration so Glotty appears in System Settings. May show a system prompt for Accessibility.")
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let refreshToken: Int

    private var granted: Bool {
        _ = refreshToken // dependency to force re-eval
        return permission.isGranted()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .imageScale(.large)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName).font(.headline)
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button(granted ? "Granted ✓" : "Open Settings") {
                    PermissionCheck.openSettings(for: permission)
                }
                .disabled(granted)
                if !granted {
                    Button("Re-register") {
                        PermissionCheck.requestRegistration(for: permission)
                    }
                    .controlSize(.small)
                    .help("Forces macOS to add Glotty to the toggle list. Use this if the row is missing in System Settings.")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}
