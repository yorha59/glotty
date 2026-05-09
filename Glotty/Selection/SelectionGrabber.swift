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

    private func synthesizeCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let kVK_C: CGKeyCode = 8

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_C, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: kVK_C, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
