import Foundation
import CoreGraphics
import AppKit

/// Minimal `Fn → T` leader detection via `CGEventTap`.
/// - On `Fn`-down: records timestamp, lets the event pass through so macOS native Fn behavior still triggers if no follow-up arrives.
/// - On `T` key-down within 600ms after Fn went down (or while Fn is still held): consumes the event and fires `onFire`.
/// - All other keys / timing: pass through untouched.
final class FnLeaderHotkey {
    var onFire: (() -> Void)?
    var onShowHUD: (() -> Void)?
    var onHideHUD: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: CFAbsoluteTime = 0
    private var wasFnPressed = false
    private var pendingHUDShow: DispatchWorkItem?
    private var hudVisible = false
    private let leaderWindow: CFTimeInterval = 0.6
    private let hudShowDelay: CFTimeInterval = 0.25
    private static let kVK_T: Int64 = 17

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
            let fnNow = event.flags.contains(.maskSecondaryFn)
            if fnNow && !wasFnPressed {
                fnDownAt = CFAbsoluteTimeGetCurrent()
                FnLeaderHotkey.debug("Fn DOWN")
                scheduleHUDShow()
            } else if !fnNow && wasFnPressed {
                FnLeaderHotkey.debug("Fn UP")
                cancelHUD()
            }
            wasFnPressed = fnNow
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let withinWindow = (CFAbsoluteTimeGetCurrent() - fnDownAt) < leaderWindow
            if keycode == FnLeaderHotkey.kVK_T {
                FnLeaderHotkey.debug("T keyDown (fnPressed=\(wasFnPressed) withinWindow=\(withinWindow))")
            }
            if keycode == FnLeaderHotkey.kVK_T, wasFnPressed || withinWindow {
                FnLeaderHotkey.debug("FIRE Fn→T")
                cancelHUD()
                let cb = onFire
                DispatchQueue.main.async { cb?() }
                return nil // consume the T so it doesn't leak into the focused app
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
