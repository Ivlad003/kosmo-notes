using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Models;

/// <summary>
/// Role of a chat message in a conversation. Mirrors the Swift
/// <c>ChatMessage.Role</c> enum.
/// </summary>
[JsonConverter(typeof(ChatRoleJsonConverter))]
public enum ChatRole
{
    /// <summary>System role — instructions/persona for the assistant.</summary>
    System,

    /// <summary>User role — message authored by the human.</summary>
    User,

    /// <summary>Assistant role — model output.</summary>
    Assistant,
}

/// <summary>
/// Round-trips <see cref="ChatRole"/> as the lowercase strings <c>"system"</c>,
/// <c>"user"</c>, <c>"assistant"</c> — matching Swift's <c>String</c> raw values.
/// </summary>
internal sealed class ChatRoleJsonConverter : JsonConverter<ChatRole>
{
    public override ChatRole Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.GetString();
        return raw switch
        {
            "system" => ChatRole.System,
            "user" => ChatRole.User,
            "assistant" => ChatRole.Assistant,
            _ => throw new JsonException($"Unknown ChatRole: {raw}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, ChatRole value, JsonSerializerOptions options)
    {
        string raw = value switch
        {
            ChatRole.System => "system",
            ChatRole.User => "user",
            ChatRole.Assistant => "assistant",
            _ => throw new JsonException($"Unknown ChatRole value: {value}"),
        };
        writer.WriteStringValue(raw);
    }
}
