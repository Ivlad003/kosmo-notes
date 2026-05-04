namespace KosmoNotes.Sharing.Tests;

public class SigV4EncodeTests
{
    [Fact]
    public void UnreservedCharsPassThroughBothModes()
    {
        const string s = "ABCabc012-_.~";
        Assert.Equal(s, SigV4.AwsEncode(s, encodeSlash: false));
        Assert.Equal(s, SigV4.AwsEncode(s, encodeSlash: true));
    }

    [Fact]
    public void SlashPreservedWhenNotEncoded()
    {
        Assert.Equal("a/b/c", SigV4.AwsEncode("a/b/c", encodeSlash: false));
    }

    [Fact]
    public void SlashEncodedWhenRequested()
    {
        Assert.Equal("a%2Fb%2Fc", SigV4.AwsEncode("a/b/c", encodeSlash: true));
    }

    [Fact]
    public void SpaceAndSlashMixed_NoSlashEncode()
    {
        Assert.Equal("a/b%20c", SigV4.AwsEncode("a/b c", encodeSlash: false));
    }

    [Fact]
    public void SpaceAndSlashMixed_WithSlashEncode()
    {
        Assert.Equal("a%2Fb%20c", SigV4.AwsEncode("a/b c", encodeSlash: true));
    }

    [Fact]
    public void SpacesPercentEncodedAs20()
    {
        Assert.Equal("hello%20world", SigV4.AwsEncode("hello world", encodeSlash: false));
    }

    [Fact]
    public void PlusSignEncodedAs2B()
    {
        Assert.Equal("a%2Bb", SigV4.AwsEncode("a+b", encodeSlash: false));
    }

    [Fact]
    public void EqualsAndAmpersandEncoded()
    {
        Assert.Equal("a%3Db%26c", SigV4.AwsEncode("a=b&c", encodeSlash: false));
    }

    [Fact]
    public void UpperHexInPercentEncoding()
    {
        // colon is 0x3A — must be encoded as %3A (uppercase A), never %3a.
        Assert.Equal("a%3Ab", SigV4.AwsEncode("a:b", encodeSlash: false));
    }

    [Fact]
    public void Utf8MultibytePercentEncodedPerByte()
    {
        // Cyrillic small letter "а" (U+0430) -> UTF-8 0xD0 0xB0 -> %D0%B0
        Assert.Equal("%D0%B0", SigV4.AwsEncode("а", encodeSlash: false));
    }

    [Fact]
    public void EmptyStringEncodesToEmpty()
    {
        Assert.Equal(string.Empty, SigV4.AwsEncode(string.Empty, encodeSlash: false));
    }
}
