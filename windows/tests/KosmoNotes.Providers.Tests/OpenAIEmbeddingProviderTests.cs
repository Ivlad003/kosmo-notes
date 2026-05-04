using System.Net;
using System.Net.Http;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class OpenAIEmbeddingProviderTests
{
    private static string OkBody(int dim)
    {
        var arr = new float[dim];
        for (int i = 0; i < dim; i++) arr[i] = (float)i / 1000f;
        var inner = string.Join(',', arr.Select(v => v.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return $$"""{"data":[{"embedding":[{{inner}}]}]}""";
    }

    [Fact]
    public void ModelIdentifierAndDimensions_AreFixed()
    {
        var p = new OpenAIEmbeddingProvider("k");
        Assert.Equal("text-embedding-3-small", p.ModelIdentifier);
        Assert.Equal(1536, p.Dimensions);
    }

    [Fact]
    public async Task EmbedAsync_PostsToConfiguredEndpoint_WithBearerAndJson()
    {
        var handler = CapturingHandler.RespondingJson(OkBody(8));
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider(
            "sk-emb",
            new Uri("https://example.test/v1/embeddings"),
            http);

        await provider.EmbedAsync("hello world");

        Assert.Equal(HttpMethod.Post, handler.CapturedRequest!.Method);
        Assert.Equal(new Uri("https://example.test/v1/embeddings"), handler.CapturedRequest.RequestUri);
        Assert.Equal("Bearer", handler.CapturedRequest.Headers.Authorization!.Scheme);
        Assert.Equal("sk-emb", handler.CapturedRequest.Headers.Authorization.Parameter);
        Assert.Equal("application/json", handler.CapturedContentType);
    }

    [Fact]
    public async Task EmbedAsync_BodyContainsModelInputAndEncodingFormat()
    {
        var handler = CapturingHandler.RespondingJson(OkBody(4));
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        await provider.EmbedAsync("the quick brown fox");

        using var doc = JsonDocument.Parse(handler.CapturedBody!);
        var root = doc.RootElement;
        Assert.Equal("text-embedding-3-small", root.GetProperty("model").GetString());
        Assert.Equal("the quick brown fox", root.GetProperty("input").GetString());
        Assert.Equal("float", root.GetProperty("encoding_format").GetString());
    }

    [Fact]
    public async Task EmbedAsync_ParsesFloatArrayInOrder()
    {
        var handler = CapturingHandler.RespondingJson(
            """{"data":[{"embedding":[0.1,0.2,-0.3,1.5]}]}""");
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        var v = await provider.EmbedAsync("x");
        Assert.Equal(new[] { 0.1f, 0.2f, -0.3f, 1.5f }, v);
    }

    [Fact]
    public async Task EmbedAsync_NoData_ThrowsDecodingFailed()
    {
        var handler = CapturingHandler.RespondingJson("""{"data":[]}""");
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        await Assert.ThrowsAsync<DecodingFailedException>(() => provider.EmbedAsync("x"));
    }

    [Fact]
    public async Task EmbedAsync_401_ThrowsAuthenticationFailed()
    {
        var handler = CapturingHandler.RespondingText("nope", HttpStatusCode.Unauthorized);
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        await Assert.ThrowsAsync<AuthenticationFailedException>(() => provider.EmbedAsync("x"));
    }

    [Fact]
    public async Task EmbedAsync_429_ThrowsRateLimited()
    {
        var handler = CapturingHandler.RespondingText("slow", (HttpStatusCode)429);
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        await Assert.ThrowsAsync<RateLimitedException>(() => provider.EmbedAsync("x"));
    }

    [Fact]
    public async Task EmbedAsync_500_ThrowsSendFailedWithBody()
    {
        var handler = CapturingHandler.RespondingText("err", HttpStatusCode.InternalServerError);
        using var http = new HttpClient(handler);
        var provider = new OpenAIEmbeddingProvider("k", httpClient: http);

        var ex = await Assert.ThrowsAsync<SendFailedException>(() => provider.EmbedAsync("x"));
        Assert.Contains("500", ex.Message);
        Assert.Contains("err", ex.Message);
    }
}
