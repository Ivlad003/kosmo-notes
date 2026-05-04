namespace KosmoNotes.Secrets;

/// <summary>
/// Ergonomic helpers built on top of the four-method <see cref="ISecretsStore"/>
/// surface.
/// </summary>
public static class SecretsStoreExtensions
{
    /// <summary>
    /// Sets <paramref name="key"/> to <paramref name="value"/> only if the
    /// key is not already present. Returns <c>true</c> when the value was
    /// written, <c>false</c> when an existing entry was preserved.
    /// </summary>
    /// <remarks>
    /// This is a convenience wrapper. It is not atomic with respect to
    /// concurrent writers — two parallel callers may both observe "missing"
    /// and race to set the value. Callers that require atomicity should
    /// implement compare-and-swap at the store level.
    /// </remarks>
    /// <param name="store">The secrets store to operate on.</param>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="value">The value to write if the key is missing.</param>
    /// <param name="ct">Optional cancellation token.</param>
    public static async Task<bool> TrySetAsync(
        this ISecretsStore store,
        string key,
        string value,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(value);

        if (await store.ContainsAsync(key, ct).ConfigureAwait(false))
        {
            return false;
        }

        await store.SetAsync(key, value, ct).ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// Returns the secret for <paramref name="key"/>, throwing
    /// <see cref="SecretNotFoundException"/> if no entry exists.
    /// </summary>
    /// <param name="store">The secrets store to query.</param>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="ct">Optional cancellation token.</param>
    /// <exception cref="SecretNotFoundException">No entry exists for <paramref name="key"/>.</exception>
    public static async Task<string> GetRequiredAsync(
        this ISecretsStore store,
        string key,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(key);

        string? value = await store.GetAsync(key, ct).ConfigureAwait(false);
        if (value is null)
        {
            throw new SecretNotFoundException(key);
        }
        return value;
    }
}
