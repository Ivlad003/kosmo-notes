import Foundation
import AIKit

// MARK: - RecorderState — LLM transcript cleanup
//
// Pulled out of RecorderState.swift so the main file stays focused on
// capture lifecycle (start / stop / teardown). The method is invoked
// from `stop()` after batch transcription returns; on failure the caller
// falls back to the raw ASR transcript.
//
// Access modifier dropped from `private` to module-internal so the call
// site in `RecorderState.stop()` (different file) can see it. Still
// invisible to anything outside the App target since RecorderState
// itself is internal-default.

@available(macOS 14.0, *)
extension RecorderState {

    /// Optional post-ASR pass that fixes recognition mistakes (numbers, names,
    /// double-words, missing punctuation) without touching segment boundaries.
    /// Returns `nil` on any failure — caller falls back to the raw transcript.
    /// Cost-capped via the same mechanism as summary generation, but silently
    /// skips on overage rather than prompting (the summary path already shows
    /// the "increase cap?" modal once per recording).
    func tryCleanupTranscript(
        rawText: String,
        sourceLanguage: String?
    ) async -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Same target-language resolution rule as the summary pass.
        let target: String? = settings.summaryLanguage == "auto" ? nil : settings.summaryLanguage
        let system = PromptTemplates.transcriptCleanup(sourceLanguage: sourceLanguage, targetLanguage: target)
        let userMsg = PromptTemplates.transcriptCleanupUserMessage(rawTranscript: trimmed)

        // Build the LLM provider per current settings. Mirror of tryGenerateSummary.
        guard let resolved = AIProviderResolver.resolve(settings.aiProviderConfig) else {
            return nil
        }
        let provider = resolved.provider
        let model = resolved.model
        let pricing = resolved.pricing

        // Cost estimate. Cleanup output is roughly the same length as input,
        // so cap maxTokens at ~1.2× input-token estimate to leave headroom.
        let inputTokens = CostEstimator.estimateTokens(text: system) + CostEstimator.estimateTokens(text: userMsg)
        let outputTokensCap = max(512, Int(Double(inputTokens) * 1.2))
        let estimatedCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputTokensCap,
            pricing: pricing
        )
        if estimatedCost > settings.costCapUSD {
            // Don't pop a modal for cleanup — silently skip if the cap is too
            // low. Summary already has a "increase cap?" interaction.
            return nil
        }

        let messages: [ChatMessage] = [ChatMessage(role: .user, content: userMsg)]
        let config = AIConfig(model: model, temperature: 0.0, maxTokens: outputTokensCap, systemPrompt: system)

        do {
            let cleaned = try await provider.chat(messages: messages, config: config)
            let trimmedClean = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedClean.isEmpty ? nil : trimmedClean
        } catch {
            return nil
        }
    }
}
