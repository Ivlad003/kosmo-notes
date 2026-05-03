@preconcurrency import AVFoundation
import Foundation
import Observation
import StreamingKit
import os

private let bridgeLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AudioStreamingBridge")

// MARK: - AudioStreamingBridge

/// Glue between the recorder's audio capture pipeline and `RTMPStreamer`.
///
/// AppDelegate constructs one per app launch and hands it to `RecorderState`,
/// which:
///   1. Wires `ingest(_:)` as the `audioTee` callback on its `CaptureSession`
///      so every mic / system-audio PCM buffer also gets forwarded to RTMP.
///   2. Calls `startIfEnabled(settings:)` after capture starts and `stop()`
///      before teardown — so the live stream's lifecycle exactly mirrors the
///      recording's.
///
/// `ingest` is called from `CaptureSession`'s detached drain task — outside
/// any actor — so the bridge's state needs to tolerate that. It does:
/// `streamer.appendAudio` is `nonisolated`-safe (RTMPStreamer is an actor; the
/// `await` happens via Task), and `sampleClock` is a single-writer counter
/// updated only inside `ingest`.
@available(macOS 14.0, *)
@Observable
@MainActor
final class AudioStreamingBridge {

    // MARK: Stored

    /// Underlying RTMPStreamer. Public read so views can show its `state`.
    let streamer: RTMPStreamer

    /// Monotonic sample-time counter advancing by `frameLength` per ingested
    /// buffer. Wrapped in a class for `nonisolated` mutation from the tee
    /// closure (which runs in Task.detached, outside MainActor).
    private let sampleClock: SampleClock

    // MARK: Init

    init(streamer: RTMPStreamer = RTMPStreamer()) {
        self.streamer = streamer
        self.sampleClock = SampleClock()
    }

    // MARK: Public API

    /// Called by RecorderState after capture starts. No-op if streaming is
    /// disabled or the URL/key fields are empty — the user opts in via
    /// Settings → Streaming. Errors are surfaced into the streamer's `state`
    /// (`.failed(message:)`) and otherwise swallowed: a failed stream must
    /// never break the underlying recording.
    func startIfEnabled(settings: AppSettings) async {
        guard settings.streamingEnabled,
              !settings.rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.rtmpStreamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bridgeLog.info("AudioStreamingBridge.startIfEnabled: streaming disabled or URL/key missing — skipping")
            return
        }

        // One-time privacy confirmation — first stream surfaces a modal
        // explaining that audio leaves the machine in real time. User can
        // cancel here, in which case the recording proceeds locally without
        // a parallel RTMP stream.
        guard StreamingPrivacyConfirm.confirm(settings: settings) else {
            bridgeLog.info("AudioStreamingBridge.startIfEnabled: user declined privacy confirmation — skipping")
            return
        }

        sampleClock.reset()

        let cfg = RTMPConfig(rtmpURL: settings.rtmpURL, streamKey: settings.rtmpStreamKey)
        do {
            try await streamer.start(config: cfg)
            bridgeLog.info("AudioStreamingBridge: streamer started for url=\(settings.rtmpURL, privacy: .public)")
        } catch {
            bridgeLog.error("AudioStreamingBridge: streamer.start threw — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called by RecorderState before capture teardown. Idempotent.
    func stop() async {
        await streamer.stop()
        bridgeLog.info("AudioStreamingBridge: streamer stopped")
    }

    /// Audio tee callback. Wire as `audioTee` on `CaptureSession.init`.
    /// Runs on the capture drain Task; non-isolated. Forwards into the
    /// streamer actor without awaiting (`Task { ... }` is fire-and-forget so
    /// the audio pipeline never blocks on RTMP back-pressure).
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        let when = sampleClock.advance(by: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        let streamer = self.streamer
        Task.detached {
            await streamer.appendAudio(buffer, when: when)
        }
    }

    /// Video tee callback. Wire as `videoTee` on `CaptureSession.init`.
    /// CMSampleBuffer carries its own PTS from SCStream; HaishinKit's
    /// IOStream rebases internally, so we don't touch the timeline here.
    /// Runs on ScreenRecorder's SCStream sample-handler queue (off-actor) —
    /// dispatch into the streamer actor via Task.detached, same shape as
    /// `ingest(_:)`.
    nonisolated func ingestVideo(_ buffer: CMSampleBuffer) {
        let streamer = self.streamer
        Task.detached {
            await streamer.appendVideo(buffer)
        }
    }
}

// SampleClock now lives in StreamingKit (Sources/StreamingKit/SampleClock.swift)
// so it's unit-testable from the SPM test target — App/ doesn't have a
// configured XCTest target.
