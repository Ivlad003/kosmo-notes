using KosmoNotes.Secrets;

namespace KosmoNotes.Secrets.Tests;

public sealed class SecretsStoreExtensionsTests
{
    [Fact]
    public async Task TrySetAsync_OnMissingKey_SetsAndReturnsTrue()
    {
        InMemorySecretsStore store = new();
        bool result = await store.TrySetAsync("k", "v");

        Assert.True(result);
        Assert.Equal("v", await store.GetAsync("k"));
    }

    [Fact]
    public async Task TrySetAsync_OnExistingKey_DoesNotOverwrite_AndReturnsFalse()
    {
        InMemorySecretsStore store = new();
        await store.SetAsync("k", "original");

        bool result = await store.TrySetAsync("k", "replacement");

        Assert.False(result);
        Assert.Equal("original", await store.GetAsync("k"));
    }

    [Fact]
    public async Task GetRequiredAsync_WhenPresent_ReturnsValue()
    {
        InMemorySecretsStore store = new();
        await store.SetAsync("k", "v");

        string value = await store.GetRequiredAsync("k");

        Assert.Equal("v", value);
    }

    [Fact]
    public async Task GetRequiredAsync_WhenMissing_ThrowsWithKey()
    {
        InMemorySecretsStore store = new();

        SecretNotFoundException ex = await Assert.ThrowsAsync<SecretNotFoundException>(
            () => store.GetRequiredAsync("missing"));

        Assert.Equal("missing", ex.Key);
        Assert.Contains("missing", ex.Message, StringComparison.Ordinal);
    }
}
