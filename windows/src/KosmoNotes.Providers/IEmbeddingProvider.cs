namespace KosmoNotes.Providers;

/// <summary>
/// Produces dense vector embeddings for arbitrary text. Used by semantic
/// search to find sessions conceptually related to a query, even when no
/// exact word overlaps with the FTS index.
/// Mirrors the Swift <c>EmbeddingProvider</c> protocol.
/// </summary>
public interface IEmbeddingProvider
{
    /// <summary>
    /// Identifier of the model used. Stored alongside the vector so future
    /// migrations can re-embed when the dimension or weights change.
    /// </summary>
    string ModelIdentifier { get; }

    /// <summary>
    /// Dimensionality of the returned vector. Used by callers to pre-allocate
    /// or to validate stored vectors against the active model.
    /// </summary>
    int Dimensions { get; }

    /// <summary>Embed a single text and return a 32-bit float vector.</summary>
    /// <param name="text">Input text.</param>
    /// <param name="ct">Cancellation token.</param>
    /// <returns>The vector as <see cref="float"/>[].</returns>
    Task<float[]> EmbedAsync(string text, CancellationToken ct = default);
}
