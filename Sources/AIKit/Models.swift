import Foundation

// MARK: - ChatMessage

public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - AIConfig

public struct AIConfig: Sendable, Equatable {
    public let model: String
    public let temperature: Double
    public let maxTokens: Int
    /// Optional system-role prefix. Routed provider-specifically:
    /// Anthropic uses a top-level "system" field; OpenAI prepends a system message.
    public let systemPrompt: String?

    public init(
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 1024,
        systemPrompt: String? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }
}

// MARK: - AIError

public enum AIError: Error, Sendable, Equatable {
    case invalidEndpoint
    case authenticationFailed
    case rateLimited
    case sendFailed(message: String)
    case decodingFailed(message: String)
}
