using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace KosmoNotes.Sharing;

/// <summary>
/// Hand-rolled AWS Signature Version 4 implementation, scoped to S3-compatible
/// PUT object + presigned GET use cases.
///
/// Why hand-rolled: the AWS SDK adds a large dependency surface and its
/// ergonomics around presigning custom endpoints (R2, B2, MinIO) are awkward.
/// Sig V4 itself is ~200 lines of well-specified crypto and string-massaging.
///
/// References:
///   • https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
///   • https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-streaming.html
/// </summary>
public static class SigV4
{
    /// <summary>AWS access-key + secret pair.</summary>
    public sealed record Credentials(string AccessKeyId, string SecretAccessKey);

    // MARK: - Helpers

    /// <summary>SHA-256 hex digest. Used for canonical-request hash + payload hash.</summary>
    public static string Sha256Hex(byte[] data)
    {
        var digest = SHA256.HashData(data);
        return ToLowerHex(digest);
    }

    /// <summary>SHA-256 hex digest of the UTF-8 bytes of <paramref name="s"/>.</summary>
    public static string Sha256Hex(string s) => Sha256Hex(Encoding.UTF8.GetBytes(s));

    /// <summary>HMAC-SHA256 raw bytes.</summary>
    public static byte[] HmacSha256(byte[] data, byte[] key) => HMACSHA256.HashData(key, data);

    /// <summary>HMAC-SHA256 lowercase hex.</summary>
    public static string HmacSha256Hex(byte[] data, byte[] key) => ToLowerHex(HmacSha256(data, key));

