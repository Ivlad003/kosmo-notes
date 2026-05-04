namespace KosmoNotes.Secrets;

/// <summary>
/// Platform-agnostic abstraction over a secure credentials store. Concrete
/// implementations may delegate to OS-level facilities such as DPAPI / Windows
/// Credential Manager, the macOS Keychain, or an in-memory map for tests.
/// </summary>
/// <remarks>
/// Loosely mirrors the macOS-side <c>KeychainStore</c> (<c>Sources/StorageKit/KeychainStore.swift</c>):
/// each entry is keyed by an opaque string and stores a single string secret.
/// Implementations must be thread-safe.
/// </remarks>
public interface ISecretsStore
{
    /// <summary>
    /// Returns the secret value associated with <paramref name="key"/>, or
    /// <c>null</c> if no entry exists for that key.
    /// </summary>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="ct">Optional cancellation token.</param>
    Task<string?> GetAsync(string key, CancellationToken ct = default);

    /// <summary>
    /// Sets the secret value for <paramref name="key"/>. Overwrites any
    /// existing value silently.
    /// </summary>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="value">The secret value to store.</param>
    /// <param name="ct">Optional cancellation token.</param>
    Task SetAsync(string key, string value, CancellationToken ct = default);

    /// <summary>
    /// Removes the secret associated with <paramref name="key"/>. No-op if
    /// the key is not present.
    /// </summary>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="ct">Optional cancellation token.</param>
    Task DeleteAsync(string key, CancellationToken ct = default);

    /// <summary>
    /// Returns <c>true</c> if a secret exists for <paramref name="key"/>.
    /// Cheaper than <see cref="GetAsync"/> because implementations are not
    /// required to fetch the plaintext value.
    /// </summary>
    /// <param name="key">The opaque key identifying the secret.</param>
    /// <param name="ct">Optional cancellation token.</param>
    Task<bool> ContainsAsync(string key, CancellationToken ct = default);
}
