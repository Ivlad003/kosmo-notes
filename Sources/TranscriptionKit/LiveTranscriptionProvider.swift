import Foundation

// MARK: - LiveTranscriptionProvider

/// Batch transcription provider adapted for short-window live transcription.
///
/// Unlike streaming providers (Deepgram, OpenRouter audio) that accept
/// continuous PCM and emit partial results as they decode, live-adapted batch
/// providers transcribe one short window at a time, using the same
/// `transcribe(audioFile:config:)` API as full-file batch transcription.
///
/// The live engine will:
/// 1. Export a short window (e.g., 5–10 seconds) from the growing recording.
/// 2. Call `transcribeLiveWindow(audioFile:config:)` with that window.
/// 3. Merge the returned text into the live transcript state.
///
/// This pattern allows WhisperKit and OpenAI Whisper to participate in live
/// transcription without requiring streaming infrastructure.
public protocol LiveTranscriptionProvider: Sendable {
    /// Transcribe a short audio window for live display.
    ///
    /// The provider should transcribe the **entire** audio file and return
    /// the full text as a single `LiveTranscriptWindowResult`. The window's
    /// start/end timestamps are relative to the original recording session,
    /// not the file's internal timeline (which always starts at 0).
    ///
    /// - Parameters:
    ///   - audioFile: A short (5–10 second) window exported from the live recording.
    ///   - windowStart: Session timestamp (seconds) where this window begins.
    ///   - windowEnd: Session timestamp (seconds) where this window ends.
    ///   - config: Transcription configuration (language, model, etc.).
    ///
    /// - Returns: A `LiveTranscriptWindowResult` with the transcribed text and
    ///   session-relative timestamps.
    func transcribeLiveWindow(
        audioFile: URL,
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        config: TranscriptionConfig
    ) async throws -> LiveTranscriptWindowResult
}
