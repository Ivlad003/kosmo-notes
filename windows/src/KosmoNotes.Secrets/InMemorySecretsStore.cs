namespace KosmoNotes.Secrets;

/// <summary>
/// Thread-safe in-memory implementation of <see cref="ISecretsStore"/>. Intended
/// for unit tests and ephemeral scenarios — values are kept only in process
/// memory and are lost when the process exits.
/// </summary>
public sealed class InMemorySecretsStore : ISecretsStore
{
    private readonly object _sync = new();
    private readonly Dictionary<string, string> _store = new(StringComparer.Ordinal);

    /// <summary>
    /// Creates an empty in-memory secrets store.
    /// </summary>
    public InMemorySecretsStore()
    {
    }

    /// <summary>
    /// Creates an in-memory secrets store pre-populated with the given
    /// key/value pairs. The supplied dictionary is copied; subsequent
    /// mutations to <paramref name="initial"/> do not affect the store.
    /// </summary>
    /// <param name="initial">Initial key/value pairs to seed the store with.</param>
    public InMemorySecretsStore(IDictionary<string, string> initial)
    {
        ArgumentNullException.ThrowIfNull(initial);
        foreach (KeyValuePair<string, string> kvp in initial)
        {
            _store[kvp.Key] = kvp.Value;
        }
    }

    /// <summary>
    /// Returns an isolated snapshot of the current state of the store. Useful
    /// for assertions in tests; mutating the returned dictionary does not
    /// affect the live store.
    /// </summary>
    public IReadOnlyDictionary<string, string> Snapshot()
    {
        lock (_sync)
        {
            return new Dictionary<string, string>(_store, StringComparer.Ordinal);
        }
    }

    /// <inheritdoc />
    public Task<string?> GetAsync(string key, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(key);
        ct.ThrowIfCancellationRequested();
        lock (_sync)
        {
            return Task.FromResult(_store.TryGetValue(key, out string? value) ? value : null);
        }
    }

    /// <inheritdoc />
    public Task SetAsync(string key, string value, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(value);
        ct.ThrowIfCancellationRequested();
        lock (_sync)
        {
            _store[key] = value;
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task DeleteAsync(string key, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(key);
        ct.ThrowIfCancellationRequested();
        lock (_sync)
        {
            _store.Remove(key);
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task<bool> ContainsAsync(string key, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(key);
        ct.ThrowIfCancellationRequested();
        lock (_sync)
        {
            return Task.FromResult(_store.ContainsKey(key));
        }
    }
}
