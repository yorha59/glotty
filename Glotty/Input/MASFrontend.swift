#if MAS
import AppKit

/// Mac App Store front-end — NSServices handlers.
///
/// The system delivers the user's current selection on `pboard` when they pick
/// one of Glotty's Services items (right-click → Services, or the ⌘⌥ default
/// shortcuts declared in Info-MAS.plist). We hand that text to the same
/// `handleFire` pipeline the web build drives from the Fn-leader — no
/// Accessibility read, no event tap, no permission prompt.
///
/// Each `@objc` method name below must match an `NSMessage` entry in
/// Info-MAS.plist. The app object is registered as `NSApp.servicesProvider`
/// in `applicationDidFinishLaunching` (see GlottyApp.swift, `#if MAS`).
extension AppDelegate {
    @objc func translateSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        runService(.translate, pboard)
    }

    @objc func explainSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        runService(.explain, pboard)
    }

    @objc func polishSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        runService(.polish, pboard)
    }

    private func runService(_ mode: PopupMode, _ pboard: NSPasteboard) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handleFire(mode: mode, providedText: text)
        }
    }
}
#endif
