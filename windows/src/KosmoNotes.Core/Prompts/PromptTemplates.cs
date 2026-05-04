using System.Text.Json;
using System.Text.Json.Serialization;

namespace KosmoNotes.Core.Prompts;

/// <summary>
/// Voice Note kinds. The user picks one in Settings; the prompt template
/// shapes the LLM output accordingly. Mirrors Swift <c>VoiceNoteKind</c>.
/// JSON values are lowercase: <c>"freeform"</c>, <c>"task"</c>, <c>"journal"</c>, <c>"checklist"</c>.
/// </summary>
[JsonConverter(typeof(VoiceNoteKindJsonConverter))]
public enum VoiceNoteKind
{
    /// <summary>Light cleanup; preserves voice.</summary>
    Freeform,

    /// <summary>Single actionable task: title + body + optional due / tags.</summary>
    Task,

    /// <summary>First-person journal entry, datestamped header.</summary>
    Journal,

    /// <summary>Bulleted checklist with <c>- [ ]</c> items.</summary>
    Checklist,
}

internal sealed class VoiceNoteKindJsonConverter : JsonConverter<VoiceNoteKind>
{
    public override VoiceNoteKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.GetString();
        return raw switch
        {
            "freeform" => VoiceNoteKind.Freeform,
            "task" => VoiceNoteKind.Task,
            "journal" => VoiceNoteKind.Journal,
            "checklist" => VoiceNoteKind.Checklist,
            _ => throw new JsonException($"Unknown VoiceNoteKind: {raw}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, VoiceNoteKind value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(PromptTemplates.RawValue(value));
    }
}

/// <summary>
/// Static prompt factories. Mirrors the Swift <c>PromptTemplates</c> enum.
/// </summary>
/// <remarks>
/// String literals are intentionally byte-identical to the Swift source. Swift's
/// multi-line strings: <c>\</c> at end of line strips the newline (joining
/// lines with no separator). The first newline after the opening <c>"""</c> and
/// the last newline before the closing <c>"""</c> are also stripped. We
/// replicate that here with hand-joined raw string literals.
/// </remarks>
public static class PromptTemplates
{
    /// <summary>
    /// Maps common BCP-47 codes to English display names; falls back to the raw code.
    /// Mirrors Swift's <c>displayName(for:)</c> helper.
    /// </summary>
    internal static string DisplayName(string code)
    {
        return code.ToLowerInvariant() switch
        {
            "en" => "English",
            "uk" => "Ukrainian",
            "ru" => "Russian",
            "fr" => "French",
            "de" => "German",
            "es" => "Spanish",
            _ => code,
        };
    }

    /// <summary>
    /// Resolves the effective output language. <c>"auto"</c> or <c>null</c> →
    /// use source language; if source is also <c>null</c> → <c>"en"</c>. Mirrors
    /// Swift's <c>resolveTarget(source:target:)</c>.
    /// </summary>
    internal static string ResolveTarget(string? source, string? target)
    {
        string t = (target ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(t) || t == "auto")
        {
            string s = (source ?? string.Empty).Trim();
            return string.IsNullOrEmpty(s) ? "en" : s;
        }
        return t;
    }

    /// <summary>
    /// Raw string value for a <see cref="VoiceNoteKind"/> — matches Swift's
    /// <c>String</c> raw values used in the prompt body.
    /// </summary>
    internal static string RawValue(VoiceNoteKind kind) => kind switch
    {
        VoiceNoteKind.Freeform => "freeform",
        VoiceNoteKind.Task => "task",
        VoiceNoteKind.Journal => "journal",
        VoiceNoteKind.Checklist => "checklist",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown VoiceNoteKind."),
    };

    /// <summary>
    /// System prompt for a post-meeting Markdown summary.
    /// </summary>
    /// <param name="sourceLanguage">BCP-47 source language detected by ASR; null = unknown.</param>
    /// <param name="targetLanguage">User's preferred output language; null/"auto" → match source.</param>
    public static string MeetingSummary(string? sourceLanguage, string? targetLanguage)
    {
        string resolvedTarget = ResolveTarget(sourceLanguage, targetLanguage);
        string targetDisplay = DisplayName(resolvedTarget);
        string sourceDisplay = sourceLanguage is null ? "unknown" : DisplayName(sourceLanguage);

        // Swift backslash-newline within """...""" strips the line break.
        return
            $"You are a meeting note-taking assistant. Output a concise but complete " +
            $"summary of the meeting in {targetDisplay}, in Markdown:\n" +
            "\n" +
            "# Summary\n" +
            "\n" +
            "{2-3 sentences capturing the main purpose and outcome}\n" +
            "\n" +
            "## Key decisions\n" +
            "- ...\n" +
            "\n" +
            "## Action items\n" +
            "- [ ] {action} — {owner if mentioned}\n" +
            "\n" +
            "## Topics discussed\n" +
            "- ...\n" +
            "\n" +
            "If the source language differs from the target language, translate the " +
            $"content into {targetDisplay}. Preserve proper nouns and quoted phrases " +
            "verbatim.\n" +
            "\n" +
            $"Source language: {sourceDisplay}.\n" +
            $"Target language: {targetDisplay}.";
    }

