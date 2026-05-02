import Foundation
import Testing
@testable import AIKit

// MARK: - CostEstimator tests

@Suite("CostEstimator.estimateTokens")
struct CostEstimatorTokenTests {

    @Test("Empty string returns 0")
    func emptyString() {
        #expect(CostEstimator.estimateTokens(text: "") == 0)
    }

    @Test("ASCII text: token count ≈ charCount/4 within ±20%")
    func asciiApproximation() {
        // 400 ASCII chars → expect ~100 tokens (80–120 is ±20%)
        let text = String(repeating: "abcd", count: 100) // 400 chars
        let tokens = CostEstimator.estimateTokens(text: text)
        #expect(tokens >= 80 && tokens <= 120)
    }

    @Test("Cyrillic text: token count ≈ charCount/3 within ±20%")
    func cyrillicApproximation() {
        // 300 Cyrillic chars → expect ~100 tokens (80–120 is ±20%)
        let text = String(repeating: "абвг", count: 75) // 300 chars
        let tokens = CostEstimator.estimateTokens(text: text)
        #expect(tokens >= 80 && tokens <= 120)
    }

    @Test("Single character returns at least 1")
    func singleChar() {
        #expect(CostEstimator.estimateTokens(text: "x") >= 1)
    }
}

@Suite("CostEstimator.estimate")
struct CostEstimatorCostTests {

    @Test("Zero tokens yields zero cost")
    func zeroCost() {
        let cost = CostEstimator.estimate(
            inputTokens: 0,
            outputTokens: 0,
            pricing: CostEstimator.anthropic_claude_sonnet_4_6
        )
        #expect(cost == 0.0)
    }

    @Test("Anthropic sonnet 4.6: 1000 input + 1000 output = $0.018")
    func anthropicSonnetCost() {
        // input: 1000/1M * $3.00 = $0.003
        // output: 1000/1M * $15.00 = $0.015
        // total: $0.018
        let cost = CostEstimator.estimate(
            inputTokens: 1000,
            outputTokens: 1000,
            pricing: CostEstimator.anthropic_claude_sonnet_4_6
        )
        #expect(abs(cost - 0.018) < 0.0001)
    }

    @Test("OpenAI gpt-4o-mini: 1000 input + 1000 output = $0.00075")
    func openAIMiniCost() {
        // input: 1000/1M * $0.15 = $0.00015
        // output: 1000/1M * $0.60 = $0.00060
        // total: $0.00075
        let cost = CostEstimator.estimate(
            inputTokens: 1000,
            outputTokens: 1000,
            pricing: CostEstimator.openai_gpt_4o_mini
        )
        #expect(abs(cost - 0.00075) < 0.000001)
    }

    @Test("Only input tokens, zero output")
    func inputOnlyTokens() {
        let cost = CostEstimator.estimate(
            inputTokens: 1_000_000,
            outputTokens: 0,
            pricing: CostEstimator.anthropic_claude_sonnet_4_6
        )
        #expect(abs(cost - 3.0) < 0.0001)
    }

    @Test("Only output tokens, zero input")
    func outputOnlyTokens() {
        let cost = CostEstimator.estimate(
            inputTokens: 0,
            outputTokens: 1_000_000,
            pricing: CostEstimator.anthropic_claude_sonnet_4_6
        )
        #expect(abs(cost - 15.0) < 0.0001)
    }
}
