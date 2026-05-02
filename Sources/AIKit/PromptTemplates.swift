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
