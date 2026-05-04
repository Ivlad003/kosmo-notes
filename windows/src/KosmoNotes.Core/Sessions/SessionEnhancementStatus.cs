using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Sessions;

/// <summary>
/// Records whether all <em>optional</em> post-stop enhancements (transcript cleanup,
/// AI summary, semantic embedding, Markdown export) succeeded. Mirrors the Swift
/// <c>SessionEnhancementStatus</c> enum.
/// </summary>
/// <remarks>
/// <c>Failed</c> is intentionally absent — <see cref="SessionStatus.Failed"/> covers
/// hard-failure paths (recording or transcription itself blew up).
/// <see cref="SessionEnhancementStatus"/> is only meaningful on completed sessions.
/// </remarks>
[JsonConverter(typeof(SessionEnhancementStatusJsonConverter))]
public enum SessionEnhancementStatus
{
    /// <summary>All optional post-stop enhancements completed.</summary>
    Ok,

    /// <summary>Some optional enhancement step failed; the session is degraded.</summary>
    Partial,
}

internal sealed class SessionEnhancementStatusJsonConverter : JsonConverter<SessionEnhancementStatus>
{
    public override SessionEnhancementStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.GetString();
        return raw switch
        {
            "ok" => SessionEnhancementStatus.Ok,
            "partial" => SessionEnhancementStatus.Partial,
            _ => throw new JsonException($"Unknown SessionEnhancementStatus: {raw}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, SessionEnhancementStatus value, JsonSerializerOptions options)
    {
        string raw = value switch
        {
            SessionEnhancementStatus.Ok => "ok",
            SessionEnhancementStatus.Partial => "partial",
            _ => throw new JsonException($"Unknown value: {value}"),
        };
        writer.WriteStringValue(raw);
    }
}
