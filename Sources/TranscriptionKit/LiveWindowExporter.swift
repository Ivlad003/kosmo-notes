import AVFoundation
import Foundation
import os

private let exporterLog = Logger(subsystem: "dev.kosmonotes.studio", category: "LiveWindowExporter")

// MARK: - LiveWindowExporter

/// Exports a time-bounded window from an audio file for live transcription.
///
/// Similar to `AudioChunker` but designed for a single window rather than
/// splitting a file into many chunks. Used by the live transcription engine
/// to extract short (5–10 second) segments from a growing recording.
///
/// Uses `AVMutableComposition` + `AVAssetExportSession` with
/// `AVAssetExportPresetAppleM4A` (AAC re-encode) for macOS 14+ compatibility.
public actor LiveWindowExporter {

    // MARK: Types

    public enum ExportError: Error, Sendable, LocalizedError {
        case invalidParameters
        case assetLoadFailed(underlying: String)
        case compositionFailed
        case emptyComposition
        case exportSessionCreationFailed
        case exportFailed(status: Int, underlying: String?)

        public var errorDescription: String? {
            switch self {
            case .invalidParameters:
                return "Invalid window parameters (windowStart must be ≥ 0, windowDuration must be > 0)."
            case .assetLoadFailed(let s):
                return "Could not load audio asset for window export: \(s)"
            case .compositionFailed:
                return "Could not build the AVMutableComposition for window export."
            case .emptyComposition:
                return "No audio could be inserted for the requested window."
            case .exportSessionCreationFailed:
                return "Could not create the AVAssetExportSession for window export."
            case .exportFailed(let status, let underlying):
                return "AVAssetExportSession failed (status=\(status)): \(underlying ?? "no detail")"
            }
        }
    }

    // MARK: Init

    public init() {}

    // MARK: Public API

    /// Export a time-bounded window from `audioFile` to a temporary `.m4a` file.
    ///
    /// - Parameters:
    ///   - audioFile: The source audio file to extract from.
    ///   - windowStart: Start time in seconds (must be ≥ 0).
    ///   - windowDuration: Window duration in seconds (must be > 0).
    ///
    /// - Returns: A URL to the exported window file (in `temporaryDirectory`).
    ///   **Caller is responsible** for deleting this file after transcription.
    ///
    /// If the window extends past the file's end, it is automatically clipped
    /// to the available duration.
    public nonisolated func export(
        audioFile: URL,
        windowStart: TimeInterval,
        windowDuration: TimeInterval
    ) async throws -> URL {
        guard windowStart >= 0, windowDuration > 0 else {
            throw ExportError.invalidParameters
        }

        let asset = AVURLAsset(url: audioFile)
        let totalDuration: CMTime
        do {
            totalDuration = try await asset.load(.duration)
        } catch {
            throw ExportError.assetLoadFailed(underlying: error.localizedDescription)
        }

        let totalSeconds = CMTimeGetSeconds(totalDuration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw ExportError.assetLoadFailed(underlying: "Invalid or zero-length audio duration")
        }

        // Clip window to available duration.
        let actualStart = min(windowStart, totalSeconds)
        let actualEnd = min(windowStart + windowDuration, totalSeconds)
        let actualDuration = actualEnd - actualStart

        guard actualDuration > 0 else {
            throw ExportError.invalidParameters
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ExportError.assetLoadFailed(underlying: error.localizedDescription)
        }
        guard !audioTracks.isEmpty else {
            throw ExportError.assetLoadFailed(underlying: "No audio tracks in source file")
        }

        let composition = AVMutableComposition()
        var insertedTrackCount = 0
        let timeRange = CMTimeRange(
            start: CMTime(seconds: actualStart, preferredTimescale: 48_000),
            duration: CMTime(seconds: actualDuration, preferredTimescale: 48_000)
        )

        for (trackIdx, sourceTrack) in audioTracks.enumerated() {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ExportError.compositionFailed
            }
            do {
                try compTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
                insertedTrackCount += 1
            } catch {
                exporterLog.error("LiveWindowExporter.export: track \(trackIdx, privacy: .public) insertTimeRange failed — \(error.localizedDescription, privacy: .public)")
                // Per-track failure isn't fatal — keep going so we still
                // export whatever this window has.
            }
        }

        try Self.ensureInsertedTrackCount(insertedTrackCount)

        let outputURL = URL.temporaryDirectory.appendingPathComponent("live-window-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.exportSessionCreationFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        exporterLog.info("LiveWindowExporter.export: file=\(audioFile.lastPathComponent, privacy: .public) start=\(actualStart, privacy: .public)s dur=\(actualDuration, privacy: .public)s out=\(outputURL.lastPathComponent, privacy: .public)")

        try await runExport(exporter)
        return outputURL
    }

    // MARK: Private

    internal static func ensureInsertedTrackCount(_ insertedTrackCount: Int) throws {
        guard insertedTrackCount > 0 else {
            throw ExportError.emptyComposition
        }
    }

    private nonisolated func runExport(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    cont.resume()
                default:
                    let error = ExportError.exportFailed(
                        status: exporter.status.rawValue,
                        underlying: exporter.error?.localizedDescription
                    )
                    exporterLog.error("LiveWindowExporter.runExport failed — \(error.localizedDescription, privacy: .public)")
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
