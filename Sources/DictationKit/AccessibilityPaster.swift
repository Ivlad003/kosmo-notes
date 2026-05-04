import AppKit
import ApplicationServices
import os

private let pasterLog = Logger(subsystem: "dev.kosmonotes.dictation", category: "AccessibilityPaster")

// MARK: - DictationInsertionStrategy

/// How a dictated transcript reaches the user's destination.
///
/// Three explicit modes. The default is `clipboardSimulatedV` — it works
/// universally (Slack, Discord, Cursor, VS Code, Telegram, etc.) and is what
/// every reliable Mac dictation tool uses. The other two are escape hatches.
public enum DictationInsertionStrategy: String, Sendable, Codable, CaseIterable, Hashable {

    /// Try `kAXSelectedTextAttribute` (direct insert) first. Faster in apps that
    /// honour it (Notes, TextEdit, Mail, Safari address). Known false-positive
    /// in Electron-based targets — the AX call returns success while no text
    /// actually appears. Falls back to clipboard+⌘V on AX failure.
    case axapiThenClipboard

    /// Default. Write to clipboard, simulate ⌘V, restore previous clipboard.
    case clipboardSimulatedV

    /// Write to clipboard only. No automatic ⌘V — the user pastes manually
    /// wherever they want it. Useful when focus has shifted to a different
    /// window or you don't want the active app to receive the paste.
    case clipboardOnly

    /// Human-readable name for the Settings picker.
    public var displayName: String {
        switch self {
        case .axapiThenClipboard: return "AXAPI direct insert (faster, less reliable)"
        case .clipboardSimulatedV: return "Clipboard + ⌘V (recommended)"
        case .clipboardOnly: return "Clipboard only (paste manually)"
        }
    }

    /// Sub-caption shown under the Settings picker.
    public var detailDescription: String {
        switch self {
        case .axapiThenClipboard:
            return "Tries AXAPI direct insertion first; falls back to clipboard+⌘V if AX is unavailable. Many Electron apps (Slack/Discord/Cursor/VS Code) silently swallow AX without inserting."
        case .clipboardSimulatedV:
            return "Universally compatible. Writes the transcript to your clipboard, simulates ⌘V, and restores your previous clipboard ~150 ms later."
        case .clipboardOnly:
            return "Just writes the transcript to your clipboard — no auto-paste. Useful when the focused app shouldn't receive the paste, or when you want to control where the text lands."
        }
    }
}

// MARK: - AccessibilityPaster

/// Inserts text into the currently focused UI element.
@available(macOS 14.0, *)
public enum AccessibilityPaster {

    public enum PasteResult: Sendable, Equatable {
        case axInserted
        case clipboardSimulatedV
        /// Clipboard-only path: text was placed on the clipboard but no ⌘V
        /// was simulated. Caller is expected to surface a notification.
        case clipboardOnly
        case failed(reason: String)
    }

    /// Returns true if this process has Accessibility permission.
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Open System Settings → Privacy → Accessibility.
    public static func openSystemSettingsAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Insert `text` according to the requested `strategy`.
    public static func paste(_ text: String, strategy: DictationInsertionStrategy = .clipboardSimulatedV) -> PasteResult {
        pasterLog.info("paste: strategy=\(strategy.rawValue, privacy: .public) chars=\(text.count, privacy: .public)")

        switch strategy {
        case .axapiThenClipboard:
            if isTrusted() {
                let systemWide = AXUIElementCreateSystemWide()
                var focusedElement: CFTypeRef?
                let getErr = AXUIElementCopyAttributeValue(
                    systemWide,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedElement
                )
                if getErr == .success, let element = focusedElement {
                    let axElement = element as! AXUIElement  // swiftlint:disable:this force_cast
                    let setErr = AXUIElementSetAttributeValue(
                        axElement,
                        kAXSelectedTextAttribute as CFString,
                        text as CFTypeRef
                    )
                    if setErr == .success {
                        pasterLog.info("paste: AXAPI .success — note: many Electron apps return success without inserting")
                        return .axInserted
                    } else {
                        pasterLog.info("paste: AXAPI setErr=\(setErr.rawValue, privacy: .public) — falling back to clipboard")
                    }
                } else {
                    pasterLog.info("paste: AXAPI getErr=\(getErr.rawValue, privacy: .public) — falling back to clipboard")
                }
            } else {
                pasterLog.info("paste: AXAPI requested but process not trusted — using clipboard")
            }
            return pasteViaClipboard(text, simulateCmdV: true)

        case .clipboardSimulatedV:
            return pasteViaClipboard(text, simulateCmdV: true)

        case .clipboardOnly:
            return pasteViaClipboard(text, simulateCmdV: false)
        }
    }

    // MARK: - Private

    /// Clipboard write with timing the macOS pasteboard server and Electron
    /// receivers actually need. When `simulateCmdV` is true, also posts the
    /// ⌘V chord and restores the user's previous clipboard ~150 ms later.
    /// When false, just writes — caller paste manually.
    private static func pasteViaClipboard(_ text: String, simulateCmdV: Bool) -> PasteResult {
        let pasteboard = NSPasteboard.general

        // Save existing string-type clipboard payload (best-effort; we only
        // round-trip plain strings since that's what dictation produces).
        let savedString = pasteboard.string(forType: .string)
        let savedChange = pasteboard.changeCount

        pasteboard.clearContents()
        let writeOK = pasteboard.setString(text, forType: .string)
        guard writeOK else {
            pasterLog.error("paste: NSPasteboard.setString failed")
            return .failed(reason: "Could not write to clipboard")
        }
        pasterLog.info("paste: clipboard written (\(text.count, privacy: .public) chars)")

        guard simulateCmdV else {
            // Clipboard-only mode — leave the clipboard with our text and bail.
            // Don't restore — the user is going to paste manually, possibly
            // many seconds from now.
            return .clipboardOnly
        }

        // Pasteboard propagation delay.
        Thread.sleep(forTimeInterval: 0.020)

        // Synthesize Cmd+V.
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            return .failed(reason: "Could not create CGEventSource")
        }
        let vKeyCode: CGKeyCode = 0x09  // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) else {
            return .failed(reason: "Could not create CGEvent")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.010)
        keyUp.post(tap: .cghidEventTap)
        pasterLog.info("paste: Cmd+V posted")

        // Restore previous clipboard contents on a background task. Skipped
        // when nothing was there or when something has touched the clipboard
        // in between (e.g. clipboard manager intercepting our write).
        if let saved = savedString {
            Task.detached { @Sendable in
                try? await Task.sleep(for: .milliseconds(150))
                await MainActor.run {
                    let pb = NSPasteboard.general
                    let expectedChange = savedChange + 1
                    if pb.changeCount == expectedChange {
                        pb.clearContents()
                        pb.setString(saved, forType: .string)
                    }
                }
            }
        }

        return .clipboardSimulatedV
    }
}
