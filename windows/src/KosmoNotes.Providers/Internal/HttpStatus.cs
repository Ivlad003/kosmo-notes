using System.Net;
using System.Net.Http;
using KosmoNotes.Core.Models;

namespace KosmoNotes.Providers.Internal;

/// <summary>
/// Translates an HTTP response status into the matching <see cref="AIException"/>
/// subtype so providers can share one tiny error-mapping helper.
/// </summary>
internal static class HttpStatus
{
    /// <summary>
    /// If the response is not a success, throw the appropriate
    /// <see cref="AIException"/> subtype. Caller may pass a label describing
    /// the provider for the fall-through "HTTP &lt;code&gt;: &lt;body&gt;" message.
    /// </summary>
    public static async Task ThrowIfNotSuccessAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode) return;

        switch ((int)response.StatusCode)
        {
            case 401:
                throw new AuthenticationFailedException();
            case 429:
                throw new RateLimitedException();
            default:
                string body = await ReadBodySafeAsync(response, ct).ConfigureAwait(false);
                throw new SendFailedException($"HTTP {(int)response.StatusCode}: {body}");
        }
    }

    /// <summary>Read the response body as a string, swallowing any read failure.</summary>
    public static async Task<string> ReadBodySafeAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            return await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            return "<unreadable body>";
        }
    }
}
