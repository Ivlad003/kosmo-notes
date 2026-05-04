namespace KosmoNotes.Sharing.Tests;

public class S3EndpointVariantsTests
{
    private static SigV4.Credentials Creds => new(
        AccessKeyId: "AKIAIOSFODNN7EXAMPLE",
        SecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");

    [Fact]
    public void AwsEndpointBuildsObjectUrl()
    {
        var c = new S3Client(
            new Uri("https://s3.amazonaws.com"),
            "us-east-1",
            "mybucket",
            Creds);
        Assert.Equal("https://s3.amazonaws.com/mybucket/folder/key.txt", c.ObjectUrl("folder/key.txt").AbsoluteUri);
    }

    [Fact]
    public void CloudflareR2EndpointBuildsObjectUrl()
    {
        var c = new S3Client(
            new Uri("https://abc123.r2.cloudflarestorage.com"),
            "auto",
            "mybucket",
            Creds);
        Assert.Equal(
            "https://abc123.r2.cloudflarestorage.com/mybucket/key",
            c.ObjectUrl("key").AbsoluteUri);
    }

    [Fact]
    public void MinioCustomPortBuildsObjectUrl()
    {
        var c = new S3Client(
            new Uri("http://localhost:9000"),
            "us-east-1",
            "mybucket",
            Creds);
        Assert.Equal(
            "http://localhost:9000/mybucket/k",
            c.ObjectUrl("k").AbsoluteUri);
    }

    [Fact]
    public void MinioPresignedUrlIncludesPort()
    {
        var c = new S3Client(
            new Uri("http://localhost:9000"),
            "us-east-1",
            "mybucket",
            Creds);
        var url = c.PresignedGetUrl(
            "k", 60,
            now: DateTimeOffset.FromUnixTimeSeconds(1_369_353_600));
        Assert.StartsWith("http://localhost:9000/mybucket/k?", url.AbsoluteUri);
    }

    [Fact]
    public void R2PresignedUrlUsesAutoRegion()
    {
        var c = new S3Client(
            new Uri("https://abc123.r2.cloudflarestorage.com"),
            "auto",
            "mybucket",
            Creds);
        var url = c.PresignedGetUrl(
            "k", 60,
            now: DateTimeOffset.FromUnixTimeSeconds(1_369_353_600));
        // Scope embeds the region.
        Assert.Contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fauto%2Fs3%2Faws4_request", url.AbsoluteUri);
    }

    [Fact]
    public void KeyWithSpacesGetsEncodedButSlashesPreserved()
    {
        var c = new S3Client(
            new Uri("https://s3.amazonaws.com"),
            "us-east-1",
            "mybucket",
            Creds);
        var url = c.ObjectUrl("a b/c d/e f.txt");
        Assert.Equal("https://s3.amazonaws.com/mybucket/a%20b/c%20d/e%20f.txt", url.AbsoluteUri);
    }

    [Fact]
    public void KeyWithUtf8MultibyteEncoded()
    {
        var c = new S3Client(
            new Uri("https://s3.amazonaws.com"),
            "us-east-1",
            "mybucket",
            Creds);
        // Cyrillic "а" -> %D0%B0
        var url = c.ObjectUrl("а.txt");
        Assert.Equal("https://s3.amazonaws.com/mybucket/%D0%B0.txt", url.AbsoluteUri);
    }
}
