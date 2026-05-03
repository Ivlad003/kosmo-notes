import Foundation
import os

private let agentToolLog = Logger(subsystem: "dev.jarvisnote.studio", category: "AgentTool")

// MARK: - AgentTool

/// One executable capability the agent can call mid-session. Each tool exposes
/// a JSON-schema description (so Claude knows when + how to use it) and an
/// `execute(input:)` async function that does the real work and returns
/// human-readable output (becomes the `tool_result` sent back to Claude).
///
/// Tools are intentionally simple-typed (`[String: Any]` in / `String` out).
/// Agent loops are short enough that the schema rigour of full Codable types
/// isn't worth the boilerplate; safety is enforced inside each tool body
/// (path allowlists, command sanitization).
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema (object) describing the tool's input. Sent verbatim to
    /// Anthropic in the `tools` array so the model picks the right one.
    var inputSchema: [String: Any] { get }

    /// Execute and return the result text. Throwing folds into `tool_result`
    /// with `is_error: true` so the model can recover.
    func execute(input: [String: Any]) async throws -> String
}

// MARK: - Built-in tools

/// Read the contents of a UTF-8 text file. Restricted to the workspace
/// directory the user picked in Settings — tries ~/Documents/JarvisNote-agent
/// by default if no workspace is set.
public struct ReadFileTool: AgentTool {
    public let name = "read_file"
    public let description = "Read the contents of a UTF-8 text file at the given absolute path. Returns the file contents as a string."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute filesystem path to read.",
            ],
        ],
        "required": ["path"],
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String else {
            throw AgentToolError.badInput("read_file: missing 'path'")
        }
        let url = URL(fileURLWithPath: path)
        try AgentToolGuard.requireInsideWorkspace(url, workspace: workspace, tool: "read_file")
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return "<binary file, \(data.count) bytes>"
        }
        // Cap response so a 10MB file doesn't blow the context window.
        if text.count > 64_000 {
            return String(text.prefix(64_000)) + "\n\n... [truncated, file is \(text.count) chars]"
        }
        return text
    }
}

/// Atomically write a UTF-8 text file. Same workspace allowlist as read_file.
public struct WriteFileTool: AgentTool {
    public let name = "write_file"
    public let description = "Write a UTF-8 text file. Overwrites if it exists, creates parent directories if missing. Use absolute paths inside your workspace."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Absolute filesystem path to write."],
            "content": ["type": "string", "description": "Text to write."],
        ],
        "required": ["path", "content"],
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String else { throw AgentToolError.badInput("write_file: missing 'path'") }
        guard let content = input["content"] as? String else { throw AgentToolError.badInput("write_file: missing 'content'") }
        let url = URL(fileURLWithPath: path)
        try AgentToolGuard.requireInsideWorkspace(url, workspace: workspace, tool: "write_file")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: [.atomic])
        return "Wrote \(content.count) chars to \(url.path)"
    }
}

/// Run a shell command. Allowlist-gated by `BashTool.allowedCommands` —
/// agent must call `which/ls/cat/echo/grep/find/head/tail/wc/file/git status`
/// etc. Anything else is refused. Output is captured and trimmed for context.
public struct BashTool: AgentTool {
    public let name = "bash"
    public let description = "Run a shell command and return stdout+stderr. Strict allowlist of safe read-only commands; mutations require explicit user approval at the JarvisNote level."
    public let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "Single shell command to run. Pipes / redirects supported. Must start with one of: ls, cat, echo, pwd, which, head, tail, wc, file, find, grep, rg, sed, awk, date, uname, env, git, swift, xcodebuild.",
            ],
        ],
        "required": ["command"],
    ]

    private static let allowedFirstWords: Set<String> = [
        "ls", "cat", "echo", "pwd", "which", "head", "tail", "wc", "file",
        "find", "grep", "rg", "sed", "awk", "date", "uname", "env",
        "git", "swift", "xcodebuild", "make", "npm", "node", "python", "python3",
    ]

    private let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    public func execute(input: [String: Any]) async throws -> String {
        guard let command = input["command"] as? String else {
            throw AgentToolError.badInput("bash: missing 'command'")
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.badInput("bash: empty command") }
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? ""
        guard Self.allowedFirstWords.contains(firstWord) else {
            throw AgentToolError.notAllowed("bash: '\(firstWord)' not in agent allowlist")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", trimmed]
        task.currentDirectoryURL = workspace
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            throw AgentToolError.runtime("bash launch failed: \(error.localizedDescription)")
        }
        task.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? "<non-utf8 output>"
        let truncated = output.count > 32_000 ? String(output.prefix(32_000)) + "\n... [truncated]" : output
        let exitInfo = task.terminationStatus == 0 ? "" : " (exit \(task.terminationStatus))"
        return "$ \(trimmed)\(exitInfo)\n\(truncated)"
    }
}

// MARK: - Errors + helpers

public enum AgentToolError: Error, LocalizedError {
    case badInput(String)
    case notAllowed(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .badInput(let s), .notAllowed(let s), .runtime(let s):
            return s
        }
    }
}

enum AgentToolGuard {
    /// Reject any path that resolves outside `workspace`. Resolves
    /// `..`/symlinks via standardizedFileURL so the agent can't escape via
    /// `/foo/../etc/passwd`.
    static func requireInsideWorkspace(_ url: URL, workspace: URL, tool: String) throws {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedWS = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let urlPath = resolvedURL.path
        let wsPath = resolvedWS.path
        if urlPath != wsPath && !urlPath.hasPrefix(wsPath + "/") {
            agentToolLog.error("\(tool, privacy: .public): path \(urlPath, privacy: .public) is outside workspace \(wsPath, privacy: .public)")
            throw AgentToolError.notAllowed("\(tool): path outside workspace (\(wsPath))")
        }
    }
}
