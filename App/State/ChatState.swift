import Foundation
import Observation
import AIKit
import StorageKit

// MARK: - ChatState

/// Observable state for the Chat window.
///
/// Provider is resolved per-call from `settings.llmProvider` so the user can
/// switch providers between messages without reopening the window.
@available(macOS 14.0, *)
@Observable
@MainActor
final class ChatState {

    // MARK: Observable state

    var messages: [ChatMessage] = []
    var inputDraft: String = ""
    var isSending: Bool = false
    var lastError: String?
    /// When true, the last completed session's transcript is injected as a
    /// system context message prepended to the conversation.
    var includeLastSessionContext: Bool = false

    // MARK: Dependencies

    private let settings: AppSettings
    private let database: AppDatabase
    private let sessionStore: SessionStore

    // MARK: Init

    init(settings: AppSettings, database: AppDatabase, sessionStore: SessionStore) {
        self.settings = settings
        self.database = database
        self.sessionStore = sessionStore
    }

    // MARK: - Actions

    /// Takes `inputDraft`, appends a user message, calls the provider, appends
    /// the assistant reply. Clears `inputDraft` on success; surfaces errors via
    /// `lastError` rather than throwing so the UI stays responsive.
    func send() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputDraft = ""
        lastError = nil
        isSending = true
        defer { isSending = false }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        do {
            let provider = try makeProvider()
            let config = makeConfig()
            var outgoing = messages

            if includeLastSessionContext, let contextMessage = await loadLastSessionContext() {
                // Prepend context before the conversation so the provider sees it first.
                outgoing.insert(contextMessage, at: 0)
            }

            let reply = try await provider.chat(messages: outgoing, config: config)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch let error as AIError {
            lastError = friendlyMessage(for: error)
            // Remove the optimistic user message on failure so the user can retry.
            messages.removeLast()
            inputDraft = text
        } catch {
            lastError = error.localizedDescription
            messages.removeLast()
            inputDraft = text
        }
    }

    /// Wipes the conversation history and any displayed error.
    func clear() {
        messages = []
        lastError = nil
    }

    // MARK: - Private helpers

    private func makeProvider() throws -> any AIProvider {
        switch settings.llmProvider {
        case .anthropic:
            let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AIError.authenticationFailed
            }
            return AnthropicProvider(apiKey: key)
        case .openai:
            let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AIError.authenticationFailed
            }
            return OpenAIProvider(apiKey: key)
        }
    }

    private func makeConfig() -> AIConfig {
        switch settings.llmProvider {
        case .anthropic:
            return AIConfig(model: AnthropicProvider.defaultModel)
        case .openai:
            return AIConfig(model: OpenAIProvider.defaultModel)
        }
    }

    /// Loads the last completed session's transcript.txt as a system message.
    /// Returns nil if no completed session exists or the file cannot be read.
    private func loadLastSessionContext() async -> ChatMessage? {
        do {
            let sessions = try await database.listSessions(limit: 10)
            guard let last = sessions.first(where: { $0.status == .complete }) else { return nil }
            let dir = await sessionStore.sessionDir(for: last.id)
            let transcriptURL = dir.appendingPathComponent("transcript.txt")
            let text = try String(contentsOf: transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(
                role: .system,
                content: "You have the user's most recent recording transcript as context:\n\n\(text)"
            )
        } catch {
            // Transcript may not exist yet; silently ignore and proceed without context.
            return nil
        }
    }

    private func friendlyMessage(for error: AIError) -> String {
        switch error {
        case .authenticationFailed:
            return "API key is missing or invalid. Check Settings → AI Providers."
        case .rateLimited:
            return "Rate limited by the provider. Wait a moment and try again."
        case .invalidEndpoint:
            return "Invalid provider endpoint."
        case .sendFailed(let msg):
            return "Request failed: \(msg)"
        case .decodingFailed(let msg):
            return "Could not parse the provider response: \(msg)"
        }
    }
}
