import AVFoundation
import AppKit
import Foundation

// MARK: - FrameExtractor

/// Extracts a single JPEG frame from a video file at a given timestamp.
///
/// Used by ChatState to pull frames out of screen.mp4 and attach them as
/// vision content to LLM messages.
@available(macOS 14.0, *)
struct FrameExtractor {

    enum FrameError: Error, LocalizedError {
        case noVideoTracks
        case pastDuration(requested: TimeInterval, duration: TimeInterval)
        case imageGenerationFailed
        case jpegEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTracks:
                return "The file has no video tracks — screen recording may not be present."
            case .pastDuration(let req, let dur):
                return "Requested time \(Int(req))s is past the video duration \(Int(dur))s."
            case .imageGenerationFailed:
                return "Could not extract a frame at the requested time."
            case .jpegEncodingFailed:
                return "Could not encode the extracted frame as JPEG."
            }
        }
    }

    /// Extract a single JPEG frame at `time` seconds from `videoURL`.
    ///
    /// Uses 100 ms tolerance after the requested time to find the nearest keyframe
    /// quickly without forcing an exact (slow) seek.
    static func extractFrame(
        at time: TimeInterval,
        from videoURL: URL,
        jpegQuality: CGFloat = 0.8
    ) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)

        // Confirm there is at least one video track before attempting image generation.
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw FrameError.noVideoTracks }

        // Reject timestamps past the video duration (with a 1 s grace for short videos).
        let duration = try await asset.load(.duration)
        let durationSecs = CMTimeGetSeconds(duration)
        if time > durationSecs + 1 {
            throw FrameError.pastDuration(requested: time, duration: durationSecs)
        }
        // Clamp to valid range so we don't ask for frames beyond EOF.
        let clampedTime = min(time, max(0, durationSecs - 0.1))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Zero tolerance before so we don't get an earlier frame; 100 ms after to find nearest.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let requestTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: requestTime)

        // Encode CGImage → JPEG via NSBitmapImageRep.
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else {
            throw FrameError.jpegEncodingFailed
        }
        return jpegData
    }
}
