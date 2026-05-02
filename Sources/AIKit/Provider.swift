import Foundation

// MARK: - AIProvider

/// Single-shot (non-streaming) chat completion. Streaming is v1.1.
public protocol AIProvider: Sendable {
    /// Returns the assistant's reply text. Throws `AIError` on failure.
    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String
}
