using System.Net;
using System.Net.Http;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class OpenAIProviderTests
{
    private static AIConfig DefaultConfig() => new("gpt-4o-mini", 0.5, 256);

    private static string OkBodyJson() =>
        """{"choices":[{"message":{"role":"assistant","content":"ok"}}]}""";

    [Fact]
    public async Task ChatAsync_SendsPostWithBearerAuthToConfiguredEndpoint()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("sk-test", new Uri("https://example.test/v1/chat/completions"), http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal(HttpMethod.Post, handler.CapturedRequest!.Method);
        Assert.Equal(new Uri("https://example.test/v1/chat/completions"), handler.CapturedRequest.RequestUri);
        Assert.Equal("Bearer", handler.CapturedRequest.Headers.Authorization!.Scheme);
        Assert.Equal("sk-test", handler.CapturedRequest.Headers.Authorization.Parameter);
        Assert.Equal("application/json", handler.CapturedContentType);
    }

    [Fact]
    public async Task ChatAsync_BodyIncludesAllConfigFields()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hello") },
            new AIConfig("gpt-4o-mini", 0.42, 777));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var root = doc.RootElement;
        Assert.Equal("gpt-4o-mini", root.GetProperty("model").GetString());
        Assert.Equal(0.42, root.GetProperty("temperature").GetDouble(), 5);
        Assert.Equal(777, root.GetProperty("max_tokens").GetInt32());
    }

    [Fact]
    public async Task ChatAsync_PrependsSystemPromptAsFirstMessage()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") },
            new AIConfig("gpt-test", SystemPrompt: "be brief"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var msgs = doc.RootElement.GetProperty("messages");
        Assert.Equal(2, msgs.GetArrayLength());
        Assert.Equal("system", msgs[0].GetProperty("role").GetString());
        Assert.Equal("be brief", msgs[0].GetProperty("content").GetString());
        Assert.Equal("user", msgs[1].GetProperty("role").GetString());
    }

    [Fact]
    public async Task ChatAsync_DoesNotPrependWhenSystemPromptIsNull()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[]
            {
                ChatMessage.FromText(ChatRole.User, "hi"),
                ChatMessage.FromText(ChatRole.Assistant, "hello"),
            },
            DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var msgs = doc.RootElement.GetProperty("messages");
        Assert.Equal(2, msgs.GetArrayLength());
        Assert.Equal("user", msgs[0].GetProperty("role").GetString());
    }

    [Fact]
    public async Task ChatAsync_SingleTextPart_SendsContentAsPlainString()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "single") }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content");
        Assert.Equal(JsonValueKind.String, content.ValueKind);
        Assert.Equal("single", content.GetString());
    }

    [Fact]
    public async Task ChatAsync_MixedPartsBecomeImageUrlDataUriBlock()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        var jpeg = new byte[] { 1, 2, 3, 4 };
        var msg = new ChatMessage(ChatRole.User, new ChatPart[]
        {
            new TextPart("see:"),
            new ImagePart(jpeg, "image/jpeg"),
        });

        await provider.ChatAsync(new[] { msg }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content");
        Assert.Equal(JsonValueKind.Array, content.ValueKind);
        Assert.Equal(2, content.GetArrayLength());
        Assert.Equal("text", content[0].GetProperty("type").GetString());
        Assert.Equal("see:", content[0].GetProperty("text").GetString());
        Assert.Equal("image_url", content[1].GetProperty("type").GetString());
        var url = content[1].GetProperty("image_url").GetProperty("url").GetString();
        Assert.StartsWith("data:image/jpeg;base64,", url);
        Assert.EndsWith(Convert.ToBase64String(jpeg), url);
    }

    [Fact]
    public async Task ChatAsync_ParsesFirstChoiceContent()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"choices":[{"message":{"role":"assistant","content":"hello world"}}]}""");
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        var reply = await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());
        Assert.Equal("hello world", reply);
    }

    [Fact]
    public async Task ChatAsync_NoChoices_ThrowsDecodingFailed()
    {
        var handler = CapturingHandler.RespondingJson("""{"choices":[]}""");
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await Assert.ThrowsAsync<DecodingFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_401_ThrowsAuthenticationFailed()
    {
        var handler = CapturingHandler.RespondingText("nope", HttpStatusCode.Unauthorized);
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await Assert.ThrowsAsync<AuthenticationFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_429_ThrowsRateLimited()
    {
        var handler = CapturingHandler.RespondingText("slow", (HttpStatusCode)429);
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        await Assert.ThrowsAsync<RateLimitedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_500_ThrowsSendFailedWithBody()
    {
        var handler = CapturingHandler.RespondingText("kaboom", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new OpenAIProvider("k", httpClient: http);

        var ex = await Assert.ThrowsAsync<SendFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
        Assert.Contains("500", ex.Message);
        Assert.Contains("kaboom", ex.Message);
    }
}
