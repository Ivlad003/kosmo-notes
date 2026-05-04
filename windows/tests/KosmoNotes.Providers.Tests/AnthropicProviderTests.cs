using System.Net;
using System.Net.Http;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class AnthropicProviderTests
{
    private static AIConfig DefaultConfig() => new("claude-test", 0.5, 256, null);

    private static byte[] OkBody() =>
        """{"content":[{"type":"text","text":"hello world"}]}"""u8.ToArray();

    [Fact]
    public async Task ChatAsync_SendsPostToConfiguredEndpoint()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k1", new Uri("https://example.test/v1/messages"), http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.NotNull(handler.CapturedRequest);
        Assert.Equal(HttpMethod.Post, handler.CapturedRequest!.Method);
        Assert.Equal(new Uri("https://example.test/v1/messages"), handler.CapturedRequest.RequestUri);
    }

    [Fact]
    public async Task ChatAsync_SendsRequiredHeaders()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("secret-key", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        var headers = handler.CapturedRequest!.Headers;
        Assert.True(headers.TryGetValues("x-api-key", out var keyValues));
        Assert.Equal("secret-key", string.Join(",", keyValues!));
        Assert.True(headers.TryGetValues("anthropic-version", out var verValues));
        Assert.Equal("2023-06-01", string.Join(",", verValues!));
        Assert.Equal("application/json", handler.CapturedContentType);
    }

    [Fact]
    public async Task ChatAsync_BodyIncludesModelMaxTokensTemperatureAndMessages()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hello") },
            new AIConfig("claude-sonnet-4-6", 0.3, 512));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var root = doc.RootElement;
        Assert.Equal("claude-sonnet-4-6", root.GetProperty("model").GetString());
        Assert.Equal(512, root.GetProperty("max_tokens").GetInt32());
        Assert.Equal(0.3, root.GetProperty("temperature").GetDouble(), 5);
        var msgs = root.GetProperty("messages");
        Assert.Equal(1, msgs.GetArrayLength());
        Assert.Equal("user", msgs[0].GetProperty("role").GetString());
        Assert.Equal("hello", msgs[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task ChatAsync_PutsSystemPromptAtTopLevel_NotInMessagesArray()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") },
            new AIConfig("claude-test", SystemPrompt: "be brief"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var root = doc.RootElement;
        Assert.Equal("be brief", root.GetProperty("system").GetString());
        var msgs = root.GetProperty("messages");
        foreach (var m in msgs.EnumerateArray())
        {
            Assert.NotEqual("system", m.GetProperty("role").GetString());
        }
    }

    [Fact]
    public async Task ChatAsync_SystemPromptFromConfigOverridesSystemMessage()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[]
            {
                ChatMessage.FromText(ChatRole.System, "ignored"),
                ChatMessage.FromText(ChatRole.User, "hi"),
            },
            new AIConfig("claude-test", SystemPrompt: "preferred"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        Assert.Equal("preferred", doc.RootElement.GetProperty("system").GetString());
    }

    [Fact]
    public async Task ChatAsync_FallsBackToLastSystemMessage_WhenConfigSystemPromptIsNull()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[]
            {
                ChatMessage.FromText(ChatRole.System, "first"),
                ChatMessage.FromText(ChatRole.System, "second"),
                ChatMessage.FromText(ChatRole.User, "hi"),
            },
            new AIConfig("claude-test"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        Assert.Equal("second", doc.RootElement.GetProperty("system").GetString());
        Assert.Equal(1, doc.RootElement.GetProperty("messages").GetArrayLength());
    }

    [Fact]
    public async Task ChatAsync_OmitsSystemFieldWhenNoSystemPromptOrMessages()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"hi"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        Assert.False(doc.RootElement.TryGetProperty("system", out _));
    }

    [Fact]
    public async Task ChatAsync_SingleTextPart_SendsContentAsPlainString()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"ok"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "single") }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content");
        Assert.Equal(JsonValueKind.String, content.ValueKind);
        Assert.Equal("single", content.GetString());
    }

    [Fact]
    public async Task ChatAsync_MixedPartsBecomeArrayWithImageBase64Block()
    {
        var handler = CapturingHandler.RespondingJson("""{"content":[{"type":"text","text":"ok"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        var jpeg = new byte[] { 0xFF, 0xD8, 0xFF, 0xE0 };
        var msg = new ChatMessage(ChatRole.User, new ChatPart[]
        {
            new TextPart("look:"),
            new ImagePart(jpeg, "image/jpeg"),
        });

        await provider.ChatAsync(new[] { msg }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content");
        Assert.Equal(JsonValueKind.Array, content.ValueKind);
        Assert.Equal(2, content.GetArrayLength());
        Assert.Equal("text", content[0].GetProperty("type").GetString());
        Assert.Equal("look:", content[0].GetProperty("text").GetString());
        Assert.Equal("image", content[1].GetProperty("type").GetString());
        var src = content[1].GetProperty("source");
        Assert.Equal("base64", src.GetProperty("type").GetString());
        Assert.Equal("image/jpeg", src.GetProperty("media_type").GetString());
        Assert.Equal(Convert.ToBase64String(jpeg), src.GetProperty("data").GetString());
    }

    [Fact]
    public async Task ChatAsync_ParsesTextBlocksConcatenated()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}""");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        var result = await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal("hello world", result);
    }

    [Fact]
    public async Task ChatAsync_401_ThrowsAuthenticationFailed()
    {
        var handler = CapturingHandler.RespondingText("unauthorized", HttpStatusCode.Unauthorized);
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await Assert.ThrowsAsync<AuthenticationFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_429_ThrowsRateLimited()
    {
        var handler = CapturingHandler.RespondingText("slow down", (HttpStatusCode)429);
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await Assert.ThrowsAsync<RateLimitedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_500_ThrowsSendFailedWithBodyInMessage()
    {
        var handler = CapturingHandler.RespondingText("boom", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        var ex = await Assert.ThrowsAsync<SendFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
        Assert.Contains("500", ex.Message);
        Assert.Contains("boom", ex.Message);
    }

    [Fact]
    public async Task ChatAsync_GarbageJson_ThrowsDecodingFailed()
    {
        var handler = CapturingHandler.RespondingJson("not json at all");
        using var http = new HttpClient(handler);
        var provider = new AnthropicProvider("k", httpClient: http);

        await Assert.ThrowsAsync<DecodingFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }
}
