using System.Text;
using System.Text.Json;
using KosmoNotes.Core.Models;

namespace KosmoNotes.Core.Tests;

public class ChatMessageJsonTests
{
    private static JsonSerializerOptions Options => new(JsonSerializerDefaults.Web);

    [Fact]
    public void Role_SerializesAsLowercaseString()
    {
        Assert.Equal("\"system\"", JsonSerializer.Serialize(ChatRole.System, Options));
        Assert.Equal("\"user\"", JsonSerializer.Serialize(ChatRole.User, Options));
        Assert.Equal("\"assistant\"", JsonSerializer.Serialize(ChatRole.Assistant, Options));
    }

    [Fact]
    public void Role_DeserializesFromLowercaseString()
    {
        Assert.Equal(ChatRole.System, JsonSerializer.Deserialize<ChatRole>("\"system\"", Options));
        Assert.Equal(ChatRole.User, JsonSerializer.Deserialize<ChatRole>("\"user\"", Options));
        Assert.Equal(ChatRole.Assistant, JsonSerializer.Deserialize<ChatRole>("\"assistant\"", Options));
    }

    [Fact]
    public void TextPart_RoundTrips()
    {
        ChatPart input = new TextPart("Hello world");
        string json = JsonSerializer.Serialize(input, Options);
        Assert.Contains("\"type\":\"text\"", json);
        Assert.Contains("\"text\":\"Hello world\"", json);

        var decoded = JsonSerializer.Deserialize<ChatPart>(json, Options);
        Assert.Equal(input, decoded);
    }

    [Fact]
    public void ImagePart_RoundTrips()
    {
        byte[] bytes = new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10 }; // JPEG magic
        ChatPart input = new ImagePart(bytes, "image/jpeg");
        string json = JsonSerializer.Serialize(input, Options);
        Assert.Contains("\"type\":\"image\"", json);
        Assert.Contains("\"mimeType\":\"image/jpeg\"", json);
        // jpegData is base64 — check decoding instead of literal match.
        var decoded = JsonSerializer.Deserialize<ChatPart>(json, Options);
        var img = Assert.IsType<ImagePart>(decoded);
        Assert.Equal(bytes, img.JpegData);
        Assert.Equal("image/jpeg", img.MimeType);
    }

    [Fact]
    public void ChatMessage_MixedParts_RoundTrips()
    {
        var input = new ChatMessage(
            ChatRole.User,
            new ChatPart[]
            {
                new TextPart("First piece"),
                new ImagePart(new byte[] { 1, 2, 3, 4 }, "image/png"),
                new TextPart("Second piece"),
            });

        string json = JsonSerializer.Serialize(input, Options);
        var decoded = JsonSerializer.Deserialize<ChatMessage>(json, Options);
        Assert.NotNull(decoded);
        Assert.Equal(input, decoded);
    }

    [Fact]
    public void TextAccessor_JoinsTextPartsWithSpaces_IgnoresImages()
    {
        var msg = new ChatMessage(
            ChatRole.Assistant,
            new ChatPart[]
            {
                new TextPart("Hello"),
                new ImagePart(new byte[] { 9, 9 }, "image/jpeg"),
                new TextPart("world"),
                new TextPart("again"),
            });
        Assert.Equal("Hello world again", msg.Text);
    }

    [Fact]
    public void TextAccessor_NoTextParts_ReturnsEmpty()
    {
        var msg = new ChatMessage(
            ChatRole.User,
            new ChatPart[]
            {
                new ImagePart(new byte[] { 0 }, "image/jpeg"),
            });
        Assert.Equal(string.Empty, msg.Text);
    }

    [Fact]
    public void FromText_ProducesSingleTextPartMessage()
    {
        var msg = ChatMessage.FromText(ChatRole.System, "You are helpful.");
        Assert.Equal(ChatRole.System, msg.Role);
        var part = Assert.Single(msg.Parts);
        var text = Assert.IsType<TextPart>(part);
        Assert.Equal("You are helpful.", text.Text);
    }

    [Fact]
    public void Decode_UnknownPartType_Throws()
    {
        const string json = "{\"type\":\"video\",\"url\":\"x\"}";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<ChatPart>(json, Options));
    }

    [Fact]
    public void Decode_ImagePartFromUtf8_Works()
    {
        // Same shape we'd see written from another runtime.
        const string json = "{\"type\":\"image\",\"jpegData\":\"AQID\",\"mimeType\":\"image/jpeg\"}";
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        var part = JsonSerializer.Deserialize<ChatPart>(bytes, Options);
        var img = Assert.IsType<ImagePart>(part);
        Assert.Equal(new byte[] { 1, 2, 3 }, img.JpegData);
    }
}
