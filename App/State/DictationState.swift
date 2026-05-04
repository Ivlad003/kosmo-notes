@preconcurrency import AVFoundation
import Foundation
import Observation
import os
import DictationKit
import TranscriptionKit
import StorageKit
import AIKit

private let dictationLog = Logger(subsystem: "dev.kosmonotes.studio", category: "Dictation")

// MARK: - DictationState

/// App-layer @Observable wrapper around DictationPipeline.
/// Owns the HotkeyMonitor and lazily creates the pipeline on first use.
/// When a `sessionStore` is provided, every successful dictation is persisted
/// into the Library as a `mode = .dictation` SessionRecord with audio.m4a +
/// transcript.txt + transcript.jsonl, so the user can replay the audio and see
/// what was transcribed.
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
    private let sessionStore: SessionStore?
    private var pipeline: DictationPipeline?
    private let installer = TriggerHotkeyInstaller(comboName: .dictation, label: "Dictation")
    /// NotificationCenter token observing AppSettings.dictationTriggerDidChange,
    /// so a Settings change re-registers the hotkey live.
    private var triggerChangeObserver: NSObjectProtocol?

    // MARK: - Init

    init(settings: AppSettings, sessionStore: SessionStore? = nil) {
        self.settings = settings
        self.sessionStore = sessionStore
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
        // Snapshot the live config to logs every press so we can correlate the
        // configured insertion strategy / LLM cleanup state with whatever the
        // user observes (text appearing or not, latency, paste target).
        settings.logSnapshot(context: "before-dictation")
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
            lastResult = p.lastTranscript
            dictationLog.info("Dictation.handleRelease: pipeline completed — text pasted")
            await persistIfPossible(pipeline: p, status: .complete)
        case .failed(let msg):
            uiStatus = .failed(msg)
            dictationLog.error("Dictation.handleRelease: pipeline failed — \(msg, privacy: .public)")
            // Persist whatever we got — failed sessions are still useful in
            // Library if at least the audio + a partial transcript made it.
            await persistIfPossible(pipeline: p, status: .failed)
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
            maxDurationSeconds: settings.dictationMaxSeconds,
            insertionStrategy: settings.dictationInsertion
        )
    }

    // MARK: - Persistence

    /// After stopAndProcess finishes (succeed or fail), copy the captured PCM
    /// + transcript out of the pipeline and into a new Library session.
    private func persistIfPossible(pipeline p: DictationPipeline, status: SessionStatus) async {
        guard let store = sessionStore else { return }
        guard let pcm = p.lastPCMData,
              let sampleRate = p.lastSampleRate,
              let duration = p.lastDurationSecs else {
            dictationLog.info("Dictation.persist: no captured audio/duration — skipping")
            return
        }

        do {
            // 1. Reserve a SessionRecord. Mode = .dictation makes it filterable
            // in Library's Mode picker.
            let record = try await store.createSession(mode: .dictation, language: nil)
            let dir = await store.sessionDir(for: record.id)
            dictationLog.info("Dictation.persist: created session \(record.id, privacy: .public)")

            // 2. Encode PCM → AAC .m4a alongside the WAV that pipeline already
            // wrote (and discarded). Reusing AVAudioFile means no AVAssetWriter
            // wiring — the framework handles PCM→AAC conversion when the file
            // is opened with AAC settings.
            let audioURL = dir.appendingPathComponent("audio.m4a")
            try writeAACFile(pcmData: pcm, sampleRate: sampleRate, to: audioURL)

            // 3. Write transcript text + JSONL (single segment covering whole clip).
            let transcript = (p.lastTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try writeTranscriptFiles(transcript: transcript, durationSecs: duration, sessionDir: dir)

            // 4. Index FTS so the dictation is searchable in Library.
            if !transcript.isEmpty {
                try await store.indexTranscript(sid: record.id, text: transcript)
            }

            // 5. Finalize: status=complete (or failed) + actual duration.
            _ = try await store.finalize(
                id: record.id,
                status: status,
                durationSecs: duration,
                enhancementStatus: .ok
            )
            dictationLog.info("Dictation.persist: \(record.id, privacy: .public) finalized as \(String(describing: status), privacy: .public) (\(String(format: "%.1f", duration))s)")
        } catch {
            dictationLog.error("Dictation.persist: failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Write the raw Float32 PCM as a mono 16 kHz AAC `.m4a` file. AVAudioFile
    /// handles the format conversion when its settings differ from the source
    /// buffer (no manual AVAudioConverter wiring required).
    private func writeAACFile(pcmData: Data, sampleRate: Double, to url: URL) throws {
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        // Source PCM format (matches what the engine captured).
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DictationPersistError.formatCreationFailed
        }

        // Destination AAC settings. 64 kbps mono is plenty for voice; keeps
        // small dictations to a few KB instead of MBs.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw DictationPersistError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcmData.withUnsafeBytes { rawPtr in
            guard let floatPtr = rawPtr.bindMemory(to: Float.self).baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            channelData[0].update(from: floatPtr, count: frameCount)
        }

        try file.write(from: buffer)
    }

    /// Write transcript.txt + transcript.jsonl matching the meeting/voice-note
    /// session layout. Even though dictation has no fine-grained segmentation,
    /// emitting a single JSONL row keeps the Library detail view code path the
    /// same as for meetings.
    private func writeTranscriptFiles(transcript: String, durationSecs: TimeInterval, sessionDir: URL) throws {
        let txtURL = sessionDir.appendingPathComponent("transcript.txt")
        try transcript.write(to: txtURL, atomically: true, encoding: .utf8)

        guard !transcript.isEmpty else { return }
        // Single "whole-clip" segment — Whisper batch doesn't return per-word
        // timings here, so confidence is 1.0 and we cover [0, durationSecs).
        let segment = TranscriptSegment(
            start: 0,
            end: durationSecs,
            text: transcript,
            confidence: 1.0,
            isFinal: true
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(segment)
        let line = data + Data([0x0A])
        let jsonlURL = sessionDir.appendingPathComponent("transcript.jsonl")
        try line.write(to: jsonlURL, options: .atomic)
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

private enum DictationPersistError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Could not create AVAudioFormat for PCM source"
        case .bufferCreationFailed: return "Could not allocate PCM buffer for AAC encoding"
        }
    }
}
