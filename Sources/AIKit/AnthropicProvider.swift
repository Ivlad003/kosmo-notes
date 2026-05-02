import Foundation

// MARK: - AnthropicProvider

/// `AIProvider` for Anthropic's Messages API (`POST /v1/messages`).
///
/// Anthropic does not allow "system" role in the messages array — it must be
/// a top-level "system" field. This provider filters system messages out of
/// the array and uses the last system message's content as the top-level field.
///
/// Supports multipart messages: text parts become `{"type":"text","text":"..."}`,
/// image parts become `{"type":"image","source":{"type":"base64",...}}`.
/// System messages are always text-only (Anthropic API constraint).
public final class AnthropicProvider: AIProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Stored

    private let apiKey: String
    private let endpoint: URL
    private let httpClient: HTTPClient

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = AnthropicProvider.defaultEndpoint,
        httpClient: @escaping HTTPClient = AnthropicProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-sonnet-4-6"

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: AIProvider

    public func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        let request = try Self.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            messages: messages,
            config: config
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw AIError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.sendFailed(message: "Non-HTTP response from Anthropic API")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parse(data: data)
        case 401:
            throw AIError.authenticationFailed
        case 429:
            throw AIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw AIError.sendFailed(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    // MARK: - Request builder (internal for tests)

    static func buildRequest(
        endpoint: URL,
        apiKey: String,
        messages: [ChatMessage],
        config: AIConfig
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Separate system messages from conversation messages.
        // Anthropic rejects "system" role in the messages array;
        // use the last system message's content as the top-level field.
        let systemMessages = messages.filter { $0.role == .system }
        let conversationMessages = messages.filter { $0.role != .system }

        // Prefer explicit config.systemPrompt; fall back to last system message.
        let systemField: String? = config.systemPrompt ?? systemMessages.last?.text

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": conversationMessages.map { msg -> [String: Any] in
                ["role": msg.role.rawValue, "content": Self.serializeParts(msg.parts)]
            },
        ]
        if let system = systemField {
            body["system"] = system
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    // MARK: - Response parser (internal for tests)

    static func parse(data: Data) throws -> String {
        struct Response: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIError.decodingFailed(message: error.localizedDescription)
        }

        // Concatenate all text-type blocks in order.
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()

        return text
    }

    // MARK: - Private: part serialization

    /// Convert structured message parts to Anthropic content-block JSON objects.
    /// text → {"type":"text","text":"..."}
    /// image → {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"<b64>"}}
    private static func serializeParts(_ parts: [ChatMessage.Part]) -> Any {
        // Single text-only part: send as plain string for maximum API compatibility.
        if parts.count == 1, case .text(let s) = parts[0] {
            return s
        }
        return parts.map { part -> [String: Any] in
            switch part {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let jpegData, let mimeType):
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": jpegData.base64EncodedString(),
                    ] as [String: Any],
                ]
            }
        }
    }
}
