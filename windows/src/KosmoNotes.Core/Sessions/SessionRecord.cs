using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Sessions;

/// <summary>
/// On-disk session sidecar record. Mirrors the Swift <c>SessionRecord</c> struct.
/// Serialized to <c>session.json</c> alongside <c>audio.m4a</c> /
/// <c>transcript.jsonl</c> / <c>summary.md</c>.
/// </summary>
/// <param name="Id">Stable session id (typically a UUID).</param>
/// <param name="RecordedAt">UTC start time of the recording.</param>
/// <param name="DurationSecs">Duration of the audio in seconds.</param>
/// <param name="Mode">Capture mode (Meeting / Dictation / Voice Note).</param>
/// <param name="Language">Detected source language (BCP-47), or <c>null</c> if unknown.</param>
/// <param name="Status">Lifecycle status (recording / transcribing / complete / failed).</param>
/// <param name="EnhancementStatus">
/// Whether optional post-stop enhancements all succeeded. Defaults to
/// <see cref="SessionEnhancementStatus.Ok"/>; older sidecars without this field
/// also decode to <see cref="SessionEnhancementStatus.Ok"/>.
/// </param>
[JsonConverter(typeof(SessionRecordJsonConverter))]
public sealed record SessionRecord(
    string Id,
    DateTimeOffset RecordedAt,
    double DurationSecs,
    SessionMode Mode,
    string? Language,
    SessionStatus Status,
    SessionEnhancementStatus EnhancementStatus = SessionEnhancementStatus.Ok);

/// <summary>
/// Custom JSON converter so older sidecars without an <c>enhancementStatus</c> field
/// decode cleanly with <see cref="SessionEnhancementStatus.Ok"/> as the default —
/// matches the Swift <c>decodeIfPresent</c> fallback.
/// </summary>
internal sealed class SessionRecordJsonConverter : JsonConverter<SessionRecord>
{
    public override SessionRecord Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            throw new JsonException("Expected start of object for SessionRecord.");
        }

        string? id = null;
        DateTimeOffset? recordedAt = null;
        double? durationSecs = null;
        SessionMode? mode = null;
        string? language = null;
        SessionStatus? status = null;
        SessionEnhancementStatus enhancementStatus = SessionEnhancementStatus.Ok;

        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndObject)
            {
                break;
            }
            if (reader.TokenType != JsonTokenType.PropertyName)
            {
                throw new JsonException("Expected property name in SessionRecord.");
            }
            string property = reader.GetString() ?? throw new JsonException("Null property name.");
            reader.Read();
            switch (property)
            {
                case "id":
                    id = reader.GetString();
                    break;
                case "recordedAt":
                    recordedAt = JsonSerializer.Deserialize<DateTimeOffset>(ref reader, options);
                    break;
                case "durationSecs":
                    durationSecs = reader.GetDouble();
                    break;
                case "mode":
                    mode = JsonSerializer.Deserialize<SessionMode>(ref reader, options);
                    break;
                case "language":
                    language = reader.TokenType == JsonTokenType.Null ? null : reader.GetString();
                    break;
                case "status":
                    status = JsonSerializer.Deserialize<SessionStatus>(ref reader, options);
                    break;
                case "enhancementStatus":
                    if (reader.TokenType == JsonTokenType.Null)
                    {
                        enhancementStatus = SessionEnhancementStatus.Ok;
                    }
                    else
                    {
                        enhancementStatus = JsonSerializer.Deserialize<SessionEnhancementStatus>(ref reader, options);
                    }
                    break;
                default:
                    reader.Skip();
                    break;
            }
        }

        if (id is null) throw new JsonException("Missing 'id' on SessionRecord.");
        if (recordedAt is null) throw new JsonException("Missing 'recordedAt' on SessionRecord.");
        if (durationSecs is null) throw new JsonException("Missing 'durationSecs' on SessionRecord.");
        if (mode is null) throw new JsonException("Missing 'mode' on SessionRecord.");
        if (status is null) throw new JsonException("Missing 'status' on SessionRecord.");

        return new SessionRecord(
            id,
            recordedAt.Value,
            durationSecs.Value,
            mode.Value,
            language,
            status.Value,
            enhancementStatus);
    }

    public override void Write(Utf8JsonWriter writer, SessionRecord value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WritePropertyName("recordedAt");
        JsonSerializer.Serialize(writer, value.RecordedAt, options);
        writer.WriteNumber("durationSecs", value.DurationSecs);
        writer.WritePropertyName("mode");
        JsonSerializer.Serialize(writer, value.Mode, options);
        if (value.Language is null)
        {
            writer.WriteNull("language");
        }
        else
        {
            writer.WriteString("language", value.Language);
        }
        writer.WritePropertyName("status");
        JsonSerializer.Serialize(writer, value.Status, options);
        writer.WritePropertyName("enhancementStatus");
        JsonSerializer.Serialize(writer, value.EnhancementStatus, options);
        writer.WriteEndObject();
    }
}
