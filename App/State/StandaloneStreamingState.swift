@preconcurrency import AVFoundation
import AppKit
import CaptureKit
import Foundation
import Observation
import os

private let standaloneLog = Logger(subsystem: "dev.kosmonotes.studio", category: "StandaloneStreaming")

// MARK: - StandaloneStreamingState

/// Standalone "stream-only" RTMP path — mic-only audio capture wired straight
/// into `AudioStreamingBridge`. No `RecorderState`, no `SegmentWriter`, no
/// disk. Toggled via the ⌘⇧S global hotkey or a menu item; lives outside the
/// recording flow so users can broadcast without producing a saved session.
///
/// Sync-with-recording RTMP (⌘⇧R + Settings → Streaming toggle) remains the
/// primary path; this state object only kicks in when the user explicitly
/// wants to stream without recording.
///
/// The audio chain is intentionally minimal: a bare `AudioEngine` produces
/// mic PCM buffers; a detached drain task forwards each one to
/// `AudioStreamingBridge.ingest(_:)`. System audio, screen video, and
/// transcription are all out of scope here — those live in the full
/// `RecorderState` path.
@available(macOS 14.0, *)
@Observable
@MainActor
final class StandaloneStreamingState {

    // MARK: Stored

    private let bridge: AudioStreamingBridge
    private let settings: AppSettings
    private var engine: AudioEngine?
    private var drainTask: Task<Void, Never>?
    /// Mirror of whether the standalone stream is currently running. UI binds
    /// to this for the menu item title and status indicator.
    private(set) var isActive: Bool = false

    // MARK: Init

    init(bridge: AudioStreamingBridge, settings: AppSettings) {
        self.bridge = bridge
        self.settings = settings
    }

    // MARK: Public API

    /// Toggle standalone streaming on/off. Idempotent — pressing the hotkey
    /// twice in quick succession won't double-start. Surfaces start failures
    /// via NSAlert (mic permission denied, RTMP misconfigured, etc).
    func toggle() async {
        if isActive {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isActive else { return }
        guard settings.streamingEnabled else {
            presentAlert(
                "Streaming disabled",
                "Toggle 'Also broadcast to RTMP while recording' on in Settings → Streaming, then try again. The same toggle controls the standalone path."
            )
            return
        }
        guard !settings.rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.rtmpStreamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentAlert(
                "Streaming destination not configured",
                "Set the RTMP URL and stream key in Settings → Streaming before starting a standalone stream."
            )
            return
        }

        // One-time privacy confirmation. Reused between sync (RecorderState
        // path) and standalone — both flows funnel through StreamingPrivacyConfirm
        // so the user only ever sees the modal once.
        guard StreamingPrivacyConfirm.confirm(settings: settings) else {
            standaloneLog.info("StandaloneStreaming.start: user declined privacy confirmation — aborting")
            return
        }

        // Pre-flight: mic permission. First call triggers the OS prompt; cached
        // on subsequent calls. Standalone streaming has no other pre-flight —
        // unlike RecorderState it doesn't need transcription keys, screen
        // recording grants, or anything else.
        let micGranted = await PermissionsHelper.requestMicAccess()
        guard micGranted else {
            PermissionsHelper.showMissingAlert(.microphone)
            return
        }

        let engine = AudioEngine()
        let stream: AsyncStream<AVAudioPCMBuffer>
        do {
            stream = try await engine.start()
        } catch {
            standaloneLog.error("StandaloneStreaming.start: AudioEngine failed — \(error.localizedDescription, privacy: .public)")
            presentAlert("Microphone start failed", error.localizedDescription)
            return
        }
        self.engine = engine

        await bridge.startIfEnabled(settings: settings)

        let bridgeRef = bridge
        let streamBox = UncheckedSendableBox(stream)
        drainTask = Task.detached {
            for await buffer in streamBox.value {
                bridgeRef.ingest(buffer)
            }
            standaloneLog.info("StandaloneStreaming: drain task exited")
        }

        isActive = true
        standaloneLog.info("StandaloneStreaming.start: streaming live to \(self.settings.rtmpURL, privacy: .public)")
    }

    func stop() async {
        guard isActive else { return }
        drainTask?.cancel()
        drainTask = nil
        await engine?.stop()
        engine = nil
        await bridge.stop()
        isActive = false
        standaloneLog.info("StandaloneStreaming.stop: stopped")
    }

    // MARK: Private

    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Helpers

/// Same boxing trick CaptureSession uses to ferry a non-Sendable AsyncStream
/// across actor boundaries when the consumer guarantees single-ownership.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
