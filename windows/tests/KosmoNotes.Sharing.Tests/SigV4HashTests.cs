using System.Text;

namespace KosmoNotes.Sharing.Tests;

public class SigV4HashTests
{
    [Fact]
    public void Sha256OfEmptyStringMatchesAwsConstant()
    {
        Assert.Equal(SigV4.EmptyPayloadHash, SigV4.Sha256Hex(string.Empty));
    }

    [Fact]
    public void Sha256OfEmptyByteArrayMatchesAwsConstant()
    {
        Assert.Equal(SigV4.EmptyPayloadHash, SigV4.Sha256Hex(Array.Empty<byte>()));
    }

    [Fact]
    public void Sha256OfAbcMatchesReferenceVector()
    {
        // FIPS 180-2 reference: SHA-256("abc")
        Assert.Equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            SigV4.Sha256Hex("abc"));
    }

    [Fact]
    public void HmacSha256HexJefeReference()
    {
        // RFC 4231 / common reference: HMAC-SHA256("Jefe", "what do ya want for nothing?")
        var mac = SigV4.HmacSha256Hex(
            Encoding.UTF8.GetBytes("what do ya want for nothing?"),
            Encoding.UTF8.GetBytes("Jefe"));
        Assert.Equal("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", mac);
    }

    [Fact]
    public void HmacSha256RawBytesMatchHex()
    {
        var raw = SigV4.HmacSha256(
            Encoding.UTF8.GetBytes("what do ya want for nothing?"),
            Encoding.UTF8.GetBytes("Jefe"));
        var sb = new StringBuilder(raw.Length * 2);
        foreach (var b in raw) sb.Append(b.ToString("x2"));
        Assert.Equal("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", sb.ToString());
    }
}
