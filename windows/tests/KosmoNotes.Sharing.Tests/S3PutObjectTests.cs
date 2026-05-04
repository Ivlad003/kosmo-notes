using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace KosmoNotes.Sharing.Tests;

public class S3PutObjectTests
{
    private static SigV4.Credentials Creds => new(
        AccessKeyId: "AKIAIOSFODNN7EXAMPLE",
        SecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");

    /// <summary>HttpMessageHandler that captures the outgoing request and returns a fixed response.</summary>
    private sealed class CapturingHandler : HttpMessageHandler
    {
        public HttpRequestMessage? Captured { get; private set; }
        public byte[]? CapturedBody { get; private set; }
        public HttpStatusCode StatusCode { get; set; } = HttpStatusCode.OK;
        public string ResponseBody { get; set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Captured = request;
            if (request.Content is not null)
            {
                CapturedBody = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            }
            return new HttpResponseMessage(StatusCode)
            {
                Content = new StringContent(ResponseBody, Encoding.UTF8, "text/plain"),
            };
        }
    }

    [Fact]
    public async Task PutObject_SendsCorrectHttpRequest()
    {
        var handler = new CapturingHandler();
        using var http = new HttpClient(handler);
        var client = new S3Client(
            endpoint: new Uri("https://s3.amazonaws.com"),
            region: "us-east-1",
            bucket: "mybucket",
            credentials: Creds,
            httpClient: http);

        var data = Encoding.UTF8.GetBytes("hello world");
        var url = await client.PutObjectAsync(
            "path/to/file.txt", data,
            contentType: "text/plain",
            now: DateTimeOffset.FromUnixTimeSeconds(1_369_353_600));

        Assert.Equal("https://s3.amazonaws.com/mybucket/path/to/file.txt", url.ToString());

        var req = handler.Captured!;
        Assert.Equal(HttpMethod.Put, req.Method);
        Assert.Equal("https://s3.amazonaws.com/mybucket/path/to/file.txt", req.RequestUri!.AbsoluteUri);

        // x-amz-content-sha256 == SHA-256 of the body.
        var hash = SigV4.Sha256Hex(data);
        Assert.Equal(hash, req.Headers.GetValues("x-amz-content-sha256").Single());

        // x-amz-date pinned by `now`.
        Assert.Equal("20130524T000000Z", req.Headers.GetValues("x-amz-date").Single());

        // Authorization header — read via raw header values because HttpClient
        // may not parse the comma-delimited Sig V4 param list into Authorization.
        var authRaw = req.Headers.GetValues("Authorization").Single();
        Assert.StartsWith(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
            authRaw);
        Assert.Contains(
            "SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date",
            authRaw);
        Assert.Contains("Signature=", authRaw);

        // Content-Type set on the content (Sig V4 also signs it).
        Assert.Equal("text/plain", req.Content!.Headers.ContentType!.MediaType);

        // Body bytes match.
        Assert.Equal(data, handler.CapturedBody);

        // Content-Length matches.
        Assert.Equal(data.LongLength, req.Content.Headers.ContentLength);
    }

    [Fact]
    public async Task PutObject_NonSuccessStatusThrowsS3Exception()
    {
        var handler = new CapturingHandler
        {
            StatusCode = HttpStatusCode.Forbidden,
            ResponseBody = "<Error><Code>AccessDenied</Code></Error>",
        };
        using var http = new HttpClient(handler);
        var client = new S3Client(
            endpoint: new Uri("https://s3.amazonaws.com"),
            region: "us-east-1",
            bucket: "mybucket",
            credentials: Creds,
            httpClient: http);

        var ex = await Assert.ThrowsAsync<S3Exception>(() =>
            client.PutObjectAsync("k", Array.Empty<byte>()));

        Assert.Equal(403, ex.StatusCode);
        Assert.Contains("AccessDenied", ex.ResponseBody);
    }

    [Fact]
    public async Task PutObject_500StatusAlsoThrows()
    {
        var handler = new CapturingHandler { StatusCode = HttpStatusCode.InternalServerError };
        using var http = new HttpClient(handler);
        var client = new S3Client(
            endpoint: new Uri("https://s3.amazonaws.com"),
            region: "us-east-1",
            bucket: "mybucket",
            credentials: Creds,
            httpClient: http);

        var ex = await Assert.ThrowsAsync<S3Exception>(() =>
            client.PutObjectAsync("k", new byte[] { 1, 2, 3 }));
        Assert.Equal(500, ex.StatusCode);
    }

    [Fact]
    public async Task PutObject_ContentTypeDefaultIsOctetStream()
    {
        var handler = new CapturingHandler();
        using var http = new HttpClient(handler);
        var client = new S3Client(
            endpoint: new Uri("https://s3.amazonaws.com"),
            region: "us-east-1",
            bucket: "mybucket",
            credentials: Creds,
            httpClient: http);

        await client.PutObjectAsync("k", new byte[] { 1, 2, 3 });

        Assert.Equal(
            "application/octet-stream",
            handler.Captured!.Content!.Headers.ContentType!.MediaType);
    }

    [Fact]
    public async Task PutObject_EmptyBodyHasEmptyPayloadHash()
    {
        var handler = new CapturingHandler();
        using var http = new HttpClient(handler);
        var client = new S3Client(
            endpoint: new Uri("https://s3.amazonaws.com"),
            region: "us-east-1",
            bucket: "mybucket",
            credentials: Creds,
            httpClient: http);

        await client.PutObjectAsync("k", Array.Empty<byte>());

        Assert.Equal(
            SigV4.EmptyPayloadHash,
            handler.Captured!.Headers.GetValues("x-amz-content-sha256").Single());
    }
}