    /// <summary>
    /// AWS-flavoured percent encoding: rules are stricter than <c>Uri.EscapeDataString</c>.
    /// All bytes outside the unreserved set (RFC-3986 §2.3 — A-Z a-z 0-9 - _ . ~) are encoded.
    /// Slashes are encoded depending on <paramref name="encodeSlash"/>. Used for both
    /// canonical URI (slashes preserved) and canonical query strings (slashes encoded).
    /// </summary>
    public static string AwsEncode(string s, bool encodeSlash)
    {
        var utf8 = Encoding.UTF8.GetBytes(s);
        var sb = new StringBuilder(utf8.Length);
        foreach (var b in utf8)
        {
            var isUnreserved =
                (b >= 0x41 && b <= 0x5A) ||  // A-Z
                (b >= 0x61 && b <= 0x7A) ||  // a-z
                (b >= 0x30 && b <= 0x39) ||  // 0-9
                b == 0x2D ||                  // -
                b == 0x5F ||                  // _
                b == 0x2E ||                  // .
                b == 0x7E;                    // ~
            if (isUnreserved)
            {
                sb.Append((char)b);
            }
            else if (b == 0x2F && !encodeSlash) // /
            {
                sb.Append((char)b);
            }
            else
            {
                sb.Append('%');
                sb.Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return sb.ToString();
    }

    // MARK: - Date / time helpers

    /// <summary><c>YYYYMMDDTHHMMSSZ</c> (ISO basic UTC). Used in <c>x-amz-date</c>.</summary>
    public static string AmzDateTime(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);

    /// <summary><c>YYYYMMDD</c>. Used in scope.</summary>
    public static string AmzDateOnly(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyyMMdd", CultureInfo.InvariantCulture);

    // MARK: - Signing key derivation

    /// <summary>
    /// Derive the per-request signing key. AWS-spec exact:
    ///   kDate    = HMAC("AWS4" + secret, date)
    ///   kRegion  = HMAC(kDate, region)
    ///   kService = HMAC(kRegion, service)
    ///   kSigning = HMAC(kService, "aws4_request")
    /// </summary>
    public static byte[] SigningKey(string secret, string date, string region, string service)
    {
        var kSecret = Encoding.UTF8.GetBytes("AWS4" + secret);
        var kDate = HmacSha256(Encoding.UTF8.GetBytes(date), kSecret);
        var kRegion = HmacSha256(Encoding.UTF8.GetBytes(region), kDate);
        var kService = HmacSha256(Encoding.UTF8.GetBytes(service), kRegion);
        var kSigning = HmacSha256(Encoding.UTF8.GetBytes("aws4_request"), kService);
        return kSigning;
    }

    // MARK: - Canonical request

    /// <summary>Structured canonical request shaped per Sig V4 spec.</summary>
    public sealed record CanonicalRequest(
        string Method,
        string CanonicalUri,
        string CanonicalQuery,
        string CanonicalHeaders,
        string SignedHeaders,
        string PayloadHash)
    {
        /// <summary>The canonical request joined with newlines (the Sig V4 string form).</summary>
        public string StringValue =>
            $"{Method}\n{CanonicalUri}\n{CanonicalQuery}\n{CanonicalHeaders}\n{SignedHeaders}\n{PayloadHash}";
    }

    /// <summary>
    /// Build the canonical request per Sig V4 spec.
    /// Header keys are case-insensitive — they are lowercased and sorted internally.
    /// Header values are trimmed of leading/trailing whitespace. We do NOT collapse
    /// multiple-space sequences in values: for our use cases (host, x-amz-*,
    /// content-type, content-length) values never contain runs of spaces, and the
    /// generic RFC 7230 LWS-collapse rule is intentionally omitted.
    /// </summary>
    public static CanonicalRequest Canonicalize(
        string method,
        string path,
        IReadOnlyList<KeyValuePair<string, string>> query,
        IReadOnlyDictionary<string, string> headers,
        string payloadHash)
    {
        var canonicalUri = string.IsNullOrEmpty(path) ? "/" : AwsEncode(path, encodeSlash: false);

        // AWS-encode key+value, sort alphabetically by encoded key (then encoded value),
        // join with '&'.
        var encodedPairs = new List<KeyValuePair<string, string>>(query.Count);
        foreach (var pair in query)
        {
            encodedPairs.Add(new KeyValuePair<string, string>(
                AwsEncode(pair.Key, encodeSlash: true),
                AwsEncode(pair.Value, encodeSlash: true)));
        }
        encodedPairs.Sort((a, b) =>
        {
            var c = string.CompareOrdinal(a.Key, b.Key);
            return c != 0 ? c : string.CompareOrdinal(a.Value, b.Value);
        });
        var canonicalQuery = string.Join("&", encodedPairs.Select(p => p.Key + "=" + p.Value));

        // Lowercase header keys, trim values, sort, join with '\n', append trailing '\n'.
        var lowered = headers
            .Select(kv => new KeyValuePair<string, string>(
                kv.Key.ToLowerInvariant(),
                kv.Value.Trim()))
            .OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .ToList();

        var canonicalHeaders = string.Join("\n", lowered.Select(kv => $"{kv.Key}:{kv.Value}")) + "\n";
        var signedHeaders = string.Join(";", lowered.Select(kv => kv.Key));

        return new CanonicalRequest(
            Method: method.ToUpperInvariant(),
            CanonicalUri: canonicalUri,
            CanonicalQuery: canonicalQuery,
            CanonicalHeaders: canonicalHeaders,
            SignedHeaders: signedHeaders,
            PayloadHash: payloadHash);
    }

    // MARK: - String-to-sign + signature

    /// <summary>Build the Sig V4 string-to-sign for the given canonical request and date.</summary>
    public static string StringToSign(
        DateTimeOffset date,
        string region,
        string service,
        CanonicalRequest cr)
    {
        var amzDate = AmzDateTime(date);
        var scope = $"{AmzDateOnly(date)}/{region}/{service}/aws4_request";
        var crHash = Sha256Hex(cr.StringValue);
        return $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{crHash}";
    }

    /// <summary>Compute the final hex signature for a string-to-sign.</summary>
    public static string Signature(
        string stringToSign,
        string secret,
        DateTimeOffset date,
        string region,
        string service)
    {
        var key = SigningKey(secret, AmzDateOnly(date), region, service);
        return HmacSha256Hex(Encoding.UTF8.GetBytes(stringToSign), key);
    }

    // MARK: - Signed-payload constants

    /// <summary>SHA-256 of an empty body. Used as <c>x-amz-content-sha256</c> for presigned URLs.</summary>
    public const string EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    /// <summary>Marker payload hash for presigned URLs: signed using <c>UNSIGNED-PAYLOAD</c>.</summary>
    public const string UnsignedPayload = "UNSIGNED-PAYLOAD";

    // MARK: - Internal helpers

    private static string ToLowerHex(byte[] bytes)
    {
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
        {
            sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }
}
