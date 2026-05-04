using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Models;

/// <summary>
/// A single content part inside a <see cref="ChatMessage"/>.
/// Mirrors the Swift <c>ChatMessage.Part</c> enum (text/image cases).
/// </summary>
/// <remarks>
/// JSON wire shape (matches Swift's keyed-container encoding):
/// <c>{"type":"text","text":"..."}</c> or
/// <c>{"type":"image","jpegData":"&lt;base64&gt;","mimeType":"..."}</c>.
/// </remarks>
[JsonConverter(typeof(ChatPartJsonConverter))]
public abstract record ChatPart
{
    private protected ChatPart() { }
}

/// <summary>A text part — plain UTF-8 text content.</summary>
public sealed record TextPart(string Text) : ChatPart;

/// <summary>
/// A JPEG-encoded image part. Providers base64-encode <see cref="JpegData"/>
/// for transport.
/// </summary>
public sealed record ImagePart(byte[] JpegData, string MimeType) : ChatPart
{
    /// <inheritdoc />
    public bool Equals(ImagePart? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return MimeType == other.MimeType
            && JpegData.AsSpan().SequenceEqual(other.JpegData);
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        // Hash mime type + length + first/last bytes; cheap and good enough.
        int h = MimeType.GetHashCode();
        h = HashCode.Combine(h, JpegData.Length);
        if (JpegData.Length > 0)
        {
            h = HashCode.Combine(h, JpegData[0], JpegData[^1]);
        }
        return h;
    }
}

/// <summary>
/// Round-trips a <see cref="ChatPart"/> as a tagged object with a <c>type</c>
/// discriminator, matching the Swift Codable shape.
/// </summary>
internal sealed class ChatPartJsonConverter : JsonConverter<ChatPart>
{
    public override ChatPart? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            throw new JsonException("Expected start of object for ChatPart.");
        }

        string? type = null;
        string? text = null;
        byte[]? jpegData = null;
        string? mimeType = null;

        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndObject)
            {
                break;
            }
            if (reader.TokenType != JsonTokenType.PropertyName)
            {
                throw new JsonException("Expected property name in ChatPart.");
            }
            string property = reader.GetString() ?? throw new JsonException("Null property name.");
            reader.Read();
            switch (property)
            {
                case "type":
                    type = reader.GetString();
                    break;
                case "text":
                    text = reader.GetString();
                    break;
                case "jpegData":
                    jpegData = reader.GetBytesFromBase64();
                    break;
                case "mimeType":
                    mimeType = reader.GetString();
                    break;
                default:
                    reader.Skip();
                    break;
            }
        }

        return type switch
        {
            "text" => new TextPart(text ?? throw new JsonException("Missing 'text' for text part.")),
            "image" => new ImagePart(
                jpegData ?? throw new JsonException("Missing 'jpegData' for image part."),
                mimeType ?? throw new JsonException("Missing 'mimeType' for image part.")),
            null => throw new JsonException("Missing 'type' discriminator on ChatPart."),
            _ => throw new JsonException($"Unknown ChatPart type: {type}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, ChatPart value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case TextPart t:
                writer.WriteString("type", "text");
                writer.WriteString("text", t.Text);
                break;
            case ImagePart i:
                writer.WriteString("type", "image");
                writer.WriteBase64String("jpegData", i.JpegData);
                writer.WriteString("mimeType", i.MimeType);
                break;
            default:
                throw new JsonException($"Unsupported ChatPart subtype: {value.GetType()}");
        }
        writer.WriteEndObject();
    }
}
