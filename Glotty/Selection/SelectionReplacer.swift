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
    private static let terminalBundleIDs: Set<String> = [
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
    @discardableResult
    func replace(with replacement: String) async -> Outcome {
        if replaceViaAccessibility(replacement) { return .accessibility }
        // The AX path didn't take. Before falling back to a synthesized paste,
        // bail on terminals — there, Cmd+V appends at the cursor rather than
        // replacing the selection, which produced "correct word tacked on after
        // the typo". Let the caller surface "copied to clipboard" instead.
        if frontmostIsTerminal() { return .failed }
        if await replaceViaPaste(replacement) { return .paste }
        return .failed
    }

    private func frontmostIsTerminal() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIDs.contains(id)
    }

    // MARK: - AX path

    /// Set `kAXSelectedTextAttribute` on the focused element. Guarded by
    /// `AXUIElementIsAttributeSettable` so we never clobber a read-only field
    /// (a web article you're only reading, a label) — those report the
    /// attribute as not settable, and we fall through to the paste path which
    /// is itself a harmless no-op there.
    private func replaceViaAccessibility(_ replacement: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAny: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedAny
        )
        guard focusResult == .success,
              let focusedRef = focusedAny,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let focused = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            return false
        }

        let setResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        )
        return setResult == .success
    }

    // MARK: - Paste fallback

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
        // and the app pastes the old contents.
        try? await Task.sleep(nanoseconds: 120_000_000) // 120ms

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
