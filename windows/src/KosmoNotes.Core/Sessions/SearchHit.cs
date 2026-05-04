namespace KosmoNotes.Core.Sessions;

/// <summary>
/// One full-text search hit. Mirrors the Swift <c>SearchHit</c> struct.
/// </summary>
/// <param name="Sid">Session id (foreign key into the sessions table).</param>
/// <param name="Snippet">FTS5-generated snippet, possibly with HTML highlight markers.</param>
public sealed record SearchHit(string Sid, string Snippet);
