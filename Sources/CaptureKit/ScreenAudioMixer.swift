@preconcurrency import AVFoundation
import Foundation
import os

private let mixerLog = Logger(subsystem: "dev.kosmonotes.studio", category: "ScreenAudioMixer")

// MARK: - ScreenAudioMixer

/// Post-process step that pulls the microphone track out of `audio.m4a` and
/// folds it into `screen.mp4` so playback gives you both your own voice AND
/// system audio (Meet/Zoom participants, browser sound, etc).
///
/// The capture pipeline can't easily mix mic + system in real time without
/// a sample-aligned ring buffer. Instead we let SegmentWriter keep the mic
/// in its 2-track `audio.m4a` (track 0 = mic, track 1 = system), and let
/// ScreenRecorder write `screen.mp4` with video + SCKit system-audio. After
/// both files are finalized, this mixer rebuilds `screen.mp4` as
/// video + (system_audio + mic) mixed into one AAC track via AVAssetExportSession.
///
/// Failure is non-fatal — caller should swallow errors and leave the
/// system-audio-only `screen.mp4` in place.
public enum ScreenAudioMixer {

    public enum MixError: Error, Sendable {
        case noVideoTrack
        case exportSessionInitFailed
        case exportFailed(underlying: Error?)
        case replaceFailed(underlying: Error)
    }

    /// Mix the mic track from `audioM4A` into `screenMP4` in place. Atomic:
    /// writes to a sibling `.mixed.mp4` and replaces only on success.
    ///
    /// - Parameters:
    ///   - screenMP4: original `screen.mp4` (video + optional system audio).
    ///   - audioM4A: finalized `audio.m4a` (track 0 = mic).
    ///   - micVolume: relative volume for the mic track (default 1.0).
    ///   - systemVolume: relative volume for the system-audio track (default 0.7
    ///     so participants don't clip when summed with mic).
    public static func mixMicInto(
        screenMP4: URL,
        audioM4A: URL,
        micVolume: Float = 1.0,
        systemVolume: Float = 0.7
    ) async throws {
        mixerLog.info("ScreenAudioMixer.mixMicInto: screen=\(screenMP4.lastPathComponent, privacy: .public) audio=\(audioM4A.lastPathComponent, privacy: .public)")

        let composition = AVMutableComposition()
        let screenAsset = AVURLAsset(url: screenMP4)
        let audioAsset = AVURLAsset(url: audioM4A)

        let videoDuration = try await screenAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        // Trim mic to the screen window — they should be near-identical, but a
        // half-second mismatch from finalize ordering shouldn't leak silence.
        let micWindow = CMTimeMinimum(videoDuration, audioDuration)

        // Video track from screen.mp4
        let videoTracks = try await screenAsset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            mixerLog.error("ScreenAudioMixer.mixMicInto: screen.mp4 has no video track")
            throw MixError.noVideoTrack
        }
        let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try composedVideo?.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        // Preserve original orientation/scaling.
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        composedVideo?.preferredTransform = preferredTransform

        // System audio track from screen.mp4 (optional — recordingMode may
        // have been audio-only inside the screen file).
        let screenAudioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        var composedSystem: AVMutableCompositionTrack? = nil
        if let sourceSystem = screenAudioTracks.first {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceSystem, at: .zero)
            composedSystem = track
        }

        // Mic track from audio.m4a track 0. SegmentWriter writes mic to track 0
        // and (when system audio is enabled) system to track 1. We deliberately
        // pick the FIRST audio track — that's the mic per our pipeline contract.
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        var composedMic: AVMutableCompositionTrack? = nil
        if let sourceMic = audioTracks.first {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(CMTimeRange(start: .zero, duration: micWindow), of: sourceMic, at: .zero)
            composedMic = track
        } else {
            mixerLog.error("ScreenAudioMixer.mixMicInto: audio.m4a has no audio tracks — skipping mic mix")
        }

        // Audio mix gains. Sum-to-one-ish to avoid clipping when both speak.
        let audioMix = AVMutableAudioMix()
        var inputs: [AVMutableAudioMixInputParameters] = []
        if let track = composedSystem {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(systemVolume, at: .zero)
            inputs.append(p)
        }
        if let track = composedMic {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(micVolume, at: .zero)
            inputs.append(p)
        }
        audioMix.inputParameters = inputs

        // Export to a sibling temp file, then atomic-replace the original.
        let tmpURL = screenMP4.deletingPathExtension().appendingPathExtension("mixed.mp4")
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
                ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            mixerLog.error("ScreenAudioMixer: AVAssetExportSession init failed")
            throw MixError.exportSessionInitFailed
        }
        exporter.outputURL = tmpURL
        exporter.outputFileType = .mp4
        exporter.audioMix = audioMix
        // Passthrough preset can't re-mix; force HighestQuality if a mic mix is requested.
        if composedMic != nil, exporter.presetName == AVAssetExportPresetPassthrough {
            guard let q = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw MixError.exportSessionInitFailed
            }
            q.outputURL = tmpURL
            q.outputFileType = .mp4
            q.audioMix = audioMix
            try await runExport(q)
        } else {
            try await runExport(exporter)
        }

        // Atomic replace screen.mp4 with the mixed file.
        do {
            _ = try FileManager.default.replaceItemAt(screenMP4, withItemAt: tmpURL)
            mixerLog.info("ScreenAudioMixer.mixMicInto: success — screen.mp4 now has mixed mic+system audio")
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            mixerLog.error("ScreenAudioMixer.mixMicInto: replace failed — \(error.localizedDescription, privacy: .public)")
            throw MixError.replaceFailed(underlying: error)
        }
    }

    /// Bridge AVAssetExportSession's old completion-handler API to async/await.
    /// `AVAssetExportSession.export()` only got an async overload in macOS 15.
    private static func runExport(_ exporter: AVAssetExportSession) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume(returning: ()) }
        }
        if exporter.status != .completed {
            mixerLog.error("ScreenAudioMixer: exporter status=\(exporter.status.rawValue, privacy: .public) error=\(exporter.error?.localizedDescription ?? "nil", privacy: .public)")
            throw MixError.exportFailed(underlying: exporter.error)
        }
    }
}
