using System.Globalization;
using System.Net.Http.Headers;
using System.Text;

namespace KosmoNotes.Sharing;

/// <summary>
/// Tiny S3-compatible client. Implements just enough of the S3 REST API for
/// upload + presigned GET. Compatible with AWS S3, Cloudflare R2 (region:
/// <c>auto</c>), Backblaze B2, MinIO, RustFS — anything that speaks S3 + Sig V4.
/// </summary>
public sealed class S3Client
{
    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    /// <summary>S3 endpoint root, e.g. <c>https://s3.amazonaws.com</c>.</summary>
    public Uri Endpoint { get; }

    /// <summary>AWS region, e.g. <c>us-east-1</c> or <c>auto</c> for R2.</summary>
    public string Region { get; }

    /// <summary>Bucket name.</summary>
    public string Bucket { get; }

    /// <summary>Access-key / secret credentials.</summary>
    public SigV4.Credentials Credentials { get; }

    /// <summary>
    /// Construct an S3 client. If <paramref name="httpClient"/> is null a default
    /// <see cref="HttpClient"/> is created and disposed with this instance.
    /// </summary>
    public S3Client(
        Uri endpoint,
        string region,
        string bucket,
        SigV4.Credentials credentials,
        HttpClient? httpClient = null)
    {
        Endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        Region = region ?? throw new ArgumentNullException(nameof(region));
        Bucket = bucket ?? throw new ArgumentNullException(nameof(bucket));
        Credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
        if (httpClient is null)
        {
            _httpClient = new HttpClient();
            _ownsHttpClient = true;
        }
        else
        {
            _httpClient = httpClient;
            _ownsHttpClient = false;
        }
    }

    /// <summary>
    /// Build the URL for a key under this bucket. Uses path-style addressing
    /// (<c>https://endpoint/bucket/key</c>) which works across all S3-compatibles.
    /// The key is split on '/' and each segment is AWS-encoded so safe characters
    /// in the key (slashes for prefixes) are preserved while spaces / unicode are
    /// percent-escaped.
    /// </summary>
    public Uri ObjectUrl(string key)
    {
        if (key is null) throw new ArgumentNullException(nameof(key));

        var endpointStr = Endpoint.GetLeftPart(UriPartial.Authority);
        var basePath = Endpoint.AbsolutePath.TrimEnd('/');

        // Path = <endpoint-path>/<bucket>/<encoded-key-segments-joined-by-/>
        var encodedBucket = SigV4.AwsEncode(Bucket, encodeSlash: true);
        var encodedKey = string.Join(
            "/",
            key.Split('/').Select(seg => SigV4.AwsEncode(seg, encodeSlash: true)));

        var path = basePath + "/" + encodedBucket + "/" + encodedKey;
        return new Uri(endpointStr + path);
    }

    // MARK: - PutObject

    /// <summary>
    /// Upload <paramref name="data"/> to <paramref name="key"/> with optional
    /// content-type. Returns the object URL. Signed via Sig V4 in the
    /// <c>Authorization</c> header. Throws <see cref="S3Exception"/> on non-2xx.
    /// </summary>
    public async Task<Uri> PutObjectAsync(
        string key,
        byte[] data,
        string contentType = "application/octet-stream",
        DateTimeOffset? now = null,
        CancellationToken ct = default)
    {
        if (key is null) throw new ArgumentNullException(nameof(key));
        if (data is null) throw new ArgumentNullException(nameof(data));

        var url = ObjectUrl(key);
        var host = url.Host;
        if (string.IsNullOrEmpty(host)) throw new S3Exception("Invalid S3 endpoint.");

        var stamp = now ?? DateTimeOffset.UtcNow;
        var amzDate = SigV4.AmzDateTime(stamp);
        var payloadHash = SigV4.Sha256Hex(data);
        var contentLength = data.Length.ToString(CultureInfo.InvariantCulture);

        // Include Host with port if the endpoint specifies one (mirrors what
        // HttpClient sends and what S3 validates).
        var hostHeader = url.IsDefaultPort ? host : $"{host}:{url.Port}";

        var headers = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["host"] = hostHeader,
            ["x-amz-date"] = amzDate,
            ["x-amz-content-sha256"] = payloadHash,
            ["content-type"] = contentType,
            ["content-length"] = contentLength,
        };

        // Sig V4 canonical request takes the *decoded* path; Canonicalize will
        // AWS-encode it. (Mirrors Swift's `url.path` which is also decoded.)
        var canonical = SigV4.Canonicalize(
            method: "PUT",
            path: Uri.UnescapeDataString(url.AbsolutePath),
            query: Array.Empty<KeyValuePair<string, string>>(),
            headers: headers,
            payloadHash: payloadHash);

        var toSign = SigV4.StringToSign(stamp, Region, "s3", canonical);
        var sig = SigV4.Signature(toSign, Credentials.SecretAccessKey, stamp, Region, "s3");
        var scope = $"{SigV4.AmzDateOnly(stamp)}/{Region}/s3/aws4_request";
        var auth =
            $"AWS4-HMAC-SHA256 Credential={Credentials.AccessKeyId}/{scope}, " +
            $"SignedHeaders={canonical.SignedHeaders}, Signature={sig}";

