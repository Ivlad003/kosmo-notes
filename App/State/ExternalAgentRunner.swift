import Foundation
import os

private let externalAgentLog = Logger(subsystem: "dev.kosmonotes.studio", category: "ExternalAgentRunner")

// MARK: - ExternalAgentRunner

/// Spawns one of the supported third-party agent CLIs (Claude Code, Codex,
/// GitHub Copilot) as a subprocess inside the agent workspace folder, and
/// streams its stdout/stderr back as `AgentEvent` instances. Mirrors the
/// public surface of `AgentRunner` so `AgentSessionState` can drop it in
/// behind the same dispatch.
///
/// Behaviour notes:
///   - These CLIs reuse their own auth (claude.ai login / ChatGPT subscription /
///     `gh auth login`); we don't pass API keys.
///   - One-shot model: a single `instruction` is sent at spawn-time. Mid-session
///     `inject(_:)` writes additional lines to the child's stdin (most CLIs
///     accept follow-ups that way); if the child has already exited, the
///     injection is just logged.
///   - `requestStop()` sends SIGTERM, then SIGKILL after a short grace period.
///   - Iteration cap doesn't apply (the external CLI has its own loop); we
///     surface only `userMessage` / `assistantText` / `error` / `stop` events.
@available(macOS 14.0, *)
public actor ExternalAgentRunner {

    public typealias EventHandler = @Sendable (AgentEvent) -> Void

    public enum Backend: Sendable {
        case claudeCode(binPath: String)
        case codex(binPath: String)
        case copilot(binPath: String)

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code CLI"
            case .codex:      return "Codex CLI"
            case .copilot:    return "GitHub Copilot CLI"
            }
        }
    }

    private let backend: Backend
    private let workspace: URL
    private let onEvent: EventHandler
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stopRequested: Bool = false

    public init(
        backend: Backend,
        workspace: URL,
        onEvent: @escaping EventHandler
    ) {
        self.backend = backend
        self.workspace = workspace
        self.onEvent = onEvent
    }

    // MARK: - Public API (mirrors AgentRunner)

    public func run(initialInstruction: String) async {
        emit(.init(kind: .userMessage, text: initialInstruction))

        let resolved: ResolvedSpawn
        do {
            resolved = try resolveSpawn(for: backend, instruction: initialInstruction)
        } catch {
            emit(.init(kind: .error, text: "Could not resolve \(backend.displayName) binary: \(error.localizedDescription)"))
            return
        }

        emit(.init(kind: .assistantText, text: "Starting \(backend.displayName) — \(resolved.commandPreview)"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved.executable)
        proc.arguments = resolved.arguments
        proc.currentDirectoryURL = workspace
        proc.environment = augmentedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdin
        self.process = proc
        self.stdinPipe = stdin

        // Bridge the C-style terminationHandler into Swift Concurrency. Wire it
        // BEFORE `run()` so we never miss the callback on a fast-failing child.
        let exitedBox = AsyncSignal()
        proc.terminationHandler = { _ in exitedBox.fire() }

        do {
            try proc.run()
        } catch {
            emit(.init(kind: .error, text: "Failed to launch \(resolved.executable): \(error.localizedDescription)"))
            self.process = nil
            self.stdinPipe = nil
            return
        }

        externalAgentLog.info("ExternalAgentRunner: launched \(resolved.executable, privacy: .public) cwd=\(self.workspace.path, privacy: .public)")

        // Drain stdout + stderr in parallel on detached tasks so they don't
        // serialize on this actor's executor (otherwise a long-running stdout
        // drain blocks stderr and the child deadlocks filling the pipe). Each
        // line becomes an `assistantText` event for incremental console updates.
        let stdoutFD = stdoutPipe.fileHandleForReading
        let stderrFD = stderrPipe.fileHandleForReading
        let onEvent = self.onEvent
        let stdoutDrain = Task.detached {
            await Self.drain(handle: stdoutFD, kind: .assistantText, label: nil, emit: onEvent)
        }
        let stderrDrain = Task.detached {
            await Self.drain(handle: stderrFD, kind: .assistantText, label: "[stderr] ", emit: onEvent)
        }

        // Wait for the process to exit, then wait for both drains to finish so
        // we capture trailing output before declaring the run done.
        await exitedBox.wait()
        _ = await stdoutDrain.value
        _ = await stderrDrain.value

        let status = proc.terminationStatus
        let reason = proc.terminationReason
        self.process = nil
        self.stdinPipe = nil

        if stopRequested {
            emit(.init(kind: .stop, text: "Agent stopped by user (status=\(status))."))
        } else if status == 0 && reason == .exit {
            emit(.init(kind: .stop, text: "\(backend.displayName) finished cleanly."))
        } else {
            emit(.init(kind: .error, text: "\(backend.displayName) exited with status=\(status) reason=\(reason == .uncaughtSignal ? "signal" : "exit")."))
        }
    }

    public func inject(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        emit(.init(kind: .userMessage, text: "[injected] " + trimmed))
        guard let stdin = stdinPipe else {
            emit(.init(kind: .error, text: "Cannot inject — child process is not accepting stdin (already exited?)."))
            return
        }
        let line = (trimmed + "\n").data(using: .utf8) ?? Data()
        do {
            try stdin.fileHandleForWriting.write(contentsOf: line)
        } catch {
            emit(.init(kind: .error, text: "stdin write failed: \(error.localizedDescription)"))
        }
    }

    public func requestStop() {
        stopRequested = true
        guard let proc = process, proc.isRunning else { return }
        externalAgentLog.info("ExternalAgentRunner: SIGTERM pid=\(proc.processIdentifier, privacy: .public)")
        proc.terminate()
        // Escalate to SIGKILL after 2 s if still alive.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.killIfStillRunning()
        }
    }

    private func killIfStillRunning() {
        guard let proc = process, proc.isRunning else { return }
        externalAgentLog.info("ExternalAgentRunner: SIGKILL pid=\(proc.processIdentifier, privacy: .public)")
        kill(proc.processIdentifier, SIGKILL)
    }

    // MARK: - Spawn resolution

    private struct ResolvedSpawn {
        let executable: String
        let arguments: [String]
        let commandPreview: String
    }

    private enum SpawnError: Error, LocalizedError {
        case binaryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let name): return "\(name) not found on $PATH. Install it or set the absolute path in Settings → Agent."
            }
        }
    }

    private func resolveSpawn(for backend: Backend, instruction: String) throws -> ResolvedSpawn {
        switch backend {
        case .claudeCode(let configured):
            let exe = try resolveBinary(name: "claude", configured: configured)
            // `--print` (alias `-p`) returns once the agent is done. Combined
            // with `--output-format stream-json --verbose` we get one JSON
            // event per line on stdout — perfect for line-by-line streaming.
            // Fallback to plain text if the user prefers (we still stream
            // each printed line). `--dangerously-skip-permissions` is omitted
            // on purpose — Claude Code prompts for tool use, which is fine
            // because the agent runs visibly in the console.
            let args = ["--print", "--output-format", "stream-json", "--verbose", instruction]
            return ResolvedSpawn(executable: exe, arguments: args, commandPreview: "claude --print --output-format stream-json …")
        case .codex(let configured):
            let exe = try resolveBinary(name: "codex", configured: configured)
            // `codex exec "<prompt>"` runs non-interactively, prints output to
            // stdout, and exits when the task is done. No streaming JSON flag
            // — output is plain text.
            let args = ["exec", instruction]
            return ResolvedSpawn(executable: exe, arguments: args, commandPreview: "codex exec …")
        case .copilot(let configured):
            // Copilot CLI is `gh copilot suggest -t shell "<question>"` — one-shot
            // suggestion, no agent loop. We use it for "give me a shell command
            // for X"-shaped prompts; mid-session injection is meaningless here.
            let exe = try resolveBinary(name: "gh", configured: configured)
            let args = ["copilot", "suggest", "-t", "shell", instruction]
            return ResolvedSpawn(executable: exe, arguments: args, commandPreview: "gh copilot suggest -t shell …")
        }
    }

    /// Honor the user-set absolute path first; otherwise probe a small list
    /// of common install locations + `/usr/bin/which`.
    private func resolveBinary(name: String, configured: String) throws -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        // GUI apps don't inherit the user's interactive PATH. Probe the usual
        // suspects (Homebrew on Apple Silicon + Intel, npm-global, user bin).
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "\(NSHomeDirectory())/.npm-global/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last-ditch: shell out to `which` with a login-shell-flavored PATH.
        if let viaWhich = whichLookup(name: name) {
            return viaWhich
        }
        throw SpawnError.binaryNotFound(name)
    }

    private func whichLookup(name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bash", "-l", "-c", "command -v \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        } catch {
            return nil
        }
    }

    /// Pad PATH so spawned children can find their own dependencies (node,
    /// python, git) when we set `executableURL` to an absolute path.
    private func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.npm-global/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(existing):\(extras)"
        } else {
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:\(extras)"
        }
        return env
    }

    // MARK: - Streaming

    /// Read `handle` line-by-line; emit each non-empty line via `emit`.
    /// Returns when the pipe hits EOF (i.e. the child closed its stdout/stderr).
    /// Static so the two simultaneous drains don't serialize on the actor's
    /// executor — that would let one pipe fill up while we're stuck on the
    /// other and the child would block forever on `write`.
    nonisolated private static func drain(
        handle: FileHandle,
        kind: AgentEvent.Kind,
        label: String?,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async {
        var carry = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4096) ?? Data()
            } catch {
                emit(AgentEvent(kind: .error, text: "Pipe read failed: \(error.localizedDescription)"))
                return
            }
            if chunk.isEmpty {
                if !carry.isEmpty, let s = String(data: carry, encoding: .utf8), !s.isEmpty {
                    emit(AgentEvent(kind: kind, text: (label ?? "") + s))
                }
                return
            }
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 0x0A) {
                let lineData = carry.subdata(in: 0..<nl)
                carry.removeSubrange(0...nl)
                if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                    emit(AgentEvent(kind: kind, text: (label ?? "") + s))
                }
            }
        }
    }

    private func emit(_ event: AgentEvent) {
        onEvent(event)
    }
}

// MARK: - AsyncSignal

/// One-shot Sendable continuation bridge: `fire()` can be called from any
/// thread (e.g. the C `terminationHandler` callback) and `await wait()`
/// resumes exactly once. Using a class with a small lock so multiple awaiters
/// after fire() see the already-fired state without crashing.
@available(macOS 14.0, *)
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        if fired { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
