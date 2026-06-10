import Foundation
import AppKit
import ApplicationServices

/// Two-stage selection grab. Tries the Accessibility API first (zero clipboard pollution,
/// works in most native Cocoa apps). Falls back to synthesizing Cmd+C and reading the
/// pasteboard for apps that don't expose AX (Electron, some Java).
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

        // Restore the user's original clipboard
        if let savedString {
            pasteboard.clearContents()
            pasteboard.setString(savedString, forType: .string)
        }

        guard changed, let grabbed, !grabbed.isEmpty else { return nil }
        return grabbed
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
