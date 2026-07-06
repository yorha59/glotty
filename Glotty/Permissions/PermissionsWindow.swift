import AppKit
import SwiftUI
import Combine

@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?

    func show() {
        Log.debug(.permissions, "PermissionsWindowController.show() called")

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
        w.title = "Glotty — \("Permissions".t)"
        // `.resizable` as the fallback to the screen-clamped size below —
        // the user can always drag an edge if the auto size doesn't fit.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSizeClampedToScreen(NSSize(width: 480, height: 460))
        w.contentMinSize = NSSize(width: 400, height: 340)
        w.center()
        w.level = .floating
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive — picking one.
        w.collectionBehavior = [.moveToActiveSpace]

        window = w

        // `NSApp.activate` is unreliable for LSUIElement apps. orderFrontRegardless does
        // the right thing without needing a Dock icon.
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        Log.debug(.permissions, "window shown — frame=\(w.frame) visible=\(w.isVisible) onScreen=\(w.screen?.localizedName ?? "nil")")
    }
}

struct PermissionsView: View {
    /// `nil` when the view is embedded in Settings (no separate window to
    /// close). Standalone window passes a closure here.
    let onClose: (() -> Void)?

    @State private var refreshToken = 0
    @State private var timer: Timer?

    var body: some View {
        // One unified stage that always shows the permission detection
        // rows + status badges. Previously the body switched between a
        // "permissionsStage" (rows visible) and a "readyStage" (no
        // rows, just a "you're ready" panel) — that hid the live
        // status the moment everything went green and left users
        // without a way to confirm what was detected. We now keep the
        // rows up at all times so the detect/granted feedback the
        // Welcome flow exposes is also reachable from Settings.
        permissionsStage
        .padding(20)
        // Standalone window has a fixed size; the Settings embed lets the
        // tab pane decide. Apply the fixed frame only when there's an
        // onClose (i.e. running in the standalone window controller).
        .frame(
            minWidth: 480,
            maxWidth: onClose == nil ? .infinity : 480,
            maxHeight: onClose == nil ? .infinity : 460
        )
        .onAppear {
            // Poll permission state while visible. Refreshes the local
            // refreshToken (forces PermissionRow re-eval) and reads the
            // async notifications status into PermissionCheck's cache.
            PermissionCheck.refreshNotificationsStatus()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    PermissionCheck.refreshNotificationsStatus()
                    refreshToken &+= 1
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .localizationAware()
    }

    // The previous "readyStage" / `stepRow` helpers (a separate UI
    // shown when everything was granted, hiding the per-permission
    // status rows) have been removed — `permissionsStage` now covers
    // both states with the same live-status layout.

    private var permissionsStage: some View {
        let allGranted = !PermissionCheck.anyMissing()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: allGranted ? "checkmark.seal.fill" : "lock.open")
                    .font(.system(size: 22))
                    .foregroundStyle(allGranted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text((allGranted ? "Permissions granted" : "Glotty needs these permissions").t)
                        .font(.title3).bold()
                    Text((allGranted
                         ? "Live status below. Revoke or re-grant any of them from the matching System Settings pane — the row updates automatically."
                         : "Status updates live. Grant in System Settings — this window refreshes automatically.").t)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, refreshToken: refreshToken)
                }
                // System dependency check — same shape as the
                // permission rows. Mirrors the Welcome flow's
                // permissions step so what the user saw during
                // onboarding stays reachable here.
                DictionaryAppRow(refreshToken: refreshToken)
            }

            // Recovery affordance for the signature-collision case: a
            // differently-signed Glotty (e.g. a debug copy installed
            // earlier) already owns the System Settings toggle, so this
            // binary reads as not-granted and the user can't add it.
            // Only shown while something is still missing.
            if !allGranted {
                staleEntryRecoveryCard
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
                if let onClose {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Shown when a permission is still missing. Names the most
    /// confusing failure mode — Glotty already appears enabled but
    /// doesn't work because the toggle belongs to a different build's
    /// signature — and offers a one-click reset that clears the stale
    /// entry and re-registers the running binary.
    private var staleEntryRecoveryCard: some View {
        let title: String = "Already shows as enabled but still not working?".t
        // Single literal (not + concatenation) so extract-strings.sh's
        // `"…".t` rule catches it for the catalog — a concatenated
        // string has no whole-literal for the scanner to see.
        let explain: String = "If “Glotty” already appears switched on in System Settings but Fn → T still does nothing, that toggle belongs to an earlier Glotty with a different signature (e.g. a debug copy). macOS won’t let this build reuse it. Remove that row with the “–” button and re-add Glotty — or hit “Reset” on the affected permission above to clear it and grant again.".t

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline).bold()
            }
            Text(explain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
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
                Text(permission.displayName.t).font(.headline)
                Text(permission.purpose.t)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button((granted ? "Granted ✓" : "Open Settings").t) {
                    PermissionCheck.openSettings(for: permission)
                }
                .disabled(granted)
                if !granted {
                    Button("Reset".t) {
                        PermissionCheck.resetAndReregister(for: permission)
                    }
                    .controlSize(.small)
                    .help("Adds Glotty to the toggle list (use if the row is missing), and clears any leftover entry from an earlier, differently-signed build so this one can register fresh.")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}

/// System-dependency row for Apple's built-in Dictionary.app. Same
/// visual shape as `PermissionRow` so the Settings list reads
/// uniformly. Re-evaluated whenever the parent bumps
/// `refreshToken` (every second while the view is visible), so a
/// freshly-restored Dictionary.app flips from "Missing" to
/// "Installed" automatically.
private struct DictionaryAppRow: View {
    let refreshToken: Int

    private var url: URL? {
        _ = refreshToken
        for path in ["/System/Applications/Dictionary.app",
                     "/Applications/Dictionary.app"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    var body: some View {
        let present = url != nil
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: present ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(present ? .green : .orange)
                .imageScale(.large)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dictionary.app").font(.headline)
                Text((present
                     ? "Apple's built-in Dictionary app — Glotty reads its catalog to power offline dictionary lookups during Translate."
                     : "Required for offline dictionary lookups. Ships with macOS; can't be reinstalled from the App Store. Run Software Update or use Migration Assistant to restore it.").t)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if present {
                    Button("Installed ✓".t) { }
                        .disabled(true)
                } else {
                    Button("Software Update".t) {
                        if let su = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") {
                            NSWorkspace.shared.open(su)
                        }
                    }
                    Button("Apple Support".t) {
                        if let url = URL(string: "https://support.apple.com/guide/dictionary/welcome/mac") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .help("Apple's Dictionary user guide — covers reinstalling system apps.")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}
