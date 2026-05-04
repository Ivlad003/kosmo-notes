namespace KosmoNotes.Secrets;

/// <summary>
/// Thrown by <see cref="SecretsStoreExtensions.GetRequiredAsync"/> when the
/// caller demands a secret that the store does not contain.
/// </summary>
public sealed class SecretNotFoundException : Exception
{
    /// <summary>
    /// The key that was looked up. Useful for diagnostic logging and for
    /// surfacing actionable error messages (e.g. "configure
    /// <c>kosmonotes.provider.anthropic.api_key</c>").
    /// </summary>
    public string Key { get; }

    /// <summary>
    /// Creates a new <see cref="SecretNotFoundException"/> for the given key.
    /// </summary>
    /// <param name="key">The missing key.</param>
    public SecretNotFoundException(string key)
        : base($"Secret not found: {key}")
    {
        Key = key;
    }
}
