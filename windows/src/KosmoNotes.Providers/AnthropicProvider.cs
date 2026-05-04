using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// <see cref="IAIProvider"/> for Anthropic's Messages API
/// (<c>POST https://api.anthropic.com/v1/messages</c>). Mirrors the Swift
/// <c>AnthropicProvider</c> exactly.
/// </summary>
/// <remarks>
/// Anthropic does not allow <c>"system"</c> role inside the messages array —
/// it must be a top-level <c>"system"</c> field. This provider filters
/// system messages out of the array and uses the last system message's
/// content as the top-level field, unless <see cref="AIConfig.SystemPrompt"/>
/// is set (which takes priority).
///
/// Multipart messages: text parts become <c>{"type":"text","text":"..."}</c>;
/// image parts become <c>{"type":"image","source":{"type":"base64",...}}</c>.
/// A message with a single text part is sent as a plain string, which is
/// what the API expects in the common case.
/// </remarks>
public sealed class AnthropicProvider : IAIProvider
{
    /// <summary>The API endpoint URL when no override is supplied.</summary>
    public static readonly Uri DefaultEndpoint =
        new("https://api.anthropic.com/v1/messages");

    /// <summary>The model identifier used by default in <see cref="AIConfig"/>.</summary>
    public const string DefaultModel = "claude-sonnet-4-6";

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly HttpClient _httpClient;

    /// <summary>Create a provider using the given API key.</summary>
    /// <param name="apiKey">Anthropic API key (sent as <c>x-api-key</c> header).</param>
    /// <param name="endpoint">
    /// Optional endpoint override. Defaults to <see cref="DefaultEndpoint"/>.
    /// </param>
    /// <param name="httpClient">
    /// Optional client for tests; uses a process-wide default when null.
    /// </param>
    public AnthropicProvider(string apiKey, Uri? endpoint = null, HttpClient? httpClient = null)
    {
        _apiKey = apiKey;
        _endpoint = endpoint ?? DefaultEndpoint;
        _httpClient = httpClient ?? HttpDefaults.Default;
    }

    /// <inheritdoc />
    public async Task<string> ChatAsync(
        IReadOnlyList<ChatMessage> messages,
        AIConfig config,
        CancellationToken ct = default)
    {
        using var request = BuildRequest(_endpoint, _apiKey, messages, config);

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
            return Parse(body);
        }
        finally
        {
            response.Dispose();
        }
    }

    /// <summary>
    /// Build the <see cref="HttpRequestMessage"/> for a chat call. Internal so
    /// tests can inspect the wire shape without making a real HTTP call.
    /// </summary>
    internal static HttpRequestMessage BuildRequest(
        Uri endpoint,
        string apiKey,
        IReadOnlyList<ChatMessage> messages,
        AIConfig config)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.TryAddWithoutValidation("x-api-key", apiKey);
        request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");

        // Separate system messages from conversation messages.
        // Anthropic rejects "system" role in the messages array;
        // use the last system message's content as the top-level field.
        var conversationMessages = messages.Where(m => m.Role != ChatRole.System).ToList();
        ChatMessage? lastSystem = messages.LastOrDefault(m => m.Role == ChatRole.System);

        // Prefer explicit config.SystemPrompt; fall back to last system message text.
        string? systemField = config.SystemPrompt ?? lastSystem?.Text;

        var body = new JsonObject
        {
            ["model"] = config.Model,
            ["max_tokens"] = config.MaxTokens,
            ["temperature"] = config.Temperature,
            ["messages"] = SerializeMessages(conversationMessages),
        };
        if (systemField is not null)
        {
            body["system"] = systemField;
        }

        string json = body.ToJsonString();
        request.Content = new StringContent(json, Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    /// <summary>Parse a 200-response body and concatenate all text blocks.</summary>
    internal static string Parse(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (!root.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array)
            {
                throw new DecodingFailedException("Missing 'content' array.");
            }

            var sb = new StringBuilder();
            foreach (var block in content.EnumerateArray())
            {
                if (block.TryGetProperty("type", out var type) &&
                    type.GetString() == "text" &&
                    block.TryGetProperty("text", out var text))
                {
                    sb.Append(text.GetString());
                }
            }
            return sb.ToString();
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

    private static JsonArray SerializeMessages(IEnumerable<ChatMessage> messages)
    {
        var arr = new JsonArray();
        foreach (var msg in messages)
        {
            arr.Add(new JsonObject
            {
                ["role"] = RoleToString(msg.Role),
                ["content"] = SerializeParts(msg.Parts),
            });
        }
        return arr;
    }

    private static JsonNode SerializeParts(IReadOnlyList<ChatPart> parts)
    {
        // Single text-only part: send as plain string for max API compatibility.
        if (parts.Count == 1 && parts[0] is TextPart only)
        {
            return JsonValue.Create(only.Text)!;
        }

        var arr = new JsonArray();
        foreach (var part in parts)
        {
            switch (part)
            {
                case TextPart t:
                    arr.Add(new JsonObject { ["type"] = "text", ["text"] = t.Text });
                    break;
                case ImagePart img:
                    arr.Add(new JsonObject
                    {
                        ["type"] = "image",
                        ["source"] = new JsonObject
                        {
                            ["type"] = "base64",
                            ["media_type"] = img.MimeType,
                            ["data"] = Convert.ToBase64String(img.JpegData),
                        },
                    });
                    break;
            }
        }
        return arr;
    }

    private static string RoleToString(ChatRole role) => role switch
    {
        ChatRole.System => "system",
        ChatRole.User => "user",
        ChatRole.Assistant => "assistant",
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };
}
