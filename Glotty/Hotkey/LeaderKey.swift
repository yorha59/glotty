import Foundation
import CoreGraphics
import AppKit

/// The first half of a Glotty leader-key shortcut (e.g. the "Fn" in Fn → T).
/// Modifier-only — full key-with-modifier chords (Cmd-Shift-T) are a separate feature.
enum LeaderKey: String, CaseIterable, Identifiable {
    case fn
    case command
    case option
    case control
    case shift
    case capsLock

    var id: String { rawValue }

    /// User-facing label. Symbols match macOS menu conventions.
    var label: String {
        switch self {
        case .fn:        return "Fn"
        case .command:   return "⌘ Command"
        case .option:    return "⌥ Option"
        case .control:   return "⌃ Control"
        case .shift:     return "⇧ Shift"
        case .capsLock:  return "⇪ Caps Lock"
        }
    }

    /// Test whether this modifier is set in a `CGEventFlags`. Called per event in
    /// the hot path, so it's a tight switch + `.contains` rather than anything fancy.
    func isActive(in flags: CGEventFlags) -> Bool {
        switch self {
        case .fn:        return flags.contains(.maskSecondaryFn)
        case .command:   return flags.contains(.maskCommand)
        case .option:    return flags.contains(.maskAlternate)
        case .control:   return flags.contains(.maskControl)
        case .shift:     return flags.contains(.maskShift)
        case .capsLock:  return flags.contains(.maskAlphaShift)
        }
    }

    /// Reverse mapping for the Settings recorder: figure out which LeaderKey just
    /// became active given before/after `NSEvent.ModifierFlags` snapshots.
    static func newlyPressed(before: NSEvent.ModifierFlags,
                             after: NSEvent.ModifierFlags) -> LeaderKey? {
        let added = after.subtracting(before)
        // Priority order matches the LeaderKey case order so the picker label
        // stays predictable when the user presses multiple modifiers at once.
        if added.contains(.function) { return .fn }
        if added.contains(.command)  { return .command }
        if added.contains(.option)   { return .option }
        if added.contains(.control)  { return .control }
        if added.contains(.shift)    { return .shift }
        if added.contains(.capsLock) { return .capsLock }
        return nil
    }
}
