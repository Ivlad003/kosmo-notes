namespace KosmoNotes.Core.Transcription;

/// <summary>
/// One unit of transcribed audio. Mirrors the Swift <c>TranscriptSegment</c> struct.
/// </summary>
/// <remarks>
/// Stored on disk as one JSONL line in <c>transcript.jsonl</c>. Only
/// <see cref="IsFinal"/> = <c>true</c> segments are persisted; interim
/// segments are streamed to UI but discarded when the final lands.
/// </remarks>
/// <param name="Start">Seconds from session start.</param>
/// <param name="End">Seconds from session start (exclusive end).</param>
/// <param name="Text">Decoded text — may include punctuation when smart formatting is on.</param>
/// <param name="Confidence">Provider confidence in [0, 1].</param>
/// <param name="IsFinal">
/// <c>true</c> if the provider has committed; <c>false</c> for interim segments.
/// Only finals are persisted.
/// </param>
/// <param name="Speaker">
/// Speaker label assigned by the provider (when diarization is enabled). v1 keeps this <c>null</c>.
/// </param>
public sealed record TranscriptSegment(
    double Start,
    double End,
    string Text,
    double Confidence,
    bool IsFinal,
    string? Speaker = null);
