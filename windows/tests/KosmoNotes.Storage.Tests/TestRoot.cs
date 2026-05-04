namespace KosmoNotes.Storage.Tests;

/// <summary>
/// Disposable scratch directory under <c>%TEMP%</c> used by tests that need
/// real filesystem isolation. Cleans itself up on dispose.
/// </summary>
internal sealed class TestRoot : IDisposable
{
    public string Path { get; }

    public TestRoot()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(Path);
    }

    public string Db => System.IO.Path.Combine(Path, "sessions.sqlite");

    public string Dir(string sub) => System.IO.Path.Combine(Path, sub);

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
        catch
        {
            // Best effort. WAL sidecar files may briefly linger on Windows.
        }
    }
}
