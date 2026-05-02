import Foundation
import Testing
@testable import AIKit

// MARK: - PromptTemplates tests

@Suite("PromptTemplates.meetingSummary")
struct PromptTemplatesMeetingSummaryTests {

    @Test("Contains required Markdown section headers")
    func containsMarkdownSections() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: "en", targetLanguage: "en")
        #expect(prompt.contains("Markdown"))
        #expect(prompt.contains("# Summary"))
        #expect(prompt.contains("## Action items"))
    }

    @Test("Target language 'uk' resolves to Ukrainian in the prompt")
    func ukrainianTarget() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: "en", targetLanguage: "uk")
        #expect(prompt.contains("Ukrainian"))
    }

    @Test("Target language 'de' resolves to German in the prompt")
    func germanTarget() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: "en", targetLanguage: "de")
        #expect(prompt.contains("German"))
    }

    @Test("targetLanguage 'auto' resolves to source language display name")
    func autoResolvesToSource() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: "uk", targetLanguage: "auto")
        // Should say Ukrainian (the source) not English
        #expect(prompt.contains("Ukrainian"))
    }

    @Test("targetLanguage nil resolves to source language")
    func nilResolvesToSource() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: "fr", targetLanguage: nil)
        #expect(prompt.contains("French"))
    }

    @Test("targetLanguage 'auto' with nil source falls back to English")
    func autoNilSourceFallsBackToEnglish() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: nil, targetLanguage: "auto")
        #expect(prompt.contains("English"))
    }

    @Test("targetLanguage nil with nil source falls back to English")
    func nilNilFallsBackToEnglish() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: nil, targetLanguage: nil)
        #expect(prompt.contains("English"))
    }

    @Test("Source language unknown is represented as 'unknown' in the prompt")
    func nilSourceLabelledUnknown() {
        let prompt = PromptTemplates.meetingSummary(sourceLanguage: nil, targetLanguage: "en")
        #expect(prompt.contains("Source language: unknown"))
    }
}

@Suite("PromptTemplates.meetingUserMessage")
struct PromptTemplatesMeetingUserMessageTests {

    @Test("User message starts with the expected container prefix")
    func startsWithTranscriptPrefix() {
        let msg = PromptTemplates.meetingUserMessage(transcript: "Hello world.")
        #expect(msg.hasPrefix("Here is the meeting transcript:"))
    }

    @Test("User message contains the full transcript text")
    func containsTranscript() {
        let transcript = "Alice: let's ship. Bob: agreed."
        let msg = PromptTemplates.meetingUserMessage(transcript: transcript)
        #expect(msg.contains(transcript))
    }
}

@Suite("PromptTemplates.resolveTarget")
struct PromptTemplatesResolveTargetTests {

    @Test("'auto' with known source returns source")
    func autoWithSource() {
        #expect(PromptTemplates.resolveTarget(source: "uk", target: "auto") == "uk")
    }

    @Test("nil target with known source returns source")
    func nilTargetWithSource() {
        #expect(PromptTemplates.resolveTarget(source: "ru", target: nil) == "ru")
    }

    @Test("'auto' with nil source returns 'en'")
    func autoWithNilSource() {
        #expect(PromptTemplates.resolveTarget(source: nil, target: "auto") == "en")
    }

    @Test("Explicit target overrides source")
    func explicitTargetWins() {
        #expect(PromptTemplates.resolveTarget(source: "uk", target: "fr") == "fr")
    }
}
