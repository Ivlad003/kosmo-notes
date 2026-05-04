using KosmoNotes.Core.Transcription;

namespace KosmoNotes.Providers;

/// <summary>
/// File-upload transcription provider. Mirrors the Swift
/// <c>BatchTranscriptionProvider</c> protocol.
/// </summary>
public interface IBatchTranscriptionProvider
{
    /// <summary>
    /// Upload <paramref name="audioFilePath"/> to the provider and return the
    /// final transcript with word-level timing grouped into ~5 s segments.
    /// </summary>
    /// <param name="audioFilePath">Absolute path to a local audio file.</param>
    /// <param name="config">Per-call configuration (language hint).</param>
    /// <param name="ct">Cancellation token.</param>
    Task<BatchTranscriptResult> TranscribeAsync(
        string audioFilePath,
        TranscriptionConfig config,
        CancellationToken ct = default);
}
