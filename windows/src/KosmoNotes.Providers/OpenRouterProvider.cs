using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// <see cref="IAIProvider"/> for OpenRouter
/// (<c>POST https://openrouter.ai/api/v1/chat/completions</c>).
/// </summary>
/// <remarks>
/// OpenRouter is OpenAI-compatible — same body shape, same response parser.
/// Two notable differences:
/// <list type="bullet">
///   <item>Model identifier is <c>vendor/model</c> instead of a bare model name.</item>
///   <item>Adds <c>HTTP-Referer</c> + <c>X-Title</c> attribution headers; without
///         them OpenRouter rate-limits more aggressively.</item>
/// </list>
/// </remarks>
public sealed class OpenRouterProvider : IAIProvider
{
    /// <summary>The OpenRouter chat-completions endpoint.</summary>
    public static readonly Uri DefaultEndpoint =
        new("https://openrouter.ai/api/v1/chat/completions");

    /// <summary>Default <c>HTTP-Referer</c> header value.</summary>
    public const string DefaultReferer = "https://kosmonotes.studio";

    /// <summary>Default <c>X-Title</c> header value.</summary>
    public const string DefaultTitle = "Jarvis Note";

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly string _referer;
    private readonly string _title;
    private readonly HttpClient _httpClient;

    /// <summary>Create a provider using the given API key.</summary>
    /// <param name="apiKey">OpenRouter API key (sent as <c>Authorization: Bearer …</c>).</param>
    /// <param name="endpoint">Optional endpoint override.</param>
    /// <param name="referer">Optional <c>HTTP-Referer</c> override.</param>
    /// <param name="title">Optional <c>X-Title</c> override.</param>
    /// <param name="httpClient">Optional client for tests.</param>
    public OpenRouterProvider(
        string apiKey,
        Uri? endpoint = null,
        string referer = DefaultReferer,
        string title = DefaultTitle,
        HttpClient? httpClient = null)
    {
        _apiKey = apiKey;
        _endpoint = endpoint ?? DefaultEndpoint;
        _referer = referer;
        _title = title;
        _httpClient = httpClient ?? HttpDefaults.Default;
    }

    /// <inheritdoc />
    public async Task<string> ChatAsync(
        IReadOnlyList<ChatMessage> messages,
        AIConfig config,
        CancellationToken ct = default)
    {
        using var request = BuildRequest(_endpoint, _apiKey, _referer, _title, messages, config);

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
            byte[] body = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            // OpenRouter shares OpenAI's response shape — reuse its parser.
            return OpenAIProvider.Parse(body);
        }
        finally
        {
            response.Dispose();
        }
    }

    internal static HttpRequestMessage BuildRequest(
        Uri endpoint,
        string apiKey,
        string referer,
        string title,
        IReadOnlyList<ChatMessage> messages,
        AIConfig config)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Headers.TryAddWithoutValidation("HTTP-Referer", referer);
        request.Headers.TryAddWithoutValidation("X-Title", title);

        string json = OpenAIProvider.BuildBodyJson(messages, config);
        request.Content = new StringContent(json, Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }
}
