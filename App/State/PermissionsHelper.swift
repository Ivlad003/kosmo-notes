@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import DictationKit

// MARK: - PermissionsHelper

/// Centralised TCC permission checks + "Open System Settings" prompts.
///
/// Mic / Screen Recording / Accessibility — the three permissions Jarvis Note
/// needs at runtime. Each call returns synchronously where the OS supports it
/// (Screen Recording, AX) or async where it requires a prompt (Mic).
///
/// Modal flow: when a feature can't run because a permission is missing, call
/// `showMissingAlert(...)` which presents an `NSAlert` with two buttons:
///   - "Open System Settings" — deep-links into the relevant Privacy pane and
///     reminds the user that AX trust requires a relaunch.
///   - "Cancel" — closes; caller surfaces the failure however it likes.
@available(macOS 14.0, *)
@MainActor
enum PermissionsHelper {

    // MARK: - Microphone

    static func micAuthStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request mic access. Returns true if granted (or already authorized).
    /// On first call this triggers the system mic prompt.
    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Screen Recording

    /// True if Screen Recording permission is currently granted.
    /// Uses `CGPreflightScreenCaptureAccess()` — does not prompt.
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system Screen Recording prompt and return whether granted
    /// in this session. Note: a fresh grant typically requires app relaunch
    /// before SCKit will succeed — callers should treat `false` here as
    /// "needs relaunch" rather than a permanent denial.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Accessibility

    /// True if this process has Accessibility permission. Re-uses the check
    /// from `AccessibilityPaster` (the source-of-truth in DictationKit).
    static func accessibilityGranted() -> Bool {
        AccessibilityPaster.isTrusted()
    }

    // MARK: - Open System Settings

    static func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        AccessibilityPaster.openSystemSettingsAccessibility()
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Modal flow

    enum Permission {
        case microphone
        case screenRecording
        case accessibility

        var title: String {
            switch self {
            case .microphone: return "Microphone access required"
            case .screenRecording: return "Screen Recording access required"
            case .accessibility: return "Accessibility access required"
            }
        }

        var body: String {
            switch self {
            case .microphone:
                return "Jarvis Note can't record your voice without Microphone access. Grant it in System Settings → Privacy & Security → Microphone, then start the recording again."
            case .screenRecording:
                return "Audio + Screen mode and system-audio capture both need Screen Recording permission. Grant it in System Settings → Privacy & Security → Screen Recording, then quit and relaunch Jarvis Note for the change to take effect."
            case .accessibility:
                return "Dictation Mode pastes the cleaned transcript into the focused text field via the Accessibility API. Grant Jarvis Note Accessibility access in System Settings → Privacy & Security → Accessibility, then quit and relaunch the app — macOS only refreshes AX trust on launch."
            }
        }
    }

    /// Present an NSAlert prompting the user to open the relevant Privacy pane.
    /// Returns true when the user clicked "Open System Settings", false on Cancel.
    @discardableResult
    static func showMissingAlert(_ permission: Permission) -> Bool {
        let alert = NSAlert()
        alert.messageText = permission.title
        alert.informativeText = permission.body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            switch permission {
            case .microphone: openMicSettings()
            case .screenRecording: openScreenRecordingSettings()
            case .accessibility: openAccessibilitySettings()
            }
            return true
        }
        return false
    }
}
