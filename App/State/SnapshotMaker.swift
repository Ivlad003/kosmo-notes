import AVFoundation
import Foundation
import StorageKit
import TranscriptionKit

// MARK: - SnapshotMaker

/// Captures a "live snapshot" of the last N audio segments from an in-progress
/// recording, runs Whisper on the concatenation, and returns the transcript text.
///
/// Does NOT touch RecorderState — reads only the segments directory on disk.
/// Mirrors RecoveryService.finalize for the AVMutableComposition + export path.
@available(macOS 14.0, *)
struct SnapshotMaker {

    let sessionStore: SessionStore
    let whisperProviderFactory: @Sendable (String) -> WhisperProvider

    // MARK: - Errors

    enum SnapshotError: Error, LocalizedError {
        case notEnoughSegments
        case compositionFailed
        case exportSessionCreationFailed
        case exportFailed(String?)

        var errorDescription: String? {
            switch self {
            case .notEnoughSegments:
                return "Recording has not produced any audio segments yet — wait a few seconds and try again."
            case .compositionFailed:
                return "Could not build audio composition from segments."
            case .exportSessionCreationFailed:
                return "Could not create audio export session."
            case .exportFailed(let msg):
                return "Audio export failed: \(msg ?? "unknown error")"
            }
        }
    }

    // MARK: - Public API

    /// Concat the last `lastSegments` .m4a files from the session's segments/
    /// directory into a temp file, transcribe via Whisper, return the text.
    /// Cleans up the temp file before returning (best-effort).
    func snapshot(
        sessionId: String,
        apiKey: String,
        language: String?,
        lastSegments: Int = 12  // 12 × 5-sec segments ≈ 60 s
    ) async throws -> String {
        let dir = await sessionStore.sessionDir(for: sessionId)
        let segmentsDir = dir.appendingPathComponent("segments")

        // Enumerate and sort .m4a files numerically (same pattern as RecoveryService.scanForOrphans).
        let allFiles = (try? FileManager.default.contentsOfDirectory(
            at: segmentsDir,
            includingPropertiesForKeys: nil
        )) ?? []

        let sorted = allFiles
            .filter { $0.pathExtension == "m4a" }
            .sorted { lhs, rhs in
                let li = Int(lhs.deletingPathExtension().lastPathComponent) ?? Int.max
                let ri = Int(rhs.deletingPathExtension().lastPathComponent) ?? Int.max
                return li < ri
            }

        guard !sorted.isEmpty else { throw SnapshotError.notEnoughSegments }

        // Take the last N — most-recent audio first, keeping natural order.
        let segmentsToUse = sorted.suffix(lastSegments)

        // Build AVMutableComposition from segments (mirrors RecoveryService.finalize).
        let composition = AVMutableComposition()
        var insertTime: CMTime = .zero

        for segURL in segmentsToUse {
            let asset = AVURLAsset(url: segURL)
            guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                  !audioTracks.isEmpty else { continue }
            guard let duration = try? await asset.load(.duration),
                  duration.isValid, duration > .zero else { continue }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            for (idx, sourceTrack) in audioTracks.enumerated() {
                let compositionTrack = trackForIndex(idx, in: composition)
                guard let compositionTrack else { throw SnapshotError.compositionFailed }
                try? compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, duration)
        }

        guard insertTime > .zero else { throw SnapshotError.notEnoughSegments }

        // Export to a unique temp path so concurrent snapshots don't collide.
        let tempURL = URL.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).m4a")

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SnapshotError.exportSessionCreationFailed
        }
        exporter.outputURL = tempURL
        exporter.outputFileType = .m4a

        try await runExport(exporter, outputURL: tempURL)

        // Transcribe — and always clean up the temp file afterward.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let provider = whisperProviderFactory(apiKey)
        let result = try await provider.transcribe(
            audioFile: tempURL,
            config: TranscriptionConfig(language: language)
        )
        return result.text
    }

    // MARK: - Private helpers

    /// Wraps the legacy exportAsynchronously callback in a Swift continuation
    /// (same pattern as RecoveryService.runExport).
    private func runExport(_ exporter: AVAssetExportSession, outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    cont.resume()
                default:
                    cont.resume(throwing: SnapshotError.exportFailed(
                        exporter.error?.localizedDescription
                    ))
                }
            }
        }
    }

    /// Returns the composition audio track at `idx`, creating tracks as needed.
    private func trackForIndex(_ idx: Int, in composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        let existing = composition.tracks(withMediaType: .audio)
        if idx < existing.count { return existing[idx] }
        var last: AVMutableCompositionTrack?
        for _ in existing.count...idx {
            last = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        return last
    }
}
