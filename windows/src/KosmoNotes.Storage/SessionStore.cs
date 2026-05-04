using System.Text.Json;
using KosmoNotes.Core.IO;
using KosmoNotes.Core.Sessions;

namespace KosmoNotes.Storage;

/// <summary>
/// Coordinates the filesystem sidecar layout and the SQLite index for sessions.
/// Mirrors the Swift <c>SessionStore</c> actor in
/// <c>Sources/StorageKit/SessionStore.swift</c>.
/// </summary>
/// <remarks>
/// Filesystem is the source of truth (per the stack invariant). Every mutation
/// writes <c>session.json</c> atomically first, then updates the DB. A future
/// rebuild can re-derive the DB from the sidecars.
/// </remarks>
public sealed class SessionStore
{
    private static readonly JsonSerializerOptions ReadOptions = new(JsonSerializerDefaults.Web);

    private readonly Database _database;

    /// <summary>
    /// Construct the store. <paramref name="rootDir"/> is created if missing.
    /// <paramref name="database"/> must already be migrated.
    /// </summary>
    public SessionStore(string rootDir, Database database)
    {
        ArgumentException.ThrowIfNullOrEmpty(rootDir);
        ArgumentNullException.ThrowIfNull(database);
        RecordingsRoot = rootDir;
        _database = database;
        Directory.CreateDirectory(rootDir);
    }

    /// <summary>Root directory holding all <c>&lt;sid&gt;/</c> session subdirectories.</summary>
    public string RecordingsRoot { get; }

    /// <summary>
    /// Create a new recording session: make the directory, write
    /// <c>session.json</c>, insert the DB row.
    /// </summary>
    public async Task<SessionRecord> CreateSessionAsync(SessionMode mode, string? language, CancellationToken ct = default)
    {
        string sid = Guid.NewGuid().ToString().ToLowerInvariant();
        string dir = SessionDir(sid);
        Directory.CreateDirectory(dir);

        var record = new SessionRecord(
            Id: sid,
            RecordedAt: DateTimeOffset.UtcNow,
            DurationSecs: 0,
            Mode: mode,
            Language: language,
            Status: SessionStatus.Recording,
            EnhancementStatus: SessionEnhancementStatus.Ok);

        WriteSessionJson(record, dir);
        await _database.InsertSessionAsync(record, ct).ConfigureAwait(false);
        return record;
    }

    /// <summary>
    /// Atomically rewrite <c>session.json</c> with the new status / duration /
    /// enhancement status, then update the DB row. Preserves the original
    /// <c>Id</c>, <c>RecordedAt</c>, <c>Mode</c>, and <c>Language</c>.
    /// </summary>
    public async Task<SessionRecord> FinalizeAsync(
        string id,
        SessionStatus status,
        double durationSecs,
        SessionEnhancementStatus enhancementStatus = SessionEnhancementStatus.Ok,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        string dir = SessionDir(id);
        SessionRecord existing = ReadSessionJson(dir);

        var updated = new SessionRecord(
            Id: existing.Id,
            RecordedAt: existing.RecordedAt,
            DurationSecs: durationSecs,
            Mode: existing.Mode,
            Language: existing.Language,
            Status: status,
            EnhancementStatus: enhancementStatus);

        WriteSessionJson(updated, dir);
        await _database.UpdateSessionAsync(updated, ct).ConfigureAwait(false);
        return updated;
    }

    /// <summary>Index transcript text into FTS5. Pass-through to <see cref="Database.IndexTranscriptAsync"/>.</summary>
    public Task IndexTranscriptAsync(string sid, string text, CancellationToken ct = default)
        => _database.IndexTranscriptAsync(sid, text, ct);

    /// <summary>Path to the directory holding sidecars for <paramref name="id"/>.</summary>
    public string SessionDir(string id)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        return Path.Combine(RecordingsRoot, id);
    }

    private static void WriteSessionJson(SessionRecord record, string dir)
    {
        string path = Path.Combine(dir, "session.json");
        AtomicWriter.WriteJson(record, path);
    }

    private static SessionRecord ReadSessionJson(string dir)
    {
        string path = Path.Combine(dir, "session.json");
        byte[] bytes = File.ReadAllBytes(path);
        SessionRecord? decoded = JsonSerializer.Deserialize<SessionRecord>(bytes, ReadOptions);
        if (decoded is null)
        {
            throw new InvalidOperationException($"session.json at '{path}' decoded to null.");
        }
        return decoded;
    }
}
