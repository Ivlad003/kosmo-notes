import AppKit
import Foundation

// MARK: - StreamingPrivacyConfirm

/// One-time pre-stream confirmation modal. RTMP broadcast is a meaningfully
/// different privacy posture from local recording — every captured second
/// leaves the machine in real time to a server the user controls (their own
/// MediaMTX, a SaaS like YouTube Live, etc.). Surfacing that fact once before
/// the first stream protects users who toggled the feature on without reading
/// the Settings privacy paragraph.
///
/// The flag is sticky: once OK is pressed, `streamingPrivacyAcknowledged`
/// flips to true and we never re-prompt. Users who want the same warning
/// later can read it in Settings → Streaming.
@available(macOS 14.0, *)
@MainActor
enum StreamingPrivacyConfirm {

    /// Returns `true` when the user has either pre-acknowledged the privacy
    /// warning OR taps OK on the just-shown modal. Returns `false` when they
    /// tap Cancel — caller should abort the stream-start in that case.
    static func confirm(settings: AppSettings) -> Bool {
        if settings.streamingPrivacyAcknowledged { return true }

        let alert = NSAlert()
        alert.messageText = "Start live RTMP stream?"
        alert.informativeText = """
        KosmoNotes is about to publish your microphone audio (and, when Audio + Screen mode is on, system audio + screen video) in real time to:

        \(settings.rtmpURL)

        Verify you trust this destination — the stream content is sent unencrypted unless the URL starts with rtmps://. This warning shows once; you can revisit the privacy text any time in Settings → Streaming.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start streaming")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return false
        }
        settings.streamingPrivacyAcknowledged = true
        return true
    }
}
