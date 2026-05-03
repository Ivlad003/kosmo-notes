@preconcurrency import AVFoundation
import Foundation
import HaishinKit
import os

private let transportLog = Logger(subsystem: "dev.kosmonotes.studio", category: "RTMPTransport")

// MARK: - HaishinKitRTMPTransport

/// Production `RTMPTransport` backed by HaishinKit 1.x.
///
/// Lifecycle: `connectAndPublish` constructs an `RTMPConnection` and an
/// `RTMPStream`, fires `connect(url)` and `publish(streamKey)` immediately,
/// and returns. HaishinKit performs the actual handshake asynchronously on
/// its internal queue and buffers any sample buffers we push in the meantime,
/// so callers can start `appendAudio`/`appendVideo` immediately after
/// `connectAndPublish` resolves. **Connection failures that happen mid-stream
/// are not yet surfaced through this adapter** — Phase 2c will hook the
/// `RTMPConnectionDelegate` callbacks into a state-event channel.
///
/// Sendability: HaishinKit's RTMPConnection / RTMPStream are reference types
/// that aren't marked `Sendable`. They're internally thread-safe (HaishinKit
/// dispatches onto its own queues), so we mark the adapter `@unchecked
/// Sendable`. **No internal locking** — `RTMPStreamer` is the sole owner and
/// drives this from inside its actor isolation, which serializes every call
/// site for free.
public final class HaishinKitRTMPTransport: RTMPTransport, @unchecked Sendable {

    // MARK: Stored

    private var connection: RTMPConnection?
    private var stream: RTMPStream?

    // MARK: Init

    public init() {}

    // MARK: RTMPTransport

    public func connectAndPublish(url: String, streamKey: String) async throws {
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        self.connection = connection
        self.stream = stream

        // Both calls are fire-and-forget — HaishinKit dispatches handshake +
        // publish onto its own queue and buffers samples until ready. If the
        // socket can't open at all (DNS / refused), the failure is surfaced
        // via the `rtmpStatus` event stream which Phase 2c will hook.
        connection.connect(url)
        stream.publish(streamKey)
        transportLog.info("HaishinKit transport: connect+publish issued for url=\(url, privacy: .public)")
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // IOStream auto-routes by mediaType; AVAudioBuffer overload skips the
        // CMSampleBuffer dance entirely.
        stream?.append(buffer, when: when)
    }

    public func appendVideo(_ buffer: CMSampleBuffer) {
        stream?.append(buffer)
    }

    public func close() async {
        let stream = self.stream
        let connection = self.connection
        self.stream = nil
        self.connection = nil

        stream?.close()
        connection?.close()
        transportLog.info("HaishinKit transport: closed")
    }
}
