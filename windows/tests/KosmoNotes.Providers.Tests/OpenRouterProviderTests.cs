using System.Net;
using System.Net.Http;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class OpenRouterProviderTests
{
    private static AIConfig DefaultConfig() => new("anthropic/claude-sonnet-4-6");

    private static string OkBodyJson() =>
        """{"choices":[{"message":{"role":"assistant","content":"ok"}}]}""";

    [Fact]
    public async Task ChatAsync_SendsAttributionHeaders_WithDefaultsWhenUnset()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.True(handler.CapturedRequest!.Headers.TryGetValues("HTTP-Referer", out var refValues));
        Assert.Equal(OpenRouterProvider.DefaultReferer, string.Join(",", refValues!));
        Assert.True(handler.CapturedRequest.Headers.TryGetValues("X-Title", out var titleValues));
        Assert.Equal(OpenRouterProvider.DefaultTitle, string.Join(",", titleValues!));
    }

    [Fact]
    public async Task ChatAsync_AttributionHeaders_OverrideWhenProvided()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", referer: "https://app.test", title: "Custom App", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal("https://app.test",
            string.Join(",", handler.CapturedRequest!.Headers.GetValues("HTTP-Referer")));
        Assert.Equal("Custom App",
            string.Join(",", handler.CapturedRequest.Headers.GetValues("X-Title")));
    }

    [Fact]
    public async Task ChatAsync_DefaultsToConfiguredEndpoint()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal(OpenRouterProvider.DefaultEndpoint, handler.CapturedRequest!.RequestUri);
    }

    [Fact]
    public async Task ChatAsync_PrependsSystemPromptAsFirstMessage()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") },
            new AIConfig("anthropic/claude-x", SystemPrompt: "be brief"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var msgs = doc.RootElement.GetProperty("messages");
        Assert.Equal("system", msgs[0].GetProperty("role").GetString());
        Assert.Equal("be brief", msgs[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task ChatAsync_MixedPartsBecomeImageUrlDataUriBlock()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        var jpeg = new byte[] { 9, 8, 7, 6, 5 };
        var msg = new ChatMessage(ChatRole.User, new ChatPart[]
        {
            new TextPart("see:"),
            new ImagePart(jpeg, "image/jpeg"),
        });

        await provider.ChatAsync(new[] { msg }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content");
        Assert.Equal(JsonValueKind.Array, content.ValueKind);
        Assert.Equal("image_url", content[1].GetProperty("type").GetString());
        var url = content[1].GetProperty("image_url").GetProperty("url").GetString();
        Assert.StartsWith("data:image/jpeg;base64,", url);
        Assert.EndsWith(Convert.ToBase64String(jpeg), url);
    }

    [Fact]
    public async Task ChatAsync_BearerAuthorizationHeader()
    {
        var handler = CapturingHandler.RespondingJson(OkBodyJson());
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("rk-secret", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal("Bearer", handler.CapturedRequest!.Headers.Authorization!.Scheme);
        Assert.Equal("rk-secret", handler.CapturedRequest.Headers.Authorization.Parameter);
    }

    [Fact]
    public async Task ChatAsync_ParsesOpenAIShape()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"choices":[{"message":{"role":"assistant","content":"router-says-hi"}}]}""");
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        var reply = await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig());
        Assert.Equal("router-says-hi", reply);
    }

    [Fact]
    public async Task ChatAsync_401_ThrowsAuthenticationFailed()
    {
        var handler = CapturingHandler.RespondingText("nope", HttpStatusCode.Unauthorized);
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        await Assert.ThrowsAsync<AuthenticationFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_429_ThrowsRateLimited()
    {
        var handler = CapturingHandler.RespondingText("slow", (HttpStatusCode)429);
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        await Assert.ThrowsAsync<RateLimitedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_500_ThrowsSendFailedWithBody()
    {
        var handler = CapturingHandler.RespondingText("oops", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new OpenRouterProvider("k", httpClient: http);

        var ex = await Assert.ThrowsAsync<SendFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
        Assert.Contains("500", ex.Message);
        Assert.Contains("oops", ex.Message);
    }
}
