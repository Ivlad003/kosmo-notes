namespace KosmoNotes.Core.Transcription;

/// <summary>
/// Result of a batch (file-upload) transcription. Mirrors the Swift
/// <c>BatchTranscriptResult</c> struct.
/// </summary>
/// <param name="Language">Detected BCP-47 language code, or <c>null</c> when unknown.</param>
/// <param name="Duration">Audio duration in seconds (provider-reported).</param>
/// <param name="Segments">~5 s grouped segments suitable for display.</param>
/// <param name="Text">Single concatenated plain-text transcript.</param>
public sealed record BatchTranscriptResult(
    string? Language,
    double Duration,
    IReadOnlyList<TranscriptSegment> Segments,
    string Text);
