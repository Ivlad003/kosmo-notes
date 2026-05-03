@preconcurrency import AVFoundation
import Foundation

// MARK: - RTMPStreamer

/// The single live-streaming pipeline for the app.
///
/// Drives a state machine (.idle → .connecting → .publishing → .idle) over an
/// injected `RTMPTransport`. Production code uses `HaishinKitRTMPTransport`;
/// tests inject a `MockRTMPTransport` so the state machine can be exercised
/// without opening a real socket.
///
/// Subscribes to `transport.events` while a stream is active so mid-stream
/// failures (peer drop, publish-rejected, network error) flip `state` to
/// `.failed(message:)` instead of leaving a zombie that thinks it's still
/// publishing. The event subscription is cancelled in `stop()` so a
/// user-initiated close doesn't masquerade as a failure.
///
/// `appendAudio` / `appendVideo` are no-ops outside `.publishing` so callers
/// (the eventual `CaptureSession` tee) can wire them unconditionally and let
/// the streamer drop samples while the stream is offline.
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

    private let transport: any RTMPTransport
    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private var activeConfig: RTMPConfig?
    /// Task draining `transport.events` while a session is active. Cancelled
    /// in `stop()` so the .closed event we emit during user-initiated teardown
    /// doesn't trigger a spurious .failed transition.
    private var eventTask: Task<Void, Never>?

    // MARK: Init

    /// Default init wires the production HaishinKit transport. Tests inject a
    /// mock via the explicit-transport overload.
    public init(transport: any RTMPTransport = HaishinKitRTMPTransport()) {
        self.transport = transport
        var continuation: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    deinit {
        stateContinuation.finish()
        eventTask?.cancel()
    }

    // MARK: Public API

    /// Begin publishing to the configured RTMP endpoint.
    ///
    /// Idempotency: calling while already publishing or connecting throws
    /// `.alreadyPublishing`. Calling from `.failed` or `.idle` runs the full
    /// connect+publish flow.
    ///
    /// On `transport.connectAndPublish` throw, state transitions to
    /// `.failed(message:)` and the original error is re-thrown so the caller
    /// can surface it directly.
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

        do {
            try await transport.connectAndPublish(url: config.rtmpURL, streamKey: config.streamKey)
            transition(to: .publishing)
            await startEventTask()
        } catch {
            // Map any transport error to .failed and clear active config.
            // Surface a typed StreamingError so the UI gets a stable case set
            // regardless of whether HaishinKit threw a system error or a
            // mock transport threw a test fixture.
            activeConfig = nil
            let wrapped: StreamingError
            if let typed = error as? StreamingError {
                wrapped = typed
            } else {
                wrapped = .connectionFailed(message: error.localizedDescription)
            }
            transition(to: .failed(message: wrapped.errorDescription ?? "Unknown failure"))
            throw wrapped
        }
    }

    /// Stop publishing and close the underlying transport. Safe to call from
    /// any state — non-active states are no-ops (no error thrown) so the UI's
    /// "Stop" button can be wired without state checks.
    public func stop() async {
        switch state {
        case .idle, .failed:
            return
        case .connecting, .publishing:
            // Cancel event subscription FIRST so the .closed event we yield
            // during transport.close() doesn't race with the manual transition
            // below and turn into a spurious .failed.
            eventTask?.cancel()
            eventTask = nil
            await transport.close()
            activeConfig = nil
            transition(to: .idle)
        }
    }

    /// Push one mic / system-audio PCM buffer onto the live stream. No-op when
    /// not `.publishing` — callers can wire this unconditionally from the
    /// capture pipeline and let the streamer drop samples while offline.
    public func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard case .publishing = state else { return }
        transport.appendAudio(buffer, when: when)
    }

    /// Push one screen / camera video frame onto the live stream. No-op when
    /// not `.publishing`.
    public func appendVideo(_ buffer: CMSampleBuffer) {
        guard case .publishing = state else { return }
        transport.appendVideo(buffer)
    }

    // MARK: Private

    private func transition(to next: State) {
        guard state != next else { return }
        state = next
        stateContinuation.yield(next)
    }

    /// Spin up the transport-event drain task. Mid-stream events
    /// (`.failed`, unsolicited `.closed`) flip our state to `.failed` so the
    /// UI sees the dead stream. `.publishing` events are informational —
    /// we already transitioned optimistically in `start()`.
    private func startEventTask() async {
        let stream = await transport.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event: event)
            }
        }
    }

    private func handle(event: TransportEvent) {
        switch event {
        case .publishing:
            // Provider confirmed publish-start. We already optimistically
            // transitioned to .publishing on connectAndPublish returning;
            // this event is informational. Re-yield to keep the state stream
            // consistent if a subscriber missed the first transition.
            if state != .publishing {
                transition(to: .publishing)
            }
        case .failed(let err):
            // Mid-stream failure during .publishing OR a late failure during
            // .connecting both flip us to .failed. Once .failed, ignore
            // further transport noise.
            switch state {
            case .publishing, .connecting:
                transition(to: .failed(message: err.errorDescription ?? "Stream failed"))
            case .idle, .failed:
                break
            }
        case .closed:
            // Unsolicited peer-close while .publishing → .failed.
            // User-initiated stop() cancels eventTask before close() yields
            // .closed, so a graceful close never reaches this handler.
            if case .publishing = state {
                transition(to: .failed(message: "RTMP peer closed the connection unexpectedly"))
            }
        }
    }
}
