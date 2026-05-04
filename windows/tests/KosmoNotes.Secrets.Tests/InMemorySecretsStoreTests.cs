using KosmoNotes.Secrets;

namespace KosmoNotes.Secrets.Tests;

public sealed class InMemorySecretsStoreTests
{
    [Fact]
    public async Task EmptyStore_GetReturnsNull()
    {
        InMemorySecretsStore store = new();
        Assert.Null(await store.GetAsync("missing"));
    }

    [Fact]
    public async Task EmptyStore_ContainsReturnsFalse()
    {
        InMemorySecretsStore store = new();
        Assert.False(await store.ContainsAsync("missing"));
    }

    [Fact]
    public async Task EmptyStore_DeleteIsNoOp()
    {
        InMemorySecretsStore store = new();
        // Should not throw and should leave the store empty.
        await store.DeleteAsync("missing");
        Assert.Empty(store.Snapshot());
    }

    [Fact]
    public async Task SetThenGet_ReturnsValue_AndContainsTrue()
    {
        InMemorySecretsStore store = new();
        await store.SetAsync("k", "v");

        Assert.Equal("v", await store.GetAsync("k"));
        Assert.True(await store.ContainsAsync("k"));
    }

    [Fact]
    public async Task Set_OverwritesExistingValue()
    {
        InMemorySecretsStore store = new();
        await store.SetAsync("x", "v1");
        await store.SetAsync("x", "v2");

        Assert.Equal("v2", await store.GetAsync("x"));
    }

    [Fact]
    public async Task Delete_RemovesValue()
    {
        InMemorySecretsStore store = new();
        await store.SetAsync("k", "v");
        await store.DeleteAsync("k");

        Assert.Null(await store.GetAsync("k"));
        Assert.False(await store.ContainsAsync("k"));
    }

    [Fact]
    public async Task Snapshot_IsIsolatedCopy()
    {
        InMemorySecretsStore store = new(new Dictionary<string, string> { ["a"] = "1" });
        IReadOnlyDictionary<string, string> snap = store.Snapshot();

        // Take two snapshots with a mutation between them and confirm the first is
        // unchanged — proves the snapshot is a copy, not a live view.
        Assert.Equal("1", snap["a"]);

        await store.SetAsync("a", "2");
        await store.SetAsync("b", "3");

        // First snapshot should still see the original state.
        Assert.Equal("1", snap["a"]);
        Assert.Single(snap);

        // A fresh snapshot reflects the new state.
        IReadOnlyDictionary<string, string> snap2 = store.Snapshot();
        Assert.Equal("2", snap2["a"]);
        Assert.Equal("3", snap2["b"]);
    }

    [Fact]
    public async Task Constructor_WithInitialDict_PrePopulates()
    {
        Dictionary<string, string> seed = new() { ["a"] = "1", ["b"] = "2" };
        InMemorySecretsStore store = new(seed);

        Assert.Equal("1", await store.GetAsync("a"));
        Assert.Equal("2", await store.GetAsync("b"));

        // Mutating the seed dictionary post-construction must not affect the store
        // (constructor copies entries).
        seed["a"] = "mutated";
        seed["c"] = "new";
        Assert.Equal("1", await store.GetAsync("a"));
        Assert.Null(await store.GetAsync("c"));
    }

    [Fact]
    public void Constructor_WithNullDict_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new InMemorySecretsStore(null!));
    }
}
