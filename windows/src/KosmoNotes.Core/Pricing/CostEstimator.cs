namespace KosmoNotes.Core.Pricing;

/// <summary>
/// Rough cost projection for a single chat call. Mirrors the Swift
/// <c>CostEstimator</c> enum in <c>Sources/AIKit/CostEstimator.swift</c>.
/// Used to gate expensive requests against the user's per-session cost cap
/// before sending anything to the API.
/// </summary>
public static class CostEstimator
{
    /// <summary>
    /// USD pricing per 1 000 000 tokens. Mirrors Swift <c>Pricing</c> struct.
    /// </summary>
    /// <param name="InputPerMillion">Input price per 1M tokens, USD.</param>
    /// <param name="OutputPerMillion">Output price per 1M tokens, USD.</param>
    public sealed record Pricing(double InputPerMillion, double OutputPerMillion);

    /// <summary>
    /// USD pricing per minute of audio for hosted speech-to-text providers.
    /// Mirrors Swift <c>TranscriptionPricing</c> struct.
    /// </summary>
    /// <param name="PerMinute">USD price per minute of audio.</param>
    public sealed record TranscriptionPricing(double PerMinute);

    /// <summary>Anthropic claude-sonnet-4-6 pricing as of 2026-04.</summary>
    public static readonly Pricing AnthropicClaudeSonnet46 = new(InputPerMillion: 3.0, OutputPerMillion: 15.0);

    /// <summary>OpenAI gpt-4o-mini pricing as of 2026-04.</summary>
    public static readonly Pricing OpenAIGpt4oMini = new(InputPerMillion: 0.15, OutputPerMillion: 0.60);

    /// <summary>
    /// OpenRouter conservative default (matches their flagship Sonnet route as
    /// a safe upper bound; users on cheaper models will under-spend the cap).
    /// </summary>
    public static readonly Pricing OpenRouterDefault = new(InputPerMillion: 3.5, OutputPerMillion: 17.0);

    /// <summary>OpenAI <c>whisper-1</c> hosted Whisper Large-v2: $0.006 / minute.</summary>
    public static readonly TranscriptionPricing OpenAIWhisper1 = new(PerMinute: 0.006);

    /// <summary>OpenAI <c>gpt-4o-transcribe</c>: ~$0.006 / minute.</summary>
    public static readonly TranscriptionPricing OpenAIGpt4oTranscribe = new(PerMinute: 0.006);

    /// <summary>OpenAI <c>gpt-4o-mini-transcribe</c>: ~$0.003 / minute.</summary>
    public static readonly TranscriptionPricing OpenAIGpt4oMiniTranscribe = new(PerMinute: 0.003);

    /// <summary>Deepgram Nova-2 batch (<c>/v1/listen</c>): $0.0043 / minute.</summary>
    public static readonly TranscriptionPricing DeepgramNova2Batch = new(PerMinute: 0.0043);

    /// <summary>
    /// Rough token count heuristic: ~4 chars/token for Latin scripts, ~3 for
    /// non-Latin (CJK, Cyrillic, Arabic, etc.). Errs on the conservative
    /// (larger) side so the cost estimate is slightly above actual.
    /// </summary>
    /// <remarks>
    /// Counts Unicode scalars (codepoints), not UTF-16 chars, so non-BMP
    /// characters are counted once each — matching Swift's
    /// <c>String.unicodeScalars</c> semantics.
    /// </remarks>
    public static int EstimateTokens(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return 0;
        }

        int total = 0;
        int nonLatin = 0;
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        // Fall back to a manual codepoint walk; Swift counts Unicode scalars,
        // which equals codepoints (not grapheme clusters).
        for (int i = 0; i < text.Length;)
        {
            int cp = char.ConvertToUtf32(text, i);
            total++;
            if (cp >= 0x0400)
            {
                nonLatin++;
            }
            i += char.IsSurrogatePair(text, i) ? 2 : 1;
        }
        // Suppress unused warning for the StringInfo enumerator we tried first.
        _ = enumerator;

        if (total == 0)
        {
            return 0;
        }

        double ratio = ((double)nonLatin / total) > 0.3 ? 3.0 : 4.0;
        return Math.Max(1, (int)Math.Ceiling(total / ratio));
    }

    /// <summary>USD cost for one call given exact input/output token counts.</summary>
    public static double Estimate(int inputTokens, int outputTokens, Pricing pricing)
    {
        ArgumentNullException.ThrowIfNull(pricing);
        double inputCost = inputTokens / 1_000_000.0 * pricing.InputPerMillion;
        double outputCost = outputTokens / 1_000_000.0 * pricing.OutputPerMillion;
        return inputCost + outputCost;
    }

    /// <summary>
    /// Estimate USD cost for transcribing <paramref name="durationSec"/> of audio
    /// at the given per-minute rate. Returns 0 for non-positive durations.
    /// </summary>
    public static double EstimateTranscription(double durationSec, TranscriptionPricing pricing)
    {
        ArgumentNullException.ThrowIfNull(pricing);
        if (durationSec <= 0)
        {
            return 0;
        }
        return (durationSec / 60.0) * pricing.PerMinute;
    }
}
