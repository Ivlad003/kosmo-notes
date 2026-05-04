using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using KosmoNotes.Core.Models;
using KosmoNotes.Core.Transcription;
using KosmoNotes.Providers.Tests.Support;

namespace KosmoNotes.Providers.Tests;

public class DeepgramBatchProviderTests
{
    private static string TempAudioFile(byte[]? bytes = null)
    {
        var path = Path.Combine(Path.GetTempPath(),
            $"dg-batch-{Guid.NewGuid():N}.m4a");
        File.WriteAllBytes(path, bytes ?? new byte[] { 0x00, 0x01, 0x02, 0x03 });
        return path;
    }

    private static string SyntheticDeepgramJson(int wordCount, double secondsPerWord, double duration, string? language = null, string? transcript = null)
    {
        var sb = new StringBuilder();
        sb.Append("""{"results":{"channels":[{""");
        if (language is not null)
        {
            sb.Append("\"detected_language\":\"").Append(language).Append("\",");
        }
        sb.Append("\"alternatives\":[{");
        sb.Append("\"transcript\":\"").Append(transcript ?? string.Join(' ', Enumerable.Range(0, wordCount).Select(i => $"w{i}"))).Append("\",");
        sb.Append("\"words\":[");
        for (int i = 0; i < wordCount; i++)
        {
            if (i > 0) sb.Append(',');
            double start = i * secondsPerWord;
            double end = start + secondsPerWord;
            sb.Append('{')
              .Append("\"start\":").Append(start.ToString(System.Globalization.CultureInfo.InvariantCulture))
              .Append(",\"end\":").Append(end.ToString(System.Globalization.CultureInfo.InvariantCulture))
              .Append(",\"word\":\"w").Append(i).Append("\"")
              .Append(",\"punctuated_word\":\"w").Append(i).Append("\"")
              .Append('}');
        }
        sb.Append("]}]}]},\"metadata\":{\"duration\":")
          .Append(duration.ToString(System.Globalization.CultureInfo.InvariantCulture))
          .Append("}}");
        return sb.ToString();
    }

    // ---- URL builder ------------------------------------------------------

    [Fact]
    public void BuildUrl_DefaultLanguageNull_OmitsLanguageParam()
    {
        var url = DeepgramBatchProvider.BuildUrl(
            new Uri("https://api.deepgram.com/v1/listen"), "nova-2", null);
        Assert.Equal("https://api.deepgram.com/v1/listen?model=nova-2&punctuate=true&smart_format=true", url.ToString());
    }

    [Fact]
    public void BuildUrl_LanguageAuto_OmitsLanguageParam()
    {
        var url = DeepgramBatchProvider.BuildUrl(
            new Uri("https://api.deepgram.com/v1/listen"), "nova-2", "auto");
        Assert.DoesNotContain("language=", url.ToString());
    }

    [Fact]
    public void BuildUrl_LanguageEmpty_OmitsLanguageParam()
    {
        var url = DeepgramBatchProvider.BuildUrl(
            new Uri("https://api.deepgram.com/v1/listen"), "nova-2", "");
        Assert.DoesNotContain("language=", url.ToString());
    }

    [Fact]
    public void BuildUrl_LanguageSet_AppendsAtEnd()
    {
        var url = DeepgramBatchProvider.BuildUrl(
            new Uri("https://api.deepgram.com/v1/listen"), "nova-2", "uk");
        Assert.EndsWith("&language=uk", url.ToString());
    }

    [Fact]
    public void BuildUrl_PreservesOrder_ModelPunctuateSmartFormatLanguage()
    {
        var url = DeepgramBatchProvider.BuildUrl(
            new Uri("https://api.deepgram.com/v1/listen"), "nova-2", "en-US");
        var q = url.Query;
        int model = q.IndexOf("model=", StringComparison.Ordinal);
        int punctuate = q.IndexOf("punctuate=", StringComparison.Ordinal);
        int smart = q.IndexOf("smart_format=", StringComparison.Ordinal);
        int lang = q.IndexOf("language=", StringComparison.Ordinal);
        Assert.True(model < punctuate);
        Assert.True(punctuate < smart);
        Assert.True(smart < lang);
    }

    // ---- Request shape ----------------------------------------------------

