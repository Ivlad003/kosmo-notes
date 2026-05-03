import Foundation

// MARK: - AIProviderResolver

/// Builds the configured `AIProvider` (Anthropic / OpenAI / OpenRouter / Ollama)
/// together with its default model and `CostEstimator.Pricing` from a flat
/// settings struct.
///
/// Replaces the four-arm `switch settings.llmProvider { … }` ladder that was
/// duplicated across `RecorderState.tryGenerateSummary`, `RecorderState.tryCleanupTranscript`,
/// `ChatState.makeProvider`, `DictationState.makeLLMProvider`, `PushToMarkdownState.makeLLMProvider`,
/// and `MarkdownExporter.makeProvider`.
///
/// Returns `nil` when the API key is missing or when the Ollama endpoint fails
/// validation. Each call site converts `nil` to its own error surface (silent
/// skip, modal, or thrown `AIError`) as appropriate.
public enum AIProviderResolver {

    /// Which concrete `AIProvider` to build. Mirrors `AppSettings.LLMProviderChoice`
    /// but lives in AIKit so the layering stays one-way (App → AIKit, never reverse).
    public enum Kind: String, Sendable, CaseIterable {
        case anthropic
        case openai
        case openrouter
        case ollama
    }

    /// Plain-data inputs the resolver needs. AppSettings supplies these via
    /// `AppSettings.aiProviderConfig` — the resolver itself has no dependency
    /// on AppSettings so unit tests can construct configs directly.
    public struct Config: Sendable {
        public let kind: Kind
        public let anthropicAPIKey: String
        public let openaiAPIKey: String
        public let openrouterAPIKey: String
        public let openrouterModel: String
        public let ollamaEndpoint: String
        public let ollamaModel: String
        public let ollamaAPIMode: OllamaProvider.APIMode
        public let ollamaBearer: String?

        public init(
            kind: Kind,
            anthropicAPIKey: String,
            openaiAPIKey: String,
            openrouterAPIKey: String,
            openrouterModel: String,
            ollamaEndpoint: String,
            ollamaModel: String,
            ollamaAPIMode: OllamaProvider.APIMode,
            ollamaBearer: String?
        ) {
            self.kind = kind
            self.anthropicAPIKey = anthropicAPIKey
            self.openaiAPIKey = openaiAPIKey
            self.openrouterAPIKey = openrouterAPIKey
            self.openrouterModel = openrouterModel
            self.ollamaEndpoint = ollamaEndpoint
            self.ollamaModel = ollamaModel
            self.ollamaAPIMode = ollamaAPIMode
            self.ollamaBearer = ollamaBearer
        }
    }

    /// Resolved triple: the live provider, its default model id, and the
    /// pricing tuple used for cost-cap estimation. Ollama is local-only so its
    /// pricing is `(0, 0)`.
    public struct Resolved: Sendable {
        public let provider: any AIProvider
        public let model: String
        public let pricing: CostEstimator.Pricing

        public init(provider: any AIProvider, model: String, pricing: CostEstimator.Pricing) {
            self.provider = provider
            self.model = model
            self.pricing = pricing
        }
    }

    /// Build the configured provider, default model, and pricing. Returns
    /// `nil` when the API key is empty (Anthropic / OpenAI / OpenRouter) or
    /// the Ollama endpoint fails `OllamaProvider.validate`.
    public static func resolve(_ config: Config) -> Resolved? {
        switch config.kind {
        case .anthropic:
            let key = config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return Resolved(
                provider: AnthropicProvider(apiKey: key),
                model: AnthropicProvider.defaultModel,
                pricing: CostEstimator.anthropic_claude_sonnet_4_6
            )

        case .openai:
            let key = config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return Resolved(
                provider: OpenAIProvider(apiKey: key),
                model: OpenAIProvider.defaultModel,
                pricing: CostEstimator.openai_gpt_4o_mini
            )

        case .openrouter:
            let key = config.openrouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let trimmedModel = config.openrouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty model would 400 at the OpenRouter API. Match the explicit
            // fallback DictationState / PushToMarkdownState / MarkdownExporter
            // already used; RecorderState and ChatState gain it for free.
            let model = trimmedModel.isEmpty ? "openai/gpt-4o-mini" : trimmedModel
            return Resolved(
                provider: OpenRouterProvider(apiKey: key),
                model: model,
                pricing: CostEstimator.openrouter_default
            )

        case .ollama:
            let endpoint = URL(string: config.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
            let bearer = (config.ollamaBearer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let provider: OllamaProvider
            do {
                provider = try OllamaProvider(
                    endpoint: endpoint,
                    apiMode: config.ollamaAPIMode,
                    bearerToken: bearer.isEmpty ? nil : bearer
                )
            } catch {
                return nil
            }
            let trimmedModel = config.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty model is rejected by Ollama. Same fallback the dictation
            // path already used so RecorderState / ChatState don't ship an
            // empty model id when the user hasn't picked one.
            let model = trimmedModel.isEmpty ? "qwen2.5:14b" : trimmedModel
            return Resolved(
                provider: provider,
                model: model,
                pricing: CostEstimator.Pricing(inputPerMillion: 0, outputPerMillion: 0)
            )
        }
    }
}
