namespace KosmoNotes.Sharing.Tests;

public class SigV4CanonicalRequestTests
{
    [Fact]
    public void EmptyPathBecomesSlash()
    {
        var cr = SigV4.Canonicalize(
            method: "PUT",
            path: string.Empty,
            query: Array.Empty<KeyValuePair<string, string>>(),
            headers: new Dictionary<string, string> { ["host"] = "example.com" },
            payloadHash: SigV4.EmptyPayloadHash);
        Assert.Equal("/", cr.CanonicalUri);
    }

    [Fact]
    public void HeadersLowercasedSortedAndTrimmed()
    {
        var cr = SigV4.Canonicalize(
            method: "PUT",
            path: "/key",
            query: Array.Empty<KeyValuePair<string, string>>(),
            headers: new Dictionary<string, string>
            {
                ["X-Amz-Date"] = "20150830T123600Z",
                ["Host"] = "  example.com  ",
                ["Content-Type"] = "text/plain",
            },
            payloadHash: SigV4.EmptyPayloadHash);

        Assert.Equal(
            "content-type:text/plain\nhost:example.com\nx-amz-date:20150830T123600Z\n",
            cr.CanonicalHeaders);
        Assert.Equal("content-type;host;x-amz-date", cr.SignedHeaders);
    }

    [Fact]
    public void QueryParamsSortedByEncodedKey()
    {
        var cr = SigV4.Canonicalize(
            method: "GET",
            path: "/",
            query: new[]
            {
                new KeyValuePair<string, string>("Z", "1"),
                new KeyValuePair<string, string>("A", "2"),
                new KeyValuePair<string, string>("M", "3"),
            },
            headers: new Dictionary<string, string> { ["host"] = "example.com" },
            payloadHash: SigV4.UnsignedPayload);
        Assert.Equal("A=2&M=3&Z=1", cr.CanonicalQuery);
    }

    [Fact]
    public void QueryParamsSortedByEncodedValueWhenKeysEqual()
    {
        var cr = SigV4.Canonicalize(
            method: "GET",
            path: "/",
            query: new[]
            {
                new KeyValuePair<string, string>("k", "z"),
                new KeyValuePair<string, string>("k", "a"),
                new KeyValuePair<string, string>("k", "m"),
            },
            headers: new Dictionary<string, string> { ["host"] = "example.com" },
            payloadHash: SigV4.UnsignedPayload);
        Assert.Equal("k=a&k=m&k=z", cr.CanonicalQuery);
    }

    [Fact]
    public void QueryValuesAreAwsEncoded()
    {
        var cr = SigV4.Canonicalize(
            method: "GET",
            path: "/",
            query: new[]
            {
                new KeyValuePair<string, string>("path", "a/b c"),
            },
            headers: new Dictionary<string, string> { ["host"] = "example.com" },
            payloadHash: SigV4.UnsignedPayload);
        // both '/' (encodeSlash=true) and ' ' must be percent-encoded
        Assert.Equal("path=a%2Fb%20c", cr.CanonicalQuery);
    }

    [Fact]
    public void StringValueShape()
    {
        var cr = SigV4.Canonicalize(
            method: "get",
            path: "/foo",
            query: new[]
            {
                new KeyValuePair<string, string>("a", "1"),
            },
            headers: new Dictionary<string, string> { ["Host"] = "example.com" },
            payloadHash: SigV4.UnsignedPayload);

        // method uppercased, path encoded but slash preserved, sorted/lowered headers,
        // newlines exactly per spec, payload hash last.
        Assert.Equal(
            "GET\n/foo\na=1\nhost:example.com\n\nhost\nUNSIGNED-PAYLOAD",
            cr.StringValue);
    }

    [Fact]
    public void CanonicalRequestForS3GetVanilla()
    {
        // A worked example matching the AWS Sig V4 spec layout for GET
        // https://s3.amazonaws.com/examplebucket/test.txt with no query.
        var cr = SigV4.Canonicalize(
            method: "GET",
            path: "/examplebucket/test.txt",
            query: Array.Empty<KeyValuePair<string, string>>(),
            headers: new Dictionary<string, string>
            {
                ["host"] = "s3.amazonaws.com",
                ["x-amz-content-sha256"] = SigV4.EmptyPayloadHash,
                ["x-amz-date"] = "20130524T000000Z",
            },
            payloadHash: SigV4.EmptyPayloadHash);

        var expected = string.Join("\n",
            "GET",
            "/examplebucket/test.txt",
            string.Empty,
            "host:s3.amazonaws.com",
            "x-amz-content-sha256:" + SigV4.EmptyPayloadHash,
            "x-amz-date:20130524T000000Z",
            string.Empty,
            "host;x-amz-content-sha256;x-amz-date",
            SigV4.EmptyPayloadHash);
        Assert.Equal(expected, cr.StringValue);
    }
}
