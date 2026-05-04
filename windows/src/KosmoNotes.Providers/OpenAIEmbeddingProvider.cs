using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// <see cref="IEmbeddingProvider"/> for OpenAI's
/// <c>text-embedding-3-small</c> model — 1536 dimensions, $0.02/1M tokens.
/// Cheap enough that hundreds of hour-long transcripts cost cents to index.
/// </summary>
public sealed class OpenAIEmbeddingProvider : IEmbeddingProvider
{
    /// <summary>The default embeddings endpoint.</summary>
    public static readonly Uri DefaultEndpoint =
        new("https://api.openai.com/v1/embeddings");

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly HttpClient _httpClient;

    /// <inheritdoc />
    public string ModelIdentifier => "text-embedding-3-small";

    /// <inheritdoc />
    public int Dimensions => 1536;

    /// <summary>Create a provider using the given API key.</summary>
    /// <param name="apiKey">OpenAI API key.</param>
    /// <param name="endpoint">Optional endpoint override.</param>
    /// <param name="httpClient">Optional client for tests.</param>
    public OpenAIEmbeddingProvider(string apiKey, Uri? endpoint = null, HttpClient? httpClient = null)
    {
        _apiKey = apiKey;
        _endpoint = endpoint ?? DefaultEndpoint;
        _httpClient = httpClient ?? HttpDefaults.Default;
    }

    /// <inheritdoc />
    public async Task<float[]> EmbedAsync(string text, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);

        // The endpoint truncates at 8191 tokens; long transcripts must be
        // split by the caller. Mirrors Swift's "trust the caller" comment.
        var body = new JsonObject
        {
            ["model"] = ModelIdentifier,
            ["input"] = text,
            ["encoding_format"] = "float",
        };
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            throw new SendFailedException(ex.Message, ex);
        }

        try
        {
            await HttpStatus.ThrowIfNotSuccessAsync(response, ct).ConfigureAwait(false);
            byte[] data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            try
            {
                using var doc = JsonDocument.Parse(data);
                if (!doc.RootElement.TryGetProperty("data", out var arr) ||
                    arr.ValueKind != JsonValueKind.Array ||
                    arr.GetArrayLength() == 0)
                {
                    throw new DecodingFailedException("No embedding in response");
                }
                if (!arr[0].TryGetProperty("embedding", out var emb) ||
                    emb.ValueKind != JsonValueKind.Array)
                {
                    throw new DecodingFailedException("Missing 'embedding' array.");
                }

                int n = emb.GetArrayLength();
                var result = new float[n];
                int i = 0;
                foreach (var v in emb.EnumerateArray())
                {
                    result[i++] = v.GetSingle();
                }
                return result;
            }
            catch (DecodingFailedException)
            {
                throw;
            }
            catch (JsonException ex)
            {
                throw new DecodingFailedException(ex.Message, ex);
            }
        }
        finally
        {
            response.Dispose();
        }
    }
}
