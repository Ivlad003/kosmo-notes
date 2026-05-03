@preconcurrency import AVFoundation
import Foundation
import HaishinKit

// MARK: - RTMPStreamer

/// The single live-streaming pipeline for the app.
///
/// Phase 1 (this file) wires the **state machine** and **public API surface**
/// only. The actual HaishinKit `RTMPConnection` / `RTMPStream` lifecycle is
/// stubbed — `start(config:)` validates the config, transitions through
/// `.connecting` to `.publishing` immediately, and `appendAudio` /
/// `appendVideo` accept buffers without forwarding them anywhere. This lets
/// the rest of the app (Settings UI, hotkey, recording-time wire-up) land
/// against a stable interface before the network plumbing turns on.
///
/// Phase 2 (next commit on this branch) replaces the stubs with real
/// HaishinKit calls and wires audio / video sample-buffer tees from
/// `CaptureSession` and `ScreenRecorder`.
public actor RTMPStreamer {

    // MARK: State

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case publishing
        case failed(message: String)
    }

    /// Observable state. Read from any actor; mutate only inside `RTMPStreamer`.
    public private(set) var state: State = .idle

    /// `AsyncStream` of state transitions for SwiftUI / AppKit observers. Drops
    /// duplicates — only emits on actual changes.
    public var states: AsyncStream<State> { stateStream }

    // MARK: Stored

    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private var activeConfig: RTMPConfig?

    // MARK: Init

    public init() {
        var continuation: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: Public API

    /// Begin publishing to the configured RTMP endpoint.
    ///
    /// Idempotency: calling while already publishing throws
    /// `.alreadyPublishing`. Calling from `.failed` or `.idle` is fine —
    /// state transitions to `.connecting` immediately, then either
    /// `.publishing` or `.failed`.
    ///
    /// Phase 1: validates config and transitions to `.publishing` without
    /// opening a socket. Phase 2 will replace the body with the real
    /// HaishinKit `RTMPConnection.connect` + `RTMPStream.publish` flow.
    public func start(config: RTMPConfig) async throws {
        switch state {
        case .publishing, .connecting:
            throw StreamingError.alreadyPublishing
        case .idle, .failed:
            break
        }

        try config.validate()

        transition(to: .connecting)
        activeConfig = config

        // Phase 2 inserts the real connect / publish here. For now pretend
        // the connection succeeded immediately so downstream wiring (Settings
        // UI, hotkey, recording sync) can be exercised without a server.
        transition(to: .publishing)
    }

    /// Stop publishing and close the underlying connection. Safe to call from
    /// any state — non-publishing states are no-ops (no error thrown) so the
    /// UI's "Stop" button can be wired without state checks.
    public func stop() async {
        switch state {
        case .idle, .failed:
            return
        case .connecting, .publishing:
            // Phase 2: tear down RTMPStream + RTMPConnection here.
            activeConfig = nil
            transition(to: .idle)
        }
    }

    /// Push one mic / system-audio sample buffer onto the live stream. Caller
    /// is responsible for sample-rate compatibility (HaishinKit re-encodes).
    /// No-op when not `.publishing`.
    ///
    /// Phase 2: forwards into `RTMPStream.appendSampleBuffer(_:withType: .audio)`.
    public func appendAudio(_ buffer: CMSampleBuffer) {
        guard case .publishing = state else { return }
        // Phase 2 wires HaishinKit here.
        _ = buffer
    }

    /// Push one screen / camera video frame onto the live stream. Buffer must
    /// be H.264-encodable (CVPixelBuffer-backed CMSampleBuffer with timing
    /// info). No-op when not `.publishing`.
    ///
    /// Phase 2: forwards into `RTMPStream.appendSampleBuffer(_:withType: .video)`.
    public func appendVideo(_ buffer: CMSampleBuffer) {
        guard case .publishing = state else { return }
        // Phase 2 wires HaishinKit here.
        _ = buffer
    }

    // MARK: Private

    private func transition(to next: State) {
        guard state != next else { return }
        state = next
        stateContinuation.yield(next)
    }
}
