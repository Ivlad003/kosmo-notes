using KosmoNotes.Secrets;

namespace KosmoNotes.Secrets.Tests;

public sealed class ConcurrencyTests
{
    [Fact]
    public async Task ParallelSets_AcrossDistinctKeys_AllSucceed()
    {
        InMemorySecretsStore store = new();

        const int writers = 10;
        const int perWriter = 100;

        Task[] tasks = new Task[writers];
        for (int w = 0; w < writers; w++)
        {
            int writerIdx = w;
            tasks[w] = Task.Run(async () =>
            {
                for (int i = 0; i < perWriter; i++)
                {
                    await store.SetAsync($"w{writerIdx}-k{i}", $"v{writerIdx}-{i}");
                }
            });
        }

        await Task.WhenAll(tasks);

        IReadOnlyDictionary<string, string> snap = store.Snapshot();
        Assert.Equal(writers * perWriter, snap.Count);

        // Spot-check a couple of values.
        Assert.Equal("v0-0", snap["w0-k0"]);
        Assert.Equal("v9-99", snap["w9-k99"]);
    }

    [Fact]
    public async Task ParallelMixedOps_OnSameKey_NeverThrow()
    {
        InMemorySecretsStore store = new();

        const int iterations = 500;
        const string key = "shared";

        Task setter = Task.Run(async () =>
        {
            for (int i = 0; i < iterations; i++)
            {
                await store.SetAsync(key, $"v{i}");
            }
        });

        Task getter = Task.Run(async () =>
        {
            for (int i = 0; i < iterations; i++)
            {
                _ = await store.GetAsync(key);
            }
        });

        Task deleter = Task.Run(async () =>
        {
            for (int i = 0; i < iterations; i++)
            {
                await store.DeleteAsync(key);
            }
        });

        Task containser = Task.Run(async () =>
        {
            for (int i = 0; i < iterations; i++)
            {
                _ = await store.ContainsAsync(key);
            }
        });

        // The bar: this should complete without throwing. Final state of `key` is
        // racy and intentionally not asserted on.
        await Task.WhenAll(setter, getter, deleter, containser);
    }
}
