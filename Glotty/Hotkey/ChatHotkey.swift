#if MAS
import AppKit
import Carbon.HIToolbox

/// System-wide chat hotkey for the Mac App Store build: ⌘⌥C.
///
/// Uses Carbon `RegisterEventHotKey`, which registers a global hotkey WITHOUT
/// Accessibility or Input-Monitoring permission — unlike the web build's
/// `CGEvent` tap (`FnLeaderHotkey`), which App Review rejects under Guideline
/// 2.4.5. Trade-offs: `RegisterEventHotKey` can only bind a real key plus
/// modifiers (no bare Fn), and it can't intercept/consume other keystrokes.
/// Both are fine here — chat is one dedicated combo, nothing to consume.
final class ChatHotkey {
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    enum HotkeyError: Error { case registerFailed }

    func install() throws {
        // 'GLTC' — unique four-char signature for our hotkey id.
        let hotKeyID = EventHotKeyID(signature: 0x474C_5443, id: 1)
        let modifiers = UInt32(cmdKey | optionKey)
        let keyCode = UInt32(kVK_ANSI_C)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registerFailed }
        hotKeyRef = ref

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<ChatHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Only one hotkey is registered, so any press routed here is ours.
            DispatchQueue.main.async { me.onFire?() }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec, selfPtr, &eventHandler)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
#endif
