using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// API mode selector for <see cref="OllamaProvider"/>. Mirrors the Swift
/// <c>OllamaProvider.APIMode</c> enum.
/// </summary>
public enum OllamaApiMode
{
    /// <summary>Native Ollama JSON over <c>POST /api/chat</c>.</summary>
    Native,

    /// <summary>OpenAI-compatible payload over <c>POST /v1/chat/completions</c>.</summary>
    OpenAICompat,
}

/// <summary>
/// <see cref="IAIProvider"/> for Ollama's local inference server.
/// </summary>
/// <remarks>
/// <para>Two API modes selected at construction time:</para>
/// <list type="bullet">
///   <item><see cref="OllamaApiMode.Native"/>: <c>POST /api/chat</c> — native Ollama
///         JSON, <c>stream:false</c>.</item>
///   <item><see cref="OllamaApiMode.OpenAICompat"/>: <c>POST /v1/chat/completions</c>
///         — OpenAI-compatible payload.</item>
/// </list>
/// <para>Endpoint validation: <c>https</c> is allowed for any host;
/// <c>http</c> only for <c>localhost</c>, <c>127.0.0.1</c>, and the RFC-1918
/// private ranges (<c>10.*</c>, <c>192.168.*</c>, <c>172.16.*–172.31.*</c>).
/// Throws <see cref="InvalidEndpointException"/> from the constructor on
/// any other endpoint.</para>
/// </remarks>
public sealed class OllamaProvider : IAIProvider
{
    private readonly Uri _endpoint;
    private readonly OllamaApiMode _apiMode;
    private readonly string? _bearerToken;
    private readonly HttpClient _httpClient;

    /// <summary>Create a provider against the given Ollama endpoint.</summary>
    /// <param name="endpoint">Base endpoint (e.g. <c>http://localhost:11434</c>).</param>
    /// <param name="apiMode">Which API surface to call.</param>
    /// <param name="bearerToken">Optional Authorization header value (rare for local Ollama).</param>
    /// <param name="httpClient">Optional client for tests.</param>
    /// <exception cref="InvalidEndpointException">If the endpoint is not allowed.</exception>
    public OllamaProvider(
        Uri endpoint,
        OllamaApiMode apiMode = OllamaApiMode.Native,
        string? bearerToken = null,
        HttpClient? httpClient = null)
    {
        ValidateEndpoint(endpoint);
        _endpoint = endpoint;
        _apiMode = apiMode;
        _bearerToken = bearerToken;
        _httpClient = httpClient ?? HttpDefaults.Default;
    }

