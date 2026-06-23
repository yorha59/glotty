#if MAS
import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon `RegisterEventHotKey` — the
/// App-Store-legal global hotkey (no Accessibility / Input-Monitoring, unlike
/// the web build's `CGEvent` tap). Bind a real key + modifiers; bare modifiers
/// and the Fn key can't be registered.
///
/// Multiple instances share one application event target, so the installed
/// handler filters by `EventHotKeyID` (signature + id) and only fires the
/// matching instance — without that check, every hotkey press would fire
/// every instance's callback.
final class CarbonHotkey {
    var onFire: (() -> Void)?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: OSType
    private let id: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    enum HotkeyError: Error { case registerFailed }

    /// - keyCode: a virtual key code (e.g. `kVK_ANSI_C`).
    /// - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    /// - signature/id: a unique pair identifying this hotkey in callbacks.
    init(keyCode: Int, modifiers: Int, signature: OSType, id: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.signature = signature
        self.id = id
    }

    func install() throws {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registerFailed }
        hotKeyRef = ref

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var pressedID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let me = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
            if pressedID.id == me.id && pressedID.signature == me.signature {
                DispatchQueue.main.async { me.onFire?() }
            }
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
