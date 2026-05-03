import AppKit
@preconcurrency import ApplicationServices
import Foundation
import os

private let kteLog = Logger(subsystem: "dev.kosmonotes.studio", category: "KeyTriggerEngine")

// MARK: - KeyTriggerEngine
//
// Singleton CGEventTap that powers `.holdKey` and `.doubleTapModifier`
// triggers. Combo triggers stay on the existing `KeyboardShortcuts` library —
// this engine is only spun up the first time a hold/double-tap subscription
// is registered (so users who never opt-in pay nothing).
//
// Why CGEventTap?
//   - Modifier-only events (Shift / Cmd / etc) fire `kCGEventFlagsChanged`,
//     not `keyDown` — `KeyboardShortcuts` doesn't expose them.
//   - Bare-key hold detection requires sub-keypress timing.
//   - Both need access to events globally (any frontmost app), which is what
//     CGEventTap provides — and which is why it requires Accessibility TCC.
//
// Threading: events arrive on a background CFRunLoop thread. We hop to the
// main actor before invoking subscribers so they can safely touch UI state.

@available(macOS 14.0, *)
@MainActor
public final class KeyTriggerEngine {

    // MARK: Singleton

    public static let shared = KeyTriggerEngine()
    private init() {}

    // MARK: Subscription

    public typealias Handler = @MainActor () -> Void

    /// Stable identifier for a registration so callers can unregister cleanly.
    public struct SubscriptionID: Hashable, Sendable {
        public let value: UUID
        public init() { self.value = UUID() }
    }

    private struct Subscription {
        let trigger: HotkeyTrigger
        let onPress: Handler
        let onRelease: Handler
    }

    private var subs: [SubscriptionID: Subscription] = [:]

    /// Per-key timer for hold detection: started on press, cancels on release.
    private var holdTimers: [String: DispatchWorkItem] = [:]
    /// Tracks which (subscriptionID, key) pairs are currently in their "held →
    /// fired onPress" state so we know to fire onRelease later.
    private var firedHolds: Set<String> = []
    /// Last-press timestamp per modifier for double-tap detection.
    private var lastModifierTap: [DoubleTapModifier: TimeInterval] = [:]
    /// Snapshot of the last-seen flags mask, so we can diff to detect
    /// per-modifier press/release independently.
    private var lastFlags: CGEventFlags = []

    // MARK: CGEventTap state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Register a non-combo trigger. Combo triggers are intentionally rejected
    /// here — wire those through `KeyboardShortcuts` directly.
    public func register(trigger: HotkeyTrigger, onPress: @escaping Handler, onRelease: @escaping Handler) -> SubscriptionID? {
        if case .combo = trigger {
            kteLog.error("KeyTriggerEngine: refusing to register .combo trigger — use KeyboardShortcuts.")
            return nil
        }
        let id = SubscriptionID()
        subs[id] = Subscription(trigger: trigger, onPress: onPress, onRelease: onRelease)
        ensureEventTap()
        return id
    }

    public func unregister(_ id: SubscriptionID) {
        subs.removeValue(forKey: id)
        if subs.isEmpty {
            tearDownEventTap()
        }
    }

    // MARK: Permission

    /// True when the user has granted Accessibility permission. Without it,
    /// CGEventTap returns nil and no triggers fire.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Show the system prompt for Accessibility permission. Doesn't block —
    /// user has to flip the toggle in System Settings → Privacy & Security
    /// → Accessibility, then re-launch (or call `register` again).
    public static func promptForAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Event tap lifecycle

    private func ensureEventTap() {
        guard eventTap == nil else { return }

        guard Self.hasAccessibilityPermission() else {
            kteLog.error("KeyTriggerEngine: Accessibility permission missing — hold / double-tap triggers will not fire. Prompting.")
            Self.promptForAccessibilityPermission()
            return
        }

        let mask: UInt32 =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // userInfo passes a self-reference into the C callback, which then
        // hops back to the main actor.
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                  // observe only, never swallow
            eventsOfInterest: CGEventMask(mask),
            callback: KeyTriggerEngine.tapCallback,
            userInfo: info
        ) else {
            kteLog.error("KeyTriggerEngine: CGEvent.tapCreate returned nil — Accessibility permission probably revoked.")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = src
        kteLog.info("KeyTriggerEngine: event tap installed")
    }

