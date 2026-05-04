using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KosmoNotes.Core.Models;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// <see cref="IAIProvider"/> for OpenAI's Chat Completions API
/// (<c>POST https://api.openai.com/v1/chat/completions</c>).
/// </summary>
/// <remarks>
/// OpenAI treats <c>system</c> as a regular role in the messages array.
/// When <see cref="AIConfig.SystemPrompt"/> is set it is prepended as the
/// first message.
///
/// Multipart messages: text parts become <c>{"type":"text","text":"..."}</c>;
/// image parts become <c>{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}</c>.
/// A message with a single text part is sent as a plain string.
/// </remarks>
public sealed class OpenAIProvider : IAIProvider
{
    /// <summary>The API endpoint URL when no override is supplied.</summary>
    public static readonly Uri DefaultEndpoint =
        new("https://api.openai.com/v1/chat/completions");

    /// <summary>The model identifier OpenAI callers usually default to.</summary>
    public const string DefaultModel = "gpt-4o-mini";

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly HttpClient _httpClient;

    /// <summary>Create a provider using the given API key.</summary>
    /// <param name="apiKey">OpenAI API key (sent as <c>Authorization: Bearer …</c>).</param>
    /// <param name="endpoint">
    /// Optional endpoint override. Defaults to <see cref="DefaultEndpoint"/>.
    /// </param>
    /// <param name="httpClient">
    /// Optional client for tests; uses a process-wide default when null.
    /// </param>
    public OpenAIProvider(string apiKey, Uri? endpoint = null, HttpClient? httpClient = null)
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
    /// Build the request message — internal so other OpenAI-compat providers
    /// (OpenRouter, Ollama-OpenAICompat) can reuse the body builder.
    /// </summary>
    internal static HttpRequestMessage BuildRequest(
        Uri endpoint,
        string apiKey,
        IReadOnlyList<ChatMessage> messages,
        AIConfig config)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        string json = BuildBodyJson(messages, config);
        request.Content = new StringContent(json, Encoding.UTF8);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    /// <summary>
    /// Build the JSON body. Shared with <see cref="OpenRouterProvider"/> and
    /// the OpenAI-compat path of <see cref="OllamaProvider"/>.
    /// </summary>
    internal static string BuildBodyJson(IReadOnlyList<ChatMessage> messages, AIConfig config)
    {
        var allMessages = new List<ChatMessage>(messages.Count + 1);
        if (config.SystemPrompt is { } systemPrompt)
        {
            allMessages.Add(ChatMessage.FromText(ChatRole.System, systemPrompt));
        }
        allMessages.AddRange(messages);

        var body = new JsonObject
        {
            ["model"] = config.Model,
            ["max_tokens"] = config.MaxTokens,
            ["temperature"] = config.Temperature,
            ["messages"] = SerializeMessages(allMessages),
        };
        return body.ToJsonString();
    }

    /// <summary>Parse a 200-response body and return the first choice's content.</summary>
    internal static string Parse(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (!root.TryGetProperty("choices", out var choices) ||
                choices.ValueKind != JsonValueKind.Array ||
                choices.GetArrayLength() == 0)
            {
                throw new DecodingFailedException("No choices in response");
            }
            var first = choices[0];
            if (!first.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content))
            {
                throw new DecodingFailedException("Missing message.content in choice.");
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

    internal static JsonNode SerializeParts(IReadOnlyList<ChatPart> parts)
    {
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
                    string dataUrl = $"data:{img.MimeType};base64,{Convert.ToBase64String(img.JpegData)}";
                    arr.Add(new JsonObject
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new JsonObject { ["url"] = dataUrl },
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
