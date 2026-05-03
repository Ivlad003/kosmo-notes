import Foundation
import Observation
import os

private let agentSessionLog = Logger(subsystem: "dev.kosmonotes.studio", category: "AgentSession")

// MARK: - AgentSessionState

/// UI-facing state for the autonomous agent. One instance per app launch
/// (singleton owned by AppDelegate); manages at most ONE active run at a
/// time, streams events into the published `events` array (so SwiftUI can
/// re-render), and writes every event to a per-session JSONL on disk.
///
/// Mid-session injection: the console window's text field calls
/// `inject(_:)`. Stop button calls `requestStop()`.
@available(macOS 14.0, *)
@Observable
@MainActor
final class AgentSessionState {

    enum Status: Equatable, Sendable {
        case idle
        case running(sessionID: String)
        case finished(sessionID: String)
        case failed(String)
    }

    // MARK: - Observable

    var status: Status = .idle
    /// Live event stream — appended to as the agent runs. Console view
    /// renders this. Cleared on `start(...)`.
    var events: [AgentEvent] = []

    // MARK: - Dependencies

    private let settings: AppSettings
    /// One of these is non-nil while a session runs. Built-in backend uses
    /// AgentRunner; CLI backends use ExternalAgentRunner. Polymorphism via
    /// helpers below to avoid an extra protocol layer.
    private var builtinRunner: AgentRunner?
    private var externalRunner: ExternalAgentRunner?
    private var sessionLogURL: URL?
    private var jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Kick off a new agent session with the given initial instruction.
    /// Cancels any in-flight session first. Returns once the loop ends.
    func start(initialInstruction: String) async {
        // If something is already running, stop it cleanly first.
        if case .running = status {
            await builtinRunner?.requestStop()
            await externalRunner?.requestStop()
        }

        let workspace = resolveWorkspace()
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            status = .failed("Could not create workspace at \(workspace.path): \(error.localizedDescription)")
            return
        }

        let sessionID = UUID().uuidString
        events = []
        sessionLogURL = openLogFile(sessionID: sessionID)
        status = .running(sessionID: sessionID)

        agentSessionLog.info("AgentSession.start: id=\(sessionID, privacy: .public) backend=\(self.settings.agentBackend.rawValue, privacy: .public) workspace=\(workspace.path, privacy: .public)")

        let onEvent: AgentRunner.EventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event)
            }
        }

        switch settings.agentBackend {
        case .builtin:
            await runBuiltin(workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
        case .claudeCode:
            await runExternal(backend: .claudeCode(binPath: settings.agentClaudeCodeBin),
                              workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
        case .codex:
            await runExternal(backend: .codex(binPath: settings.agentCodexBin),
                              workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
        case .copilot:
            await runExternal(backend: .copilot(binPath: settings.agentCopilotBin),
                              workspace: workspace, instruction: initialInstruction, onEvent: onEvent)
        }

        // Loop returned — flip status to finished. Failed events were already
        // surfaced via handleEvent.
        if case .running(let id) = status {
            status = .finished(sessionID: id)
        }
        builtinRunner = nil
        externalRunner = nil
    }

    /// Append a new user message to the running session. No-op if idle.
    func inject(_ message: String) async {
        guard case .running = status else { return }
        if let r = builtinRunner { await r.inject(message); return }
        if let r = externalRunner { await r.inject(message) }
    }

    /// Cooperative stop. Loop wraps up the current iteration then exits.
    func requestStop() async {
        guard case .running = status else { return }
        if let r = builtinRunner { await r.requestStop(); return }
        if let r = externalRunner { await r.requestStop() }
    }

    // MARK: - Backend dispatch

    private func runBuiltin(
        workspace: URL,
        instruction: String,
        onEvent: @escaping AgentRunner.EventHandler
    ) async {
        let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = .failed("Anthropic API key required for built-in backend (Settings → AI Providers).")
            return
        }

        let tools: [AgentTool] = [
            BashTool(workspace: workspace),
            ReadFileTool(workspace: workspace),
            WriteFileTool(workspace: workspace),
        ]
        let systemPrompt = settings.agentSystemPrompt.isEmpty
            ? AppSettings.defaultAgentSystemPrompt
            : settings.agentSystemPrompt
        let contextualSystem = systemPrompt + "\n\nYour workspace directory is `\(workspace.path)` — restrict all file operations to within it. The user's locale, current date, and OS info: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)."

        let runner = AgentRunner(
            apiKey: key,
            model: "claude-sonnet-4-6",
            systemPrompt: contextualSystem,
            maxIterations: settings.agentMaxIterations,
            tools: tools,
            onEvent: onEvent
        )
        self.builtinRunner = runner
        await runner.run(initialInstruction: instruction)
    }

    private func runExternal(
        backend: ExternalAgentRunner.Backend,
        workspace: URL,
        instruction: String,
        onEvent: @escaping ExternalAgentRunner.EventHandler
    ) async {
        let runner = ExternalAgentRunner(
            backend: backend,
            workspace: workspace,
            onEvent: onEvent
        )
        self.externalRunner = runner
        await runner.run(initialInstruction: instruction)
    }

    // MARK: - Private

    private func handleEvent(_ event: AgentEvent) {
        events.append(event)
        appendToLogFile(event)
    }

    private func resolveWorkspace() -> URL {
        let raw = settings.agentWorkspaceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("KosmoNotes-agent")
    }

    private func openLogFile(sessionID: String) -> URL? {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("KosmoNotes/agent-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func appendToLogFile(_ event: AgentEvent) {
        guard let url = sessionLogURL else { return }
        guard let data = try? jsonEncoder.encode(event) else { return }
        var line = data
        line.append(0x0A)  // newline
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        }
    }
}
