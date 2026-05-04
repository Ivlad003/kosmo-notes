using System.Diagnostics;
using System.Text.Json;

namespace KosmoNotes.Core.IO;

/// <summary>
/// Base class for atomic-write failures. Mirrors the Swift
/// <c>AtomicWriterError</c> enum cases.
/// </summary>
public class AtomicWriterException : Exception
{
    /// <summary>Create a new atomic-write failure.</summary>
    public AtomicWriterException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Atomic file writer using the tmp + flush(true) + rename pattern. Mirrors
/// the Swift <c>AtomicWriter</c> in <c>Sources/StorageKit/AtomicWriter.swift</c>.
/// </summary>
/// <remarks>
/// <para>
/// On Unix the Swift implementation also fsyncs the parent directory after the
/// rename so the rename itself is durable across power loss. On Windows the
/// equivalent durability story is provided by <c>MoveFileEx</c>'s
/// <c>MOVEFILE_REPLACE_EXISTING</c> semantics, which is what
/// <see cref="System.IO.File.Move(string, string, bool)"/> uses on .NET 8.
/// </para>
/// <para>
/// <strong>Deviation from Swift:</strong> the parent-directory <c>fsync</c> is skipped
/// on all platforms. On Windows it is unavailable; on Unix it would require
/// P/Invoke into <c>open(2)</c> + <c>fsync(2)</c>, and v1 of the Windows port
/// relies on <see cref="FileStream.Flush(bool)"/> for the data file plus
/// <c>File.Move(overwrite: true)</c> for the rename. Acceptable for v1 — this
/// helper is used for human-edited config and per-session sidecars, not for
/// crash-critical bookkeeping.
/// </para>
/// </remarks>
public static class AtomicWriter
{
    /// <summary>
    /// Atomically write <paramref name="data"/> to <paramref name="path"/>.
    /// </summary>
    /// <remarks>
    /// The bytes are first written to <c>&lt;path&gt;.tmp.&lt;pid&gt;</c>, the temp file
    /// is flushed to disk via <see cref="FileStream.Flush(bool)"/>, then the
    /// temp file is renamed over the destination. The temp file is removed on
    /// any error path (best effort).
    /// </remarks>
    /// <exception cref="AtomicWriterException">Thrown on filesystem errors.</exception>
    public static void Write(byte[] data, string path)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentException.ThrowIfNullOrEmpty(path);

        string tmpPath = $"{path}.tmp.{Environment.ProcessId}";

        // Phase 1: write + flush(true).
        try
        {
            using var fs = new FileStream(
                tmpPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None);
            fs.Write(data, 0, data.Length);
            // Flush user-mode buffers AND ask the OS to flush its buffers to disk.
            fs.Flush(flushToDisk: true);
        }
        catch (Exception ex)
        {
            BestEffortDeleteTemp(tmpPath);
            throw new AtomicWriterException($"Write to temp file failed: {tmpPath}", ex);
        }

        // Phase 2: atomic rename. File.Move(overwrite:true) on .NET 8 uses
        // MoveFileEx(MOVEFILE_REPLACE_EXISTING) on Windows and rename(2) on
        // Unix — both are atomic at the FS level.
        try
        {
            File.Move(tmpPath, path, overwrite: true);
        }
        catch (Exception ex)
        {
            BestEffortDeleteTemp(tmpPath);
            throw new AtomicWriterException($"Rename to destination failed: {path}", ex);
        }
    }

    /// <summary>
    /// JSON-encode <paramref name="value"/> with web defaults (camelCase) and
    /// atomically write to <paramref name="path"/>.
    /// </summary>
    public static void WriteJson<T>(T value, string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value, options);
        Write(bytes, path);
    }

    private static void BestEffortDeleteTemp(string tmpPath)
    {
        try
        {
            if (File.Exists(tmpPath))
            {
                File.Delete(tmpPath);
            }
        }
        catch (Exception ex)
        {
            // Swallow; mirrors Swift's `try?` cleanup. Log to the debug stream
            // so it's at least observable in attached debuggers.
            Debug.WriteLine($"[AtomicWriter] Failed to clean up temp file {tmpPath}: {ex.Message}");
        }
    }
}
