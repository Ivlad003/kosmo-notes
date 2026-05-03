@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation
import AIKit
import CaptureKit
import StorageKit
import TranscriptionKit

// MARK: - Codec mapping

/// Maps AppSettings.AudioCodec → CaptureKit.AudioCodecChoice. Kept inline so
/// AppSettings doesn't need to import CaptureKit.
private extension AppSettings.AudioCodec {
    var captureChoice: AudioCodecChoice {
        switch self {
        case .aac:   return .aac
        case .heAAC: return .heAAC
        case .opus:  return .opus
        }
    }
}

// MARK: - RecorderState

/// The single mutable record-time state object for the app.
///
/// Wires together CaptureKit (audio in — mic, optional system audio via
/// Core Audio Tap on 14.4+ or ScreenCaptureKit mixdown, optional screen
/// capture), StorageKit (sessions on disk + DB), and TranscriptionKit
/// (batch transcription via the user-selected provider — Whisper /
/// AssemblyAI / Deepgram batch). The popover / menu observe `status` and
/// `micLevel` to render UI. Errors are surfaced via
/// `status = .failed(message:)` so the UI can show the user a single line.
///
/// Transcription is **batch** in v1.0 (per design-doc Decision Log D15):
/// the recorded `audio.m4a` is submitted to the provider's batch endpoint
/// once `stop()` finishes. Deepgram streaming infrastructure exists
/// (`DeepgramProvider.openResilientSession`) and is unit-tested, but is
/// not wired into the recorder UI — that lands in v1.1 alongside a
/// CaptureSession PCM tee and a live-transcript surface.
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
    /// Live mute toggle for the mic during a recording. UI binds to this so
    /// the menu item / popover button reflects the current state. Setter
    /// forwards into the actor stack so the tap closure starts dropping
    /// buffers immediately. Resets to false on every new recording.
    var micMuted: Bool = false
    /// Set after a successful AI summary write; nil when no summary exists yet.
    var lastSummaryURL: URL? = nil

    // MARK: - Dependencies

    // `database` and `settings` are module-internal (not private) so the
    // post-stop extension files (RecorderState+Summary, +Cleanup, +SemanticIndex)
    // can read them. RecorderState itself is internal-default, so these stay
    // invisible to anything outside the App target.
    let database: AppDatabase
    private let sessionStore: SessionStore
    private let recoveryService = RecoveryService()
    let settings: AppSettings

    // MARK: - Recording-time state

    private var captureSession: CaptureSession?
    private var micMeter: MicLevelMeter?
    private let sleepAssertion = SleepAssertion()
    /// Floating webcam bubble window; opened only when both Audio + Screen
    /// mode AND `cameraBubbleEnabled` are on, AND camera permission was
    /// granted. The bubble lives on screen for ScreenCaptureKit to capture
    /// it as part of `screen.mp4` — no separate compositing in our writer.
    private let cameraBubbleController = CameraBubbleWindowController()

    /// Optional sync-with-recording RTMP bridge. Wired by AppDelegate when
    /// the app boots; nil-tolerant so recordings work even if the bridge
    /// fails to construct. When non-nil, every PCM buffer the capture
    /// session produces also feeds into `bridge.ingest`, and the stream's
    /// lifecycle exactly mirrors the recording's.
    private let audioStreamingBridge: AudioStreamingBridge?

    // MARK: - Init

    init(
        database: AppDatabase,
        sessionStore: SessionStore,
        settings: AppSettings,
        audioStreamingBridge: AudioStreamingBridge? = nil
    ) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings
        self.audioStreamingBridge = audioStreamingBridge
    }

    // MARK: - Public API

    /// Tracks the mode of the active session so the post-process pipeline
    /// can pick the right prompt (Meeting summary vs. Voice Note).
    /// Module-internal so RecorderState+Summary can read it.
    var activeMode: SessionMode = .meeting

    /// Live-toggle mic mute during an in-flight recording. No-op when
    /// nothing is recording. UI calls this from the menu item / popover.
    func toggleMicMute() async {
        guard case .recording = status else { return }
        let next = !micMuted
        await captureSession?.setMicMuted(next)
        micMuted = next
    }

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

        // Pre-flight: API key for the configured transcription provider. The
        // selection in Settings → Transcription was previously decorative — the
        // record path always required an OpenAI key and always used Whisper.
        // Now we honor the choice and check the right key.
        switch settings.transcriptionProvider {
        case .openaiWhisper:
            let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if openaiKey.isEmpty {
                status = .failed(message: "Set your OpenAI API key in Settings → Transcription before recording.")
                return
            }
        case .deepgram:
            let deepgramKey = settings.deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if deepgramKey.isEmpty {
                status = .failed(message: "Set your Deepgram API key in Settings → Transcription before recording.")
                return
            }
        case .gemini:
            let geminiKey = settings.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if geminiKey.isEmpty {
                status = .failed(message: "Set your Gemini API key in Settings → Transcription before recording.")
                return
            }
        case .openrouterAudio:
            let orKey = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if orKey.isEmpty {
                status = .failed(message: "Set your OpenRouter API key in Settings → AI Providers before recording (used for OpenRouter multimodal transcription).")
                return
            }
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

        // Screen Recording permission is intentionally NOT pre-flighted here.
        // CGPreflightScreenCaptureAccess() reads TCC, which keys grants by the
        // binary's mach-o cdhash for ad-hoc-signed apps. Every rebuild changes
        // that hash, so even a freshly-granted "Allow" reads as denied on the
        // very next build. The preflight gate that lived here would loop the
        // user through "Open System Settings → toggle is already on → press
        // Record → denied" forever.
        //
        // Instead, we let SCKit handle permission natively: SCShareableContent /
        // SCStream.startCapture pop the system prompt themselves on first use
        // and bind the grant to the running binary's cdhash. If access is
        // truly denied, ScreenRecorder.start throws and the catch below surfaces
        // a clear "Could not start recording: …" message rather than our own
        // (now-redundant) modal.
        //
        // Best-effort nudge: still call CGRequest... so the row appears in
        // System Settings before anything else fails. No-op when already granted.
        if screenEnabled || systemAudioEnabled {
            _ = PermissionsHelper.requestScreenRecordingAccess()
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
                processTapBundleIDs: bundleIDs,
                videoUseHEVC: settings.videoUseHEVC,
                videoBitrate: settings.videoBitrate,
                audioBitrate: settings.audioBitrate,
                audioSampleRate: settings.audioSampleRate,
                audioCodec: settings.audioCodec.captureChoice,
                systemAudioDeviceUID: settings.systemAudioDeviceUID.isEmpty ? nil : settings.systemAudioDeviceUID
            )
            // Open the camera bubble window BEFORE starting SCStream so the
            // window is on screen by the time the first screen frame is
            // captured. Only when in Audio + Screen mode (no point recording
            // a webcam if there's no video file) and user has opted in.
            // If camera permission is missing we surface the alert and skip
            // — recording continues without the bubble.
            if screenEnabled && settings.cameraBubbleEnabled {
                let granted = await PermissionsHelper.requestCameraAccess()
                if granted {
                    await cameraBubbleController.show(settings: settings)
                } else {
                    PermissionsHelper.showMissingAlert(.camera)
                    // Don't fail the recording — just skip the bubble.
                }
            }

            // audioTee + videoTee fan every mic / system PCM buffer and every
            // screen-video CMSampleBuffer into the RTMP bridge (when wired).
            // Bridge is nil-tolerant; bridge itself is no-op when
            // streamingEnabled is off — both layers fail-soft so a
            // misconfigured RTMP destination never breaks the recording.
            let teeBridge = audioStreamingBridge
            let audioTee: (@Sendable (AVAudioPCMBuffer) -> Void)? = teeBridge.map { bridge in
                { buffer in bridge.ingest(buffer) }
            }
            let videoTee: (@Sendable (CMSampleBuffer) -> Void)? = teeBridge.map { bridge in
                { buffer in bridge.ingestVideo(buffer) }
            }
            let capture = CaptureSession(config: config, audioTee: audioTee, videoTee: videoTee)
            try await capture.start()
            self.captureSession = capture

            // Sync RTMP lifecycle to the recording. start() / stop() / teardown
            // already gate on capture lifecycle, so the bridge's stop() runs
            // before captureSession is torn down (see teardown()).
            await teeBridge?.startIfEnabled(settings: settings)

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

            // Reset live-mute on every new session so a previous mute doesn't
            // accidentally swallow the start of the next recording.
            self.micMuted = false
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
        await cameraBubbleController.hide()

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

            // Fold the mic track from audio.m4a into screen.mp4 so playback gives
            // you BOTH your voice and the system audio in the video file. Runs
            // concurrently with transcription — the mix is non-essential and
            // we don't want to block the transcript path on it. On failure the
            // existing screen.mp4 (system audio only) stays in place.
            let screenURL = dir.appendingPathComponent("screen.mp4")
            let mixTask: Task<Void, Never>?
            if FileManager.default.fileExists(atPath: screenURL.path) {
                mixTask = Task.detached {
                    do {
                        try await ScreenAudioMixer.mixMicInto(screenMP4: screenURL, audioM4A: audioFile)
                    } catch {
                        // Logged inside the mixer via os.Logger; nothing else to do.
                    }
                }
            } else {
                mixTask = nil
            }

            let asset = AVURLAsset(url: audioFile)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)
            _ = mixTask  // silence "unused" — task lifetime is tied to the recording cleanup path

            // Pick the configured transcription provider. Whisper uses OpenAI's
            // batch endpoint; Deepgram uses its REST batch (`/v1/listen`) since
            // we don't yet expose a PCM tee for streaming. The streaming
            // DeepgramProvider remains for v1.1.
            let language: String? = {
                let s = settings.summaryLanguage
                return (s == "auto" || s.isEmpty) ? nil : s
            }()
            let resolvedTx = TranscriptionResolver.resolve(settings.transcriptionConfig)
            let provider = resolvedTx.provider

            // Pre-flight cost gate. Long recordings + a per-minute pricing
            // model can push past the user's cap silently — surface the same
            // "increase cap or cancel" modal we already use for summary /
            // cleanup. Providers without a known per-minute price (Gemini,
            // OpenRouter) return nil pricing and skip the gate.
            let txPricing = resolvedTx.pricing
            if let pricing = txPricing {
                let estimated = CostEstimator.estimateTranscription(durationSec: duration, pricing: pricing)
                if estimated > settings.costCapUSD {
                    let proceed = await Self.confirmCostOverage(
                        kind: "Transcription",
                        estimated: estimated,
                        cap: settings.costCapUSD,
                        onIncrease: { [weak self] newCap in self?.settings.costCapUSD = newCap }
                    )
                    if !proceed {
                        status = .failed(message: "Transcription cancelled — estimated cost exceeded the cap.")
                        await teardown()
                        return
                    }
                }
            }

            let result = try await provider.transcribe(
                audioFile: audioFile,
                config: TranscriptionConfig(language: language)
            )

            // Optional LLM cleanup pass — fixes ASR mistakes (numbers, names,
            // double-words, missing punctuation) without touching segment
            // boundaries. Only the full text gets rewritten; segment timing is
            // preserved from the ASR output. On failure (no key, network, etc.)
            // we keep the raw text and continue.
            let cleanedText: String
            if settings.transcriptCleanupEnabled {
                cleanedText = await tryCleanupTranscript(
                    rawText: result.text,
                    sourceLanguage: result.language
                ) ?? result.text
            } else {
                cleanedText = result.text
            }

            // Persist transcript.jsonl (segments with timing — always raw) +
            // transcript.txt (the cleaned full text users actually read).
            // When cleanup is enabled we also save transcript.raw.txt so the
            // raw ASR output is available for audit / re-cleanup.
            let store = try TranscriptStore(sessionDir: dir)
            for segment in result.segments {
                try await store.append(segment)
            }
            try await store.close(overrideText: cleanedText)
            // Track whether any opt-in enhancement step degraded silently.
            // Audit §4.2 flagged that the user had no visible cue when an
            // opted-in feature didn't run — `partial` surfaces that in the
            // Library row.
            var enhancement: SessionEnhancementStatus = .ok
            if settings.transcriptCleanupEnabled, cleanedText != result.text {
                let rawURL = dir.appendingPathComponent("transcript.raw.txt")
                try? AtomicWriter.write(Data(result.text.utf8), to: rawURL)
            }
            // Cleanup was opted in but produced no usable result (returned the
            // raw text unchanged) → mark partial so the badge shows up.
            // We can't distinguish "model returned identical text" from
            // "fallback to raw" without a richer return type; for v1 we treat
            // identity as the signal — false positives on perfectly-clean
            // transcripts are acceptable cost.
            if settings.transcriptCleanupEnabled,
               cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
                 == result.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                enhancement = .partial
            }

            // FTS index + DB row finalize — index the cleaned text so search
            // hits the corrected words, not the misheard versions.
            try await sessionStore.indexTranscript(sid: sessionId, text: cleanedText)

            // Optional embedding index for semantic search. Failures are silent;
            // FTS5 is the primary index, embeddings just augment recall.
            if settings.semanticSearchEnabled {
                await indexSemantic(sid: sessionId, transcript: cleanedText)
            }

            // Generate AI summary; failures are non-fatal — pipeline continues regardless.
            lastSummaryURL = await tryGenerateSummary(
                transcript: cleanedText,
                sessionDir: dir,
                sourceLanguage: result.language
            )
            // Summary failed despite a non-empty transcript? Mark partial.
            // tryGenerateSummary returns nil for: empty input (skip), missing
            // API key (also fine — user not configured), cost-cap rejection
            // (intentional skip), and real LLM failure. We only know the
            // outcome; preserve a conservative "if non-empty input → expect
            // a summary" rule.
            if !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               lastSummaryURL == nil {
                enhancement = .partial
            }

            // Optional Markdown export — runs the cleaned transcript through
            // the user's custom system + user prompts and writes a `.md` to
            // their chosen folder. Independent of summary.md (which uses our
            // built-in PromptTemplates). Non-fatal if it fails.
            _ = await MarkdownExporter.export(
                transcript: cleanedText,
                settings: settings,
                sessionID: sessionId,
                sessionMode: activeMode,
                recordedAt: Date()
            )

            try await sessionStore.finalize(
                id: sessionId,
                status: .complete,
                durationSecs: duration,
                enhancementStatus: enhancement
            )

            let preview = previewText(cleanedText)
            self.status = .complete(sessionId: sessionId, audioFile: audioFile, transcriptPreview: preview)
        } catch {
            // Mark the session failed in the DB, but don't crash if that fails too.
            try? await sessionStore.finalize(id: sessionId, status: .failed, durationSecs: 0)
            self.status = .failed(message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // tryCleanupTranscript / tryGenerateSummary / indexSemantic live in
    // RecorderState+Cleanup.swift / +Summary.swift / +SemanticIndex.swift
    // so this file stays focused on capture lifecycle. confirmCostOverage
    // is kept here since it's also called from `stop()` (transcription
    // cost-cap gate); module-internal so the +Summary extension can call
    // it across files.

    // MARK: - Cost-cap modal

    /// Surface "estimate exceeds cap" modal. Returns true if the user agreed
    /// to proceed (after raising the cap), false on cancel. `kind` controls
    /// the modal title ("AI summary", "Transcription", "Cleanup", …) so the
    /// same chrome surfaces all three cost-cap gates with stage-specific text.
    /// Static so it doesn't capture `self` weakly across the alert presentation.
    @MainActor
    static func confirmCostOverage(
        kind: String = "AI summary",
        estimated: Double,
        cap: Double,
        onIncrease: (Double) -> Void
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(kind) cost exceeds cap"
        alert.informativeText = String(
            format: "Estimated cost $%.4f exceeds your per-session cap $%.2f.\n\nIncrease the cap to allow this %@, or cancel to skip it.",
            estimated,
            cap,
            kind.lowercased()
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
        // Stop the RTMP stream first so the capture drain task stops feeding
        // a now-defunct streamer. Idempotent — safe to call when streaming
        // wasn't enabled for this recording.
        await audioStreamingBridge?.stop()
        if let session = captureSession {
            _ = try? await session.stop()
            captureSession = nil
        }
        micMeter?.stop()
        micMeter = nil
        micLevel = 0
        sleepAssertion.release()
        await cameraBubbleController.hide()
    }

    private func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(240)) + "…"
    }
}
