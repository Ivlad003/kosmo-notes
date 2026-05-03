import Foundation
import AIKit

// MARK: - TranscriptionResolver

/// Builds the configured batch-transcription provider together with its
/// per-minute pricing. Replaces the four-arm switch ladder that lived in
/// `RecorderState.stop()` (provider construction + transcription-pricing
/// lookup).
///
/// API-key emptiness is **not** gated here — the call site (RecorderState.start)
/// already pre-flights the right key for the chosen provider and surfaces a
/// clear "Set your … API key" message. The resolver always returns a provider
/// instance so the call site can submit the request unconditionally; auth
/// failures bubble up as `AIError.authenticationFailed` from the provider.
public enum TranscriptionResolver {

    /// Which concrete `BatchTranscriptionProvider` to build. Mirrors
    /// `AppSettings.TranscriptionProviderChoice` but lives in TranscriptionKit
    /// so the layering stays App → TranscriptionKit only.
    public enum Kind: String, Sendable, CaseIterable {
        case deepgram
        case openaiWhisper
        case gemini
        case openrouterAudio
    }

    /// Which OpenAI hosted speech-to-text model to use when `kind == .openaiWhisper`.
    /// Mirrors `AppSettings.OpenAITranscribeModel` so the resolver can pick the
    /// right `CostEstimator.TranscriptionPricing` without depending on AppSettings.
    public enum OpenAITranscribeModel: String, Sendable, CaseIterable {
        case whisper1 = "whisper-1"
        case gpt4oTranscribe = "gpt-4o-transcribe"
        case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    }

    /// Plain-data inputs. AppSettings supplies these via
    /// `AppSettings.transcriptionConfig`.
    public struct Config: Sendable {
        public let kind: Kind
        public let openaiAPIKey: String
        public let openaiModel: OpenAITranscribeModel
        public let deepgramAPIKey: String
        public let geminiAPIKey: String
        public let openrouterAPIKey: String
        public let openrouterModel: String

        public init(
            kind: Kind,
            openaiAPIKey: String,
            openaiModel: OpenAITranscribeModel,
            deepgramAPIKey: String,
            geminiAPIKey: String,
            openrouterAPIKey: String,
            openrouterModel: String
        ) {
            self.kind = kind
            self.openaiAPIKey = openaiAPIKey
            self.openaiModel = openaiModel
            self.deepgramAPIKey = deepgramAPIKey
            self.geminiAPIKey = geminiAPIKey
            self.openrouterAPIKey = openrouterAPIKey
            self.openrouterModel = openrouterModel
        }
    }

    /// Resolved provider + (optional) per-minute pricing. Gemini and OpenRouter
    /// audio return `nil` pricing because they bill via per-token rates that
    /// don't map to "USD per minute of audio"; the call site skips the
    /// transcription cost-cap gate when pricing is `nil`.
    public struct Resolved: Sendable {
        public let provider: any BatchTranscriptionProvider
        public let pricing: CostEstimator.TranscriptionPricing?

        public init(provider: any BatchTranscriptionProvider, pricing: CostEstimator.TranscriptionPricing?) {
            self.provider = provider
            self.pricing = pricing
        }
    }

    public static func resolve(_ config: Config) -> Resolved {
        switch config.kind {
        case .deepgram:
            let key = config.deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return Resolved(
                provider: DeepgramBatchProvider(apiKey: key),
                pricing: CostEstimator.deepgram_nova_2_batch
            )

        case .openaiWhisper:
            let key = config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let pricing: CostEstimator.TranscriptionPricing
            switch config.openaiModel {
            case .whisper1:            pricing = CostEstimator.openai_whisper_1
            case .gpt4oTranscribe:     pricing = CostEstimator.openai_gpt_4o_transcribe
            case .gpt4oMiniTranscribe: pricing = CostEstimator.openai_gpt_4o_mini_transcribe
            }
            return Resolved(
                provider: WhisperProvider(apiKey: key, model: config.openaiModel.rawValue),
                pricing: pricing
            )

        case .gemini:
            let key = config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return Resolved(
                provider: GeminiAudioProvider(apiKey: key),
                pricing: nil
            )

        case .openrouterAudio:
            let key = config.openrouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = config.openrouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = trimmedModel.isEmpty ? "google/gemini-2.5-flash" : trimmedModel
            return Resolved(
                provider: OpenRouterAudioProvider(apiKey: key, model: model),
                pricing: nil
            )
        }
    }
}
