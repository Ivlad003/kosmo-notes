import Foundation

// MARK: - BatchTranscriptionProvider

/// File-based (non-streaming) transcription provider.
///
/// Whisper-style providers send the **entire** audio file at once, then return
/// the full transcript. This is fundamentally different from the streaming
/// `TranscriptionProvider` — there's no live partial output, just a single
/// blocking `transcribe(audioFile:config:)` call.
///
/// `RecorderState` picks between this and `TranscriptionProvider` based on
/// the user's chosen provider in Settings:
///   - Deepgram → streaming, live updates during recording
///   - OpenAI Whisper → batch, full transcript ~seconds after Stop
public protocol BatchTranscriptionProvider: Sendable {
    /// Transcribe one audio file. The file format must be one the provider
    /// supports (Whisper accepts m4a, mp3, mp4, mpeg, mpga, wav, webm).
    func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult
}

// MARK: - BatchTranscriptResult

public struct BatchTranscriptResult: Sendable, Equatable {
    /// Detected language (BCP-47 / ISO-639) — `nil` if the provider didn't return one.
    public let language: String?
    /// Total audio duration in seconds. `0` if not reported.
    public let duration: TimeInterval
    /// Segmented transcript. For providers that don't segment (text-only
    /// response), this is a single segment spanning [0, duration].
    public let segments: [TranscriptSegment]
    /// Full plain-text transcript. Convenience for clients that don't care
    /// about segment-level timing.
    public let text: String

    public init(
        language: String?,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        text: String
    ) {
        self.language = language
        self.duration = duration
        self.segments = segments
        self.text = text
    }
}
