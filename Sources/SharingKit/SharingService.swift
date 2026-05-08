import Foundation

// MARK: - SharingService

/// Coordinates uploading session sidecars to S3 + presigning recipient URLs.
///
/// v1.0 ships a simple bundle layout: each session uploads as `<prefix>/<sid>/audio.m4a`
/// and (when present) `<prefix>/<sid>/summary.md`. Recipients get a list of presigned
/// URLs they can open in a browser.
public struct SharingService: Sendable {

    public let s3: S3Client
    public let keyPrefix: String   // e.g. "kosmonotes/" — namespaces bucket use across users
    public let presignTTLSeconds: Int

    public init(s3: S3Client, keyPrefix: String = "kosmonotes/", presignTTLSeconds: Int = 7 * 24 * 3600) {
        self.s3 = s3
        // Normalize: ensure prefix ends with `/` so concatenation produces clean keys.
        var normalized = keyPrefix
        if !normalized.isEmpty, !normalized.hasSuffix("/") { normalized += "/" }
        self.keyPrefix = normalized
        self.presignTTLSeconds = presignTTLSeconds
    }

    // MARK: - Public API

    /// Result of a session share: presigned URLs for each artifact that was uploaded.
    public struct ShareResult: Sendable, Equatable {
        public let audioURL: URL?
        public let videoURL: URL?
        public let summaryURL: URL?
        public let transcriptURL: URL?

        public var allLinks: [URL] {
            [audioURL, videoURL, summaryURL, transcriptURL].compactMap { $0 }
        }
    }

    /// Upload audio + (optional) summary + (optional) transcript for a session,
    /// then build presigned GET URLs for each.
    /// - Parameter sessionDir: filesystem dir containing audio.m4a, summary.md, transcript.txt
    /// - Parameter sessionId: stable identifier; used as the S3 key suffix
    public func shareSession(sessionDir: URL, sessionId: String) async throws -> ShareResult {
        let now = Date()

        let audioFile = sessionDir.appendingPathComponent("audio.m4a")
        let videoFile = sessionDir.appendingPathComponent("screen.mp4")
        let summaryFile = sessionDir.appendingPathComponent("summary.md")
        let transcriptFile = sessionDir.appendingPathComponent("transcript.txt")

        var audioURL: URL?
        var videoURL: URL?
        var summaryURL: URL?
        var transcriptURL: URL?

        if FileManager.default.fileExists(atPath: audioFile.path) {
            let key = "\(keyPrefix)\(sessionId)/audio.m4a"
            let data = try Data(contentsOf: audioFile)
            try await s3.putObject(key: key, data: data, contentType: "audio/mp4", now: now)
            audioURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if FileManager.default.fileExists(atPath: videoFile.path) {
            let key = "\(keyPrefix)\(sessionId)/screen.mp4"
            let data = try Data(contentsOf: videoFile)
            try await s3.putObject(key: key, data: data, contentType: "video/mp4", now: now)
            videoURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if FileManager.default.fileExists(atPath: summaryFile.path) {
            let key = "\(keyPrefix)\(sessionId)/summary.md"
            let data = try Data(contentsOf: summaryFile)
            try await s3.putObject(key: key, data: data, contentType: "text/markdown; charset=utf-8", now: now)
            summaryURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        if FileManager.default.fileExists(atPath: transcriptFile.path) {
            let key = "\(keyPrefix)\(sessionId)/transcript.txt"
            let data = try Data(contentsOf: transcriptFile)
            try await s3.putObject(key: key, data: data, contentType: "text/plain; charset=utf-8", now: now)
            transcriptURL = try s3.presignedGetURL(key: key, expirySeconds: presignTTLSeconds, now: now)
        }

        return ShareResult(
            audioURL: audioURL,
            videoURL: videoURL,
            summaryURL: summaryURL,
            transcriptURL: transcriptURL
        )
    }
}
