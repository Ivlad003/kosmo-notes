using System.Text;

namespace KosmoNotes.Sharing.Tests;

public class SigV4SigningKeyTests
{
    [Fact]
    public void AwsReferenceSigningKey()
    {
        // AWS-published Sig V4 test vector for IAM, 2015-08-30:
        //   https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
        var key = SigV4.SigningKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            date: "20150830",
            region: "us-east-1",
            service: "iam");
        var hex = ToHex(key);
        Assert.Equal("c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9", hex);
    }

    [Fact]
    public void S3SigningKeyFor20130524ExampleBucket()
    {
        // Same secret, but for date 20130524 / s3 — used by the AWS S3 presign sample.
        var key = SigV4.SigningKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            date: "20130524",
            region: "us-east-1",
            service: "s3");
        // Sanity: 32 bytes (HMAC-SHA256 output).
        Assert.Equal(32, key.Length);
    }

    [Fact]
    public void DifferentDateProducesDifferentKey()
    {
        var a = SigV4.SigningKey("secret", "20150830", "us-east-1", "iam");
        var b = SigV4.SigningKey("secret", "20150831", "us-east-1", "iam");
        Assert.NotEqual(ToHex(a), ToHex(b));
    }

    private static string ToHex(byte[] bytes)
    {
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }
}
