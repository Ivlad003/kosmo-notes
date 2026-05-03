import Foundation
import os

private let agentLog = Logger(subsystem: "dev.jarvisnote.studio", category: "AgentRunner")

// MARK: - AgentEvent

/// One entry in the structured session log. Streamed back to the UI as the
/// agent loop progresses; also written one-per-line to the JSONL file for
/// post-hoc browsing in Settings → Agent Sessions.
public struct AgentEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case userMessage      // user instruction (initial or injected)
        case assistantText    // free-form Claude reply
        case toolCall         // model asked for a tool
        case toolResult       // tool output we sent back
        case error            // anything that broke (tool throw, API error, cap hit)
        case stop             // loop ended cleanly
    }
    public let timestamp: Date
    public let kind: Kind
    public let text: String
    public let toolName: String?

    public init(kind: Kind, text: String, toolName: String? = nil) {
        self.timestamp = Date()
        self.kind = kind
        self.text = text
        self.toolName = toolName
    }
}

// MARK: - AgentRunner

/// Runs an agentic loop against Anthropic's Messages API with tool_use.
///
/// Loop body:
///   1. send transcript so far → /v1/messages with tools[]
///   2. parse response: collect any text blocks + tool_use blocks
///   3. if any tool_use: execute each, append tool_result blocks, goto 1
///   4. if stop_reason == "end_turn" or maxIterations reached: stop
///
/// Mid-session injection: append a user message to the transcript via
/// `inject(_:)` between iterations. The next loop iteration includes it.
public actor AgentRunner {

    public enum AgentError: Error, LocalizedError {
        case missingAPIKey
        case unexpectedResponse(status: Int, body: String?)
        case parseFailed(String)
        case capReached(iterations: Int)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Anthropic API key required for agent (Settings → AI Providers)."
            case .unexpectedResponse(let s, let b): return "API HTTP \(s) — \(b ?? "")"
            case .parseFailed(let s): return "Parse failure: \(s)"
            case .capReached(let n): return "Hit max-iterations cap (\(n)). Stopped to prevent runaway."
            }
        }
    }

    public typealias EventHandler = @Sendable (AgentEvent) -> Void

    private let apiKey: String
    private let model: String
    private let systemPrompt: String
    private let maxIterations: Int
    private let tools: [AgentTool]
    private let onEvent: EventHandler
    private let session: URLSession

    /// Conversation buffer in Anthropic Messages API shape. Each entry is
    /// `["role": "user"|"assistant", "content": [...blocks...]]`. We append
    /// to this on every loop iteration.
    private var transcript: [[String: Any]] = []
    private var iterationCount: Int = 0
    private var stopRequested: Bool = false
    private var pendingInjections: [String] = []

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        systemPrompt: String,
        maxIterations: Int = 12,
        tools: [AgentTool],
        onEvent: @escaping EventHandler,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxIterations = max(1, maxIterations)
        self.tools = tools
        self.onEvent = onEvent
        self.session = session
    }

    // MARK: - Public API

    /// Drive the loop with the given user instruction. Returns when the agent
    /// stops (end_turn, cap hit, or stop requested). All progress is streamed
    /// via the `onEvent` callback set at init.
    public func run(initialInstruction: String) async {
        appendUserText(initialInstruction)
        emit(.init(kind: .userMessage, text: initialInstruction))

        while !stopRequested && iterationCount < maxIterations {
            iterationCount += 1
            agentLog.info("AgentRunner: iteration \(self.iterationCount, privacy: .public)/\(self.maxIterations, privacy: .public)")

            // Drain any injections accumulated between iterations.
            while !pendingInjections.isEmpty {
                let msg = pendingInjections.removeFirst()
                appendUserText(msg)
                emit(.init(kind: .userMessage, text: "[injected] " + msg))
            }

            do {
                let response = try await callMessages()
                let stopReason = response.stopReason
                let blocks = response.contentBlocks

                // Surface any free-form text the model produced.
                for block in blocks {
                    if let text = block["text"] as? String, !text.isEmpty {
                        emit(.init(kind: .assistantText, text: text))
                    }
                }

                // Append the assistant turn (full block array) to transcript.
                transcript.append(["role": "assistant", "content": blocks])

                // Find tool_use blocks; execute each and append a tool_result.
                let toolUseBlocks = blocks.filter { ($0["type"] as? String) == "tool_use" }
                if toolUseBlocks.isEmpty {
                    if stopReason == "end_turn" {
                        emit(.init(kind: .stop, text: "Agent finished (end_turn)."))
                        return
                    }
                    // No tool calls and not end_turn — model went silent. Bail.
                    emit(.init(kind: .stop, text: "Agent stopped (no tool calls, stop_reason=\(stopReason ?? "nil"))."))
                    return
                }

                var resultBlocks: [[String: Any]] = []
                for toolUse in toolUseBlocks {
                    guard let id = toolUse["id"] as? String,
                          let name = toolUse["name"] as? String else { continue }
                    let input = toolUse["input"] as? [String: Any] ?? [:]
                    emit(.init(kind: .toolCall, text: prettyJSON(input), toolName: name))

                    let resultText: String
                    var isError = false
                    if let tool = tools.first(where: { $0.name == name }) {
                        do {
                            resultText = try await tool.execute(input: input)
                        } catch {
                            isError = true
                            resultText = "Tool error: \(error.localizedDescription)"
                        }
                    } else {
                        isError = true
                        resultText = "Unknown tool: \(name). Available: \(tools.map(\.name).joined(separator: ", "))"
                    }
                    emit(.init(kind: .toolResult, text: resultText, toolName: name))

                    resultBlocks.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": resultText,
                        "is_error": isError,
                    ])
                }
                transcript.append(["role": "user", "content": resultBlocks])
            } catch {
                emit(.init(kind: .error, text: error.localizedDescription))
                agentLog.error("AgentRunner: iteration failed — \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        if iterationCount >= maxIterations && !stopRequested {
            emit(.init(kind: .error, text: AgentError.capReached(iterations: maxIterations).localizedDescription))
        }
    }

    /// Push a new user message onto the queue; picked up at the start of the
    /// next iteration. UI exposes this as the "inject instruction" input.
    public func inject(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingInjections.append(trimmed)
    }

    /// Cooperative stop. The current iteration finishes, then the loop exits.
    public func requestStop() {
        stopRequested = true
    }

    // MARK: - Anthropic API call

    private struct AnthropicResponse {
        let stopReason: String?
        let contentBlocks: [[String: Any]]
    }

    private func callMessages() async throws -> AnthropicResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let toolsJSON: [[String: Any]] = tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema,
            ]
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "tools": toolsJSON,
            "messages": transcript,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.unexpectedResponse(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.unexpectedResponse(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.parseFailed("response is not a JSON object")
        }
        let stopReason = envelope["stop_reason"] as? String
        let content = envelope["content"] as? [[String: Any]] ?? []
        return AnthropicResponse(stopReason: stopReason, contentBlocks: content)
    }

    // MARK: - Helpers

    private func appendUserText(_ text: String) {
        transcript.append([
            "role": "user",
            "content": [["type": "text", "text": text]],
        ])
    }

    private func emit(_ event: AgentEvent) {
        onEvent(event)
    }

    private func prettyJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return String(describing: obj)
        }
        return s
    }
}