    /// <summary>Wraps the raw transcript text as the user turn for the summary call.</summary>
    public static string MeetingUserMessage(string transcript)
        => $"Here is the meeting transcript:\n\n{transcript}";

    /// <summary>System prompt for a Voice Note finalization. Output is Markdown.</summary>
    public static string VoiceNote(VoiceNoteKind kind, string? sourceLanguage, string? targetLanguage)
    {
        string resolvedTarget = ResolveTarget(sourceLanguage, targetLanguage);
        string targetDisplay = DisplayName(resolvedTarget);
        string kindRaw = RawValue(kind);

        string kindInstructions = kind switch
        {
            VoiceNoteKind.Freeform =>
                "Output the cleaned-up note as a short Markdown document. Fix obvious " +
                "disfluencies and punctuation, but preserve the speaker's voice and " +
                "ordering. No headings unless the user explicitly dictated them.",

            VoiceNoteKind.Task =>
                "Output a single actionable task in Markdown:\n" +
                "\n" +
                "# {short imperative title — ≤8 words}\n" +
                "\n" +
                "**What:** {1-2 sentences expanding the title}\n" +
                "**When:** {if mentioned, else omit}\n" +
                "**Tags:** {comma-separated, derived from content; omit if empty}\n" +
                "\n" +
                "Anything outside the task scope (off-topic asides) goes under a " +
                "`## Notes` section at the bottom or is omitted.",

            VoiceNoteKind.Journal =>
                "Output a first-person journal entry in Markdown:\n" +
                "\n" +
                "# {today, formatted as e.g. \"Tuesday, May 2\"}\n" +
                "\n" +
                "{body, paragraph form, first person, light cleanup of disfluencies}",

            VoiceNoteKind.Checklist =>
                "Output a checklist in Markdown:\n" +
                "\n" +
                "# {short title summarizing the list — ≤8 words}\n" +
                "\n" +
                "- [ ] {item 1}\n" +
                "- [ ] {item 2}\n" +
                "...\n" +
                "\n" +
                "Only items that are actionable. Drop pure observations.",

            _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown VoiceNoteKind."),
        };

        return
            $"You are a voice-note assistant. Convert the transcribed dictation into a " +
            $"{kindRaw} note in {targetDisplay}.\n" +
            "\n" +
            $"{kindInstructions}\n" +
            "\n" +
            "If the source language differs from the target language, translate. " +
            "Preserve proper nouns and quoted phrases verbatim.";
    }

    /// <summary>Wraps the transcript as the user turn for a Voice Note finalize call.</summary>
    public static string VoiceNoteUserMessage(string transcript)
        => $"Here is the dictated note:\n\n{transcript}";

    /// <summary>
    /// System prompt for cleaning a long-form transcript after the speech-to-text stage.
    /// </summary>
    public static string TranscriptCleanup(string? sourceLanguage, string? targetLanguage)
    {
        string target = ResolveTarget(sourceLanguage, targetLanguage);
        string langName = DisplayName(target);

        return
            "You are a transcript cleanup assistant. The user supplies a raw transcript " +
            "produced by an automatic speech-to-text engine (Whisper / Deepgram / Gemini). " +
            "Your job is to fix obvious recognition errors WITHOUT rewriting the speaker's " +
            "voice. The output goes back into the user's library and feeds downstream " +
            "summary + search — preserve every meaningful word and timing cue.\n" +
            "\n" +
            "Rules:\n" +
            $"1. Output language: {langName}. Do not translate to another language.\n" +
            // Lines 2/4/6 are continued in Swift via `\` with 3-space indent on
            // the continuation; after Swift's dedent that leaves 4 spaces (1
            // trailing + 3 leading) between the joined fragments.
            "2. Fix clear ASR mistakes: misheard numbers, proper names, technical terms, " +
            "   doubled words (\"the the\" → \"the\"), nonsense from background noise.\n" +
            "3. Add or fix punctuation and capitalization where missing or wrong.\n" +
            "4. Keep the speaker's phrasing, filler patterns, and meaning. Do NOT " +
            "   summarize, paraphrase, or shorten.\n" +
            "5. Preserve speaker turns / paragraph breaks if present in the input.\n" +
            "6. Do NOT add commentary, headers, or explanations of what you changed. " +
            "   Output ONLY the cleaned transcript text.";
    }

    /// <summary>User message wrapper for the cleanup task.</summary>
    public static string TranscriptCleanupUserMessage(string rawTranscript)
        => $"Raw transcript follows. Return the cleaned version only.\n\n{rawTranscript}";
}
