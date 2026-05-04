namespace KosmoNotes.Storage;

/// <summary>
/// One stored embedding row from the <c>session_embeddings</c> table.
/// Mirrors the Swift tuple <c>(sid, vector, model)</c>.
/// </summary>
/// <param name="Sid">Session id (foreign key into the sessions table).</param>
/// <param name="Vector">Packed Float32 LE blob produced by the embedding provider.</param>
/// <param name="Model">Model identifier the embedding was produced with (e.g. <c>text-embedding-3-small</c>).</param>
public sealed record EmbeddingRow(string Sid, byte[] Vector, string Model);
