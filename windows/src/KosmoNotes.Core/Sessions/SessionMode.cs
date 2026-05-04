using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Sessions;

/// <summary>
/// Capture mode for a session. Mirrors the Swift <c>SessionMode</c> enum.
/// JSON values are camelCase: <c>"meeting"</c>, <c>"dictation"</c>, <c>"voiceNote"</c>.
/// </summary>
[JsonConverter(typeof(SessionModeJsonConverter))]
public enum SessionMode
{
    /// <summary>Meeting mode (long-form, with summary).</summary>
    Meeting,

    /// <summary>Dictation mode (short, paste-ready).</summary>
    Dictation,

    /// <summary>Voice Note mode (templated freeform / task / journal / checklist).</summary>
    VoiceNote,
}

internal sealed class SessionModeJsonConverter : JsonConverter<SessionMode>
{
    public override SessionMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.GetString();
        return raw switch
        {
            "meeting" => SessionMode.Meeting,
            "dictation" => SessionMode.Dictation,
            "voiceNote" => SessionMode.VoiceNote,
            _ => throw new JsonException($"Unknown SessionMode: {raw}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, SessionMode value, JsonSerializerOptions options)
    {
        string raw = value switch
        {
            SessionMode.Meeting => "meeting",
            SessionMode.Dictation => "dictation",
            SessionMode.VoiceNote => "voiceNote",
            _ => throw new JsonException($"Unknown SessionMode value: {value}"),
        };
        writer.WriteStringValue(raw);
    }
}
