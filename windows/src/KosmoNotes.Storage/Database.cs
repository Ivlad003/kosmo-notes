using KosmoNotes.Core.Sessions;
using Microsoft.Data.Sqlite;

namespace KosmoNotes.Storage;

/// <summary>
/// SQLite-backed storage for sessions, transcripts (FTS5), and embeddings.
/// Mirrors the Swift <c>AppDatabase</c> actor in
/// <c>Sources/StorageKit/Database.swift</c>.
/// </summary>
/// <remarks>
/// <para>
/// Concurrency model: a single <see cref="SqliteConnection"/> guarded by a
/// <see cref="SemaphoreSlim"/>. WAL gives us crash safety on writes; the
/// per-call serialization cost is not material at v1 scale (hundreds of
/// sessions). If profiling later shows contention, split into one writer
/// connection + a pool of readers.
/// </para>
/// <para>
/// Migrations are tracked in a <c>_migrations</c> table by name (<c>v1</c>,
/// <c>v2_embeddings</c>, <c>v3_enhancement_status</c>) so re-running
/// <see cref="MigrateAsync"/> is idempotent.
/// </para>
/// </remarks>
public sealed class Database : IAsyncDisposable
{
    private static readonly object InitLock = new();
    private static bool _bundleInitialized;

    private readonly SqliteConnection _connection;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _disposed;

    /// <summary>
    /// Open or create the SQLite database at <paramref name="path"/>. Does NOT
    /// run migrations — call <see cref="MigrateAsync"/> after construction.
    /// </summary>
    /// <param name="path">Filesystem path to the SQLite database file.</param>
    public Database(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        EnsureBundleInitialized();

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Default,
            Pooling = false,
        };
        _connection = new SqliteConnection(builder.ConnectionString);
        _connection.Open();

