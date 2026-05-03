import Foundation
import os
import AIKit
import StorageKit

private let exporterLog = Logger(subsystem: "dev.jarvisnote.studio", category: "MarkdownExporter")

// MARK: - MarkdownExporter

/// Optional post-recording pipeline step that runs the cleaned transcript
/// through the user's configured LLM with **user-defined** system + user
/// prompts, then atomic-writes the result as a `.md` file at the user's
/// chosen folder. Independent of the built-in `summary.md` (which uses our
/// PromptTemplates and lives inside the session dir).
///
/// Failures are non-fatal — caller (RecorderState.stop) ignores the return
/// value when nil. Cost-capped via the same `costCapUSD` mechanism as
/// summary generation, but silently skips on overage rather than prompting.
@available(macOS 14.0, *)
@MainActor
enum MarkdownExporter {

    /// Run the export. Returns the URL of the written `.md` on success,
    /// nil on any failure (disabled, missing prompt placeholder, missing
    /// API key, LLM failure, write failure).
    static func export(
        transcript: String,
        settings: AppSettings,
        sessionID: String,
        sessionMode: SessionMode,
        recordedAt: Date
    ) async -> URL? {
        guard settings.markdownExportEnabled else { return nil }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            exporterLog.info("MarkdownExporter: skipping — transcript is empty")
            return nil
        }

        // Resolve the user prompt template. Fall back to the default if the
        // user accidentally cleared it — better than sending an empty user
        // message which most LLMs reject.
        let userTemplate = settings.markdownExportUserPrompt.isEmpty
            ? AppSettings.defaultMarkdownExportUserPrompt
            : settings.markdownExportUserPrompt
        let systemPrompt = settings.markdownExportSystemPrompt.isEmpty
            ? AppSettings.defaultMarkdownExportSystemPrompt
            : settings.markdownExportSystemPrompt

        // Substitute `{transcript}`. If the user removed the token, append
        // the transcript so the model still has it — better than producing
        // an LLM hallucination from an empty user message.
        let userMessage: String
        if userTemplate.contains("{transcript}") {
            userMessage = userTemplate.replacingOccurrences(of: "{transcript}", with: trimmed)
        } else {
            userMessage = userTemplate + "\n\n" + trimmed
        }

        // Build provider + cost guard. Same per-provider model defaults as
        // tryGenerateSummary so the export honors the AI Providers tab.
        guard let (provider, model, pricing) = makeProvider(settings: settings) else {
            exporterLog.error("MarkdownExporter: no LLM provider available (missing API key)")
            return nil
        }

        let inputTokens = CostEstimator.estimateTokens(text: systemPrompt)
            + CostEstimator.estimateTokens(text: userMessage)
        let outputCap = max(2048, Int(Double(inputTokens) * 1.5))
        let estCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputCap,
            pricing: pricing
        )
        if estCost > settings.costCapUSD {
            exporterLog.error("MarkdownExporter: skipping — estimated cost $\(estCost, privacy: .public) exceeds cap $\(settings.costCapUSD, privacy: .public)")
            return nil
        }

        let config = AIConfig(
            model: model,
            temperature: 0.3,
            maxTokens: outputCap,
            systemPrompt: systemPrompt
        )
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: userMessage)]

        let markdown: String
        do {
            markdown = try await provider.chat(messages: messages, config: config)
        } catch {
            exporterLog.error("MarkdownExporter: LLM call failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmedMD = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMD.isEmpty else {
            exporterLog.error("MarkdownExporter: LLM returned empty output")
            return nil
        }

        // Resolve target folder. Empty setting → ~/Documents/JarvisNote.
        let folderURL = resolveExportFolder(settings: settings)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            exporterLog.error("MarkdownExporter: could not create folder \(folderURL.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let filename = makeFilename(sessionID: sessionID, mode: sessionMode, recordedAt: recordedAt)
        let outURL = folderURL.appendingPathComponent(filename)

        do {
            try AtomicWriter.write(Data(trimmedMD.utf8), to: outURL)
            exporterLog.info("MarkdownExporter: wrote \(outURL.path, privacy: .public) (\(trimmedMD.count, privacy: .public) chars)")
            return outURL
        } catch {
            exporterLog.error("MarkdownExporter: AtomicWriter failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private helpers

    /// Resolve `settings.markdownExportFolder` to an absolute file URL.
    /// Empty → fall back to `~/Documents/JarvisNote`. `~` is expanded.
    private static func resolveExportFolder(settings: AppSettings) -> URL {
        let raw = settings.markdownExportFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
            return docs.appendingPathComponent("JarvisNote")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// "2026-05-03_1442_meeting_e0123456.md" — sortable date prefix, mode
    /// label, then a short session-id suffix so two same-minute recordings
    /// don't collide.
    private static func makeFilename(sessionID: String, mode: SessionMode, recordedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: recordedAt)
        let modeStr = mode.rawValue
        let shortID = String(sessionID.prefix(8))
        return "\(date)_\(modeStr)_\(shortID).md"
    }

    /// Build the AIProvider + model + pricing for the active LLM provider.
    /// Mirror of RecorderState.tryGenerateSummary's switch — kept duplicated
    /// rather than factored out to keep the helper self-contained and to
    /// avoid leaking a public Provider-builder onto AppSettings.
    private static func makeProvider(
        settings: AppSettings
    ) -> (provider: any AIProvider, model: String, pricing: CostEstimator.Pricing)? {
        switch settings.llmProvider {
        case .anthropic:
            let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return (AnthropicProvider(apiKey: key), "claude-sonnet-4-6", CostEstimator.anthropic_claude_sonnet_4_6)
        case .openai:
            let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return (OpenAIProvider(apiKey: key), "gpt-4o-mini", CostEstimator.openai_gpt_4o_mini)
        case .openrouter:
            let key = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let model = settings.openrouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return (OpenRouterProvider(apiKey: key), model.isEmpty ? "openai/gpt-4o-mini" : model, CostEstimator.openrouter_default)
        case .ollama:
            let endpoint = URL(string: settings.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
            let mode: OllamaProvider.APIMode = settings.ollamaApiMode == .native ? .native : .openaiCompat
            let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let provider = try OllamaProvider(
                    endpoint: endpoint,
                    apiMode: mode,
                    bearerToken: bearer.isEmpty ? nil : bearer
                )
                return (provider, settings.ollamaModel, CostEstimator.Pricing(inputPerMillion: 0, outputPerMillion: 0))
            } catch {
                return nil
            }
        }
    }
}
