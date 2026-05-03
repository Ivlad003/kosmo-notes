@preconcurrency import AVFoundation
import Foundation
import HaishinKit
import os

private let transportLog = Logger(subsystem: "dev.kosmonotes.studio", category: "RTMPTransport")

// MARK: - HaishinKitRTMPTransport

/// Production `RTMPTransport` backed by HaishinKit 1.x.
///
/// **Lifecycle.** `connectAndPublish` constructs an `RTMPConnection` + an
/// `RTMPStream`, fires `connect(url)` and `publish(streamKey)` immediately,
/// and returns. HaishinKit performs the actual handshake asynchronously on
/// its internal queue and buffers any sample buffers we push in the meantime,
/// so callers can start `appendAudio` / `appendVideo` immediately.
///
/// **Mid-stream events.** The adapter registers an `addEventListener` on the
/// connection's `.rtmpStatus` channel; status codes (`NetConnection.Connect.*`,
/// `NetStream.Publish.*`) are mapped onto the `events` AsyncStream so
/// `RTMPStreamer` can flip its public state when:
///   - publish-start fires (proof the muxer is live → `.publishing`)
///   - the peer drops mid-broadcast or rejects publish (`.failed`)
///   - a graceful peer-close arrives (`.closed`)
///
/// Selector-based event observation requires an NSObject host with `@objc`
/// methods, which is why the class inherits from `NSObject` rather than
/// being a plain `final class`.
///
/// Sendability: HaishinKit's RTMPConnection / RTMPStream are reference types
/// that aren't marked `Sendable`. They're internally thread-safe (HaishinKit
/// dispatches onto its own queues), so we mark the adapter `@unchecked
/// Sendable`. **No internal locking** for the connection/stream pointers —
/// `RTMPStreamer` is the sole owner and drives this from inside its actor
/// isolation, which serializes every call site for free. The
/// `eventContinuation` is only touched from `@objc handleStatus(_:)` and
/// `close()` — both effectively single-threaded for any given session.
public final class HaishinKitRTMPTransport: NSObject, RTMPTransport, @unchecked Sendable {

    // MARK: Stored

    private var connection: RTMPConnection?
    private var stream: RTMPStream?

    private let eventStream: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    public var events: AsyncStream<TransportEvent> {
        get async { eventStream }
    }

    // MARK: Init

    public override init() {
        var continuation: AsyncStream<TransportEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
        super.init()
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: RTMPTransport

    public func connectAndPublish(url: String, streamKey: String) async throws {
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        self.connection = connection
        self.stream = stream

        // Register on .rtmpStatus before issuing connect so we don't miss the
        // very first NetConnection.Connect.Success event.
        connection.addEventListener(.rtmpStatus, selector: #selector(handleStatus(_:)), observer: self)

        // Fire-and-forget: connect+publish are issued synchronously but the
        // actual handshake / stream creation runs on HaishinKit's queue.
        // Publish-start arrives via handleStatus; mid-stream failures too.
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

        connection?.removeEventListener(.rtmpStatus, selector: #selector(handleStatus(_:)), observer: self)
        stream?.close()
        connection?.close()
        // Tell subscribers the session ended cleanly. RTMPStreamer differentiates
        // a user-initiated close from an unsolicited one by checking its own
        // state — close() called while .idle suppresses the .closed reaction.
        eventContinuation.yield(.closed)
        transportLog.info("HaishinKit transport: closed")
    }

    // MARK: Status handling

    /// Selector target for HaishinKit's `.rtmpStatus` event. Runs on whatever
    /// queue HaishinKit dispatches from — in practice its private socket
    /// queue. Keep work here lock-free + allocation-light: parse the event,
    /// map the code to a TransportEvent, yield, return.
    @objc private func handleStatus(_ notification: Notification) {
        let event = Event.from(notification)
        guard let data = event.data as? [String: Any?],
              let code = data["code"] as? String else {
            return
        }
        transportLog.info("HaishinKit transport: rtmpStatus code=\(code, privacy: .public)")

        switch code {
        case RTMPStream.Code.publishStart.rawValue:
            // Provider accepted the publish — muxer is live. RTMPStreamer
            // already optimistically transitioned to .publishing on connectAndPublish
            // returning; this event is informational confirmation. Yielding it
            // anyway lets future consumers (a "live" indicator) hook in.
            eventContinuation.yield(.publishing)

        case RTMPConnection.Code.connectFailed.rawValue,
             RTMPConnection.Code.connectRejected.rawValue:
            let description = (data["description"] as? String) ?? code
            eventContinuation.yield(.failed(.connectionFailed(message: description)))

        case RTMPStream.Code.publishBadName.rawValue:
            // Most common cause: another publisher already holds this stream
            // key, or the provider rejected the key as malformed.
            let description = (data["description"] as? String) ?? "stream key rejected"
            eventContinuation.yield(.failed(.publishFailed(message: description)))

        case RTMPConnection.Code.connectClosed.rawValue:
            // Peer closed the connection. Could be graceful (we asked for it
            // via close()) or unexpected (network drop, server kicked us).
            // RTMPStreamer's state machine decides which interpretation fits.
            eventContinuation.yield(.closed)

        default:
            // Codes we don't surface yet: NetConnection.Connect.Success
            // (already handled by the optimistic transition), NetStream.Pause /
            // Unpause (we never pause), bandwidth-related callbacks, etc.
            break
        }
    }
}
