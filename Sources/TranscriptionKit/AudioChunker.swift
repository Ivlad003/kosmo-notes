import AVFoundation
import Foundation
import os

private let chunkerLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AudioChunker")

// MARK: - AudioChunker

/// Splits an audio file into time-bounded chunks for upload to APIs that
/// have per-request duration / size limits.
///
/// Concrete drivers:
/// - OpenAI `gpt-4o-transcribe` rejects audio longer than 1400 s with
///   HTTP 400 `invalid_value`.
/// - OpenAI `whisper-1` accepts up to 25 MB per upload.
/// - Many other providers (Gemini, OpenRouter audio) cap on body size,
///   not duration, but the duration-based approach also keeps file size
///   bounded (96 kbps × 1200 s ≈ 14.4 MB, well under 25 MB).
///
/// Chunking uses `AVMutableComposition` + `AVAssetExportSession` with
/// `AVAssetExportPresetAppleM4A` — the same approach as `RecoveryService`.
/// Passthrough fails with `Operation Stopped` on multi-asset compositions
/// since macOS 14, so we re-encode through the AAC path. For our AAC source
/// at the same bitrate that's effectively a no-op; for sources with mixed
/// rates / codecs (e.g. recovered orphans with HE-AAC fallback) this also
/// homogenizes the output.
public actor AudioChunker {

    // MARK: Types

    public struct Chunk: Sendable, Equatable {
        /// Path to the chunk audio file. May be the original `audioFile` URL
        /// when no chunking was needed (single-chunk fast path).
        public let url: URL
        /// Offset (seconds) of this chunk's start within the original audio.
        /// Use this to shift transcript-segment timestamps when merging.
        public let startTime: TimeInterval
        /// Duration of this chunk in seconds.
        public let duration: TimeInterval

        public init(url: URL, startTime: TimeInterval, duration: TimeInterval) {
            self.url = url
            self.startTime = startTime
            self.duration = duration
        }
    }

    public enum ChunkerError: Error, Sendable, LocalizedError {
        case assetLoadFailed(underlying: String)
        case compositionFailed
        case exportSessionCreationFailed
        case exportFailed(status: Int, underlying: String?)

        public var errorDescription: String? {
            switch self {
            case .assetLoadFailed(let s):
                return "Could not load audio asset for chunking: \(s)"
            case .compositionFailed:
                return "Could not build the AVMutableComposition for chunking."
            case .exportSessionCreationFailed:
                return "Could not create the AVAssetExportSession for chunking."
            case .exportFailed(let status, let underlying):
                return "AVAssetExportSession failed (status=\(status)): \(underlying ?? "no detail")"
            }
        }
    }

    // MARK: Init

    public init() {}

    // MARK: Public API

    /// Slice `audioFile` into temp `.m4a` chunks of at most `maxChunkDuration`
    /// seconds each. Returns chunks in chronological order with `startTime`
    /// offsets relative to the source.
    ///
    /// **Single-chunk fast path:** if the source duration is ≤ `maxChunkDuration`,
    /// returns a single `Chunk(url: audioFile, startTime: 0, duration: <total>)`
    /// pointing at the *original* file — no copy, no temp dir.
    ///
    /// **Caller is responsible** for deleting any temp files in the returned
    /// chunks (their parent directory is the standard `temporaryDirectory`
    /// child named `audio-chunks-<uuid>`). The fast-path single chunk reuses
    /// the input URL and must NOT be deleted by the caller.
    public nonisolated func chunk(
        audioFile: URL,
        maxChunkDuration: TimeInterval
    ) async throws -> [Chunk] {
        precondition(maxChunkDuration > 0, "maxChunkDuration must be positive")

        let asset = AVURLAsset(url: audioFile)
        let totalDuration: CMTime
        do {
            totalDuration = try await asset.load(.duration)
        } catch {
            // Asset metadata unreadable (corrupt headers, missing tracks,
            // synthetic test fixtures with non-audio bytes, etc.). Fall back
            // to single-chunk fast path — the caller's upload-and-let-server-
            // decide path matches pre-chunking behavior, and the server-side
            // error will be more informative than ours.
            chunkerLog.info("AudioChunker.chunk: asset.load(.duration) failed (\(error.localizedDescription, privacy: .public)) — returning single-chunk fast path")
            return [Chunk(url: audioFile, startTime: 0, duration: 0)]
        }
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        if !totalSeconds.isFinite || totalSeconds <= 0 {
            chunkerLog.info("AudioChunker.chunk: invalid duration \(totalSeconds, privacy: .public) — returning single-chunk fast path")
            return [Chunk(url: audioFile, startTime: 0, duration: 0)]
        }

        // Single-chunk fast path. Spare the temp-dir overhead.
        if totalSeconds <= maxChunkDuration {
            return [Chunk(url: audioFile, startTime: 0, duration: totalSeconds)]
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ChunkerError.assetLoadFailed(underlying: error.localizedDescription)
        }
        guard !audioTracks.isEmpty else {
            throw ChunkerError.assetLoadFailed(underlying: "No audio tracks in source file")
        }

        let chunkCount = Int(ceil(totalSeconds / maxChunkDuration))
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        chunkerLog.info("AudioChunker.chunk: source=\(audioFile.lastPathComponent, privacy: .public) totalSec=\(totalSeconds, privacy: .public) chunks=\(chunkCount, privacy: .public) tempDir=\(tempBase.path, privacy: .public)")

        var chunks: [Chunk] = []
        for i in 0..<chunkCount {
            let startSec = Double(i) * maxChunkDuration
            let endSec = min(startSec + maxChunkDuration, totalSeconds)
            let chunkDuration = endSec - startSec

            // Per-chunk composition. Re-creating each iteration avoids a
            // monotonically-growing insertTime accumulator and keeps each
            // chunk's track ranges starting at .zero.
            let composition = AVMutableComposition()
            let timeRange = CMTimeRange(
                start: CMTime(seconds: startSec, preferredTimescale: 48_000),
                duration: CMTime(seconds: chunkDuration, preferredTimescale: 48_000)
            )

            for (trackIdx, sourceTrack) in audioTracks.enumerated() {
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw ChunkerError.compositionFailed
                }
                do {
                    try compTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
                } catch {
                    chunkerLog.error("AudioChunker.chunk: track \(trackIdx, privacy: .public) insertTimeRange failed in chunk \(i, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                    // Per-track failure isn't fatal — keep going so we still
                    // export whatever this chunk has.
                }
            }

            let outputURL = tempBase.appendingPathComponent("\(i).m4a")
            guard let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw ChunkerError.exportSessionCreationFailed
            }
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a

            try await runExport(exporter, outputURL: outputURL)
            chunks.append(Chunk(url: outputURL, startTime: startSec, duration: chunkDuration))
        }

        return chunks
    }

    /// Convenience: the directory containing the temp chunks (if any), so the
    /// caller can `removeItem(at:)` after upload. Returns nil for the
    /// single-chunk fast path (no temp dir was created).
    public nonisolated func tempDirectory(for chunks: [Chunk], originalAudioFile: URL) -> URL? {
        guard let first = chunks.first else { return nil }
        if first.url == originalAudioFile { return nil }
        return first.url.deletingLastPathComponent()
    }

    // MARK: Private

    private nonisolated func runExport(_ exporter: AVAssetExportSession, outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    cont.resume()
                default:
                    cont.resume(throwing: ChunkerError.exportFailed(
                        status: exporter.status.rawValue,
                        underlying: exporter.error?.localizedDescription
                    ))
                }
            }
        }
    }
}
