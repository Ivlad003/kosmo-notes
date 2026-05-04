namespace KosmoNotes.Sharing.Tests;

public class SigV4DateTests
{
    [Fact]
    public void AmzDateTimeProducesIsoBasic()
    {
        // 2015-08-30 12:36:00 UTC
        var d = DateTimeOffset.FromUnixTimeSeconds(1_440_938_160);
        Assert.Equal("20150830T123600Z", SigV4.AmzDateTime(d));
    }

    [Fact]
    public void AmzDateOnlyProducesYyyyMmDd()
    {
        var d = DateTimeOffset.FromUnixTimeSeconds(1_440_938_160);
        Assert.Equal("20150830", SigV4.AmzDateOnly(d));
    }

    [Fact]
    public void NonUtcInputNormalizedToUtc()
    {
        // 2015-08-30 14:36:00 +02:00 == 12:36:00 UTC
        var d = new DateTimeOffset(2015, 8, 30, 14, 36, 0, TimeSpan.FromHours(2));
        Assert.Equal("20150830T123600Z", SigV4.AmzDateTime(d));
        Assert.Equal("20150830", SigV4.AmzDateOnly(d));
    }
}
