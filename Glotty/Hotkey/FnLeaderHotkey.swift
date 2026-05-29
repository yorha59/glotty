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

    private static func debug(_ msg: String) {
        let line = "[\(Date())] FnLeaderHotkey: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/glotty-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if macOS disabled it (e.g. during heavy load)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let withinWindow = (CFAbsoluteTimeGetCurrent() - fnDownAt) < leaderWindow
            let active = (wasFnPressed || withinWindow) && !firedDuringCurrentHold

            // Read user-rebindable keycodes per-event. UserDefaults lookups are
            // microsecond-cheap and let the user change bindings without restart.
            let translateKey = Int64(Keycode.currentTranslate())
            let explainKey   = Int64(Keycode.currentExplain())
            let polishKey    = Int64(Keycode.currentPolish())
            let chatKey      = Int64(Keycode.currentChat())

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
