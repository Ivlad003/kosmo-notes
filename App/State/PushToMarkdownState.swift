import Foundation
import Observation
import os
import AIKit
import DictationKit
import StorageKit
import TranscriptionKit

private let pushToMDLog = Logger(subsystem: "dev.kosmonotes.studio", category: "PushToMarkdown")

// MARK: - PushToMarkdownState

/// Push-to-Markdown is the same press / hold / release pattern as Dictation,
/// but instead of pasting the cleaned text into the focused field it goes
/// straight through `MarkdownExporter` (the same system + user prompts the
/// user configured in Settings → Markdown) and lands as a new `.md` file
/// at the configured folder. Each press = one file.
///
/// Implementation reuses `DictationPipeline` for the mic capture + Whisper
/// transcription + optional LLM cleanup. The "paste" stage is hijacked: the
/// injected `Paster` closure spawns a detached Task that calls
/// `MarkdownExporter.export(...)`, then returns `.clipboardSimulatedV` so
/// the pipeline's own status flips to `.completed`.
@available(macOS 14.0, *)
@Observable
@MainActor
final class PushToMarkdownState {

    enum UIStatus: Equatable, Sendable {
        case idle
        case recording
        case processing
        case completed(URL?)
        case failed(String)
    }

    // MARK: - Observable

    var uiStatus: UIStatus = .idle
    var lastSavedURL: URL?

    // MARK: - Dependencies

    private let settings: AppSettings
    private let sessionStore: SessionStore
    private var pipeline: DictationPipeline?
    private let installer = TriggerHotkeyInstaller(comboName: .pushToMarkdown, label: "PushToMarkdown")
    private var triggerChangeObserver: NSObjectProtocol?

    // MARK: - Init

    init(settings: AppSettings, sessionStore: SessionStore) {
        self.settings = settings
        self.sessionStore = sessionStore
    }

    /// Wire up the global hotkey. Call once on launch alongside DictationState.
    /// Also observes the trigger-change notification so a Settings edit takes
    /// effect without relaunching.
    func install() {
        installer.install(
            trigger: settings.pushToMarkdownTrigger,
            onPress: { [weak self] in
                Task { @MainActor [weak self] in await self?.handlePress() }
            },
            onRelease: { [weak self] in
                Task { @MainActor [weak self] in await self?.handleRelease() }
            }
        )
        triggerChangeObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.pushToMarkdownTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installer.reinstall(
                    trigger: self.settings.pushToMarkdownTrigger,
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

    func uninstall() {
        installer.uninstall()
        if let token = triggerChangeObserver {
            NotificationCenter.default.removeObserver(token)
            triggerChangeObserver = nil
        }
    }

    // MARK: - Private

    private func handlePress() async {
        pushToMDLog.info("PushToMarkdown.handlePress: hotkey fired")

        guard settings.pushToMarkdownEnabled else {
            pushToMDLog.info("PushToMarkdown: disabled in Settings — ignoring press")
            return
        }
        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openaiKey.isEmpty else {
            uiStatus = .failed("OpenAI API key required for push-to-Markdown transcription. Set it in Settings → Transcription.")
            pushToMDLog.error("PushToMarkdown: missing OpenAI key")
            return
        }

        // Build the pipeline fresh so settings changes (provider, cleanup
        // toggle, max duration) apply without an app relaunch — same logic
        // as DictationState.
        do {
            pipeline = try makePipeline(openaiKey: openaiKey)
        } catch {
            uiStatus = .failed(error.localizedDescription)
            return
        }
        guard let p = pipeline else { return }
        do {
            try await p.startRecording()
            uiStatus = .recording
            pushToMDLog.info("PushToMarkdown: recording started")
        } catch {
            uiStatus = .failed("Could not start: \(error.localizedDescription)")
            pushToMDLog.error("PushToMarkdown: startRecording threw — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleRelease() async {
        pushToMDLog.info("PushToMarkdown.handleRelease: hotkey released")
        guard let p = pipeline else { return }
        uiStatus = .processing
        await p.stopAndProcess()
        switch p.status {
        case .completed:
            // The injected paster fires the MarkdownExporter Task; we polled
            // the pipeline and saw .completed which means cleanup ran. Wait
            // briefly for the saver to finish — simpler than threading a
            // continuation through DictationKit's API.
            // (saveMarkdownAndUpdateStatus runs inside the paster closure;
            // when it finishes it sets lastSavedURL via @MainActor)
            uiStatus = .completed(lastSavedURL)
        case .failed(let msg):
            uiStatus = .failed(msg)
            pushToMDLog.error("PushToMarkdown: pipeline failed — \(msg, privacy: .public)")
        default:
            uiStatus = .idle
        }
    }

    private func makePipeline(openaiKey: String) throws -> DictationPipeline {
        let whisper = WhisperProvider(apiKey: openaiKey, model: settings.openaiTranscribeModel.rawValue)

        let resolved = AIProviderResolver.resolve(settings.aiProviderConfig)
        let llm: (any AIProvider)? = settings.dictationLLMCleanup ? resolved?.provider : nil
        let model = resolved?.model ?? ""

        // Hijack the paster injection: instead of pasting, fire a detached
        // Task that runs the cleaned text through MarkdownExporter and
        // saves the resulting `.md`. Return .clipboardSimulatedV so the
        // pipeline's own `.completed` state fires.
        let saver: DictationPipeline.Paster = { [weak self] cleanedText in
            Task { @MainActor [weak self] in
                await self?.saveMarkdown(cleanedText: cleanedText)
            }
            return .clipboardSimulatedV
        }

        return DictationPipeline(
            transcriber: { url, cfg in
                try await whisper.transcribe(audioFile: url, config: cfg)
            },
            paster: saver,
            llmProvider: llm,
            llmModel: model,
            maxDurationSeconds: max(15, settings.dictationMaxSeconds)
        )
    }

    /// Run the cleaned dictation text through MarkdownExporter and stash
    /// the resulting URL on `lastSavedURL` so handleRelease can publish it.
    private func saveMarkdown(cleanedText: String) async {
        // MarkdownExporter checks `markdownExportEnabled` itself, but for
        // push-to-MD we want it to save regardless of that toggle (this
        // feature has its own enable flag). Temporarily flip it on for the
        // duration of the call, then restore — keeps the user's main
        // post-recording export setting independent.
        let originalEnabled = settings.markdownExportEnabled
        settings.markdownExportEnabled = true
        defer { settings.markdownExportEnabled = originalEnabled }

        let id = UUID().uuidString
        let url = await MarkdownExporter.export(
            transcript: cleanedText,
            settings: settings,
            sessionID: id,
            sessionMode: .dictation,
            recordedAt: Date()
        )
        if let url {
            pushToMDLog.info("PushToMarkdown: saved \(url.path, privacy: .public)")
            lastSavedURL = url
        } else {
            pushToMDLog.error("PushToMarkdown: MarkdownExporter returned nil")
        }
    }

}
