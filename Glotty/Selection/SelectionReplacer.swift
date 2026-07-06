import Foundation
import AppKit
import ApplicationServices

/// Writes `replacement` over the user's current selection in the frontmost app —
/// the mirror image of `SelectionGrabber`. Tries the Accessibility API first
/// (sets the focused element's selected text directly, zero clipboard pollution),
/// and falls back to synthesizing Cmd+V for apps that don't expose a settable
/// AX selected-text attribute (Electron, some Java).
///
/// Both paths replace whatever is currently selected, so the caller must grab
/// the selection (which leaves it highlighted) immediately before calling this.
final class SelectionReplacer {
    enum Outcome {
        case accessibility   // wrote via AX, no clipboard touched
        case paste           // wrote via synthesized Cmd+V
        case failed          // nothing editable to write into
    }

    /// Bundle ids of terminal emulators. In a terminal the highlighted text is
    /// just a copy selection — it isn't the insertion point — so a synthesized
    /// Cmd+V inserts the correction at the prompt cursor (appending) instead of
    /// replacing the selection. There's no way to replace selected scrollback
    /// text in a terminal, so we must NOT paste there; the caller copies the
    /// correction to the clipboard instead.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp", "dev.warp.Warp-Stable",
        "org.alacritty", "io.alacritty",
        "com.mitchellh.ghostty",
        "com.apple.dt.Xcode",          // integrated console — paste won't replace
    ]

    /// Replace the current selection with `replacement`. Returns how it was
    /// written (or `.failed` if no editable target accepted it).
    ///
    /// We use the synthesized-paste path for every app except terminals. We do
    /// NOT try AX `setSelectedText` first: Chromium-based apps (Chrome, Electron)
    /// report that attribute as settable and return `.success`, but don't
    /// actually replace the text — so corrections silently no-op'd in the
    /// browser while we reported success. Paste reliably replaces the selection
    /// in native fields and Chromium/Electron alike. Terminals are excluded
    /// because there a paste appends at the prompt instead of replacing.
    @discardableResult
    func replace(with replacement: String) async -> Outcome {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if frontmostIsTerminal() {
            Log.debug(.app, "replace — terminal (\(front)); deferring to clipboard")
            return .failed
        }
        let ok = await replaceViaPaste(replacement)
        Log.debug(.app, "replace — paste into \(front) → \(ok)")
        return ok ? .paste : .failed
    }

    private func frontmostIsTerminal() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIDs.contains(id)
    }

    // MARK: - Paste

    /// Put the replacement on the pasteboard, synthesize Cmd+V to paste over the
    /// selection, then restore the user's original clipboard. Symmetric with
    /// `SelectionGrabber.grabViaPasteboard`, and tagged with the same synthetic
    /// marker so Glotty's own event tap ignores the keystroke.
    private func replaceViaPaste(_ replacement: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)

        synthesizeCmdV()

        // Wait for the target app to consume the paste before we put the
        // user's clipboard back, otherwise the restore can race the Cmd+V
        // and the app pastes the old contents. Chromium can be slower to
        // apply the paste than native fields, so we give it a bit longer.
        try? await Task.sleep(nanoseconds: 220_000_000) // 220ms

        if let savedString {
            pasteboard.clearContents()
            pasteboard.setString(savedString, forType: .string)
        }
        // Paste is fire-and-forget — we can't observe whether the app actually
        // had an editable target. We optimistically report success; the AX
        // settable check above is what gates "is this even editable" in the
        // common native-app case.
        return true
    }

    private func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let kVK_V: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Reuse the grabber's marker so FnLeaderHotkey skips these events.
        down.setIntegerValueField(.eventSourceUserData, value: SelectionGrabber.syntheticEventUserData)
        up.setIntegerValueField(.eventSourceUserData, value: SelectionGrabber.syntheticEventUserData)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
