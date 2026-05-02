@preconcurrency import AVFoundation
import AppKit
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
    private let sleepAssertion = SleepAssertion()

    // MARK: - Init

    init(database: AppDatabase, sessionStore: SessionStore, settings: AppSettings) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings
    }

    // MARK: - Public API

    /// Tracks the mode of the active session so the post-process pipeline
    /// can pick the right prompt (Meeting summary vs. Voice Note).
    private var activeMode: SessionMode = .meeting

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

        // Pre-flight: Microphone permission. First call triggers the macOS prompt;
        // subsequent calls return cached status. On denial, surface a modal with a
        // direct link to System Settings → Privacy → Microphone.
        let micGranted = await PermissionsHelper.requestMicAccess()
        if !micGranted {
            PermissionsHelper.showMissingAlert(.microphone)
            status = .failed(message: "Microphone access denied. Grant in System Settings, then try again.")
            return
        }

        let screenEnabled = settings.recordingMode == .audioAndScreen
        let systemAudioEnabled = settings.systemAudioEnabled

        // Pre-flight: Screen Recording permission, when either Audio + Screen mode
        // is enabled (writes screen.mp4) or the system-audio toggle is on (SCKit
        // mixdown also requires this entitlement). Calling CGRequest... triggers
        // the prompt on first run; the granted state often only takes effect after
        // a relaunch, so we surface a modal explaining that.
        if screenEnabled || systemAudioEnabled {
            if !PermissionsHelper.screenRecordingGranted() {
                PermissionsHelper.requestScreenRecordingAccess()
                PermissionsHelper.showMissingAlert(.screenRecording)
                status = .failed(message: "Screen Recording access required. Grant in System Settings, then quit and relaunch Jarvis Note.")
                return
            }
        }

        let language: String? = {
            let s = settings.summaryLanguage
            return (s == "auto" || s.isEmpty) ? nil : s
        }()

        do {
            let session = try await sessionStore.createSession(mode: mode, language: language)
            let dir = await sessionStore.sessionDir(for: session.id)
            self.activeMode = mode

            // Process Tap is only meaningful when system audio is enabled and we're on
            // 14.4+. Below 14.4 the field is set but never used (CaptureSession.start
            // gates the codepath on `#available(macOS 14.4, *)`).
            let bundleIDs = settings.processTapBundleIDs
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let config = CaptureSession.Config(
                micEnabled: true,
                systemAudioEnabled: systemAudioEnabled,
                sessionDir: dir,
                screenRecordingEnabled: screenEnabled,
                screenOutputURL: screenEnabled ? dir.appendingPathComponent("screen.mp4") : nil,
                useProcessTap: settings.useProcessTap,
                processTapBundleIDs: bundleIDs
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

            // Prevent the system from idle-sleeping for the lifetime of the
            // recording. Released in stop() / teardown().
            sleepAssertion.hold()

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
        sleepAssertion.release()

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

            // Optional embedding index for semantic search. Failures are silent;
            // FTS5 is the primary index, embeddings just augment recall.
            if settings.semanticSearchEnabled {
                await indexSemantic(sid: sessionId, transcript: result.text)
            }

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
        let system: String
        let userMsg: String
        switch activeMode {
        case .voiceNote:
            system = PromptTemplates.voiceNote(
                kind: settings.voiceNoteKind,
                sourceLanguage: sourceLanguage,
                targetLanguage: target
            )
            userMsg = PromptTemplates.voiceNoteUserMessage(transcript: trimmed)
        case .meeting, .dictation:
            system = PromptTemplates.meetingSummary(sourceLanguage: sourceLanguage, targetLanguage: target)
            userMsg = PromptTemplates.meetingUserMessage(transcript: trimmed)
        }

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
        case .openrouter:
            let key = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            provider = OpenRouterProvider(apiKey: key)
            model = settings.openrouterModel
            pricing = CostEstimator.openrouter_default
        case .ollama:
            let endpoint = URL(string: settings.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
            let mode: OllamaProvider.APIMode = settings.ollamaApiMode == .native ? .native : .openaiCompat
            let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                provider = try OllamaProvider(
                    endpoint: endpoint,
                    apiMode: mode,
                    bearerToken: bearer.isEmpty ? nil : bearer
                )
            } catch {
                return nil
            }
            model = settings.ollamaModel
            pricing = CostEstimator.Pricing(inputPerMillion: 0, outputPerMillion: 0)  // local, free
        }

        // Estimate cost before sending. If it exceeds the cap, surface a modal
        // so the user can either bump the cap or skip this run. Ollama is free
        // (pricing zero), so this branch is a no-op for local inference.
        let inputTokens = CostEstimator.estimateTokens(text: system) + CostEstimator.estimateTokens(text: userMsg)
        let outputTokensCap = 1500
        let estimatedCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputTokensCap,
            pricing: pricing
        )
        if estimatedCost > settings.costCapUSD {
            let proceed = await Self.confirmCostOverage(
                estimated: estimatedCost,
                cap: settings.costCapUSD,
                onIncrease: { [weak self] newCap in
                    self?.settings.costCapUSD = newCap
                }
            )
            if !proceed { return nil }
        }

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

    // MARK: - Semantic indexing

    /// Embed the transcript and persist the vector under the session ID.
    /// Best-effort: any failure (no API key, network, etc) is silently skipped.
    private func indexSemantic(sid: String, transcript: String) async {
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Truncate at ~6000 chars (~1500 tokens at 4 chars/tok ratio for Latin)
        // — enough for a meaningful semantic vector without going near the
        // 8192-token API limit. Long meetings still get a single vector that
        // captures the overall topic.
        let snippet = String(trimmed.prefix(6000))

        let provider = OpenAIEmbeddingProvider(apiKey: key)
        do {
            let vector = try await provider.embed(snippet)
            let blob = EmbeddingMath.pack(vector)
            try await database.upsertEmbedding(
                sid: sid,
                vector: blob,
                model: provider.modelIdentifier
            )
        } catch {
            // Silent failure — FTS5 still works.
        }
    }

    // MARK: - Cost-cap modal

    /// Surface "estimate exceeds cap" modal. Returns true if the user agreed
    /// to proceed (after raising the cap), false on cancel.
    /// Static so it doesn't capture `self` weakly across the alert presentation.
    @MainActor
    private static func confirmCostOverage(
        estimated: Double,
        cap: Double,
        onIncrease: (Double) -> Void
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "AI summary cost exceeds cap"
        alert.informativeText = String(
            format: "Estimated cost $%.4f exceeds your per-session cap $%.2f.\n\nIncrease the cap to allow this summary, or cancel to skip it.",
            estimated,
            cap
        )
        alert.alertStyle = .warning
        let increaseTitle = String(format: "Increase cap to $%.2f", estimated)
        alert.addButton(withTitle: increaseTitle)
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Round up to the next cent so the new cap actually exceeds the estimate.
            let rounded = (ceil(estimated * 100) / 100)
            onIncrease(rounded)
            return true
        }
        return false
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
        sleepAssertion.release()
    }

    private func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(240)) + "…"
    }
}
