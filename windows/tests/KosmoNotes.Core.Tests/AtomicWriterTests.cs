using System.Text;
using KosmoNotes.Core.IO;

namespace KosmoNotes.Core.Tests;

public class AtomicWriterTests : IDisposable
{
    private readonly string _tempDir;

    public AtomicWriterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"kn-atomic-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempDir))
            {
                Directory.Delete(_tempDir, recursive: true);
            }
        }
        catch
        {
            // best-effort
        }
    }

    [Fact]
    public void Write_NewFile_PersistsBytes()
    {
        string path = Path.Combine(_tempDir, "fresh.bin");
        byte[] data = Encoding.UTF8.GetBytes("hello, atomic world");
        AtomicWriter.Write(data, path);

        Assert.True(File.Exists(path));
        Assert.Equal(data, File.ReadAllBytes(path));
    }

    [Fact]
    public void Write_OverwritesExistingFile()
    {
        string path = Path.Combine(_tempDir, "overwrite.bin");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("old contents"));

        byte[] newData = Encoding.UTF8.GetBytes("new contents");
        AtomicWriter.Write(newData, path);

        Assert.Equal(newData, File.ReadAllBytes(path));
    }

    [Fact]
    public void Write_LeavesNoTempFilesAfterSuccess()
    {
        string path = Path.Combine(_tempDir, "clean.bin");
        AtomicWriter.Write(Encoding.UTF8.GetBytes("hi"), path);

        string[] tempFiles = Directory.GetFiles(_tempDir, "*.tmp.*");
        Assert.Empty(tempFiles);
    }

    [Fact]
    public void Write_FailsWhenParentDirMissing_AndCleansUpTemp()
    {
        string nonexistentDir = Path.Combine(_tempDir, "does", "not", "exist");
        string path = Path.Combine(nonexistentDir, "x.bin");

        Assert.Throws<AtomicWriterException>(() =>
            AtomicWriter.Write(Encoding.UTF8.GetBytes("data"), path));

        Assert.False(File.Exists(path));
        // No stray .tmp files in our temp root.
        Assert.Empty(Directory.GetFiles(_tempDir, "*.tmp.*", SearchOption.AllDirectories));
    }

    [Fact]
    public void Write_NullData_Throws()
    {
        string path = Path.Combine(_tempDir, "null.bin");
        Assert.Throws<ArgumentNullException>(() => AtomicWriter.Write(null!, path));
    }

    [Fact]
    public void Write_EmptyPath_Throws()
    {
        Assert.Throws<ArgumentException>(() => AtomicWriter.Write(new byte[] { 1, 2 }, string.Empty));
    }

    [Fact]
    public void WriteJson_RoundTripsCamelCaseFields()
    {
        string path = Path.Combine(_tempDir, "obj.json");
        var value = new SamplePayload(Identifier: "abc", Count: 7);
        AtomicWriter.WriteJson(value, path);

        string text = File.ReadAllText(path);
        Assert.Contains("\"identifier\":\"abc\"", text);
        Assert.Contains("\"count\":7", text);
    }

    [Fact]
    public void WriteJson_OverwritesExisting()
    {
        string path = Path.Combine(_tempDir, "obj.json");
        AtomicWriter.WriteJson(new SamplePayload("first", 1), path);
        AtomicWriter.WriteJson(new SamplePayload("second", 2), path);

        string text = File.ReadAllText(path);
        Assert.Contains("\"identifier\":\"second\"", text);
        Assert.Contains("\"count\":2", text);
        Assert.DoesNotContain("first", text);
    }

    private sealed record SamplePayload(string Identifier, int Count);
}
