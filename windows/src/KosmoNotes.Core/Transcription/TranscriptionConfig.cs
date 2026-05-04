namespace KosmoNotes.Core.Transcription;

/// <summary>
/// Per-session transcription configuration. Minimal C# mirror of the Swift
/// <c>TranscriptionConfig</c> struct — for v1 only the language hint is used
/// by <c>DeepgramBatchProvider</c>'s URL builder.
/// </summary>
/// <param name="Language">
/// BCP-47 language code (e.g. <c>"en"</c>, <c>"uk"</c>). <c>null</c> = auto-detect.
/// </param>
public sealed record TranscriptionConfig(string? Language);
