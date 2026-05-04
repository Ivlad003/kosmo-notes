using System.Net;
using System.Net.Http;

namespace KosmoNotes.Providers.Tests.Support;

/// <summary>
/// Test handler that captures the outgoing request, returns a canned response,
/// and exposes a copy of the request body for inspection. The body is read
/// before the response is returned because <see cref="HttpClient"/> disposes
/// the request content during <see cref="HttpClient.SendAsync(HttpRequestMessage, System.Threading.CancellationToken)"/>.
/// </summary>
public sealed class CapturingHandler : HttpMessageHandler
{
    /// <summary>The captured request (without its content stream).</summary>
    public HttpRequestMessage? CapturedRequest { get; private set; }

    /// <summary>The captured request body bytes (or null if no body).</summary>
    public byte[]? CapturedBody { get; private set; }

    /// <summary>The captured request body decoded as UTF-8 (or null if no body).</summary>
    public string? CapturedBodyText { get; private set; }

    /// <summary>The captured Content-Type header from the request body, if any.</summary>
    public string? CapturedContentType { get; private set; }

    /// <summary>How many requests were sent through this handler.</summary>
    public int CallCount { get; private set; }

    /// <summary>Status code returned for the next response.</summary>
    public HttpStatusCode StatusCode { get; set; } = HttpStatusCode.OK;

    /// <summary>Body bytes returned for the next response.</summary>
    public byte[] ResponseBody { get; set; } = Array.Empty<byte>();

    /// <summary>Content-Type for the response body.</summary>
    public string ResponseContentType { get; set; } = "application/json";

    /// <summary>Helper that returns a JSON 200 response.</summary>
    public static CapturingHandler RespondingJson(string body, HttpStatusCode status = HttpStatusCode.OK)
    {
        return new CapturingHandler
        {
            StatusCode = status,
            ResponseBody = System.Text.Encoding.UTF8.GetBytes(body),
            ResponseContentType = "application/json",
        };
    }

    /// <summary>Helper that returns a plain-text response with the given status.</summary>
    public static CapturingHandler RespondingText(string body, HttpStatusCode status)
    {
        return new CapturingHandler
        {
            StatusCode = status,
            ResponseBody = System.Text.Encoding.UTF8.GetBytes(body),
            ResponseContentType = "text/plain",
        };
    }

    /// <inheritdoc />
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        CallCount++;
        CapturedRequest = request;
        if (request.Content is not null)
        {
            CapturedBody = await request.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            CapturedBodyText = System.Text.Encoding.UTF8.GetString(CapturedBody);
            CapturedContentType = request.Content.Headers.ContentType?.MediaType;
        }

        var response = new HttpResponseMessage(StatusCode)
        {
            Content = new ByteArrayContent(ResponseBody),
        };
        response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(ResponseContentType);
        return response;
    }
}
