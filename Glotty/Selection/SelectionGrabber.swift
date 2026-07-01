import Foundation
import AppKit
import ApplicationServices

/// Three-stage selection grab. Tries the Accessibility API first (zero clipboard
/// pollution, works in most native Cocoa apps). Falls back to synthesizing Cmd+C
/// and reading the pasteboard for apps that don't expose AX (Electron, some
/// Java). Finally, for apps with Secure Keyboard Entry that drop the synthetic
/// Cmd+C (Warp and other terminals), falls back to whatever the user copied
/// themselves with a real Cmd+C — there the flow is "⌘C, then trigger".
final class SelectionGrabber {
    func grab() async -> String? {
        if let text = grabFromAccessibility(), !text.isEmpty {
            return text
        }
        return await grabViaPasteboard()
    }

    // MARK: - AX path

    private func grabFromAccessibility() -> String? {
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
            return nil
        }
        let focused = focusedRef as! AXUIElement

        var textAny: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &textAny
        )
        guard textResult == .success, let text = textAny as? String else {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    /// Screen rectangle of the current selection, via the focused element's
    /// selected range + `kAXBoundsForRangeParameterizedAttribute`. Returns AX
    /// coordinates (top-left origin, primary-screen space). `nil` when the app
    /// doesn't expose AX text geometry (Electron, etc.) — callers fall back to
    /// the mouse location for placement.
    func selectionScreenRect() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAny: AnyObject?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedAny) == .success,
              let focusedRef = focusedAny,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = focusedRef as! AXUIElement

        var rangeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, &rangeAny) == .success,
              let rangeRef = rangeAny,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = rangeRef as! AXValue

        var boundsAny: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                focused, kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue, &boundsAny) == .success,
              let boundsRef = boundsAny,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect
    }

    /// What the hover trigger needs: the selected text plus geometry, read in
    /// one silent AX pass (no clipboard). `selectionRect` is the precise bounds
    /// of the selection when the app exposes them; `elementFrame` is the focused
    /// text element's frame, used as a coarser fallback hit-area/anchor for the
    /// many apps that don't implement bounds-for-range. Both are AX coords
    /// (top-left origin, primary-screen space).
    struct HoverSelection {
        let text: String
        let selectionRect: CGRect?
        let elementFrame: CGRect?
    }

    /// Returns `nil` when there's no selection, or the app exposes neither the
    /// selection bounds nor the element frame (so we can't know the pointer is
    /// over it) — hover just won't trigger there.
    func hoverSelection() -> HoverSelection? {
        // Chromium/Electron withhold their AX tree (incl. selected text) until an
        // assistive client opts in. Nudge the front app before reading, so hover
        // works in Chrome, VS Code, Slack, etc. — not just native Cocoa apps.
        enableManualAccessibility()
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAny: AnyObject?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedAny) == .success,
              let focusedRef = focusedAny,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = focusedRef as! AXUIElement

        var textAny: AnyObject?
        guard AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, &textAny) == .success,
              let text = textAny as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let selRect = boundsForSelectedRange(focused)
        let elemFrame = frame(of: focused)
        guard selRect != nil || elemFrame != nil else { return nil }
        return HoverSelection(text: text, selectionRect: selRect, elementFrame: elemFrame)
    }

    /// Opt the frontmost app into exposing its Accessibility tree. Chromium /
    /// Electron apps (Chrome, VS Code, Slack, Discord…) return no selected text
    /// until a client sets `AXManualAccessibility`; native Cocoa apps ignore it.
    /// Idempotent — the app enables its AX engine on the first set, so repeated
    /// calls are cheap. Skip our own process.
    func enableManualAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Precise selection bounds via `kAXBoundsForRangeParameterizedAttribute`.
    /// Many apps don't implement it — returns `nil` there.
    private func boundsForSelectedRange(_ el: AXUIElement) -> CGRect? {
        var rangeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(
                el, kAXSelectedTextRangeAttribute as CFString, &rangeAny) == .success,
              let rangeRef = rangeAny,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        var boundsAny: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeRef as! AXValue, &boundsAny) == .success,
              let boundsRef = boundsAny,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect
    }

    /// Focused element frame from `kAXPosition` + `kAXSize` — widely supported.
    private func frame(of el: AXUIElement) -> CGRect? {
        var posAny: AnyObject?
        var sizeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posAny) == .success,
              let posRef = posAny, CFGetTypeID(posRef) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeAny) == .success,
              let sizeRef = sizeAny, CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Pasteboard fallback

    private func grabViaPasteboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        synthesizeCmdC()

        // Wait briefly for the target app's copy to land
        try? await Task.sleep(nanoseconds: 60_000_000) // 60ms

        let changed = pasteboard.changeCount != savedChangeCount
        let grabbed = pasteboard.string(forType: .string)

        if changed, let grabbed, !grabbed.isEmpty {
            // The synthetic copy landed — restore the user's original clipboard
            // so we don't pollute it.
            if let savedString {
                pasteboard.clearContents()
                pasteboard.setString(savedString, forType: .string)
            }
            return grabbed
        }

        // The synthetic Cmd+C changed nothing. In a terminal the highlighted
        // text isn't reachable: terminals expose no AX selected-text and they
        // drop our injected keystroke (Warp, iTerm, etc.). Fall back to whatever
        // the user already copied with a *real* Cmd+C — the terminal flow is
        // "⌘C, then trigger". We leave the clipboard untouched: it's their own
        // content. Gated on a terminal front-app so a plain "nothing selected"
        // in a normal app still returns nil (callers show the hint) instead of
        // silently acting on a stale clipboard.
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if SelectionReplacer.terminalBundleIDs.contains(app),
           let savedString,
           !savedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return savedString
        }
        return nil
    }

    /// Marker stamped on the CGEvents we synthesize for the clipboard
    /// grab, so Glotty's own Fn-leader event tap can recognize and ignore
    /// them. Without this, the synthetic Cmd+C's keycode 8 ('c') is seen
    /// by the tap as the chat hotkey and spuriously opens a chat popup
    /// right after a translate/explain/polish grab.
    static let syntheticEventUserData: Int64 = 0x474C_4F54  // "GLOT"

    private func synthesizeCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let kVK_C: CGKeyCode = 8

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_C, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: kVK_C, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Tag both events so FnLeaderHotkey skips them (see above).
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
