import Foundation
import Observation
import os
import DictationKit
import TranscriptionKit
import AIKit

private let dictationLog = Logger(subsystem: "dev.kosmonotes.studio", category: "Dictation")

// MARK: - DictationState

/// App-layer @Observable wrapper around DictationPipeline.
/// Owns the HotkeyMonitor and lazily creates the pipeline on first use.
@available(macOS 14.0, *)
@Observable
@MainActor
final class DictationState {

    enum UIStatus: Equatable, Sendable {
        case idle
        case recording
        case processing
        case completed
        case failed(String)
    }

    // MARK: - Observable

    var uiStatus: UIStatus = .idle
    var lastResult: String?

    // MARK: - Dependencies

    private let settings: AppSettings
    private var pipeline: DictationPipeline?
    private let installer = TriggerHotkeyInstaller(comboName: .dictation, label: "Dictation")
    /// NotificationCenter token observing AppSettings.dictationTriggerDidChange,
    /// so a Settings change re-registers the hotkey live.
    private var triggerChangeObserver: NSObjectProtocol?

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Wire up the hotkey monitor + a Settings change observer so picking a
    /// different trigger in Settings → Dictation takes effect without relaunch.
    func install() {
        installer.install(
            trigger: settings.dictationTrigger,
            onPress: { [weak self] in
                Task { @MainActor [weak self] in await self?.handlePress() }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in await self?.handleRelease() }
            }
        )
        triggerChangeObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.dictationTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installer.reinstall(
                    trigger: self.settings.dictationTrigger,
                    onPress: { [weak self] in
                        Task { @MainActor [weak self] in await self?.handlePress() }
                    },
                    onRelease: { [weak self] in
                        Task { @MainActor [weak self] in await self?.handleRelease() }
                    }
                )
            }
        }
    }

    /// Remove hotkey callbacks and stop observing trigger-change notifications.
    func uninstall() {
        installer.uninstall()
        if let token = triggerChangeObserver {
            NotificationCenter.default.removeObserver(token)
            triggerChangeObserver = nil
        }
    }

    // MARK: - Private

    private func handlePress() async {
        dictationLog.info("Dictation.handlePress: hotkey fired")
        // Pre-flight: Accessibility permission. Without it, the cleaned transcript
        // can't be pasted into the focused text field. Surface a modal pointing
        // at System Settings → Privacy → Accessibility and reminding the user that
        // AX trust only refreshes on relaunch.
        if !PermissionsHelper.accessibilityGranted() {
            dictationLog.error("Dictation.handlePress: Accessibility not granted — showing alert")
            PermissionsHelper.showMissingAlert(.accessibility)
            uiStatus = .failed("Accessibility access required. Grant in System Settings, then quit and relaunch KosmoNotes.")
            return
        }

        // Rebuild the pipeline on every press so settings changes apply.
        do {
            pipeline = try makePipeline()
        } catch {
            dictationLog.error("Dictation.handlePress: makePipeline threw — \(error.localizedDescription, privacy: .public)")
            uiStatus = .failed(error.localizedDescription)
            return
        }
        guard let p = pipeline else { return }
        do {
            try await p.startRecording()
            uiStatus = .recording
            dictationLog.info("Dictation.handlePress: recording started")
        } catch {
            dictationLog.error("Dictation.handlePress: startRecording threw — \(error.localizedDescription, privacy: .public)")
            uiStatus = .failed("Could not start dictation: \(error.localizedDescription)")
        }
    }

    private func handleRelease() async {
        dictationLog.info("Dictation.handleRelease: hotkey released — processing")
        guard let p = pipeline else {
            dictationLog.error("Dictation.handleRelease: no active pipeline (press did not register?)")
            return
        }
        uiStatus = .processing
        await p.stopAndProcess()
        switch p.status {
        case .completed:
            uiStatus = .completed
            dictationLog.info("Dictation.handleRelease: pipeline completed — text pasted")
        case .failed(let msg):
            uiStatus = .failed(msg)
            dictationLog.error("Dictation.handleRelease: pipeline failed — \(msg, privacy: .public)")
        default:
            uiStatus = .idle
            dictationLog.info("Dictation.handleRelease: pipeline ended in unexpected state \(String(describing: p.status), privacy: .public)")
        }
    }

    private func makePipeline() throws -> DictationPipeline {
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw DictationSetupError.missingAPIKey("Configure OpenAI key for dictation")
        }
        let whisper = WhisperProvider(apiKey: key, model: settings.openaiTranscribeModel.rawValue)

        // LLM provider + per-provider model. The pipeline used to hardcode
        // claude-sonnet-4-6 in its AIConfig, so cleanup tied to OpenAI / Ollama
        // / OpenRouter would either reject the model or silently fall back to
        // raw transcript. AIProviderResolver picks the right default per
        // provider so the configured provider actually runs cleanup with a
        // model it understands.
        let resolved = AIProviderResolver.resolve(settings.aiProviderConfig)
        let llm: (any AIProvider)? = settings.dictationLLMCleanup ? resolved?.provider : nil
        let model = resolved?.model ?? ""

        return DictationPipeline(
            whisperProvider: whisper,
            llmProvider: llm,
            llmModel: model,
            maxDurationSeconds: settings.dictationMaxSeconds
        )
    }
}

// MARK: - Errors

private enum DictationSetupError: LocalizedError {
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        }
    }
}
