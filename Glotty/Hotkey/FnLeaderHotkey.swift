import Foundation
import CoreGraphics
import AppKit

/// Minimal `Fn → T` leader detection via `CGEventTap`.
/// - On `Fn`-down: records timestamp, lets the event pass through so macOS native Fn behavior still triggers if no follow-up arrives.
/// - On `T` key-down within 600ms after Fn went down (or while Fn is still held): consumes the event and fires `onFire`.
/// - All other keys / timing: pass through untouched.
final class FnLeaderHotkey {
    var onFire: (() -> Void)?
    var onExplainFire: (() -> Void)?
    var onPolishFire: (() -> Void)?
    /// Fn → C — opens a free-form chat with Glotty (no selection
    /// required; the popup starts with the tutor's opening turn).
    var onChatFire: (() -> Void)?
    /// Fn → R — polishes the current selection and writes the result
    /// straight back over it, in place, with no popup.
    var onReplaceFire: (() -> Void)?
    /// Fn → V — speaks the current selection aloud (text-to-speech), no popup.
    var onSpeakFire: (() -> Void)?
    var onShowHUD: (() -> Void)?
    var onHideHUD: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: CFAbsoluteTime = 0
    private var wasFnPressed = false
    /// True once a hotkey has fired during the current Fn hold (or
    /// within the post-release leader window). Resets when Fn goes
    /// down again. Prevents a single Fn → P press from triggering
    /// multiple actions when the system emits more than one key event
    /// for the same physical press (observed on some keyboard layouts
    /// where Fn-held letters can produce a stray secondary keycode).
    private var firedDuringCurrentHold = false
    private var pendingHUDShow: DispatchWorkItem?
    private var hudVisible = false
    private let leaderWindow: CFTimeInterval = 0.6
    private let hudShowDelay: CFTimeInterval = 0.25

    enum HotkeyError: Error {
        case eventTapCreateFailed
    }

    func install() throws {
        FnLeaderHotkey.debug("install() begin")
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<FnLeaderHotkey>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        ) else {
            FnLeaderHotkey.debug("CGEvent.tapCreate returned nil — Input Monitoring almost certainly denied")
            throw HotkeyError.eventTapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        FnLeaderHotkey.debug("install() success — event tap active")
    }

    private static func debug(_ msg: String, file: String = #fileID, line: Int = #line) {
        Log.debug(.hotkey, msg, file: file, line: line)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if macOS disabled it (e.g. during heavy load)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore events Glotty itself synthesized — the selection grabber
        // posts a Cmd+C to copy the selection, and that synthetic 'c'
        // (keycode 8) is exactly the chat hotkey, so without this it would
        // fire a chat popup right after every translate/explain/polish.
        if event.getIntegerValueField(.eventSourceUserData) == SelectionGrabber.syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let leader = Keycode.currentLeader()
            let leaderNow = leader.isActive(in: event.flags)
            if leaderNow && !wasFnPressed {
                fnDownAt = CFAbsoluteTimeGetCurrent()
                // Fresh hold begins — re-arm so the next key press
                // can fire even if a previous press already fired.
                firedDuringCurrentHold = false
                FnLeaderHotkey.debug("\(leader.label) DOWN")
                scheduleHUDShow()
            } else if !leaderNow && wasFnPressed {
                FnLeaderHotkey.debug("\(leader.label) UP")
                cancelHUD()
            }
            wasFnPressed = leaderNow
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Skip any keyDown carrying the Command modifier. Glotty's
            // hotkeys are Fn+letter (no Command), so the only Cmd+key this
            // tap ever sees is our OWN synthetic Cmd+C from the selection
            // grabber — whose keycode 8 ('c') is the chat hotkey and would
            // otherwise fire a chat popup after every translate/explain/
            // polish grab. (The `.eventSourceUserData` marker we also stamp
            // doesn't reliably survive posting to the HID tap, so this
            // modifier check is the real guard.) Returning unretained
            // leaves the real Cmd+C working in the target app.
            if event.flags.contains(.maskCommand) {
                return Unmanaged.passUnretained(event)
            }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let withinWindow = (CFAbsoluteTimeGetCurrent() - fnDownAt) < leaderWindow
            let active = (wasFnPressed || withinWindow) && !firedDuringCurrentHold

            // Read user-rebindable keycodes per-event. UserDefaults lookups are
            // microsecond-cheap and let the user change bindings without restart.
            let translateKey = Int64(Keycode.currentTranslate())
            let explainKey   = Int64(Keycode.currentExplain())
            let polishKey    = Int64(Keycode.currentPolish())
            let chatKey      = Int64(Keycode.currentChat())
            let replaceKey   = Int64(Keycode.currentReplace())
            let speakKey     = Int64(Keycode.currentSpeak())

            if keycode == translateKey, active {
                FnLeaderHotkey.debug("FIRE Fn→translate (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
            if keycode == explainKey, active, explainKey != translateKey {
                FnLeaderHotkey.debug("FIRE Fn→explain (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onExplainFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
            if keycode == polishKey, active,
               polishKey != translateKey, polishKey != explainKey {
                FnLeaderHotkey.debug("FIRE Fn→polish (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onPolishFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
            if keycode == chatKey, active,
               chatKey != translateKey, chatKey != explainKey, chatKey != polishKey {
                FnLeaderHotkey.debug("FIRE Fn→chat (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onChatFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
            if keycode == replaceKey, active,
               replaceKey != translateKey, replaceKey != explainKey,
               replaceKey != polishKey, replaceKey != chatKey {
                FnLeaderHotkey.debug("FIRE Fn→replace (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onReplaceFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
            if keycode == speakKey, active,
               speakKey != translateKey, speakKey != explainKey,
               speakKey != polishKey, speakKey != chatKey, speakKey != replaceKey {
                FnLeaderHotkey.debug("FIRE Fn→speak (key \(keycode))")
                firedDuringCurrentHold = true
                cancelHUD()
                let cb = onSpeakFire
                DispatchQueue.main.async { cb?() }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func scheduleHUDShow() {
        pendingHUDShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wasFnPressed else { return }
            self.hudVisible = true
            FnLeaderHotkey.debug("HUD show")
            self.onShowHUD?()
        }
        pendingHUDShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudShowDelay, execute: work)
    }

    private func cancelHUD() {
        pendingHUDShow?.cancel()
        pendingHUDShow = nil
        if hudVisible {
            hudVisible = false
            FnLeaderHotkey.debug("HUD hide")
            DispatchQueue.main.async { [weak self] in self?.onHideHUD?() }
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
