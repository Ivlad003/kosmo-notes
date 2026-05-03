import Foundation
import Testing
@testable import DictationKit

// MARK: - HotkeyTrigger persistence
//
// AppSettings stores `dictationTrigger` as a JSON-encoded HotkeyTrigger blob in
// UserDefaults — a plain raw-value can't round-trip the enum because the
// associated values (held key, ms threshold, modifier choice) carry
// configuration the user picked in Settings. Lock the contract here so a
// silent encoding change can't drop a stored preference on the floor at the
// next launch.

@Suite("HotkeyTrigger Codable round-trip")
struct HotkeyTriggerCodableTests {

    @Test("combo round-trips")
    func comboRoundTrip() throws {
        try assertRoundTrip(.combo)
    }

    @Test("holdKey preserves both the key and the ms threshold")
    func holdKeyRoundTrip() throws {
        for key in HoldKey.allCases {
            try assertRoundTrip(.holdKey(key, minHoldMs: 250))
        }
        // Spot-check a non-default ms value to catch a regression that hard-
        // codes the ms field at encode time.
        try assertRoundTrip(.holdKey(.f13, minHoldMs: 1750))
    }

    @Test("doubleTapModifier preserves both the modifier and the window")
    func doubleTapRoundTrip() throws {
        for mod in DoubleTapModifier.allCases {
            try assertRoundTrip(.doubleTapModifier(mod, withinMs: 350))
        }
    }

    /// `Equatable` was added explicitly so we can assert round-trip equality
    /// rather than match on `String(describing:)`. Guard it doesn't drift.
    @Test("distinct triggers compare unequal")
    func distinctTriggersAreUnequal() {
        #expect(HotkeyTrigger.combo != .holdKey(.rightCommand, minHoldMs: 200))
        #expect(HotkeyTrigger.holdKey(.f13, minHoldMs: 200) !=
                HotkeyTrigger.holdKey(.f14, minHoldMs: 200))
        #expect(HotkeyTrigger.holdKey(.rightCommand, minHoldMs: 200) !=
                HotkeyTrigger.holdKey(.rightCommand, minHoldMs: 250))
        #expect(HotkeyTrigger.doubleTapModifier(.shift, withinMs: 300) !=
                HotkeyTrigger.doubleTapModifier(.command, withinMs: 300))
    }

    // MARK: - Helper

    private func assertRoundTrip(_ original: HotkeyTrigger,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        #expect(decoded == original, "JSON round-trip lost data for \(original)", sourceLocation: sourceLocation)
    }
}
