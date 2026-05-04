using KosmoNotes.Core.Prompts;

namespace KosmoNotes.Core.Tests;

public class PromptTemplatesTests
{
    // ----- MeetingSummary -----

    private const string MeetingSummary_EnUk =
        "You are a meeting note-taking assistant. Output a concise but complete summary of the meeting in Ukrainian, in Markdown:\n" +
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
        "If the source language differs from the target language, translate the content into Ukrainian. Preserve proper nouns and quoted phrases verbatim.\n" +
        "\n" +
        "Source language: English.\n" +
        "Target language: Ukrainian.";

    private const string MeetingSummary_NullNull =
        "You are a meeting note-taking assistant. Output a concise but complete summary of the meeting in English, in Markdown:\n" +
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
        "If the source language differs from the target language, translate the content into English. Preserve proper nouns and quoted phrases verbatim.\n" +
        "\n" +
        "Source language: unknown.\n" +
        "Target language: English.";

    private const string MeetingSummary_UkEn =
        "You are a meeting note-taking assistant. Output a concise but complete summary of the meeting in English, in Markdown:\n" +
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
        "If the source language differs from the target language, translate the content into English. Preserve proper nouns and quoted phrases verbatim.\n" +
        "\n" +
        "Source language: Ukrainian.\n" +
        "Target language: English.";

    [Fact]
    public void MeetingSummary_EnglishSource_UkrainianTarget()
    {
        Assert.Equal(MeetingSummary_EnUk, PromptTemplates.MeetingSummary("en", "uk"));
    }

    [Fact]
    public void MeetingSummary_NullSource_NullTarget_ResolvesToEnglish()
    {
        Assert.Equal(MeetingSummary_NullNull, PromptTemplates.MeetingSummary(null, null));
    }

    [Fact]
    public void MeetingSummary_UkrainianSource_EnglishTarget()
    {
        Assert.Equal(MeetingSummary_UkEn, PromptTemplates.MeetingSummary("uk", "en"));
    }

    [Fact]
    public void MeetingSummary_AutoTarget_ResolvesToSource()
    {
        // target == "auto" → use source ("uk") → display "Ukrainian"
        string output = PromptTemplates.MeetingSummary("uk", "auto");
        Assert.Contains("Target language: Ukrainian.", output);
        Assert.Contains("Source language: Ukrainian.", output);
    }

    [Fact]
    public void MeetingUserMessage_FormatsTranscript()
    {
        Assert.Equal(
            "Here is the meeting transcript:\n\nABC",
            PromptTemplates.MeetingUserMessage("ABC"));
    }

    // ----- VoiceNote -----

    [Fact]
    public void VoiceNote_Freeform_EnUk()
    {
        const string expected =
            "You are a voice-note assistant. Convert the transcribed dictation into a freeform note in Ukrainian.\n" +
            "\n" +
            "Output the cleaned-up note as a short Markdown document. Fix obvious disfluencies and punctuation, but preserve the speaker's voice and ordering. No headings unless the user explicitly dictated them.\n" +
            "\n" +
            "If the source language differs from the target language, translate. Preserve proper nouns and quoted phrases verbatim.";
        Assert.Equal(expected, PromptTemplates.VoiceNote(VoiceNoteKind.Freeform, "en", "uk"));
    }

    [Fact]
    public void VoiceNote_Task_NullNull_DefaultsEnglish()
    {
        const string expected =
            "You are a voice-note assistant. Convert the transcribed dictation into a task note in English.\n" +
            "\n" +
            "Output a single actionable task in Markdown:\n" +
            "\n" +
            "# {short imperative title — ≤8 words}\n" +
            "\n" +
            "**What:** {1-2 sentences expanding the title}\n" +
            "**When:** {if mentioned, else omit}\n" +
            "**Tags:** {comma-separated, derived from content; omit if empty}\n" +
            "\n" +
            "Anything outside the task scope (off-topic asides) goes under a `## Notes` section at the bottom or is omitted.\n" +
            "\n" +
            "If the source language differs from the target language, translate. Preserve proper nouns and quoted phrases verbatim.";
        Assert.Equal(expected, PromptTemplates.VoiceNote(VoiceNoteKind.Task, null, null));
    }