    private func tearDownEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        // Drop any pending hold timers — nothing to fire if no subs.
        holdTimers.values.forEach { $0.cancel() }
        holdTimers.removeAll()
        firedHolds.removeAll()
        kteLog.info("KeyTriggerEngine: event tap removed (no subscribers)")
    }

    // MARK: - C → Swift bridge

    /// CGEventTap calls back on a background thread. Hop to the main actor
    /// before touching any subscriber state. Returns the event unmodified —
    /// we're observing, not consuming.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<KeyTriggerEngine>.fromOpaque(info).takeUnretainedValue()
        let snapshotType = type
        // Snapshot what we need OFF the event before async-hopping; the
        // CGEvent reference is only valid inside this callback.
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        Task { @MainActor in
            engine.handle(type: snapshotType, keycode: keycode, flags: flags)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Event dispatch

    private func handle(type: CGEventType, keycode: Int, flags: CGEventFlags) {
        switch type {
        case .keyDown:
            handleKeyDown(keycode: keycode)
        case .keyUp:
            handleKeyUp(keycode: keycode)
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, flags: flags)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS auto-disables long-running taps; re-enable.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                kteLog.info("KeyTriggerEngine: re-enabled event tap after disable")
            }
        default:
            break
        }
    }

    /// Bare-key holds (F13–F20, Caps Lock) come in as keyDown / keyUp.
    private func handleKeyDown(keycode: Int) {
        for (id, sub) in subs {
            if case .holdKey(let key, let minHoldMs) = sub.trigger,
               let target = key.virtualKeyCode, target == keycode {
                startHoldTimer(id: id, key: key.rawValue, minHoldMs: minHoldMs, sub: sub)
            }
        }
    }

    private func handleKeyUp(keycode: Int) {
        for (id, sub) in subs {
            if case .holdKey(let key, _) = sub.trigger,
               let target = key.virtualKeyCode, target == keycode {
                endHold(id: id, key: key.rawValue, sub: sub)
            }
        }
    }

    /// Modifier presses (Right ⌘, Fn, etc.) and double-tap detection both
    /// arrive as `kCGEventFlagsChanged`. The flags mask is a snapshot of all
    /// currently-pressed modifiers; diff against `lastFlags` to figure out
    /// which one just changed.
    private func handleFlagsChanged(keycode: Int, flags: CGEventFlags) {
        let prev = lastFlags
        lastFlags = flags

        // 1. Right-hand modifier holds: detect via the `maskRightX` bits.
        for (id, sub) in subs {
            guard case .holdKey(let key, let minHoldMs) = sub.trigger, key.isModifierStyle else { continue }
            let mask = Self.holdMask(for: key)
            let wasDown = prev.contains(mask)
            let isDown = flags.contains(mask)
            if !wasDown && isDown {
                startHoldTimer(id: id, key: key.rawValue, minHoldMs: minHoldMs, sub: sub)
            } else if wasDown && !isDown {
                endHold(id: id, key: key.rawValue, sub: sub)
            }
        }

        // 2. Double-tap: only fire on a fresh press (transition off → on)
        // for the SIDE-AGNOSTIC mask of the modifier.
        for mod in DoubleTapModifier.allCases {
            let mask = Self.doubleTapMask(for: mod)
            let wasDown = prev.contains(mask)
            let isDown = flags.contains(mask)
            if !wasDown && isDown {
                let now = Date().timeIntervalSince1970
                let last = lastModifierTap[mod] ?? 0
                lastModifierTap[mod] = now
                let elapsedMs = (now - last) * 1000
                for (_, sub) in subs {
                    if case .doubleTapModifier(let target, let withinMs) = sub.trigger,
                       target == mod, elapsedMs > 0, elapsedMs <= Double(withinMs) {
                        // Reset so a third tap doesn't re-fire instantly.
                        lastModifierTap[mod] = 0
                        sub.onPress()
                        sub.onRelease()
                    }
                }
            }
        }
    }

    private func startHoldTimer(id: SubscriptionID, key: String, minHoldMs: Int, sub: Subscription) {
        let token = "\(id.value.uuidString):\(key)"
        // Cancel any existing pending timer for this id+key (defensive — a
        // duplicate down before up would otherwise leak).
        holdTimers[token]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The DispatchWorkItem hops back to main via the queue; verify
            // we're still subscribed and key is still considered held.
            self.holdTimers.removeValue(forKey: token)
            guard self.subs[id] != nil else { return }
            self.firedHolds.insert(token)
            sub.onPress()
        }
        holdTimers[token] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(50, minHoldMs)), execute: work)
    }

    private func endHold(id: SubscriptionID, key: String, sub: Subscription) {
        let token = "\(id.value.uuidString):\(key)"
        if let pending = holdTimers.removeValue(forKey: token) {
            pending.cancel()      // released before threshold → it was a tap
        }
        if firedHolds.remove(token) != nil {
            sub.onRelease()
        }
    }

    // MARK: - Mask helpers

    /// Per-modifier mask used to detect a SPECIFIC side (left vs right) for
    /// hold triggers. CGEventFlags includes per-side bits in the lower
    /// nibble of the mask, but Apple only documents the public ones below.
    private static func holdMask(for key: HoldKey) -> CGEventFlags {
        switch key {
        // Right-hand modifier bits aren't in the public CGEventFlags enum
        // but their raw values are stable. Numbers from
        // <IOKit/hidsystem/IOLLEvent.h> (NX_DEVICERCMDKEYMASK etc.).
        case .rightCommand: return CGEventFlags(rawValue: 0x0010)
        case .rightShift:   return CGEventFlags(rawValue: 0x0004)
        case .rightOption:  return CGEventFlags(rawValue: 0x0040)
        case .rightControl: return CGEventFlags(rawValue: 0x2000)
        case .fn:           return .maskSecondaryFn
        // The rest aren't modifier-style; this branch only runs when
        // `isModifierStyle` returned true so default to a no-op mask.
        default:            return []
        }
    }

    /// Side-agnostic mask for double-tap — user can tap either side.
    private static func doubleTapMask(for mod: DoubleTapModifier) -> CGEventFlags {
        switch mod {
        case .shift:   return .maskShift
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .control: return .maskControl
        }
    }
}