        // Pragmas must be set per connection. WAL gives concurrent reads while
        // we write; foreign_keys=ON is REQUIRED for ON DELETE CASCADE on the
        // session_embeddings → sessions FK to actually fire (SQLite default
        // is OFF).
        ExecuteNonQuery("PRAGMA journal_mode=WAL;");
        ExecuteNonQuery("PRAGMA foreign_keys=ON;");
    }

    /// <summary>
    /// Apply schema migrations. Idempotent — safe to call multiple times.
    /// Mirrors the Swift <c>migrate()</c> with names <c>v1</c>,
    /// <c>v2_embeddings</c>, <c>v3_enhancement_status</c>.
    /// </summary>
    public async Task MigrateAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var tx = _connection.BeginTransaction();

            using (var cmd = _connection.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY);";
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            HashSet<string> applied = await LoadAppliedMigrationsAsync(tx, ct).ConfigureAwait(false);

            await ApplyIfMissingAsync(tx, applied, "v1", V1Sql, ct).ConfigureAwait(false);
            await ApplyIfMissingAsync(tx, applied, "v2_embeddings", V2Sql, ct).ConfigureAwait(false);
            await ApplyIfMissingAsync(tx, applied, "v3_enhancement_status", V3Sql, ct).ConfigureAwait(false);

            tx.Commit();
        }
        finally
        {
            _gate.Release();
        }
    }

    // ------------------------------------------------------------- Sessions

    /// <summary>Insert a new session row. Throws if <c>id</c> already exists.</summary>
    public async Task InsertSessionAsync(SessionRecord record, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(record);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = """
                INSERT INTO sessions (id, recorded_at, duration_secs, mode, language, status, enhancement_status)
                VALUES ($id, $recordedAt, $duration, $mode, $language, $status, $enhancement);
                """;
            cmd.Parameters.AddWithValue("$id", record.Id);
            cmd.Parameters.AddWithValue("$recordedAt", ToUnixSeconds(record.RecordedAt));
            cmd.Parameters.AddWithValue("$duration", record.DurationSecs);
            cmd.Parameters.AddWithValue("$mode", ModeToRaw(record.Mode));
            cmd.Parameters.AddWithValue("$language", (object?)record.Language ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$status", StatusToRaw(record.Status));
            cmd.Parameters.AddWithValue("$enhancement", EnhancementToRaw(record.EnhancementStatus));
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Update an existing session row by id. No-op if id is missing.</summary>
    public async Task UpdateSessionAsync(SessionRecord record, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(record);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = """
                UPDATE sessions
                SET recorded_at = $recordedAt,
                    duration_secs = $duration,
                    mode = $mode,
                    language = $language,
                    status = $status,
                    enhancement_status = $enhancement
                WHERE id = $id;
                """;
            cmd.Parameters.AddWithValue("$id", record.Id);
            cmd.Parameters.AddWithValue("$recordedAt", ToUnixSeconds(record.RecordedAt));
            cmd.Parameters.AddWithValue("$duration", record.DurationSecs);
            cmd.Parameters.AddWithValue("$mode", ModeToRaw(record.Mode));
            cmd.Parameters.AddWithValue("$language", (object?)record.Language ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$status", StatusToRaw(record.Status));
            cmd.Parameters.AddWithValue("$enhancement", EnhancementToRaw(record.EnhancementStatus));
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Fetch a session by id, or <c>null</c> if absent.</summary>
    public async Task<SessionRecord?> GetSessionAsync(string id, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "SELECT id, recorded_at, duration_secs, mode, language, status, enhancement_status FROM sessions WHERE id = $id;";
            cmd.Parameters.AddWithValue("$id", id);
            using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            if (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                return ReadSessionRow(reader);
            }
            return null;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>List sessions newest-first, capped to <paramref name="limit"/>.</summary>
    public async Task<IReadOnlyList<SessionRecord>> ListSessionsAsync(int limit = 100, CancellationToken ct = default)
    {
        if (limit < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(limit), "limit must be non-negative.");
        }
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = """
                SELECT id, recorded_at, duration_secs, mode, language, status, enhancement_status
                FROM sessions
                ORDER BY recorded_at DESC
                LIMIT $limit;
                """;
            cmd.Parameters.AddWithValue("$limit", limit);
            using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            var results = new List<SessionRecord>();
            while (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                results.Add(ReadSessionRow(reader));
            }
            return results;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Delete a session and its FTS / embedding rows by id. Idempotent — rows
    /// that don't exist are silently skipped. The on-disk session directory is
    /// the caller's responsibility.
    /// </summary>
    public async Task DeleteSessionAsync(string id, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var tx = _connection.BeginTransaction();

            using (var cmd = _connection.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "DELETE FROM transcripts_fts WHERE sid = $id;";
                cmd.Parameters.AddWithValue("$id", id);
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            using (var cmd = _connection.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "DELETE FROM session_embeddings WHERE sid = $id;";
                cmd.Parameters.AddWithValue("$id", id);
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            using (var cmd = _connection.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "DELETE FROM sessions WHERE id = $id;";
                cmd.Parameters.AddWithValue("$id", id);
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            tx.Commit();
        }
        finally
        {
            _gate.Release();
        }
    }

    // ------------------------------------------------------------------ FTS

    /// <summary>Index a transcript text blob into the FTS5 virtual table.</summary>
    public async Task IndexTranscriptAsync(string sid, string text, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(sid);
        ArgumentNullException.ThrowIfNull(text);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "INSERT INTO transcripts_fts (sid, text) VALUES ($sid, $text);";
            cmd.Parameters.AddWithValue("$sid", sid);
            cmd.Parameters.AddWithValue("$text", text);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Full-text search. Returns up to <paramref name="limit"/> hits with an
    /// FTS5 <c>snippet()</c> for each, wrapping matches in <c>&lt;b&gt;...&lt;/b&gt;</c>.
    /// Empty / punctuation-only queries return an empty list.
    /// </summary>
    public async Task<IReadOnlyList<SearchHit>> SearchTranscriptsAsync(string query, int limit = 50, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (limit < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(limit), "limit must be non-negative.");
        }
        string? pattern = Fts5Pattern.MatchingAllTokensIn(query);
        if (pattern is null)
        {
            return Array.Empty<SearchHit>();
        }

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = """
                SELECT sid,
                       snippet(transcripts_fts, 1, '<b>', '</b>', '…', 10) AS snip
                FROM transcripts_fts
                WHERE transcripts_fts MATCH $pattern
                LIMIT $limit;
                """;
            cmd.Parameters.AddWithValue("$pattern", pattern);
            cmd.Parameters.AddWithValue("$limit", limit);
            using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            var results = new List<SearchHit>();
            while (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                results.Add(new SearchHit(
                    reader.GetString(0),
                    reader.GetString(1)));
            }
            return results;
        }
        finally
        {
            _gate.Release();
        }
    }

    // ----------------------------------------------------------- Embeddings

    /// <summary>Insert or replace the embedding vector for a session.</summary>
    public async Task UpsertEmbeddingAsync(string sid, byte[] vector, string model, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(sid);
        ArgumentNullException.ThrowIfNull(vector);
        ArgumentException.ThrowIfNullOrEmpty(model);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = """
                INSERT INTO session_embeddings (sid, vector, model, indexed_at)
                VALUES ($sid, $vector, $model, $indexedAt)
                ON CONFLICT(sid) DO UPDATE SET
                    vector = excluded.vector,
                    model = excluded.model,
                    indexed_at = excluded.indexed_at;
                """;
            cmd.Parameters.AddWithValue("$sid", sid);
            cmd.Parameters.AddWithValue("$vector", vector);
            cmd.Parameters.AddWithValue("$model", model);
            cmd.Parameters.AddWithValue("$indexedAt", ToUnixSeconds(DateTimeOffset.UtcNow));
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Read all stored embeddings. Order is undefined — callers compute cosine
    /// similarity in-memory and sort downstream.
    /// </summary>
    public async Task<IReadOnlyList<EmbeddingRow>> AllEmbeddingsAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "SELECT sid, vector, model FROM session_embeddings;";
            using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            var results = new List<EmbeddingRow>();
            while (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                string sid = reader.GetString(0);
                byte[] vector = (byte[])reader.GetValue(1);
                string model = reader.GetString(2);
                results.Add(new EmbeddingRow(sid, vector, model));
            }
            return results;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Returns true if an embedding row exists for <paramref name="sid"/>.</summary>
    public async Task<bool> HasEmbeddingAsync(string sid, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(sid);
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "SELECT 1 FROM session_embeddings WHERE sid = $sid LIMIT 1;";
            cmd.Parameters.AddWithValue("$sid", sid);
            object? result = await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false);
            return result is not null && result is not DBNull;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Close the underlying SQLite connection and release the gate semaphore.</summary>
    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        await _connection.DisposeAsync().ConfigureAwait(false);
        _gate.Dispose();
    }

    // ---------------------------------------------------------- Internals

    private static void EnsureBundleInitialized()
    {
        if (_bundleInitialized)
        {
            return;
        }
        lock (InitLock)
        {
            if (_bundleInitialized)
            {
                return;
            }
            // Required before opening any SqliteConnection — wires up the native
            // SQLitePCLRaw bindings. The bundle_e_sqlite3 package ships an
            // FTS5-enabled build, so no extra compile flags are needed.
            SQLitePCL.Batteries.Init();
            _bundleInitialized = true;
        }
    }

    private void ExecuteNonQuery(string sql)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private async Task<HashSet<string>> LoadAppliedMigrationsAsync(SqliteTransaction tx, CancellationToken ct)
    {
        using var cmd = _connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT name FROM _migrations;";
        var applied = new HashSet<string>(StringComparer.Ordinal);
        using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            applied.Add(reader.GetString(0));
        }
        return applied;
    }

    private async Task ApplyIfMissingAsync(
        SqliteTransaction tx,
        HashSet<string> applied,
        string name,
        string sql,
        CancellationToken ct)
    {
        if (applied.Contains(name))
        {
            return;
        }
        using (var cmd = _connection.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = sql;
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        using (var cmd = _connection.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO _migrations (name) VALUES ($name);";
            cmd.Parameters.AddWithValue("$name", name);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
    }

    private static SessionRecord ReadSessionRow(SqliteDataReader reader)
    {
        string id = reader.GetString(0);
        double epoch = Convert.ToDouble(reader.GetValue(1), System.Globalization.CultureInfo.InvariantCulture);
        double duration = Convert.ToDouble(reader.GetValue(2), System.Globalization.CultureInfo.InvariantCulture);
        string modeRaw = reader.GetString(3);
        string? language = reader.IsDBNull(4) ? null : reader.GetString(4);
        string statusRaw = reader.GetString(5);
        // enhancement_status is NOT NULL with default 'ok' after v3, but be
        // defensive in case a stale connection ever sees a pre-v3 row.
        string? enhancementRaw = reader.IsDBNull(6) ? null : reader.GetString(6);

        return new SessionRecord(
            id,
            FromUnixSeconds(epoch),
            duration,
            ModeFromRaw(modeRaw),
            language,
            StatusFromRaw(statusRaw),
            EnhancementFromRaw(enhancementRaw));
    }

    private static double ToUnixSeconds(DateTimeOffset value)
        => value.ToUnixTimeMilliseconds() / 1000.0;

    private static DateTimeOffset FromUnixSeconds(double seconds)
        => DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(seconds * 1000.0));

    private static string ModeToRaw(SessionMode mode) => mode switch
    {
        SessionMode.Meeting => "meeting",
        SessionMode.Dictation => "dictation",
        SessionMode.VoiceNote => "voiceNote",
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, "Unknown SessionMode."),
    };

    private static SessionMode ModeFromRaw(string raw) => raw switch
    {
        "meeting" => SessionMode.Meeting,
        "dictation" => SessionMode.Dictation,
        "voiceNote" => SessionMode.VoiceNote,
        _ => throw new InvalidOperationException($"Unknown SessionMode raw value '{raw}'."),
    };

    private static string StatusToRaw(SessionStatus status) => status switch
    {
        SessionStatus.Recording => "recording",
        SessionStatus.Transcribing => "transcribing",
        SessionStatus.Complete => "complete",
        SessionStatus.Failed => "failed",
        _ => throw new ArgumentOutOfRangeException(nameof(status), status, "Unknown SessionStatus."),
    };

    private static SessionStatus StatusFromRaw(string raw) => raw switch
    {
        "recording" => SessionStatus.Recording,
        "transcribing" => SessionStatus.Transcribing,
        "complete" => SessionStatus.Complete,
        "failed" => SessionStatus.Failed,
        _ => throw new InvalidOperationException($"Unknown SessionStatus raw value '{raw}'."),
    };

    private static string EnhancementToRaw(SessionEnhancementStatus status) => status switch
    {
        SessionEnhancementStatus.Ok => "ok",
        SessionEnhancementStatus.Partial => "partial",
        _ => throw new ArgumentOutOfRangeException(nameof(status), status, "Unknown SessionEnhancementStatus."),
    };

    private static SessionEnhancementStatus EnhancementFromRaw(string? raw) => raw switch
    {
        null => SessionEnhancementStatus.Ok,
        "ok" => SessionEnhancementStatus.Ok,
        "partial" => SessionEnhancementStatus.Partial,
        _ => SessionEnhancementStatus.Ok,
    };

    // -------------------------------------------------------------- Schema

    private const string V1Sql = """
        CREATE TABLE sessions (
            id            TEXT    PRIMARY KEY,
            recorded_at   REAL    NOT NULL,
            duration_secs REAL    NOT NULL DEFAULT 0,
            mode          TEXT    NOT NULL,
            language      TEXT,
            status        TEXT    NOT NULL
        );
        CREATE INDEX idx_sessions_recorded_at ON sessions(recorded_at DESC);
        CREATE VIRTUAL TABLE transcripts_fts USING fts5(
            sid UNINDEXED,
            text,
            tokenize = 'porter unicode61'
        );
        """;

    private const string V2Sql = """
        CREATE TABLE session_embeddings (
            sid         TEXT    PRIMARY KEY,
            vector      BLOB    NOT NULL,
            model       TEXT    NOT NULL,
            indexed_at  REAL    NOT NULL,
            FOREIGN KEY(sid) REFERENCES sessions(id) ON DELETE CASCADE
        );
        """;

    private const string V3Sql = """
        ALTER TABLE sessions
        ADD COLUMN enhancement_status TEXT NOT NULL DEFAULT 'ok';
        """;
}
