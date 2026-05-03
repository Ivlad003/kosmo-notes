import Foundation
import Observation
import os
import DictationKit
import KeyboardShortcuts
import TranscriptionKit

private let agentHotkeyLog = Logger(subsystem: "dev.jarvisnote.studio", category: "AgentHotkey")

extension KeyboardShortcuts.Name {
    /// Push-to-talk trigger for the autonomous agent. Default ⌘⇧A
    /// (A for Agent). Hold to record; release transcribes via Whisper
    /// and ships the result as the initial instruction to AgentSessionState.
    public static let agentTrigger = Self("agentTrigger", default: .init(.a, modifiers: [.command, .shift]))
}

// MARK: - AgentHotkeyState

/// Wires the .agentTrigger hotkey into the agent. On press: starts a mic
/// capture session via DictationPipeline (Whisper-only — no LLM cleanup
/// because we want the raw instruction). On release: feeds the transcribed
/// text to AgentSessionState.start as the initial instruction.
///
/// Mirror of PushToMarkdownState's pattern; the only difference is the
/// downstream sink (AgentSessionState instead of MarkdownExporter).
@available(macOS 14.0, *)
@Observable
@MainActor
final class AgentHotkeyState {

    enum UIStatus: Equatable, Sendable {
        case idle
        case recording
        case processing
        case launched(sessionID: String)
        case failed(String)
    }

    // MARK: - Observable

    var uiStatus: UIStatus = .idle

    // MARK: - Dependencies

    private let settings: AppSettings
    private let agentSession: AgentSessionState
    private var pipeline: DictationPipeline?
    private let hotkeyMonitor = HotkeyMonitor(name: .agentTrigger)

    init(settings: AppSettings, agentSession: AgentSessionState) {
        self.settings = settings
        self.agentSession = agentSession
    }

    func install() {
        hotkeyMonitor.startMonitoring(
            onPress: { [weak self] in
                Task { @MainActor [weak self] in await self?.handlePress() }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in await self?.handleRelease() }
            }
        )
    }

    func uninstall() { hotkeyMonitor.stopMonitoring() }

    // MARK: - Private

    private func handlePress() async {
        agentHotkeyLog.info("AgentHotkey.handlePress: hotkey fired")
        guard settings.agentEnabled else {
            agentHotkeyLog.info("AgentHotkey: agent disabled in Settings")
            return
        }
        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openaiKey.isEmpty else {
            uiStatus = .failed("OpenAI API key required to transcribe agent instructions (Settings → Transcription).")
            return
        }
        let anthropicKey = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anthropicKey.isEmpty else {
            uiStatus = .failed("Anthropic API key required for the agent loop (Settings → AI Providers).")
            return
        }

        // Build a Whisper-only pipeline — no LLM cleanup (we want the raw
        // user instruction, not a tidied-up version). Hijack `paster` to
        // forward the text to AgentSessionState.start as the initial
        // instruction; pipeline returns .clipboardSimulatedV so its own
        // status flips to `.completed`.
        let whisper = WhisperProvider(apiKey: openaiKey)
        let saver: DictationPipeline.Paster = { [weak self] instruction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uiStatus = .processing
                Task { @MainActor in
                    await self.agentSession.start(initialInstruction: instruction)
                }
                if case .running(let id) = self.agentSession.status {
                    self.uiStatus = .launched(sessionID: id)
                }
            }
            return .clipboardSimulatedV
        }
        let p = DictationPipeline(
            transcriber: { url, cfg in
                try await whisper.transcribe(audioFile: url, config: cfg)
            },
            paster: saver,
            llmProvider: nil,
            llmModel: "claude-sonnet-4-6",
            maxDurationSeconds: max(15, settings.dictationMaxSeconds)
        )
        self.pipeline = p
        do {
            try await p.startRecording()
            uiStatus = .recording
            agentHotkeyLog.info("AgentHotkey: recording instruction…")
        } catch {
            uiStatus = .failed("Could not start: \(error.localizedDescription)")
            agentHotkeyLog.error("AgentHotkey.startRecording threw — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleRelease() async {
        agentHotkeyLog.info("AgentHotkey.handleRelease: stopping + transcribing")
        guard let p = pipeline else { return }
        uiStatus = .processing
        await p.stopAndProcess()
        switch p.status {
        case .completed:
            // saver Task launched agentSession.start; status flipped there.
            break
        case .failed(let msg):
            uiStatus = .failed(msg)
        default:
            uiStatus = .idle
        }
    }
}
