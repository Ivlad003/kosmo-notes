import Foundation

// MARK: - ChatMessage

public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    /// A single content part in a message.
    public enum Part: Sendable, Codable, Equatable {
        case text(String)
        /// JPEG-encoded image data; providers base64-encode this for transport.
        case image(jpegData: Data, mimeType: String)

        // Codable conformance via a keyed container so round-trips are stable.
        private enum CodingKeys: String, CodingKey { case type, text, jpegData, mimeType }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "image":
                let data = try container.decode(Data.self, forKey: .jpegData)
                let mime = try container.decode(String.self, forKey: .mimeType)
                self = .image(jpegData: data, mimeType: mime)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                    debugDescription: "Unknown part type: \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try container.encode("text", forKey: .type)
                try container.encode(s, forKey: .text)
            case .image(let data, let mime):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .jpegData)
                try container.encode(mime, forKey: .mimeType)
            }
        }
    }

    public let role: Role
    public let parts: [Part]

    public init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience: single text-only message.
    public init(role: Role, content: String) {
        self.role = role
        self.parts = [.text(content)]
    }

    /// Concatenated text content for display and logging; ignores image parts.
    public var text: String {
        parts.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined(separator: " ")
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
