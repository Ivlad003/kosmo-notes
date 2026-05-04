using System.Text.Json;
using KosmoNotes.Core.Sessions;

namespace KosmoNotes.Storage.Tests;

public class SessionStoreTests
{
    private static async Task<(TestRoot root, Database db, SessionStore store)> BuildAsync()
    {
        var root = new TestRoot();
        var db = new Database(root.Db);
        await db.MigrateAsync();
        var store = new SessionStore(root.Dir("recordings"), db);
        return (root, db, store);
    }

    [Fact]
    public async Task CreateSession_WritesSidecarAndDbRow()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            var record = await store.CreateSessionAsync(SessionMode.Meeting, "en");
            string sidecar = Path.Combine(store.SessionDir(record.Id), "session.json");
            Assert.True(File.Exists(sidecar));

            byte[] bytes = await File.ReadAllBytesAsync(sidecar);
            var decoded = JsonSerializer.Deserialize<SessionRecord>(bytes, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            Assert.NotNull(decoded);
            Assert.Equal(record.Id, decoded!.Id);
            Assert.Equal(SessionStatus.Recording, decoded.Status);

            var fromDb = await db.GetSessionAsync(record.Id);
            Assert.NotNull(fromDb);
            Assert.Equal(SessionMode.Meeting, fromDb!.Mode);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task CreateSession_GeneratesLowercaseGuid()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            var rec = await store.CreateSessionAsync(SessionMode.Dictation, null);
            Assert.Equal(rec.Id, rec.Id.ToLowerInvariant());
            Assert.True(Guid.TryParse(rec.Id, out _));
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task Finalize_PreservesImmutableFields()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            var created = await store.CreateSessionAsync(SessionMode.VoiceNote, "uk");
            DateTimeOffset originalRecordedAt = created.RecordedAt;

            var finalized = await store.FinalizeAsync(
                created.Id,
                SessionStatus.Complete,
                durationSecs: 42.5);

            Assert.Equal(created.Id, finalized.Id);
            Assert.Equal(originalRecordedAt, finalized.RecordedAt);
            Assert.Equal(SessionMode.VoiceNote, finalized.Mode);
            Assert.Equal("uk", finalized.Language);
            Assert.Equal(SessionStatus.Complete, finalized.Status);
            Assert.Equal(42.5, finalized.DurationSecs);

            // Sidecar reflects the same.
            string sidecar = Path.Combine(store.SessionDir(created.Id), "session.json");
            byte[] bytes = await File.ReadAllBytesAsync(sidecar);
            var decoded = JsonSerializer.Deserialize<SessionRecord>(bytes, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            Assert.NotNull(decoded);
            Assert.Equal(SessionMode.VoiceNote, decoded!.Mode);
            Assert.Equal(SessionStatus.Complete, decoded.Status);
            Assert.Equal(42.5, decoded.DurationSecs);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task Finalize_WithEnhancementPartial_PersistsRaw()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            var created = await store.CreateSessionAsync(SessionMode.Meeting, null);
            var finalized = await store.FinalizeAsync(
                created.Id,
                SessionStatus.Complete,
                durationSecs: 10,
                enhancementStatus: SessionEnhancementStatus.Partial);
            Assert.Equal(SessionEnhancementStatus.Partial, finalized.EnhancementStatus);

            // Sidecar JSON contains the literal "partial" string.
            string sidecar = Path.Combine(store.SessionDir(created.Id), "session.json");
            string raw = await File.ReadAllTextAsync(sidecar);
            Assert.Contains("\"enhancementStatus\":\"partial\"", raw, StringComparison.Ordinal);

            // Round-trips through JsonSerializer (Core's converter handles older sidecars).
            var fromDisk = JsonSerializer.Deserialize<SessionRecord>(raw, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            Assert.Equal(SessionEnhancementStatus.Partial, fromDisk!.EnhancementStatus);

            // DB row tracks the partial status too.
            var fromDb = await db.GetSessionAsync(created.Id);
            Assert.Equal(SessionEnhancementStatus.Partial, fromDb!.EnhancementStatus);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task ConcurrentCreateSession_ProducesUniqueRows()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            const int N = 20;
            var tasks = new Task<SessionRecord>[N];
            for (int i = 0; i < N; i++)
            {
                tasks[i] = Task.Run(() => store.CreateSessionAsync(SessionMode.Meeting, "en"));
            }
            var records = await Task.WhenAll(tasks);
            var ids = records.Select(r => r.Id).ToHashSet();
            Assert.Equal(N, ids.Count);

            var listed = await db.ListSessionsAsync(limit: N + 5);
            Assert.Equal(N, listed.Count);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task IndexTranscript_PassesThrough()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            var rec = await store.CreateSessionAsync(SessionMode.Meeting, "en");
            await store.IndexTranscriptAsync(rec.Id, "indexed via store");
            var hits = await db.SearchTranscriptsAsync("indexed");
            Assert.Single(hits);
            Assert.Equal(rec.Id, hits[0].Sid);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task SessionDir_BuildsExpectedPath()
    {
        var (root, db, store) = await BuildAsync();
        try
        {
            string dir = store.SessionDir("abc");
            Assert.Equal(Path.Combine(store.RecordingsRoot, "abc"), dir);
        }
        finally
        {
            await db.DisposeAsync();
            root.Dispose();
        }
    }

    [Fact]
    public async Task Constructor_CreatesRootDir()
    {
        using var root = new TestRoot();
        string recordings = root.Dir("recordings-new");
        Assert.False(Directory.Exists(recordings));
        await using var db = new Database(root.Db);
        await db.MigrateAsync();
        _ = new SessionStore(recordings, db);
        Assert.True(Directory.Exists(recordings));
    }
}
