@preconcurrency import AVFoundation
import Foundation
import Observation
import AIKit
import CaptureKit
import StorageKit
import TranscriptionKit

// MARK: - RecorderState

/// The single mutable record-time state object for the app.
///
/// Wires together CaptureKit (audio in), StorageKit (sessions on disk + DB),
/// and TranscriptionKit (Whisper batch transcription). The popover / menu
/// observe `status` and `micLevel` to render UI. Errors are surfaced via
/// `status = .failed(message:)` so the UI can show the user a single line.
///
/// v0 limits — explicit:
///   - **Whisper-only batch transcription.** Deepgram streaming requires PCM
///     tee'd from the capture engine, which the current `CaptureSession` API
///     doesn't expose. v1.1 of capture lands the tee.
///   - **Mic only.** System audio (SCKit mixdown) needs Screen Recording TCC
///     prompts that v0 doesn't set up cleanly.
@available(macOS 14.0, *)
@Observable
@MainActor
final class RecorderState {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        case recording(sessionId: String)
        case transcribing(sessionId: String)
        case complete(sessionId: String, audioFile: URL, transcriptPreview: String)
        case failed(message: String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .recording: return "Recording"
            case .transcribing: return "Transcribing…"
            case .complete: return "Done"
            case .failed: return "Failed"
            }
        }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing: return true
            default: return false
            }
        }
    }

    // MARK: - Observable state

    var status: Status = .idle
    /// 0..1 RMS-based level. Updated only while `status == .recording`.
    var micLevel: Double = 0
    /// Set after a successful AI summary write; nil when no summary exists yet.
    var lastSummaryURL: URL? = nil

    // MARK: - Dependencies

    private let database: AppDatabase
    private let sessionStore: SessionStore
    private let recoveryService = RecoveryService()
    private let settings: AppSettings

    // MARK: - Recording-time state

    private var captureSession: CaptureSession?
    private var micMeter: MicLevelMeter?

    // MARK: - Init

    init(database: AppDatabase, sessionStore: SessionStore, settings: AppSettings) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings
    }

    // MARK: - Public API

    /// Convenience: start if idle/done, stop if recording. Ignored while
    /// transcribing.
    func toggle() async {
        switch status {
        case .idle, .complete, .failed:
            await start(mode: .meeting)
        case .recording:
            await stop()
        case .transcribing:
            break
        }
    }

    /// Begin a recording session.
    func start(mode: SessionMode) async {
        // Idempotent: only proceed when not already mid-session.
        guard !status.isBusy else { return }

        // Pre-flight: API key
        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if openaiKey.isEmpty {
            status = .failed(message: "Set your OpenAI API key in Settings → Transcription before recording.")
            return
        }

        let language: String? = {
            let s = settings.summaryLanguage
            return (s == "auto" || s.isEmpty) ? nil : s
        }()

        do {
            let session = try await sessionStore.createSession(mode: mode, language: language)
            let dir = await sessionStore.sessionDir(for: session.id)

            let screenEnabled = settings.recordingMode == .audioAndScreen
            let config = CaptureSession.Config(
                micEnabled: true,
                systemAudioEnabled: false,  // v0: mic only — system audio TCC dance is v1.1
                sessionDir: dir,
                screenRecordingEnabled: screenEnabled,
                screenOutputURL: screenEnabled ? dir.appendingPathComponent("screen.mp4") : nil
            )
            let capture = CaptureSession(config: config)
            try await capture.start()
            self.captureSession = capture

            let meter = MicLevelMeter()
            try meter.start { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.micLevel = level
                }
            }
            self.micMeter = meter

            self.status = .recording(sessionId: session.id)
        } catch {
            await teardown()
            self.status = .failed(message: "Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Stop recording, finalize segments, run Whisper, persist transcript.
    func stop() async {
        guard case .recording(let sessionId) = status else { return }

        // Tear down capture + meter regardless of what happens next.
        let segments: [URL]
        do {
            segments = try await captureSession?.stop() ?? []
        } catch {
            segments = []
        }
        captureSession = nil
        micMeter?.stop()
        micMeter = nil
        micLevel = 0

        guard !segments.isEmpty else {
            self.status = .failed(message: "No audio captured (check Microphone permission in System Settings).")
            return
        }

        self.status = .transcribing(sessionId: sessionId)

        do {
            let dir = await sessionStore.sessionDir(for: sessionId)

            // Concatenate .m4a segments into a single audio.m4a via AVMutableComposition.
            let orphan = RecoveryService.OrphanSession(
                id: sessionId,
                sessionDir: dir,
                segmentURLs: segments
            )
            let audioFile = try await recoveryService.finalize(orphan)

            let asset = AVURLAsset(url: audioFile)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)

            // Pick the configured transcription provider. v0 wires Whisper only;
            // Deepgram lands when capture exposes a PCM tee (v1.1).
            let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let language: String? = {
                let s = settings.summaryLanguage
                return (s == "auto" || s.isEmpty) ? nil : s
            }()
            let provider = WhisperProvider(apiKey: openaiKey)
            let result = try await provider.transcribe(
                audioFile: audioFile,
                config: TranscriptionConfig(language: language)
            )

            // Persist transcript.jsonl + transcript.txt
            let store = try TranscriptStore(sessionDir: dir)
            for segment in result.segments {
                try await store.append(segment)
            }
            try await store.close()

            // FTS index + DB row finalize
            try await sessionStore.indexTranscript(sid: sessionId, text: result.text)

            // Generate AI summary; failures are non-fatal — pipeline continues regardless.
            lastSummaryURL = await tryGenerateSummary(
                transcript: result.text,
                sessionDir: dir,
                sourceLanguage: result.language
            )

            try await sessionStore.finalize(id: sessionId, status: .complete, durationSecs: duration)

            let preview = previewText(result.text)
            self.status = .complete(sessionId: sessionId, audioFile: audioFile, transcriptPreview: preview)
        } catch {
            // Mark the session failed in the DB, but don't crash if that fails too.
            try? await sessionStore.finalize(id: sessionId, status: .failed, durationSecs: 0)
            self.status = .failed(message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AI Summary

    /// Calls the configured LLM to produce a Markdown summary and atomically
    /// writes it to `<sessionDir>/summary.md`. Returns the file URL on success,
    /// nil on any failure (missing key, cost cap exceeded, network error, etc.).
    private func tryGenerateSummary(
        transcript: String,
        sessionDir: URL,
        sourceLanguage: String?
    ) async -> URL? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Resolve target language: nil means "auto" — let PromptTemplates decide.
        let target: String? = settings.summaryLanguage == "auto" ? nil : settings.summaryLanguage
        let system = PromptTemplates.meetingSummary(sourceLanguage: sourceLanguage, targetLanguage: target)
        let userMsg = PromptTemplates.meetingUserMessage(transcript: trimmed)

        // Select provider and pricing based on user preference.
        let provider: any AIProvider
        let pricing: CostEstimator.Pricing
        let model: String

        switch settings.llmProvider {
        case .anthropic:
            let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            provider = AnthropicProvider(apiKey: key)
            model = "claude-sonnet-4-6"
            pricing = CostEstimator.anthropic_claude_sonnet_4_6
        case .openai:
            let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            provider = OpenAIProvider(apiKey: key)
            model = "gpt-4o-mini"
            pricing = CostEstimator.openai_gpt_4o_mini
        }

        // Estimate cost before sending — skip silently if it exceeds the cap.
        let inputTokens = CostEstimator.estimateTokens(text: system) + CostEstimator.estimateTokens(text: userMsg)
        let outputTokensCap = 1500
        let estimatedCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputTokensCap,
            pricing: pricing
        )
        guard estimatedCost <= settings.costCapUSD else { return nil }

        let messages: [ChatMessage] = [ChatMessage(role: .user, content: userMsg)]
        let config = AIConfig(model: model, temperature: 0.3, maxTokens: outputTokensCap, systemPrompt: system)

        do {
            let summary = try await provider.chat(messages: messages, config: config)
            let summaryURL = sessionDir.appendingPathComponent("summary.md")
            try AtomicWriter.write(Data(summary.utf8), to: summaryURL)
            return summaryURL
        } catch {
            // Summary failures are non-fatal; the session is still usable without one.
            return nil
        }
    }

    // MARK: - Helpers

    private func teardown() async {
        if let session = captureSession {
            _ = try? await session.stop()
            captureSession = nil
        }
        micMeter?.stop()
        micMeter = nil
        micLevel = 0
    }

    private func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(240)) + "…"
    }
}
