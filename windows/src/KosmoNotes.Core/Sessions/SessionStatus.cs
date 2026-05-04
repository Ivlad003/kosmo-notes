using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Sessions;

/// <summary>
/// Lifecycle status of a session row. Mirrors the Swift <c>SessionStatus</c> enum.
/// JSON values are lowercase.
/// </summary>
[JsonConverter(typeof(SessionStatusJsonConverter))]
public enum SessionStatus
{
    /// <summary>Audio capture is in progress.</summary>
    Recording,

    /// <summary>Audio capture finished; transcription/summarization is running.</summary>
    Transcribing,

    /// <summary>All pipeline stages completed successfully.</summary>
    Complete,

    /// <summary>Recording or transcription failed unrecoverably.</summary>
    Failed,
}

internal sealed class SessionStatusJsonConverter : JsonConverter<SessionStatus>
{
    public override SessionStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.GetString();
        return raw switch
        {
            "recording" => SessionStatus.Recording,
            "transcribing" => SessionStatus.Transcribing,
            "complete" => SessionStatus.Complete,
            "failed" => SessionStatus.Failed,
            _ => throw new JsonException($"Unknown SessionStatus: {raw}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, SessionStatus value, JsonSerializerOptions options)
    {
        string raw = value switch
        {
            SessionStatus.Recording => "recording",
            SessionStatus.Transcribing => "transcribing",
            SessionStatus.Complete => "complete",
            SessionStatus.Failed => "failed",
            _ => throw new JsonException($"Unknown SessionStatus value: {value}"),
        };
        writer.WriteStringValue(raw);
    }
}
