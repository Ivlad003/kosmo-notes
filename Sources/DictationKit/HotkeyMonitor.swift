import KeyboardShortcuts

// MARK: - Hotkey name registration

extension KeyboardShortcuts.Name {
    // Default: Cmd+Shift+D. Public so the Settings → Hotkeys tab in the App
    // target can render a Recorder for it.
    public static let dictation = Self("dictation", default: .init(.d, modifiers: [.command, .shift]))
    // Push-to-Markdown — same press/hold/release pattern as dictation, but
    // instead of pasting into the focused text field the cleaned transcript
    // is run through MarkdownExporter and saved as a `.md` at the configured
    // folder. Default ⌘⇧Y (Y for "yes, save it").
    public static let pushToMarkdown = Self("pushToMarkdown", default: .init(.y, modifiers: [.command, .shift]))
}

// MARK: - HotkeyMonitor

/// Wraps KeyboardShortcuts to call press/release handlers for ONE configurable
/// hotkey. Was hard-pinned to `.dictation` originally; parameterized so the
/// same monitor shape can drive Push-to-Markdown without copy-pasting state.
@available(macOS 14.0, *)
public final class HotkeyMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void

    private let name: KeyboardShortcuts.Name
    private var pressHandler: Handler?
    private var releaseHandler: Handler?

    /// Defaults to `.dictation` for backwards compatibility — existing
    /// DictationState callers don't need to change.
    public init(name: KeyboardShortcuts.Name = .dictation) {
        self.name = name
    }

    /// Begin listening. Replaces any previously installed handlers.
    public func startMonitoring(onPress: @escaping Handler, onRelease: @escaping Handler) {
        pressHandler = onPress
        releaseHandler = onRelease
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
            self?.pressHandler?()
        }
        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            self?.releaseHandler?()
        }
    }

    /// Remove all hotkey callbacks.
    public func stopMonitoring() {
        pressHandler = nil
        releaseHandler = nil
        KeyboardShortcuts.disable(name)
    }
}
