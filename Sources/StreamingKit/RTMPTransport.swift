@preconcurrency import AVFoundation
import Foundation

// MARK: - RTMPTransport

/// Internal abstraction over an RTMP publish session. Decouples `RTMPStreamer`
/// from HaishinKit (or any future replacement) and lets tests inject a
/// deterministic mock without opening a real socket.
///
/// The contract is intentionally minimal:
///   - `connectAndPublish` opens the socket, performs the RTMP handshake, and
///     issues the publish command. It throws if any of that fails.
///   - `appendAudio` / `appendVideo` push one chunk onto the live stream.
///     Implementations are expected to be tolerant of being called before
///     `connectAndPublish` finishes — HaishinKit, for example, buffers
///     internally until the connection is established.
///   - `close` tears the session down. Idempotent — calling on a non-active
///     transport is a no-op.
public protocol RTMPTransport: Sendable {

    /// Open the RTMP socket and start publishing under `streamKey`. Throws on
    /// invalid URL, socket failure, handshake rejection. `RTMPStreamer` maps
    /// thrown errors to `StreamingError.connectionFailed` / `.publishFailed`
    /// at the public API boundary.
    func connectAndPublish(url: String, streamKey: String) async throws

    /// Push one PCM audio buffer with its presentation timestamp.
    /// `when` provides the AV-sync clock the muxer reads — supplying a stable
    /// monotonically-increasing time is the caller's responsibility.
    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime)

    /// Push one video sample buffer (pre-encoded H.264 or raw CVPixelBuffer-
    /// backed; the transport's encoder takes care of the rest). Caller-side
    /// timing must already be set in the buffer's presentation timestamp.
    func appendVideo(_ buffer: CMSampleBuffer)

    /// Tear down the publish session and close the socket. Idempotent.
    func close() async
}
