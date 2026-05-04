namespace KosmoNotes.Sharing.Tests;

public class S3PresignedGetTests
{
    private static S3Client MakeClient() => new(
        endpoint: new Uri("https://s3.amazonaws.com"),
        region: "us-east-1",
        bucket: "examplebucket",
        credentials: new SigV4.Credentials(
            AccessKeyId: "AKIAIOSFODNN7EXAMPLE",
            SecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"));

    /// <summary>
    /// Byte-for-byte cross-platform parity test. The expected URL was produced
    /// by running the Swift implementation in-tree with the exact same fixed
    /// inputs (see Tests/SharingKitTests/SigV4Tests.swift + Sources/SharingKit/*).
    ///
    /// Note: this is path-style addressing. The signature differs from the
    /// AWS-docs example because that example uses virtual-hosted-style host
    /// (<c>examplebucket.s3.amazonaws.com</c>); we pin to path-style.
    /// </summary>
    [Fact]
    public void MatchesSwiftReferenceUrlByteForByte()
    {
        var client = MakeClient();
        var now = DateTimeOffset.FromUnixTimeSeconds(1_369_353_600); // 2013-05-24T00:00:00Z
        var url = client.PresignedGetUrl("test.txt", expirySeconds: 86_400, now: now);

        const string expected =
            "https://s3.amazonaws.com/examplebucket/test.txt" +
            "?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
            "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
            "&X-Amz-Date=20130524T000000Z" +
            "&X-Amz-Expires=86400" +
            "&X-Amz-SignedHeaders=host" +
            "&X-Amz-Signature=ae6011057c8f11107b5c7e484c0ae75a22797a48a32f48592f3fa1b9cd55cb40";

        Assert.Equal(expected, url.AbsoluteUri);
    }

    [Fact]
    public void PresignedUrlContainsExpectedParams()
    {
        var client = MakeClient();
        var url = client.PresignedGetUrl(
            "test.txt", expirySeconds: 3600,
            now: DateTimeOffset.FromUnixTimeSeconds(1_440_938_160));
        var s = url.AbsoluteUri;
        Assert.Contains("X-Amz-Algorithm=AWS4-HMAC-SHA256", s);
        Assert.Contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE", s);
        Assert.Contains("X-Amz-Date=20150830T123600Z", s);
        Assert.Contains("X-Amz-Expires=3600", s);
        Assert.Contains("X-Amz-SignedHeaders=host", s);
        Assert.Contains("X-Amz-Signature=", s);
    }

    [Fact]
    public void ExpiryClampedToSevenDaysMax()
    {
        var client = MakeClient();
        var url = client.PresignedGetUrl(
            "x", expirySeconds: 999_999_999,
            now: DateTimeOffset.FromUnixTimeSeconds(1_440_938_160));
        Assert.Contains("X-Amz-Expires=604800", url.AbsoluteUri);
    }

    [Fact]
    public void ExpiryClampedToOneAtMinimum()
    {
        var client = MakeClient();
        var url = client.PresignedGetUrl(
            "x", expirySeconds: 0,
            now: DateTimeOffset.FromUnixTimeSeconds(1_440_938_160));
        Assert.Contains("X-Amz-Expires=1", url.AbsoluteUri);
    }

    [Fact]
    public void NegativeExpiryClampedToOne()
    {
        var client = MakeClient();
        var url = client.PresignedGetUrl(
            "x", expirySeconds: -10,
            now: DateTimeOffset.FromUnixTimeSeconds(1_440_938_160));
        Assert.Contains("X-Amz-Expires=1", url.AbsoluteUri);
    }

    [Fact]
    public void KeyWithSpacesAndSlashesEncodedInPath()
    {
        var client = MakeClient();
        var url = client.PresignedGetUrl(
            "folder/sub folder/test name.txt", expirySeconds: 60,
            now: DateTimeOffset.FromUnixTimeSeconds(1_369_353_600));
        // Slashes preserve the prefix structure but spaces inside segments are encoded.
        Assert.Contains("/folder/sub%20folder/test%20name.txt?", url.AbsoluteUri);
    }
}
