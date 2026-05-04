using KosmoNotes.Core.Pricing;

namespace KosmoNotes.Core.Tests;

public class CostEstimatorTests
{
    [Fact]
    public void EstimateTokens_EmptyString_IsZero()
    {
        Assert.Equal(0, CostEstimator.EstimateTokens(string.Empty));
    }

    [Fact]
    public void EstimateTokens_LatinUsesFourCharsPerToken()
    {
        // 16 chars / 4 = 4 tokens (ceiling).
        Assert.Equal(4, CostEstimator.EstimateTokens("the quick brown."));
    }

    [Fact]
    public void EstimateTokens_LatinShortString_AtLeastOne()
    {
        // 1 char / 4 = 0.25 → ceiling 1.
        Assert.Equal(1, CostEstimator.EstimateTokens("a"));
    }

    [Fact]
    public void EstimateTokens_UkrainianUsesThreeCharsPerToken()
    {
        // "Привіт" — 6 Cyrillic codepoints, 100% non-Latin → ratio 3.
        // 6 / 3 = 2 tokens.
        Assert.Equal(2, CostEstimator.EstimateTokens("Привіт"));
    }

    [Fact]
    public void EstimateTokens_MixedAtThreshold_PicksRatioBasedOnFraction()
    {
        // 7 latin + 3 cyrillic = 10 codepoints. 3/10 = 0.3 → NOT > 0.3 → 4-char ratio.
        // ceil(10/4) = 3 tokens.
        string mixed = "abcdefg" + "Бог";
        Assert.Equal(3, CostEstimator.EstimateTokens(mixed));

        // 6 latin + 4 cyrillic = 10 codepoints. 4/10 = 0.4 > 0.3 → 3-char ratio.
        // ceil(10/3) = 4 tokens.
        string mixed2 = "abcdef" + "Богі";
        Assert.Equal(4, CostEstimator.EstimateTokens(mixed2));
    }

    [Fact]
    public void Estimate_KnownTokenCounts_MatchesExpected()
    {
        // Anthropic Sonnet: $3 in / $15 out per 1M.
        // 1000 in + 500 out = 0.001 * 3 + 0.0005 * 15 = 0.003 + 0.0075 = 0.0105
        double cost = CostEstimator.Estimate(1000, 500, CostEstimator.AnthropicClaudeSonnet46);
        Assert.Equal(0.0105, cost, precision: 6);
    }

    [Fact]
    public void Estimate_OpenAIMiniIsCheap()
    {
        // 0.15 / 0.60 per 1M.
        // 10_000 in + 1_000 out = 0.01 * 0.15 + 0.001 * 0.60 = 0.0015 + 0.0006 = 0.0021
        double cost = CostEstimator.Estimate(10_000, 1_000, CostEstimator.OpenAIGpt4oMini);
        Assert.Equal(0.0021, cost, precision: 6);
    }

    [Fact]
    public void Estimate_ZeroTokens_IsZero()
    {
        Assert.Equal(0.0, CostEstimator.Estimate(0, 0, CostEstimator.OpenRouterDefault));
    }

    [Fact]
    public void EstimateTranscription_KnownDuration_MatchesExpected()
    {
        // Whisper-1: $0.006 / minute. 600 sec = 10 minutes → $0.06
        double cost = CostEstimator.EstimateTranscription(600, CostEstimator.OpenAIWhisper1);
        Assert.Equal(0.06, cost, precision: 6);

        // Deepgram Nova-2: $0.0043 / minute. 60 sec = 1 minute → $0.0043
        cost = CostEstimator.EstimateTranscription(60, CostEstimator.DeepgramNova2Batch);
        Assert.Equal(0.0043, cost, precision: 6);
    }

    [Fact]
    public void EstimateTranscription_NonPositiveDuration_IsZero()
    {
        Assert.Equal(0.0, CostEstimator.EstimateTranscription(0, CostEstimator.OpenAIWhisper1));
        Assert.Equal(0.0, CostEstimator.EstimateTranscription(-30, CostEstimator.OpenAIWhisper1));
    }

    [Fact]
    public void PricingTable_HasExpectedValues()
    {
        Assert.Equal(3.0, CostEstimator.AnthropicClaudeSonnet46.InputPerMillion);
        Assert.Equal(15.0, CostEstimator.AnthropicClaudeSonnet46.OutputPerMillion);

        Assert.Equal(0.15, CostEstimator.OpenAIGpt4oMini.InputPerMillion);
        Assert.Equal(0.60, CostEstimator.OpenAIGpt4oMini.OutputPerMillion);

        Assert.Equal(3.5, CostEstimator.OpenRouterDefault.InputPerMillion);
        Assert.Equal(17.0, CostEstimator.OpenRouterDefault.OutputPerMillion);

        Assert.Equal(0.006, CostEstimator.OpenAIWhisper1.PerMinute);
        Assert.Equal(0.006, CostEstimator.OpenAIGpt4oTranscribe.PerMinute);
        Assert.Equal(0.003, CostEstimator.OpenAIGpt4oMiniTranscribe.PerMinute);
        Assert.Equal(0.0043, CostEstimator.DeepgramNova2Batch.PerMinute);
    }
}
