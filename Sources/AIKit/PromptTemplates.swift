import Foundation

// MARK: - PromptTemplates

/// Static prompt factories. Kept out of providers so tests can snapshot them without
/// instantiating any network stack.
public enum PromptTemplates {

    // MARK: BCP-47 → display name

    /// Maps common BCP-47 codes to English display names; falls back to the raw code.
    static func displayName(for code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "uk": return "Ukrainian"
        case "ru": return "Russian"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        default: return code
        }
    }

    // MARK: Meeting summary

    /// System prompt for a post-meeting Markdown summary.
    ///
    /// `sourceLanguage` is the BCP-47 code detected by Whisper (nil = unknown).
    /// `targetLanguage` is the user's preferred output language; nil / "auto" →
    /// match source, or English if source is also unknown.
    public static func meetingSummary(sourceLanguage: String?, targetLanguage: String?) -> String {
        let resolvedTarget = resolveTarget(source: sourceLanguage, target: targetLanguage)
        let targetDisplay = displayName(for: resolvedTarget)
        let sourceDisplay = sourceLanguage.map { displayName(for: $0) } ?? "unknown"

        return """
        You are a meeting note-taking assistant. Output a concise but complete \
        summary of the meeting in \(targetDisplay), in Markdown:

        # Summary

        {2-3 sentences capturing the main purpose and outcome}

        ## Key decisions
        - ...

        ## Action items
        - [ ] {action} — {owner if mentioned}

        ## Topics discussed
        - ...

        If the source language differs from the target language, translate the \
        content into \(targetDisplay). Preserve proper nouns and quoted phrases \
        verbatim.

        Source language: \(sourceDisplay).
        Target language: \(targetDisplay).
        """
    }

    /// Wraps the raw transcript text as the user turn for the summary call.
    public static func meetingUserMessage(transcript: String) -> String {
        "Here is the meeting transcript:\n\n\(transcript)"
    }

    // MARK: Voice Note

    /// Voice Note kinds. The user picks one in Settings; the prompt template
    /// shapes the LLM output accordingly.
    public enum VoiceNoteKind: String, Sendable, CaseIterable, Codable {
        case freeform   // light cleanup; preserves voice
        case task       // single actionable task: title + body + optional due / tags
        case journal    // first-person journal entry, datestamped header
        case checklist  // bulleted checklist with `- [ ]` items
    }

    /// System prompt for a Voice Note finalization. Output is Markdown.
    public static func voiceNote(
        kind: VoiceNoteKind,
        sourceLanguage: String?,
        targetLanguage: String?
    ) -> String {
        let resolvedTarget = resolveTarget(source: sourceLanguage, target: targetLanguage)
        let targetDisplay = displayName(for: resolvedTarget)
        let kindInstructions: String
        switch kind {
        case .freeform:
            kindInstructions = """
            Output the cleaned-up note as a short Markdown document. Fix obvious \
            disfluencies and punctuation, but preserve the speaker's voice and \
            ordering. No headings unless the user explicitly dictated them.
            """
        case .task:
            kindInstructions = """
            Output a single actionable task in Markdown:

            # {short imperative title — ≤8 words}

            **What:** {1-2 sentences expanding the title}
            **When:** {if mentioned, else omit}
            **Tags:** {comma-separated, derived from content; omit if empty}

            Anything outside the task scope (off-topic asides) goes under a \
            `## Notes` section at the bottom or is omitted.
            """
        case .journal:
            kindInstructions = """
            Output a first-person journal entry in Markdown:

            # {today, formatted as e.g. "Tuesday, May 2"}

            {body, paragraph form, first person, light cleanup of disfluencies}
            """
        case .checklist:
            kindInstructions = """
            Output a checklist in Markdown:

            # {short title summarizing the list — ≤8 words}

            - [ ] {item 1}
            - [ ] {item 2}
            ...

            Only items that are actionable. Drop pure observations.
            """
        }

        return """
        You are a voice-note assistant. Convert the transcribed dictation into a \
        \(kind.rawValue) note in \(targetDisplay).

        \(kindInstructions)

        If the source language differs from the target language, translate. \
        Preserve proper nouns and quoted phrases verbatim.
        """
    }

    /// Wraps the transcript as the user turn for a Voice Note finalize call.
    public static func voiceNoteUserMessage(transcript: String) -> String {
        "Here is the dictated note:\n\n\(transcript)"
    }

    // MARK: - Private helpers

    /// Resolves the effective output language.
    /// "auto" or nil → use source language; if source is also nil → "en".
    static func resolveTarget(source: String?, target: String?) -> String {
        let t = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t == "auto" {
            return source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? source!
                : "en"
        }
        return t
    }
}