    /// <inheritdoc />
    public async Task<string> ChatAsync(
        IReadOnlyList<ChatMessage> messages,
        AIConfig config,
        CancellationToken ct = default)
    {
        using var request = _apiMode switch
        {
            OllamaApiMode.Native =>
                BuildNativeRequest(_endpoint, _bearerToken, messages, config),
            OllamaApiMode.OpenAICompat =>
                BuildOpenAICompatRequest(_endpoint, _bearerToken, messages, config),
            _ => throw new ArgumentOutOfRangeException(nameof(_apiMode)),
        };

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
            return _apiMode switch
            {
                OllamaApiMode.Native => ParseNative(body),
                OllamaApiMode.OpenAICompat => OpenAIProvider.Parse(body),
                _ => throw new ArgumentOutOfRangeException(),
            };
        }
        finally
        {
            response.Dispose();
        }
    }

    /// <summary>Lists available models via <c>GET /api/tags</c>.</summary>
    /// <param name="ct">Cancellation token.</param>
    public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct = default)
    {
        var url = AppendPath(_endpoint, "api/tags");
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (_bearerToken is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _bearerToken);
        }

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
            if (!response.IsSuccessStatusCode)
            {
                string body = await HttpStatus.ReadBodySafeAsync(response, ct).ConfigureAwait(false);
                throw new SendFailedException($"listModels failed: {body}");
            }

            byte[] data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            try
            {
                using var doc = JsonDocument.Parse(data);
                if (!doc.RootElement.TryGetProperty("models", out var models) ||
                    models.ValueKind != JsonValueKind.Array)
                {
                    return Array.Empty<string>();
                }
                var result = new List<string>(models.GetArrayLength());
                foreach (var m in models.EnumerateArray())
                {
                    if (m.TryGetProperty("name", out var name) &&
                        name.ValueKind == JsonValueKind.String)
                    {
                        result.Add(name.GetString()!);
                    }
                }
                return result;
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

    // ---- Endpoint validation ----------------------------------------------

    /// <summary>
    /// Validate that <paramref name="endpoint"/> is allowed (HTTPS anywhere;
    /// HTTP only for localhost / RFC-1918). Throws on failure.
    /// </summary>
    public static void ValidateEndpoint(Uri endpoint)
    {
        if (endpoint is null) throw new InvalidEndpointException();
        string scheme = endpoint.Scheme?.ToLowerInvariant() ?? string.Empty;
        if (scheme == "https") return;

        if (scheme != "http") throw new InvalidEndpointException();

        string host = endpoint.Host?.ToLowerInvariant() ?? string.Empty;
        if (string.IsNullOrEmpty(host)) throw new InvalidEndpointException();

        if (host == "localhost" || host == "127.0.0.1") return;
        if (host.StartsWith("10.", StringComparison.Ordinal)) return;
        if (host.StartsWith("192.168.", StringComparison.Ordinal)) return;
        if (IsPrivate172(host)) return;

        throw new InvalidEndpointException();
    }

    /// <summary>Returns true for hosts in the 172.16.0.0–172.31.255.255 range.</summary>
    internal static bool IsPrivate172(string host)
    {
        var parts = host.Split('.');
        if (parts.Length != 4) return false;
        if (parts[0] != "172") return false;
        if (!int.TryParse(parts[1], out int second)) return false;
        return second >= 16 && second <= 31;
    }

    // ---- Native request ---------------------------------------------------

    internal static HttpRequestMessage BuildNativeRequest(
        Uri endpoint,
        string? bearerToken,
        IReadOnlyList<ChatMessage> messages,
        AIConfig config)
    {
        var url = AppendPath(endpoint, "api/chat");
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        if (bearerToken is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        }

        var allMessages = new List<ChatMessage>(messages.Count + 1);
        if (config.SystemPrompt is { } systemPrompt)
        {
            allMessages.Add(ChatMessage.FromText(ChatRole.System, systemPrompt));
        }
        allMessages.AddRange(messages);

        var serialized = new JsonArray();
        foreach (var msg in allMessages)
        {
            serialized.Add(SerializeNativeMessage(msg));
        }

        var body = new JsonObject
        {
            ["model"] = config.Model,
            ["messages"] = serialized,
            ["stream"] = false,
            ["options"] = new JsonObject
            {
                ["temperature"] = config.Temperature,
                ["num_predict"] = config.MaxTokens,
            },
        };

        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    private static JsonObject SerializeNativeMessage(ChatMessage msg)
    {
        var textParts = new List<string>();
        var images = new List<string>();
        foreach (var part in msg.Parts)
        {
            switch (part)
            {
                case TextPart t:
                    textParts.Add(t.Text);
                    break;
                case ImagePart img:
                    images.Add(Convert.ToBase64String(img.JpegData));
                    break;
            }
        }

        var obj = new JsonObject
        {
            ["role"] = RoleToString(msg.Role),
            ["content"] = string.Join("\n", textParts),
        };
        if (images.Count > 0)
        {
            var imgs = new JsonArray();
            foreach (var b64 in images) imgs.Add(b64);
            obj["images"] = imgs;
        }
        return obj;
    }

    internal static string ParseNative(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (!doc.RootElement.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content))
            {
                throw new DecodingFailedException("Missing message.content in response.");
            }
            return content.GetString() ?? string.Empty;
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

    // ---- OpenAI-compat request --------------------------------------------

    internal static HttpRequestMessage BuildOpenAICompatRequest(
        Uri endpoint,
        string? bearerToken,
        IReadOnlyList<ChatMessage> messages,
        AIConfig config)
    {
        var url = AppendPath(endpoint, "v1/chat/completions");
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        if (bearerToken is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        }

        string json = OpenAIProvider.BuildBodyJson(messages, config);
        request.Content = new StringContent(json, Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    // ---- Helpers ----------------------------------------------------------

    /// <summary>
    /// Append <paramref name="path"/> to <paramref name="baseUri"/> mirroring
    /// Swift's <c>URL.appendingPathComponent</c> — preserves the existing
    /// path and adds a single slash separator.
    /// </summary>
    internal static Uri AppendPath(Uri baseUri, string path)
    {
        string left = baseUri.GetLeftPart(UriPartial.Authority);
        string existingPath = baseUri.AbsolutePath;
        if (!existingPath.EndsWith('/')) existingPath += "/";
        // Trim any leading slash on the suffix to avoid double-slash.
        string suffix = path.TrimStart('/');
        return new Uri(left + existingPath + suffix);
    }

    private static string RoleToString(ChatRole role) => role switch
    {
        ChatRole.System => "system",
        ChatRole.User => "user",
        ChatRole.Assistant => "assistant",
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };
}
