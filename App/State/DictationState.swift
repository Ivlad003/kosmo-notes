import Foundation
import Observation
import DictationKit
import TranscriptionKit
import AIKit

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
    private let hotkeyMonitor = HotkeyMonitor()

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Wire up the hotkey monitor. Call once on launch.
    func install() {
        hotkeyMonitor.startMonitoring(
            onPress: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handlePress()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleRelease()
                }
            }
        )
    }

    /// Remove hotkey callbacks.
    func uninstall() {
        hotkeyMonitor.stopMonitoring()
    }

    // MARK: - Private

    private func handlePress() async {
        // Pre-flight: Accessibility permission. Without it, the cleaned transcript
        // can't be pasted into the focused text field. Surface a modal pointing
        // at System Settings → Privacy → Accessibility and reminding the user that
        // AX trust only refreshes on relaunch.
        if !PermissionsHelper.accessibilityGranted() {
            PermissionsHelper.showMissingAlert(.accessibility)
            uiStatus = .failed("Accessibility access required. Grant in System Settings, then quit and relaunch Jarvis Note.")
            return
        }

        // Build pipeline lazily on first press
        if pipeline == nil {
            do {
                pipeline = try makePipeline()
            } catch {
                uiStatus = .failed(error.localizedDescription)
                return
            }
        }
        guard let p = pipeline else { return }
        do {
            try await p.startRecording()
            uiStatus = .recording
        } catch {
            uiStatus = .failed("Could not start dictation: \(error.localizedDescription)")
        }
    }

    private func handleRelease() async {
        guard let p = pipeline else { return }
        uiStatus = .processing
        await p.stopAndProcess()
        // Mirror pipeline status back to UI
        switch p.status {
        case .completed:
            uiStatus = .completed
        case .failed(let msg):
            uiStatus = .failed(msg)
        default:
            uiStatus = .idle
        }
    }

    private func makePipeline() throws -> DictationPipeline {
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw DictationSetupError.missingAPIKey("Configure OpenAI key for dictation")
        }
        let whisper = WhisperProvider(apiKey: key)

        // LLM provider: use configured provider when cleanup is enabled
        let llm: (any AIProvider)? = settings.dictationLLMCleanup ? makeLLMProvider() : nil

        return DictationPipeline(
            whisperProvider: whisper,
            llmProvider: llm,
            maxDurationSeconds: settings.dictationMaxSeconds
        )
    }

    private func makeLLMProvider() -> (any AIProvider)? {
        switch settings.llmProvider {
        case .anthropic:
            let k = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return nil }
            return AnthropicProvider(apiKey: k)
        case .openai:
            let k = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return nil }
            return OpenAIProvider(apiKey: k)
        case .ollama:
            let endpoint = URL(string: settings.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
            let mode: OllamaProvider.APIMode = settings.ollamaApiMode == .native ? .native : .openaiCompat
            let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
            return try? OllamaProvider(
                endpoint: endpoint,
                apiMode: mode,
                bearerToken: bearer.isEmpty ? nil : bearer
            )
        }
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
