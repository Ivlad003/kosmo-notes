using System.Text.Json;
using KosmoNotes.Core.Sessions;

namespace KosmoNotes.Core.Tests;

public class SessionRecordJsonTests
{
    private static JsonSerializerOptions Options => new(JsonSerializerDefaults.Web);

    [Fact]
    public void Mode_SerializesAsCamelCaseString()
    {
        Assert.Equal("\"meeting\"", JsonSerializer.Serialize(SessionMode.Meeting, Options));
        Assert.Equal("\"dictation\"", JsonSerializer.Serialize(SessionMode.Dictation, Options));
        Assert.Equal("\"voiceNote\"", JsonSerializer.Serialize(SessionMode.VoiceNote, Options));
    }

    [Fact]
    public void Status_SerializesAsLowercaseString()
    {
        Assert.Equal("\"recording\"", JsonSerializer.Serialize(SessionStatus.Recording, Options));
        Assert.Equal("\"transcribing\"", JsonSerializer.Serialize(SessionStatus.Transcribing, Options));
        Assert.Equal("\"complete\"", JsonSerializer.Serialize(SessionStatus.Complete, Options));
        Assert.Equal("\"failed\"", JsonSerializer.Serialize(SessionStatus.Failed, Options));
    }

    [Fact]
    public void EnhancementStatus_SerializesAsLowercaseString()
    {
        Assert.Equal("\"ok\"", JsonSerializer.Serialize(SessionEnhancementStatus.Ok, Options));
        Assert.Equal("\"partial\"", JsonSerializer.Serialize(SessionEnhancementStatus.Partial, Options));
    }

    [Fact]
    public void Record_RoundTrips()
    {
        var input = new SessionRecord(
            Id: "abc-123",
            RecordedAt: DateTimeOffset.Parse("2026-05-03T12:34:56Z"),
            DurationSecs: 123.5,
            Mode: SessionMode.VoiceNote,
            Language: "uk",
            Status: SessionStatus.Complete,
            EnhancementStatus: SessionEnhancementStatus.Partial);

        string json = JsonSerializer.Serialize(input, Options);
        var decoded = JsonSerializer.Deserialize<SessionRecord>(json, Options);
        Assert.NotNull(decoded);
        Assert.Equal(input, decoded);
    }

    [Fact]
    public void Decode_OldSidecarWithoutEnhancementStatus_DefaultsToOk()
    {
        // A pre-v3 sidecar lacks the enhancementStatus field.
        const string json = """
        {
            "id": "abc-123",
            "recordedAt": "2026-05-03T12:34:56+00:00",
            "durationSecs": 60.0,
            "mode": "meeting",
            "language": "en",
            "status": "complete"
        }
        """;
        var decoded = JsonSerializer.Deserialize<SessionRecord>(json, Options);
        Assert.NotNull(decoded);
        Assert.Equal(SessionEnhancementStatus.Ok, decoded!.EnhancementStatus);
        Assert.Equal("abc-123", decoded.Id);
        Assert.Equal(SessionMode.Meeting, decoded.Mode);
        Assert.Equal(SessionStatus.Complete, decoded.Status);
        Assert.Equal("en", decoded.Language);
    }

    [Fact]
    public void Decode_NullLanguage_DecodesToNull()
    {
        const string json = """
        {
            "id": "abc",
            "recordedAt": "2026-05-03T12:00:00+00:00",
            "durationSecs": 0.0,
            "mode": "dictation",
            "language": null,
            "status": "failed",
            "enhancementStatus": "ok"
        }
        """;
        var decoded = JsonSerializer.Deserialize<SessionRecord>(json, Options);
        Assert.NotNull(decoded);
        Assert.Null(decoded!.Language);
    }

    [Fact]
    public void Decode_NullEnhancementStatus_DefaultsToOk()
    {
        const string json = """
        {
            "id": "abc",
            "recordedAt": "2026-05-03T12:00:00+00:00",
            "durationSecs": 0.0,
            "mode": "voiceNote",
            "language": "en",
            "status": "complete",
            "enhancementStatus": null
        }
        """;
        var decoded = JsonSerializer.Deserialize<SessionRecord>(json, Options);
        Assert.NotNull(decoded);
        Assert.Equal(SessionEnhancementStatus.Ok, decoded!.EnhancementStatus);
    }

    [Fact]
    public void Decode_MissingRequiredField_Throws()
    {
        const string json = """
        {
            "id": "abc",
            "recordedAt": "2026-05-03T12:00:00+00:00",
            "durationSecs": 0.0,
            "mode": "meeting"
        }
        """;
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<SessionRecord>(json, Options));
    }
}
