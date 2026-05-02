import KeyboardShortcuts

// MARK: - Hotkey name registration

extension KeyboardShortcuts.Name {
    // Default: Cmd+Shift+D
    static let dictation = Self("dictation", default: .init(.d, modifiers: [.command, .shift]))
}

// MARK: - HotkeyMonitor

/// Wraps KeyboardShortcuts to call press/release handlers for the dictation hotkey.
@available(macOS 14.0, *)
public final class HotkeyMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void

    private var pressHandler: Handler?
    private var releaseHandler: Handler?

    public init() {}

    /// Begin listening. Replaces any previously installed handlers.
    public func startMonitoring(onPress: @escaping Handler, onRelease: @escaping Handler) {
        pressHandler = onPress
        releaseHandler = onRelease
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            self?.pressHandler?()
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            self?.releaseHandler?()
        }
    }

    /// Remove all hotkey callbacks.
    public func stopMonitoring() {
        pressHandler = nil
        releaseHandler = nil
        KeyboardShortcuts.disable(.dictation)
    }
}
