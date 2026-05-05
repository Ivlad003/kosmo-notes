import KeyboardShortcuts

// MARK: - Global hotkey names

/// App-wide global hotkeys, registered at launch in `AppDelegate.bootstrapHotkeys()`.
/// `dictation` is registered separately by `HotkeyMonitor` in `DictationKit`.
extension KeyboardShortcuts.Name {
    /// Toggle Meeting Mode recording. Default ⌘⇧R.
    static let toggleMeeting = Self("toggleMeeting", default: .init(.r, modifiers: [.command, .shift]))

    /// Toggle Voice Note Mode recording. Default ⌘⇧N.
    static let toggleVoiceNote = Self("toggleVoiceNote", default: .init(.n, modifiers: [.command, .shift]))

    /// Open the Library window. Default ⌘L (chord-only when an app window is foreground;
    /// global registration via KeyboardShortcuts works regardless).
    static let openLibrary = Self("openLibrary", default: .init(.l, modifiers: [.command, .shift]))
}