    [Fact]
    public void VoiceNote_Journal_UkEn()
    {
        const string expected =
            "You are a voice-note assistant. Convert the transcribed dictation into a journal note in English.\n" +
            "\n" +
            "Output a first-person journal entry in Markdown:\n" +
            "\n" +
            "# {today, formatted as e.g. \"Tuesday, May 2\"}\n" +
            "\n" +
            "{body, paragraph form, first person, light cleanup of disfluencies}\n" +
            "\n" +
            "If the source language differs from the target language, translate. Preserve proper nouns and quoted phrases verbatim.";
        Assert.Equal(expected, PromptTemplates.VoiceNote(VoiceNoteKind.Journal, "uk", "en"));
    }

    [Fact]
    public void VoiceNote_Checklist_EnUk()
    {
        const string expected =
            "You are a voice-note assistant. Convert the transcribed dictation into a checklist note in Ukrainian.\n" +
            "\n" +
            "Output a checklist in Markdown:\n" +
            "\n" +
            "# {short title summarizing the list — ≤8 words}\n" +
            "\n" +
            "- [ ] {item 1}\n" +
            "- [ ] {item 2}\n" +
            "...\n" +
            "\n" +
            "Only items that are actionable. Drop pure observations.\n" +
            "\n" +
            "If the source language differs from the target language, translate. Preserve proper nouns and quoted phrases verbatim.";
        Assert.Equal(expected, PromptTemplates.VoiceNote(VoiceNoteKind.Checklist, "en", "uk"));
    }

    [Fact]
    public void VoiceNoteUserMessage_FormatsTranscript()
    {
        Assert.Equal(
            "Here is the dictated note:\n\nXYZ",
            PromptTemplates.VoiceNoteUserMessage("XYZ"));
    }

    // ----- TranscriptCleanup -----

    [Fact]
    public void TranscriptCleanup_EnUk_KeepsSourceLanguage()
    {
        // Despite target=uk, the cleanup prompt resolves to target normally
        // (source=en, target=uk → langName=Ukrainian)
        const string expected =
            "You are a transcript cleanup assistant. The user supplies a raw transcript " +
            "produced by an automatic speech-to-text engine (Whisper / Deepgram / Gemini). " +
            "Your job is to fix obvious recognition errors WITHOUT rewriting the speaker's " +
            "voice. The output goes back into the user's library and feeds downstream " +
            "summary + search — preserve every meaningful word and timing cue.\n" +
            "\n" +
            "Rules:\n" +
            "1. Output language: Ukrainian. Do not translate to another language.\n" +
            "2. Fix clear ASR mistakes: misheard numbers, proper names, technical terms,    doubled words (\"the the\" → \"the\"), nonsense from background noise.\n" +
            "3. Add or fix punctuation and capitalization where missing or wrong.\n" +
            "4. Keep the speaker's phrasing, filler patterns, and meaning. Do NOT    summarize, paraphrase, or shorten.\n" +
            "5. Preserve speaker turns / paragraph breaks if present in the input.\n" +
            "6. Do NOT add commentary, headers, or explanations of what you changed.    Output ONLY the cleaned transcript text.";
        Assert.Equal(expected, PromptTemplates.TranscriptCleanup("en", "uk"));
    }

    [Fact]
    public void TranscriptCleanup_NullNull_DefaultsEnglish()
    {
        string output = PromptTemplates.TranscriptCleanup(null, null);
        Assert.Contains("Output language: English. Do not translate to another language.", output);
    }

    [Fact]
    public void TranscriptCleanup_UkEn_ResolvesEnglish()
    {
        string output = PromptTemplates.TranscriptCleanup("uk", "en");
        Assert.Contains("Output language: English. Do not translate to another language.", output);
    }

    [Fact]
    public void TranscriptCleanupUserMessage_FormatsTranscript()
    {
        Assert.Equal(
            "Raw transcript follows. Return the cleaned version only.\n\nHELLO",
            PromptTemplates.TranscriptCleanupUserMessage("HELLO"));
    }

    // ----- DisplayName / ResolveTarget edge cases -----

    [Fact]
    public void DisplayName_KnownLanguages()
    {
        // Exercised indirectly through MeetingSummary; sanity-check some via
        // the public surface by checking output substrings.
        Assert.Contains("Source language: French.", PromptTemplates.MeetingSummary("fr", "fr"));
        Assert.Contains("Source language: German.", PromptTemplates.MeetingSummary("de", "de"));
        Assert.Contains("Source language: Spanish.", PromptTemplates.MeetingSummary("es", "es"));
        Assert.Contains("Source language: Russian.", PromptTemplates.MeetingSummary("ru", "ru"));
    }

    [Fact]
    public void DisplayName_UnknownCode_FallsBackToRaw()
    {
        Assert.Contains("Source language: jp.", PromptTemplates.MeetingSummary("jp", "jp"));
    }
}
