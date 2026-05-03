@preconcurrency import AVFoundation
import Foundation
@testable import StreamingKit

// MARK: - MockRTMPTransport

/// Programmable `RTMPTransport` for `RTMPStreamer` tests.
///
/// Lets each test decide whether `connectAndPublish` succeeds or throws, and
/// records every call (URL/key, audio-buffer count, video-buffer count, close
/// count) for assertions. Tests can also `simulate(_:)` mid-stream events
/// (e.g. `.failed(.publishFailed(message:))`) to drive RTMPStreamer's state
/// machine through reconnect / failure paths.
///
/// **No internal locking** — the mock is owned by `RTMPStreamer`'s actor for
/// every call (start, append, stop), so the actor's isolation already
/// serializes access. Tests read `calls` only after awaiting the streamer
/// method, so the read happens-after the mutation.
final class MockRTMPTransport: RTMPTransport, @unchecked Sendable {

    enum ConnectMode: Sendable {
        case succeed
        case fail(StreamingError)
    }

    struct Calls: Sendable {
        var connectURL: String?
        var connectStreamKey: String?
        var connectCount: Int = 0
        var audioCount: Int = 0
        var videoCount: Int = 0
        var closeCount: Int = 0
    }

    private var _mode: ConnectMode
    private var _calls = Calls()

    private let eventStream: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    var events: AsyncStream<TransportEvent> {
        get async { eventStream }
    }

    init(mode: ConnectMode = .succeed) {
        self._mode = mode
        var continuation: AsyncStream<TransportEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    var calls: Calls { _calls }

    func setMode(_ mode: ConnectMode) {
        _mode = mode
    }

    /// Inject an event onto the transport's event stream. Tests use this to
    /// drive RTMPStreamer through mid-stream failure / close paths without a
    /// real socket. Yields synchronously — combine with `await Task.yield()`
    /// before assertions if the streamer's state-update Task hasn't run yet.
    func simulate(_ event: TransportEvent) {
        eventContinuation.yield(event)
    }

    // MARK: RTMPTransport

    func connectAndPublish(url: String, streamKey: String) async throws {
        _calls.connectURL = url
        _calls.connectStreamKey = streamKey
        _calls.connectCount += 1
        switch _mode {
        case .succeed: return
        case .fail(let err): throw err
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        _calls.audioCount += 1
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        _calls.videoCount += 1
    }

    func close() async {
        _calls.closeCount += 1
        eventContinuation.yield(.closed)
    }
}