        // Build the HttpRequestMessage. Content-Type goes on Content; x-amz-* / Authorization on Headers.
        // HttpClient computes and sends Content-Length itself — we mustn't double-set it but it
        // *will* match the value we signed because the body is the exact array.
        using var request = new HttpRequestMessage(HttpMethod.Put, url)
        {
            Content = new ByteArrayContent(data),
        };
        request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        request.Headers.TryAddWithoutValidation("Host", hostHeader);
        request.Headers.TryAddWithoutValidation("x-amz-date", amzDate);
        request.Headers.TryAddWithoutValidation("x-amz-content-sha256", payloadHash);
        request.Headers.TryAddWithoutValidation("Authorization", auth);

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            throw new S3Exception("HTTP request failed: " + ex.Message, ex);
        }

        try
        {
            if ((int)response.StatusCode is < 200 or >= 300)
            {
                string body;
                try
                {
                    body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                }
                catch
                {
                    body = "<unreadable>";
                }
                throw new S3Exception(
                    $"S3 returned HTTP {(int)response.StatusCode}: {body}",
                    statusCode: (int)response.StatusCode,
                    responseBody: body);
            }
            return url;
        }
        finally
        {
            response.Dispose();
        }
    }

    // MARK: - Presigned GET

    /// <summary>
    /// Build a presigned GET URL. <paramref name="expirySeconds"/> is clamped to
    /// the AWS-spec range [1, 604800] (7 days max).
    /// </summary>
    public Uri PresignedGetUrl(string key, int expirySeconds, DateTimeOffset? now = null)
    {
        if (key is null) throw new ArgumentNullException(nameof(key));

        var url = ObjectUrl(key);
        var host = url.Host;
        if (string.IsNullOrEmpty(host)) throw new S3Exception("Invalid S3 endpoint.");

        var stamp = now ?? DateTimeOffset.UtcNow;
        var clampedExpiry = Math.Max(1, Math.Min(expirySeconds, 604_800));

        var amzDate = SigV4.AmzDateTime(stamp);
        var scope = $"{SigV4.AmzDateOnly(stamp)}/{Region}/s3/aws4_request";
        var hostHeader = url.IsDefaultPort ? host : $"{host}:{url.Port}";

        // Headers signed in the canonical request: only `host`.
        const string SignedHeaders = "host";
        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["host"] = hostHeader,
        };

        var baseQuery = new List<KeyValuePair<string, string>>
        {
            new("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            new("X-Amz-Credential", $"{Credentials.AccessKeyId}/{scope}"),
            new("X-Amz-Date", amzDate),
            new("X-Amz-Expires", clampedExpiry.ToString(CultureInfo.InvariantCulture)),
            new("X-Amz-SignedHeaders", SignedHeaders),
        };

        var canonical = SigV4.Canonicalize(
            method: "GET",
            path: Uri.UnescapeDataString(url.AbsolutePath),
            query: baseQuery,
            headers: headers,
            payloadHash: SigV4.UnsignedPayload);

        var toSign = SigV4.StringToSign(stamp, Region, "s3", canonical);
        var sig = SigV4.Signature(toSign, Credentials.SecretAccessKey, stamp, Region, "s3");

        var allQuery = new List<KeyValuePair<string, string>>(baseQuery)
        {
            new("X-Amz-Signature", sig),
        };

        var queryString = new StringBuilder();
        for (var i = 0; i < allQuery.Count; i++)
        {
            if (i > 0) queryString.Append('&');
            queryString.Append(SigV4.AwsEncode(allQuery[i].Key, encodeSlash: true));
            queryString.Append('=');
            queryString.Append(SigV4.AwsEncode(allQuery[i].Value, encodeSlash: true));
        }

        // Use AbsoluteUri so already-percent-encoded path segments survive into
        // the final URL string (e.g. spaces / unicode in the key).
        return new Uri(url.AbsoluteUri + "?" + queryString);
    }

    /// <summary>Dispose the owned <see cref="HttpClient"/> if we created it.</summary>
    public void Dispose()
    {
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
    }
}

/// <summary>Thrown when an S3 request fails.</summary>
public sealed class S3Exception : Exception
{
    /// <summary>The HTTP status code returned by S3, if any.</summary>
    public int? StatusCode { get; }

    /// <summary>The (UTF-8 decoded) response body, if any.</summary>
    public string? ResponseBody { get; }

    /// <summary>Construct an S3 exception with a message only.</summary>
    public S3Exception(string message) : base(message) { }

    /// <summary>Construct an S3 exception with a message and inner exception.</summary>
    public S3Exception(string message, Exception inner) : base(message, inner) { }

    /// <summary>Construct an S3 exception carrying the HTTP status code and response body.</summary>
    public S3Exception(string message, int statusCode, string? responseBody) : base(message)
    {
        StatusCode = statusCode;
        ResponseBody = responseBody;
    }
}
