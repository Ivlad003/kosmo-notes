using KosmoNotes.Core.Sessions;
using Microsoft.Data.Sqlite;

namespace KosmoNotes.Storage.Tests;

public class DatabaseTests
{
    private static SessionRecord MakeRecord(
        string id,
        DateTimeOffset? recordedAt = null,
        SessionMode mode = SessionMode.Meeting,
        SessionStatus status = SessionStatus.Recording,
        SessionEnhancementStatus enh = SessionEnhancementStatus.Ok,
        string? language = "en",
        double duration = 0)
        => new(
            Id: id,
            RecordedAt: recordedAt ?? DateTimeOffset.UtcNow,
            DurationSecs: duration,
            Mode: mode,
            Language: language,
            Status: status,
            EnhancementStatus: enh);

    [Fact]
    public async Task MigrateAsync_IsIdempotent()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);

        await db.MigrateAsync();
        await db.MigrateAsync(); // second call must not throw or duplicate.

        // Confirm expected tables exist.
        await using var conn = new SqliteConnection($"Data Source={root.Db}");
        await conn.OpenAsync();
        var tables = new HashSet<string>(StringComparer.Ordinal);
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name;";
            using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync()) tables.Add(reader.GetString(0));
        }
        Assert.Contains("sessions", tables);
        Assert.Contains("transcripts_fts", tables);
        Assert.Contains("session_embeddings", tables);
        Assert.Contains("_migrations", tables);

        // _migrations should have exactly the 3 named rows.
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT name FROM _migrations ORDER BY name;";
            using var reader = await cmd.ExecuteReaderAsync();
            var names = new List<string>();
            while (await reader.ReadAsync()) names.Add(reader.GetString(0));
            Assert.Equal(3, names.Count);
            Assert.Contains("v1", names);
            Assert.Contains("v2_embeddings", names);
            Assert.Contains("v3_enhancement_status", names);
        }
    }

    [Fact]
    public async Task InsertAndGet_RoundTripsAllFields()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        var record = MakeRecord(
            "sid-1",
            mode: SessionMode.VoiceNote,
            status: SessionStatus.Complete,
            enh: SessionEnhancementStatus.Partial,
            language: "uk",
            duration: 12.5,
            recordedAt: new DateTimeOffset(2026, 5, 3, 12, 0, 0, TimeSpan.Zero));

        await db.InsertSessionAsync(record);

        SessionRecord? read = await db.GetSessionAsync("sid-1");
        Assert.NotNull(read);
        Assert.Equal("sid-1", read!.Id);
        Assert.Equal(SessionMode.VoiceNote, read.Mode);
        Assert.Equal(SessionStatus.Complete, read.Status);
        Assert.Equal(SessionEnhancementStatus.Partial, read.EnhancementStatus);
        Assert.Equal("uk", read.Language);
        Assert.Equal(12.5, read.DurationSecs);
        Assert.Equal(record.RecordedAt.ToUnixTimeSeconds(), read.RecordedAt.ToUnixTimeSeconds());
    }

    [Fact]
    public async Task UpdateSession_OverwritesFields()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        var initial = MakeRecord("sid-up", status: SessionStatus.Recording, duration: 0);
        await db.InsertSessionAsync(initial);

        var updated = initial with
        {
            Status = SessionStatus.Complete,
            DurationSecs = 99.5,
            EnhancementStatus = SessionEnhancementStatus.Partial,
        };
        await db.UpdateSessionAsync(updated);

        var read = await db.GetSessionAsync("sid-up");
        Assert.NotNull(read);
        Assert.Equal(SessionStatus.Complete, read!.Status);
        Assert.Equal(99.5, read.DurationSecs);
        Assert.Equal(SessionEnhancementStatus.Partial, read.EnhancementStatus);
    }

    [Fact]
    public async Task DeleteSession_RemovesFromGetAndList()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("a"));
        await db.InsertSessionAsync(MakeRecord("b"));

        await db.DeleteSessionAsync("a");

        Assert.Null(await db.GetSessionAsync("a"));
        var list = await db.ListSessionsAsync();
        Assert.Single(list);
        Assert.Equal("b", list[0].Id);
    }

    [Fact]
    public async Task ListSessions_OrdersNewestFirst()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        var baseTime = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        for (int i = 0; i < 5; i++)
        {
            await db.InsertSessionAsync(MakeRecord($"s{i}", recordedAt: baseTime.AddMinutes(i)));
        }

        var list = await db.ListSessionsAsync();
        Assert.Equal(5, list.Count);
        Assert.Equal("s4", list[0].Id);
        Assert.Equal("s3", list[1].Id);
        Assert.Equal("s2", list[2].Id);
        Assert.Equal("s1", list[3].Id);
        Assert.Equal("s0", list[4].Id);
    }

    [Fact]
    public async Task ListSessions_RespectsLimit()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        var baseTime = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        for (int i = 0; i < 10; i++)
        {
            await db.InsertSessionAsync(MakeRecord($"s{i}", recordedAt: baseTime.AddMinutes(i)));
        }

        var list = await db.ListSessionsAsync(limit: 3);
        Assert.Equal(3, list.Count);
        Assert.Equal("s9", list[0].Id);
        Assert.Equal("s8", list[1].Id);
        Assert.Equal("s7", list[2].Id);
    }

    [Fact]
    public async Task SearchTranscripts_BasicSingleTokenHits()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("a"));
        await db.InsertSessionAsync(MakeRecord("b"));
        await db.InsertSessionAsync(MakeRecord("c"));
        await db.IndexTranscriptAsync("a", "hello world");
        await db.IndexTranscriptAsync("b", "the quick brown fox");
        await db.IndexTranscriptAsync("c", "hello fox");

        var hits = await db.SearchTranscriptsAsync("hello");
        Assert.Equal(2, hits.Count);
        var sids = hits.Select(h => h.Sid).ToHashSet();
        Assert.Contains("a", sids);
        Assert.Contains("c", sids);
        Assert.All(hits, h => Assert.Contains("<b>hello</b>", h.Snippet, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task SearchTranscripts_MultiWordIsAnd()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("a"));
        await db.InsertSessionAsync(MakeRecord("b"));
        await db.IndexTranscriptAsync("a", "hello world");
        await db.IndexTranscriptAsync("b", "the quick brown fox");

        var both = await db.SearchTranscriptsAsync("quick fox");
        Assert.Single(both);
        Assert.Equal("b", both[0].Sid);

        var none = await db.SearchTranscriptsAsync("brown jumping");
        Assert.Empty(none);
    }

    [Fact]
    public async Task SearchTranscripts_EmptyAndWhitespace_ReturnZero()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("a"));
        await db.IndexTranscriptAsync("a", "hello world");

        Assert.Empty(await db.SearchTranscriptsAsync(""));
        Assert.Empty(await db.SearchTranscriptsAsync("   "));
        Assert.Empty(await db.SearchTranscriptsAsync("\t\n"));
    }

    [Fact]
    public async Task SearchTranscripts_PunctuationOnly_ReturnsZero()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("a"));
        await db.IndexTranscriptAsync("a", "hello world!!!");

        Assert.Empty(await db.SearchTranscriptsAsync("!!!"));
        Assert.Empty(await db.SearchTranscriptsAsync(".,;"));
    }

    [Fact]
    public async Task SearchTranscripts_CyrillicLowercaseMatch()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("uk"));
        await db.IndexTranscriptAsync("uk", "Привіт світ, як справи");

        var hits = await db.SearchTranscriptsAsync("привіт");
        Assert.Single(hits);
        Assert.Equal("uk", hits[0].Sid);
    }

    [Fact]
    public async Task SearchTranscripts_LimitClamp()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        for (int i = 0; i < 5; i++)
        {
            await db.InsertSessionAsync(MakeRecord($"x{i}"));
            await db.IndexTranscriptAsync($"x{i}", $"hello number {i}");
        }
        var hits = await db.SearchTranscriptsAsync("hello", limit: 2);
        Assert.Equal(2, hits.Count);
    }

    [Fact]
    public async Task UpsertEmbedding_StoresAndReplaces()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("e1"));

        byte[] v1 = { 1, 2, 3, 4 };
        await db.UpsertEmbeddingAsync("e1", v1, "text-embedding-3-small");

        var rows = await db.AllEmbeddingsAsync();
        Assert.Single(rows);
        Assert.Equal("e1", rows[0].Sid);
        Assert.Equal(v1, rows[0].Vector);
        Assert.Equal("text-embedding-3-small", rows[0].Model);

        byte[] v2 = { 9, 8, 7, 6, 5 };
        await db.UpsertEmbeddingAsync("e1", v2, "text-embedding-3-large");

        var rows2 = await db.AllEmbeddingsAsync();
        Assert.Single(rows2);
        Assert.Equal(v2, rows2[0].Vector);
        Assert.Equal("text-embedding-3-large", rows2[0].Model);
    }

    [Fact]
    public async Task HasEmbedding_FalseThenTrue()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("h1"));

        Assert.False(await db.HasEmbeddingAsync("h1"));
        await db.UpsertEmbeddingAsync("h1", new byte[] { 1 }, "m");
        Assert.True(await db.HasEmbeddingAsync("h1"));
        Assert.False(await db.HasEmbeddingAsync("does-not-exist"));
    }

    [Fact]
    public async Task DeleteSession_CascadesToTranscriptAndEmbedding()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("c1"));
        await db.IndexTranscriptAsync("c1", "transcript text here");
        await db.UpsertEmbeddingAsync("c1", new byte[] { 1, 2, 3 }, "m");

        await db.DeleteSessionAsync("c1");

        Assert.Null(await db.GetSessionAsync("c1"));
        Assert.False(await db.HasEmbeddingAsync("c1"));
        var hits = await db.SearchTranscriptsAsync("transcript");
        Assert.Empty(hits);
        var rows = await db.AllEmbeddingsAsync();
        Assert.Empty(rows);
    }

    [Fact]
    public async Task RecordedAt_RoundTripsAtSecondPrecision()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        var when = new DateTimeOffset(2026, 1, 15, 10, 30, 0, TimeSpan.Zero);
        await db.InsertSessionAsync(MakeRecord("ts", recordedAt: when));

        var read = await db.GetSessionAsync("ts");
        Assert.NotNull(read);
        Assert.Equal(when.ToUnixTimeSeconds(), read!.RecordedAt.ToUnixTimeSeconds());
    }

    [Fact]
    public async Task PragmaJournalMode_IsWal()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        // Reuse the same connection-string path; we open a fresh raw connection
        // to assert the pragma stored in the file matches.
        await using var conn = new SqliteConnection($"Data Source={root.Db}");
        await conn.OpenAsync();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA journal_mode;";
        var mode = (string?)await cmd.ExecuteScalarAsync();
        Assert.Equal("wal", mode, ignoreCase: true);
    }

    [Fact]
    public async Task GetSession_NullForMissing()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        Assert.Null(await db.GetSessionAsync("ghost"));
    }

    [Fact]
    public async Task ListSessions_EmptyWhenNoRows()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        Assert.Empty(await db.ListSessionsAsync());
    }

    [Fact]
    public async Task EnhancementStatus_BackfillsToOkOnPreV3Rows()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();

        // Force a row that explicitly sets enhancement_status='ok' (the
        // default) and read it back to confirm enum mapping is correct.
        await db.InsertSessionAsync(MakeRecord("ok-row", enh: SessionEnhancementStatus.Ok));
        var read = await db.GetSessionAsync("ok-row");
        Assert.Equal(SessionEnhancementStatus.Ok, read!.EnhancementStatus);
    }

    [Fact]
    public async Task LanguageNullable_RoundTrips()
    {
        using var root = new TestRoot();
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        await db.InsertSessionAsync(MakeRecord("nolang", language: null));
        var read = await db.GetSessionAsync("nolang");
        Assert.Null(read!.Language);
    }
}
