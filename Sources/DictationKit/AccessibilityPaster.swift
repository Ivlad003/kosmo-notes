import AppKit
import ApplicationServices

// MARK: - AccessibilityPaster

/// Pastes text into the currently focused UI element.
///
/// Strategy 1: AXAPI direct insert via kAXSelectedTextAttribute — works in most
///             native apps and many Electron apps.
/// Strategy 2: Clipboard + simulated Cmd+V fallback.
@available(macOS 14.0, *)
public enum AccessibilityPaster {

    public enum PasteResult: Sendable, Equatable {
        case axInserted
        case clipboardSimulatedV
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

    /// Attempt to paste `text` using AXAPI first, then clipboard+Cmd+V.
    public static func paste(_ text: String) -> PasteResult {
        // Strategy 1: AXAPI direct insert
        if isTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedElement: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElement
            )
            if err == .success, let element = focusedElement {
                let axElement = element as! AXUIElement  // swiftlint:disable:this force_cast
                let setErr = AXUIElementSetAttributeValue(
                    axElement,
                    kAXSelectedTextAttribute as CFString,
                    text as CFTypeRef
                )
                if setErr == .success {
                    return .axInserted
                }
            }
        }

        // Strategy 2: Clipboard + Cmd+V simulation
        return pasteViaClipboard(text)
    }

    // MARK: - Private

    private static func pasteViaClipboard(_ text: String) -> PasteResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V via CGEvent
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
        keyUp.post(tap: .cghidEventTap)
        return .clipboardSimulatedV
    }
}
