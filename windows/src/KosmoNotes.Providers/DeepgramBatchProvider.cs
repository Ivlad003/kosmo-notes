using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Core.Transcription;
using KosmoNotes.Providers.Internal;

namespace KosmoNotes.Providers;

/// <summary>
/// <see cref="IBatchTranscriptionProvider"/> over Deepgram's REST endpoint
/// <c>https://api.deepgram.com/v1/listen</c>. Mirrors the Swift
/// <c>DeepgramBatchProvider</c>.
/// </summary>
/// <remarks>
/// Uploads the whole audio file after stop and gets back a single transcript
/// with word-level timestamps. Words are grouped into ~5 s segments so the
/// Library transcript view stays readable.
/// </remarks>
public sealed class DeepgramBatchProvider : IBatchTranscriptionProvider
{
    /// <summary>The default batch listen endpoint.</summary>
    public static readonly Uri DefaultEndpoint =
        new("https://api.deepgram.com/v1/listen");

    /// <summary>The model used by default.</summary>
    public const string DefaultModel = "nova-2";

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly string _model;
    private readonly HttpClient _httpClient;

    /// <summary>Create a provider using the given API key.</summary>
    /// <param name="apiKey">Deepgram API key (sent as <c>Authorization: Token …</c>).</param>
    /// <param name="endpoint">Optional endpoint override.</param>
    /// <param name="model">Model identifier; defaults to <see cref="DefaultModel"/>.</param>
    /// <param name="httpClient">Optional client for tests.</param>
    public DeepgramBatchProvider(
        string apiKey,
        Uri? endpoint = null,
        string model = DefaultModel,
        HttpClient? httpClient = null)
    {
        _apiKey = apiKey;
        _endpoint = endpoint ?? DefaultEndpoint;
        _model = model;
        _httpClient = httpClient ?? HttpDefaults.Default;
    }

    /// <inheritdoc />
    public async Task<BatchTranscriptResult> TranscribeAsync(
        string audioFilePath,
        TranscriptionConfig config,
        CancellationToken ct = default)
    {
        byte[] audioData;
        try
        {
            audioData = await File.ReadAllBytesAsync(audioFilePath, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new SendFailedException($"Could not read audio file: {ex.Message}", ex);
        }

        var url = BuildUrl(_endpoint, _model, config.Language);
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.TryAddWithoutValidation("Authorization", $"Token {_apiKey}");

        var content = new ByteArrayContent(audioData);
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/m4a");
        request.Content = content;

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
    /// Build the GET URL with query items in fixed insertion order
    /// (<c>model</c>, <c>punctuate</c>, <c>smart_format</c>, optional
    /// <c>language</c>). Skips language when null/empty/<c>"auto"</c>.
    /// </summary>
    internal static Uri BuildUrl(Uri endpoint, string model, string? language)
    {
        var sb = new StringBuilder();
        sb.Append(endpoint.GetLeftPart(UriPartial.Path));
        sb.Append('?');
        sb.Append("model=").Append(Uri.EscapeDataString(model));
        sb.Append('&').Append("punctuate=true");
        sb.Append('&').Append("smart_format=true");
        if (!string.IsNullOrEmpty(language) &&
            !string.Equals(language, "auto", StringComparison.OrdinalIgnoreCase))
        {
            sb.Append('&').Append("language=").Append(Uri.EscapeDataString(language));
        }
        return new Uri(sb.ToString());
    }

    /// <summary>
    /// Parse a Deepgram batch JSON response into a <see cref="BatchTranscriptResult"/>.
    /// Mirrors the Swift cursor-based 5-second word-grouping loop exactly.
    /// </summary>
    internal static BatchTranscriptResult Parse(byte[] data)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(data);
        }
        catch (JsonException ex)
        {
            throw new DecodingFailedException(ex.Message, ex);
        }

        using (doc)
        {
            var root = doc.RootElement;

            if (!root.TryGetProperty("results", out var results) ||
                !results.TryGetProperty("channels", out var channels) ||
                channels.ValueKind != JsonValueKind.Array ||
                channels.GetArrayLength() == 0)
            {
                throw new DecodingFailedException("No transcript channels in response.");
            }

            var channel = channels[0];
            if (!channel.TryGetProperty("alternatives", out var alternatives) ||
                alternatives.ValueKind != JsonValueKind.Array ||
                alternatives.GetArrayLength() == 0)
            {
                throw new DecodingFailedException("No alternatives in channel.");
            }

            var alt = alternatives[0];
            if (!alt.TryGetProperty("transcript", out var transcriptEl) ||
                transcriptEl.ValueKind != JsonValueKind.String)
            {
                throw new DecodingFailedException("Missing transcript text.");
            }
            string transcript = transcriptEl.GetString() ?? string.Empty;

            double duration = 0;
            if (root.TryGetProperty("metadata", out var metadata) &&
                metadata.TryGetProperty("duration", out var durEl) &&
                durEl.ValueKind == JsonValueKind.Number)
            {
                duration = durEl.GetDouble();
            }

            string? language = null;
            if (channel.TryGetProperty("detected_language", out var langEl) &&
                langEl.ValueKind == JsonValueKind.String)
            {
                language = langEl.GetString();
            }

            // Materialize words once.
            var words = new List<DgWord>();
            if (alt.TryGetProperty("words", out var wordsEl) &&
                wordsEl.ValueKind == JsonValueKind.Array)
            {
                foreach (var w in wordsEl.EnumerateArray())
                {
                    double start = w.TryGetProperty("start", out var s) ? s.GetDouble() : 0;
                    double end = w.TryGetProperty("end", out var e) ? e.GetDouble() : 0;
                    string? punct = w.TryGetProperty("punctuated_word", out var p) &&
                                    p.ValueKind == JsonValueKind.String
                        ? p.GetString()
                        : null;
                    string word = w.TryGetProperty("word", out var ww) ? ww.GetString() ?? string.Empty : string.Empty;
                    words.Add(new DgWord(start, end, word, punct));
                }
            }

            var segments = new List<TranscriptSegment>();
            if (words.Count == 0)
            {
                segments.Add(new TranscriptSegment(
                    Start: 0,
                    End: duration,
                    Text: transcript,
                    Confidence: 1.0,
                    IsFinal: true,
                    Speaker: null));
            }
            else
            {
                int cursor = 0;
                while (cursor < words.Count)
                {
                    double segmentStart = words[cursor].Start;
                    double cutoff = segmentStart + 5.0;
                    int endIndex = cursor;
                    while (endIndex < words.Count && words[endIndex].End <= cutoff)
                    {
                        endIndex++;
                    }
                    if (endIndex == cursor) endIndex = cursor + 1;

                    var sb = new StringBuilder();
                    for (int i = cursor; i < endIndex; i++)
                    {
                        if (i > cursor) sb.Append(' ');
                        sb.Append(words[i].Punctuated ?? words[i].Word);
                    }
                    double segmentEnd = words[endIndex - 1].End;
                    segments.Add(new TranscriptSegment(
                        Start: segmentStart,
                        End: segmentEnd,
                        Text: sb.ToString(),
                        Confidence: 1.0,
                        IsFinal: true,
                        Speaker: null));
                    cursor = endIndex;
                }
            }

            return new BatchTranscriptResult(language, duration, segments, transcript);
        }
    }

    private readonly record struct DgWord(double Start, double End, string Word, string? Punctuated);
}
