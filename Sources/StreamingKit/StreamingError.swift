import Foundation

// MARK: - StreamingError

/// Typed errors surfaced by `RTMPStreamer` and `RTMPConfig.validate()`.
///
/// Kept narrow on purpose — the UI maps these to single-line messages, so the
/// case set should be small enough that every case has an obvious user-facing
/// string. Provider-specific failure detail (e.g. HaishinKit error codes) is
/// folded into `connectionFailed(message:)` / `publishFailed(message:)`.
public enum StreamingError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case missingStreamKey
    case connectionFailed(message: String)
    case publishFailed(message: String)
    case alreadyPublishing
    case notPublishing

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Stream URL is invalid. Expected something like rtmp://host/app."
        case .missingStreamKey:
            return "Stream key is empty. Set it in Settings → Streaming."
        case .connectionFailed(let message):
            return "Could not connect to RTMP server: \(message)"
        case .publishFailed(let message):
            return "Could not publish to RTMP stream: \(message)"
        case .alreadyPublishing:
            return "A stream is already in progress. Stop it first."
        case .notPublishing:
            return "No active stream to stop."
        }
    }
}
