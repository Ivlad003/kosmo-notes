import Foundation

// MARK: - CostEstimator

/// Rough cost projection for a single chat call, used to gate expensive requests
/// against the user's per-session cost cap before sending anything to the API.
public enum CostEstimator {

    // MARK: - Pricing table

    /// USD pricing per 1 000 000 tokens. Values cached locally; update when providers
    /// change list prices rather than fetching at runtime (avoids network dependency).
    public struct Pricing: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double

        public init(inputPerMillion: Double, outputPerMillion: Double) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    /// Anthropic claude-sonnet-4-6 pricing as of 2026-04.
    public static let anthropic_claude_sonnet_4_6 = Pricing(inputPerMillion: 3.0, outputPerMillion: 15.0)

    /// OpenAI gpt-4o-mini pricing as of 2026-04.
    public static let openai_gpt_4o_mini = Pricing(inputPerMillion: 0.15, outputPerMillion: 0.60)

    // MARK: - Token estimation

    /// Rough token count heuristic: ~4 chars/token for Latin scripts, ~3 for non-Latin
    /// (CJK, Cyrillic, Arabic, etc.). Errs on the conservative (larger) side so the
    /// cost estimate is slightly above actual, making the cap a safe upper bound.
    public static func estimateTokens(text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let nonLatin = text.unicodeScalars.filter { scalar in
            // Covers Cyrillic (0400-04FF), CJK (4E00-9FFF), Arabic (0600-06FF), Hebrew (0590-05FF), etc.
            scalar.value >= 0x0400
        }.count
        // If more than 30 % of the string is non-Latin, use the 3-char ratio.
        let ratio: Double = Double(nonLatin) / Double(text.unicodeScalars.count) > 0.3 ? 3.0 : 4.0
        return max(1, Int(ceil(Double(text.unicodeScalars.count) / ratio)))
    }

    // MARK: - Cost calculation

    /// USD cost for one call given exact input/output token counts.
    public static func estimate(inputTokens: Int, outputTokens: Int, pricing: Pricing) -> Double {
        let inputCost = Double(inputTokens) / 1_000_000.0 * pricing.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000.0 * pricing.outputPerMillion
        return inputCost + outputCost
    }
}
