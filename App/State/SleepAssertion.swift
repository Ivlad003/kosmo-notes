import IOKit.pwr_mgt

// MARK: - SleepAssertion

/// Wraps IOPMAssertion to keep the system awake during a recording session.
@available(macOS 14.0, *)
final class SleepAssertion: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    /// Acquire a "prevent user idle system sleep" assertion. No-op if already held.
    func hold(reason: String = "KosmoNotes recording in progress") {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        held = (result == kIOReturnSuccess)
    }

    /// Release the assertion. No-op if not held.
    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit { release() }
}
