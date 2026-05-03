import Foundation

// MARK: - TranscriptSegment

/// One unit of transcribed audio.
///
/// Stored on disk as one JSONL line in `transcript.jsonl`. Only `isFinal == true`
/// segments are persisted; interim segments are streamed to UI but discarded
/// when the final lands.
public struct TranscriptSegment: Sendable, Codable, Equatable {

    /// Seconds from the session start.
    public let start: TimeInterval
    /// Seconds from the session start (exclusive end).
    public let end: TimeInterval
    /// Decoded text — may include punctuation if the provider was configured
    /// for smart formatting.
    public let text: String
    /// Provider's confidence score, 0.0–1.0. Pre-final segments may carry
    /// lower confidence; we still surface them for the live UI.
    public let confidence: Double
    /// `true` if the provider has committed to this transcript and won't
    /// revise it. `false` for interim segments. Only final segments are
    /// persisted by `TranscriptStore`.
    public let isFinal: Bool
    /// Speaker label assigned by the provider (when diarization is enabled).
    /// Nil for v1.0 — diarization lands in v1.1.
    public let speaker: Int?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double,
        isFinal: Bool,
        speaker: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.speaker = speaker
    }
}

// MARK: - TranscriptionConfig

/// Per-session transcription configuration.
public struct TranscriptionConfig: Sendable, Equatable {

    /// BCP-47 language code (e.g. `"en"`, `"uk"`, `"ru"`). Nil = auto-detect.
    public let language: String?
    /// Provider-specific model name. For Deepgram, e.g. `"nova-2"`.
    public let model: String
    /// PCM input sample rate. Deepgram supports 8 k–48 k linear16 in.
    /// Default: 16 kHz (Deepgram-recommended for Nova models).
    public let sampleRate: Int
    /// PCM input channel count. Almost always 1 (mono mic + system mixdown
    /// → single transcription stream).
    public let channels: Int
    /// Enable smart-formatting / punctuation in the output transcript.
    public let punctuate: Bool
    /// Emit interim (non-final) segments. Useful for live UI; can be disabled
    /// to reduce traffic.
    public let interimResults: Bool

    public init(
        language: String? = nil,
        model: String = "nova-2",
        sampleRate: Int = 16_000,
        channels: Int = 1,
        punctuate: Bool = true,
        interimResults: Bool = true
    ) {
        self.language = language
        self.model = model
        self.sampleRate = sampleRate
        self.channels = channels
        self.punctuate = punctuate
        self.interimResults = interimResults
    }
}

// MARK: - Errors

public enum TranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint
    case authenticationFailed
    case sendFailed(message: String)
    case receiveFailed(message: String)
    case decodingFailed(message: String)
    case alreadyClosed

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Transcription endpoint URL is invalid."
        case .authenticationFailed:
            return "Authentication failed (HTTP 401). Check your API key in Settings → AI Providers, or, if using a newer model like gpt-4o-transcribe, verify your OpenAI organization has access to it (https://platform.openai.com/settings/organization/general)."
        case .sendFailed(let message):
            return "Could not send audio to the transcription service: \(message)"
        case .receiveFailed(let message):
            return "Transcription service returned an error: \(message)"
        case .decodingFailed(let message):
            return "Could not decode the transcription response: \(message)"
        case .alreadyClosed:
            return "Transcription session is already closed."
        }
    }
}
