import Foundation

// MARK: - HotkeyTrigger
//
// Three ways to fire a hotkey action:
//
//   - .combo            → handled by `KeyboardShortcuts` (Cmd+Shift+R, etc.)
//   - .holdKey          → press and HOLD a single bare key (Right Cmd, Fn, F13)
//                         past `minHoldMs` to start; release ends the action.
//                         Ideal for push-to-talk so a quick accidental tap
//                         doesn't fire.
//   - .doubleTapModifier → tap a modifier (⇧/⌘/⌥/⌃) twice within `withinMs`
//                          to fire ONCE (no release event — there's nothing
//                          held). Ideal for one-shot actions like "open Library".
//
// `combo` continues to use the well-tested `KeyboardShortcuts` library; the
// other two require a CGEventTap (and Accessibility permission), implemented
// in `KeyTriggerEngine`.

public enum HotkeyTrigger: Codable, Sendable, Equatable, Hashable {

    case combo
    case holdKey(HoldKey, minHoldMs: Int)
    case doubleTapModifier(DoubleTapModifier, withinMs: Int)

    /// Human-readable label for Settings UI.
    public var displayName: String {
        switch self {
        case .combo: return "Key combination"
        case .holdKey(let key, let ms): return "Hold \(key.displayName) for \(ms) ms"
        case .doubleTapModifier(let mod, let ms): return "Double-tap \(mod.displayName) within \(ms) ms"
        }
    }
}

// MARK: - HoldKey
//
// Single bare keys safe to use as a press-and-hold trigger. Excludes letters
// and numbers (they'd swallow normal typing). `Fn` is special — its keycode
// 0x3F (63) only fires via `kCGEventFlagsChanged` with the .secondaryFn mask.

public enum HoldKey: String, Codable, CaseIterable, Sendable, Hashable {
    case rightCommand
    case rightOption
    case rightShift
    case rightControl
    case fn
    case capsLock
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20

    public var displayName: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightOption:  return "Right ⌥"
        case .rightShift:   return "Right ⇧"
        case .rightControl: return "Right ⌃"
        case .fn:           return "Fn"
        case .capsLock:     return "Caps Lock"
        case .f13:          return "F13"
        case .f14:          return "F14"
        case .f15:          return "F15"
        case .f16:          return "F16"
        case .f17:          return "F17"
        case .f18:          return "F18"
        case .f19:          return "F19"
        case .f20:          return "F20"
        }
    }

    /// Carbon virtual keycodes for F-row + caps lock. The right-hand modifiers
    /// don't have unique keycodes — they're detected via `kCGEventFlagsChanged`
    /// + the `.maskRightX` flags below in KeyTriggerEngine.
    public var virtualKeyCode: Int? {
        switch self {
        case .capsLock: return 0x39
        case .f13: return 0x69
        case .f14: return 0x6B
        case .f15: return 0x71
        case .f16: return 0x6A
        case .f17: return 0x40
        case .f18: return 0x4F
        case .f19: return 0x50
        case .f20: return 0x5A
        case .fn, .rightCommand, .rightOption, .rightShift, .rightControl:
            return nil
        }
    }

    /// True for keys that fire via `kCGEventFlagsChanged` (modifier-style).
    /// False for F-row + Caps Lock — those fire as normal key events.
    public var isModifierStyle: Bool {
        virtualKeyCode == nil
    }
}

// MARK: - DoubleTapModifier
//
// Modifiers that can be detected as a double-tap. Left/right not distinguished
// here because the goal is "user double-pressed Shift" regardless of side.

public enum DoubleTapModifier: String, Codable, CaseIterable, Sendable, Hashable {
    case shift
    case command
    case option
    case control

    public var displayName: String {
        switch self {
        case .shift:   return "⇧ Shift"
        case .command: return "⌘ Command"
        case .option:  return "⌥ Option"
        case .control: return "⌃ Control"
        }
    }
}