    [Fact]
    public async Task TranscribeAsync_PostsAudioBytes_WithTokenAuthAndAudioM4aContentType()
    {
        var bytes = new byte[] { 0xFF, 0xEE, 0xDD, 0xCC, 0x00 };
        var path = TempAudioFile(bytes);
        try
        {
            var handler = CapturingHandler.RespondingJson(SyntheticDeepgramJson(2, 0.5, 1.0));
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("dg-key", httpClient: http);

            await provider.TranscribeAsync(path, new TranscriptionConfig(null));

            Assert.Equal(HttpMethod.Post, handler.CapturedRequest!.Method);
            Assert.Equal("audio/m4a", handler.CapturedContentType);
            Assert.Equal(bytes, handler.CapturedBody);
            Assert.Equal("Token dg-key",
                string.Join(",", handler.CapturedRequest.Headers.GetValues("Authorization")));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task TranscribeAsync_LanguagePassthroughInUrl()
    {
        var path = TempAudioFile();
        try
        {
            var handler = CapturingHandler.RespondingJson(SyntheticDeepgramJson(1, 0.5, 0.5));
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("k", httpClient: http);

            await provider.TranscribeAsync(path, new TranscriptionConfig("uk"));

            Assert.Contains("language=uk", handler.CapturedRequest!.RequestUri!.Query);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task TranscribeAsync_AutoLanguageOmitted()
    {
        var path = TempAudioFile();
        try
        {
            var handler = CapturingHandler.RespondingJson(SyntheticDeepgramJson(1, 0.5, 0.5));
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("k", httpClient: http);

            await provider.TranscribeAsync(path, new TranscriptionConfig("auto"));

            Assert.DoesNotContain("language=", handler.CapturedRequest!.RequestUri!.Query);
        }
        finally
        {
            File.Delete(path);
        }
    }

    // ---- Parser -----------------------------------------------------------

    [Fact]
    public void Parse_TwelveWords_ProducesThreeFiveSecondSegments()
    {
        // 12 words at 1 second each → 0–5, 5–10, 10–12.
        var json = SyntheticDeepgramJson(wordCount: 12, secondsPerWord: 1.0, duration: 12.0);
        var data = Encoding.UTF8.GetBytes(json);

        var result = DeepgramBatchProvider.Parse(data);

        Assert.Equal(12.0, result.Duration);
        Assert.Equal(3, result.Segments.Count);
        Assert.Equal(0.0, result.Segments[0].Start);
        Assert.Equal(5.0, result.Segments[0].End);
        Assert.Equal(5.0, result.Segments[1].Start);
        Assert.Equal(10.0, result.Segments[1].End);
        Assert.Equal(10.0, result.Segments[2].Start);
        Assert.Equal(12.0, result.Segments[2].End);
        Assert.True(result.Segments.All(s => s.IsFinal));
    }

    [Fact]
    public void Parse_NoWordsArray_ProducesSingleSyntheticSegment()
    {
        const string json = """
        {"results":{"channels":[{"alternatives":[{"transcript":"hello world"}]}]},"metadata":{"duration":3.5}}
        """;
        var result = DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json));

        Assert.Single(result.Segments);
        Assert.Equal("hello world", result.Segments[0].Text);
        Assert.Equal(0.0, result.Segments[0].Start);
        Assert.Equal(3.5, result.Segments[0].End);
        Assert.Equal("hello world", result.Text);
    }

    [Fact]
    public void Parse_DetectedLanguagePassthrough()
    {
        var json = SyntheticDeepgramJson(2, 0.5, 1.0, language: "uk");
        var result = DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json));
        Assert.Equal("uk", result.Language);
    }

    [Fact]
    public void Parse_NoChannels_Throws()
    {
        const string json = """{"results":{"channels":[]}}""";
        Assert.Throws<DecodingFailedException>(
            () => DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void Parse_NoAlternatives_Throws()
    {
        const string json = """{"results":{"channels":[{"alternatives":[]}]}}""";
        Assert.Throws<DecodingFailedException>(
            () => DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void Parse_NoTranscript_Throws()
    {
        const string json = """{"results":{"channels":[{"alternatives":[{}]}]}}""";
        Assert.Throws<DecodingFailedException>(
            () => DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void Parse_MalformedJson_Throws()
    {
        Assert.Throws<DecodingFailedException>(
            () => DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes("not json")));
    }

    [Fact]
    public void Parse_PrefersPunctuatedWordOverWord()
    {
        const string json = """
        {"results":{"channels":[{"alternatives":[{"transcript":"Hi.","words":[
          {"start":0,"end":0.5,"word":"hi","punctuated_word":"Hi."}
        ]}]}]},"metadata":{"duration":0.5}}
        """;
        var result = DeepgramBatchProvider.Parse(Encoding.UTF8.GetBytes(json));
        Assert.Equal("Hi.", result.Segments[0].Text);
    }

    // ---- Error mapping ----------------------------------------------------

    [Fact]
    public async Task TranscribeAsync_401_ThrowsAuthenticationFailed()
    {
        var path = TempAudioFile();
        try
        {
            var handler = CapturingHandler.RespondingText("no", HttpStatusCode.Unauthorized);
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("k", httpClient: http);

            await Assert.ThrowsAsync<AuthenticationFailedException>(() =>
                provider.TranscribeAsync(path, new TranscriptionConfig(null)));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task TranscribeAsync_429_ThrowsRateLimited()
    {
        var path = TempAudioFile();
        try
        {
            var handler = CapturingHandler.RespondingText("slow", (HttpStatusCode)429);
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("k", httpClient: http);

            await Assert.ThrowsAsync<RateLimitedException>(() =>
                provider.TranscribeAsync(path, new TranscriptionConfig(null)));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task TranscribeAsync_500_ThrowsSendFailedWithBody()
    {
        var path = TempAudioFile();
        try
        {
            var handler = CapturingHandler.RespondingText("crash", HttpStatusCode.InternalServerError);
            using var http = new HttpClient(handler);
            var provider = new DeepgramBatchProvider("k", httpClient: http);

            var ex = await Assert.ThrowsAsync<SendFailedException>(() =>
                provider.TranscribeAsync(path, new TranscriptionConfig(null)));
            Assert.Contains("500", ex.Message);
            Assert.Contains("crash", ex.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task TranscribeAsync_MissingFile_ThrowsSendFailed()
    {
        var handler = CapturingHandler.RespondingJson("""{}""");
        using var http = new HttpClient(handler);
        var provider = new DeepgramBatchProvider("k", httpClient: http);

        await Assert.ThrowsAsync<SendFailedException>(() =>
            provider.TranscribeAsync("/nope/does/not/exist.m4a", new TranscriptionConfig(null)));
    }
}
