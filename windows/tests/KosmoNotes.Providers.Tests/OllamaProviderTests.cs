using System.Net;
using System.Net.Http;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class OllamaProviderTests
{
    private static AIConfig DefaultConfig() => new("llama3");

    // ---- Endpoint validation ----------------------------------------------

    [Fact]
    public void Ctor_RejectsHttpExternalHost()
    {
        Assert.Throws<InvalidEndpointException>(() =>
            new OllamaProvider(new Uri("http://example.com")));
    }

    [Fact]
    public void Ctor_AllowsHttpsExternalHost()
    {
        var provider = new OllamaProvider(new Uri("https://example.com"));
        Assert.NotNull(provider);
    }

    [Fact]
    public void Ctor_AllowsLocalhost()
    {
        Assert.NotNull(new OllamaProvider(new Uri("http://localhost:11434")));
    }

    [Fact]
    public void Ctor_AllowsLoopback()
    {
        Assert.NotNull(new OllamaProvider(new Uri("http://127.0.0.1:11434")));
    }

    [Theory]
    [InlineData("http://10.0.0.5")]
    [InlineData("http://10.255.255.255")]
    [InlineData("http://192.168.1.1")]
    [InlineData("http://192.168.0.10")]
    [InlineData("http://172.16.0.1")]
    [InlineData("http://172.31.255.255")]
    [InlineData("http://172.20.5.5")]
    public void Ctor_AllowsRfc1918Ranges(string url)
    {
        Assert.NotNull(new OllamaProvider(new Uri(url)));
    }

    [Theory]
    [InlineData("http://172.15.0.1")]
    [InlineData("http://172.32.0.1")]
    [InlineData("http://11.0.0.1")]
    [InlineData("http://193.168.1.1")]
    public void Ctor_RejectsNonRfc1918Hosts(string url)
    {
        Assert.Throws<InvalidEndpointException>(() => new OllamaProvider(new Uri(url)));
    }

    [Fact]
    public void Ctor_RejectsFtpScheme()
    {
        Assert.Throws<InvalidEndpointException>(() =>
            new OllamaProvider(new Uri("ftp://localhost")));
    }

    // ---- Native mode ------------------------------------------------------

    [Fact]
    public async Task NativeChat_PostsToApiChat_WithStreamFalseAndOptions()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"hi from ollama"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        var reply = await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hello") },
            new AIConfig("llama3", 0.6, 333));

        Assert.Equal("hi from ollama", reply);
        Assert.Equal(new Uri("http://localhost:11434/api/chat"), handler.CapturedRequest!.RequestUri);
        Assert.Equal(HttpMethod.Post, handler.CapturedRequest.Method);

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var root = doc.RootElement;
        Assert.Equal("llama3", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        var opts = root.GetProperty("options");
        Assert.Equal(0.6, opts.GetProperty("temperature").GetDouble(), 5);
        Assert.Equal(333, opts.GetProperty("num_predict").GetInt32());
    }

    [Fact]
    public async Task NativeChat_PrependsSystemPromptAsFirstMessage()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"x"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") },
            new AIConfig("llama3", SystemPrompt: "be brief"));

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var msgs = doc.RootElement.GetProperty("messages");
        Assert.Equal(2, msgs.GetArrayLength());
        Assert.Equal("system", msgs[0].GetProperty("role").GetString());
        Assert.Equal("be brief", msgs[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task NativeChat_JoinsTextPartsWithNewline_AndAddsImagesArray()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"x"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        var jpeg = new byte[] { 0xAA, 0xBB, 0xCC };
        var msg = new ChatMessage(ChatRole.User, new ChatPart[]
        {
            new TextPart("first"),
            new TextPart("second"),
            new ImagePart(jpeg, "image/jpeg"),
        });

        await provider.ChatAsync(new[] { msg }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var first = doc.RootElement.GetProperty("messages")[0];
        Assert.Equal("first\nsecond", first.GetProperty("content").GetString());
        var imgs = first.GetProperty("images");
        Assert.Equal(1, imgs.GetArrayLength());
        Assert.Equal(Convert.ToBase64String(jpeg), imgs[0].GetString());
    }

    [Fact]
    public async Task NativeChat_OmitsImagesArrayWhenNoImages()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"x"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var first = doc.RootElement.GetProperty("messages")[0];
        Assert.False(first.TryGetProperty("images", out _));
    }

    [Fact]
    public async Task NativeChat_BearerTokenAddsAuthorizationHeader()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"x"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), bearerToken: "tok", httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal("Bearer", handler.CapturedRequest!.Headers.Authorization!.Scheme);
        Assert.Equal("tok", handler.CapturedRequest.Headers.Authorization.Parameter);
    }

    [Fact]
    public async Task NativeChat_NoBearer_OmitsAuthorization()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"message":{"role":"assistant","content":"x"}}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Null(handler.CapturedRequest!.Headers.Authorization);
    }

    // ---- OpenAI-compat mode -----------------------------------------------

    [Fact]
    public async Task OpenAICompat_PostsToVChatCompletions_AndUsesOpenAIBody()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"choices":[{"message":{"role":"assistant","content":"compat"}}]}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(
            new Uri("http://localhost:11434"),
            apiMode: OllamaApiMode.OpenAICompat,
            httpClient: http);

        var reply = await provider.ChatAsync(
            new[] { ChatMessage.FromText(ChatRole.User, "hi") }, DefaultConfig());

        Assert.Equal("compat", reply);
        Assert.Equal(new Uri("http://localhost:11434/v1/chat/completions"), handler.CapturedRequest!.RequestUri);

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        Assert.Equal("llama3", doc.RootElement.GetProperty("model").GetString());
        Assert.True(doc.RootElement.TryGetProperty("messages", out _));
        Assert.True(doc.RootElement.TryGetProperty("max_tokens", out _));
    }

    [Fact]
    public async Task OpenAICompat_MixedPartsUseImageUrlBlock()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"choices":[{"message":{"role":"assistant","content":"x"}}]}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(
            new Uri("http://localhost:11434"),
            apiMode: OllamaApiMode.OpenAICompat,
            httpClient: http);

        var jpeg = new byte[] { 1, 2, 3 };
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
    }

    // ---- listModels -------------------------------------------------------

    [Fact]
    public async Task ListModelsAsync_GetsApiTags_AndReturnsNames()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"models":[{"name":"llama3"},{"name":"mistral"}]}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        var names = await provider.ListModelsAsync();

        Assert.Equal(new[] { "llama3", "mistral" }, names);
        Assert.Equal(HttpMethod.Get, handler.CapturedRequest!.Method);
        Assert.Equal(new Uri("http://localhost:11434/api/tags"), handler.CapturedRequest.RequestUri);
    }

    [Fact]
    public async Task ListModelsAsync_BearerToken_AddsAuthHeader()
    {
        var handler = CapturingHandler.RespondingJson("""{"models":[]}""");
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(
            new Uri("http://localhost:11434"), bearerToken: "tk", httpClient: http);

        await provider.ListModelsAsync();

        Assert.Equal("Bearer", handler.CapturedRequest!.Headers.Authorization!.Scheme);
        Assert.Equal("tk", handler.CapturedRequest.Headers.Authorization.Parameter);
    }

    [Fact]
    public async Task ListModelsAsync_500_ThrowsSendFailed()
    {
        var handler = CapturingHandler.RespondingText("err", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await Assert.ThrowsAsync<SendFailedException>(() => provider.ListModelsAsync());
    }

    // ---- Error mapping ----------------------------------------------------

    [Fact]
    public async Task ChatAsync_401_ThrowsAuthenticationFailed()
    {
        var handler = CapturingHandler.RespondingText("nope", HttpStatusCode.Unauthorized);
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await Assert.ThrowsAsync<AuthenticationFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_429_ThrowsRateLimited()
    {
        var handler = CapturingHandler.RespondingText("slow", (HttpStatusCode)429);
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        await Assert.ThrowsAsync<RateLimitedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
    }

    [Fact]
    public async Task ChatAsync_500_ThrowsSendFailedWithBody()
    {
        var handler = CapturingHandler.RespondingText("crash", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new OllamaProvider(new Uri("http://localhost:11434"), httpClient: http);

        var ex = await Assert.ThrowsAsync<SendFailedException>(() =>
            provider.ChatAsync(new[] { ChatMessage.FromText(ChatRole.User, "x") }, DefaultConfig()));
        Assert.Contains("500", ex.Message);
        Assert.Contains("crash", ex.Message);
    }
}
