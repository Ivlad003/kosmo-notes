import Foundation

// MARK: - RTMPConfig

/// Per-session RTMP destination + encode parameters.
///
/// `streamKey` is **resolved at the call site from Keychain** — this struct
/// only holds the runtime values, never persists them. Persisted Settings
/// hold the RTMP URL plus a Keychain account reference; on stream-start the
/// caller reads the key, builds an `RTMPConfig`, and discards it on stream-end.
public struct RTMPConfig: Sendable, Equatable {

    /// RTMP ingest endpoint, e.g. `"rtmp://a.rtmp.youtube.com/live2"`.
    /// Stream key is appended by the publisher, not embedded here, so the URL
    /// itself is safe to log without leaking credentials.
    public let rtmpURL: String

    /// Provider-issued stream key. Treated as a secret — never logged, never
    /// surfaced in error messages.
    public let streamKey: String

    /// Video encode bitrate in bits per second. 4 Mbps default tracks the
    /// `ScreenRecorder` setting so screen captures look the same locally and
    /// on the live feed.
    public let videoBitrate: Int

    /// Video framerate. Matches `ScreenRecorder`'s 24 fps by default; bumpable
    /// to 30/60 for fast-motion content.
    public let videoFPS: Int

    /// Audio encode bitrate in bits per second. 128 kbps stereo / 96 kbps mono
    /// is plenty for voice + ambient — well below typical RTMP ingest caps.
    public let audioBitrate: Int

    public init(
        rtmpURL: String,
        streamKey: String,
        videoBitrate: Int = 4_000_000,
        videoFPS: Int = 24,
        audioBitrate: Int = 128_000
    ) {
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
        self.videoBitrate = videoBitrate
        self.videoFPS = videoFPS
        self.audioBitrate = audioBitrate
    }
}

// MARK: - Validation

public extension RTMPConfig {

    /// Quick syntactic check. Does **not** open a socket — that's the
    /// publisher's job. Catches the common typos: missing `rtmp://` scheme,
    /// missing host, empty stream key.
    func validate() throws {
        guard !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamingError.missingStreamKey
        }
        guard let url = URL(string: rtmpURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = url.host, !host.isEmpty else {
            throw StreamingError.invalidURL
        }
    }
}
