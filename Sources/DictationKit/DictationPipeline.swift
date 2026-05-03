@preconcurrency import AVFoundation
import Foundation
import os
import os.signpost
import TranscriptionKit
import AIKit

// MARK: - DictationPipeline

/// Orchestrates: hotkey-press → AVAudioEngine mic tap → hotkey-release →
/// WAV encode → Whisper batch transcription → optional LLM cleanup →
/// AccessibilityPaster.
///
/// v0 latency note: Whisper batch median ~3 s on a typical broadband connection.
/// <1.5 s requires Deepgram streaming + a public PCM tee out of CaptureSession —
/// both deferred to v0.1. The Settings UI reflects this honestly.
@available(macOS 14.0, *)
@MainActor
public final class DictationPipeline {

    public typealias Logger = @Sendable (String) -> Void

    /// Stable signpost-event names emitted by the pipeline. Public so tests
    /// (and Instruments queries) can match against them without fuzzy strings.
    public enum Stage: String, Sendable, CaseIterable {
        case captureStart = "capture-start"
        case encodeDone = "encode-done"
        case uploadIssued = "upload-issued"
        case transcriptFinal = "transcript-final"
        case llmCleanupFinal = "llm-cleanup-final"
        case pasteIssued = "paste-issued"

        /// `OSSignposter.emitEvent` needs a `StaticString`, so we precompute
        /// one `EventName` per case from a literal.
        var signpostName: StaticString {
            switch self {
            case .captureStart:     return "capture-start"
            case .encodeDone:       return "encode-done"
            case .uploadIssued:     return "upload-issued"
            case .transcriptFinal:  return "transcript-final"
            case .llmCleanupFinal:  return "llm-cleanup-final"
            case .pasteIssued:      return "paste-issued"
            }
        }
    }

    /// Test/observability hook fired in addition to the real `os_signpost`
    /// emission. Receives the `Stage` and the absolute timestamp at which
    /// the pipeline reached it. Default `nil` keeps existing call sites
    /// (e.g. `App/State/DictationState.swift`) untouched.
    public typealias EventHook = @Sendable (Stage, ContinuousClock.Instant) -> Void

    /// Test-only paste shim. Defaults to the real `AccessibilityPaster.paste`.
    public typealias Paster = @Sendable (String) -> AccessibilityPaster.PasteResult

    /// Test-only transcription shim. Defaults to the configured
    /// `WhisperProvider.transcribe`.
    public typealias Transcriber = @Sendable (URL, TranscriptionConfig) async throws -> BatchTranscriptResult

    /// `OSSignposter` is the modern API and is `Sendable`-safe; one shared
    /// instance per process is fine.
    static let signposter = OSSignposter(
        subsystem: "dev.jarvisnote.dictation",
        category: "pipeline"
    )

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case cleaning
        case pasting
        case completed
        case failed(String)
    }

    // MARK: - Observable state

    public var status: Status = .idle

    // MARK: - Dependencies

    private let llmProvider: (any AIProvider)?
    private let llmModel: String
    private let maxDurationSeconds: Int
    private let logger: Logger?
    let eventHook: EventHook?
    let transcriber: Transcriber
    let paster: Paster

    // MARK: - Engine state (nonisolated storage via actor-hop-safe box)

    private var engineBox: EngineBox? = nil

    // MARK: - Init

    /// Production initializer. Wraps `whisperProvider.transcribe` and the
    /// real `AccessibilityPaster.paste` in shim closures so the rest of the
    /// pipeline can run against either real or mocked stages without
    /// branching.
    public init(
        whisperProvider: WhisperProvider,
        llmProvider: (any AIProvider)?,
        llmModel: String = "claude-sonnet-4-6",
        maxDurationSeconds: Int,
        logger: Logger? = nil,
        eventHook: EventHook? = nil
    ) {
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.maxDurationSeconds = maxDurationSeconds
        self.logger = logger
        self.eventHook = eventHook
        self.transcriber = { url, cfg in
            try await whisperProvider.transcribe(audioFile: url, config: cfg)
        }
        self.paster = { text in
            AccessibilityPaster.paste(text)
        }
    }

    /// Initializer that injects custom transcription / paste shims. Originally
    /// test-only (internal), now public so app-layer features like
    /// PushToMarkdownState and AgentHotkeyState can swap the paste step for
    /// their own sinks (save .md, launch agent, etc.) while reusing the
    /// dictation capture + transcribe + cleanup flow unchanged.
    public init(
        transcriber: @escaping Transcriber,
        paster: @escaping Paster,
        llmProvider: (any AIProvider)?,
        llmModel: String = "claude-sonnet-4-6",
        maxDurationSeconds: Int,
        logger: Logger? = nil,
        eventHook: EventHook? = nil
    ) {
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.maxDurationSeconds = maxDurationSeconds
        self.logger = logger
        self.eventHook = eventHook
        self.transcriber = transcriber
        self.paster = paster
    }

    // MARK: - Signpost helpers

    /// Emit an `os_signpost` `.event` for the given stage and notify the
    /// optional in-process `EventHook`. Both fire synchronously so the test
    /// hook's timestamp matches the signpost timestamp within nanoseconds.
    func emit(_ stage: Stage) {
        let now = ContinuousClock.now
        Self.signposter.emitEvent(stage.signpostName)
        eventHook?(stage, now)
    }

    // MARK: - Public API

    /// Begin capturing microphone audio. Sets status = .recording.
    public func startRecording() async throws {
        guard status == .idle || status == .completed || {
            if case .failed = status { return true } else { return false }
        }() else { return }

        emit(.captureStart)
        let box = EngineBox()
        try await box.start(maxSeconds: maxDurationSeconds)
        engineBox = box
        status = .recording
        logger?("[DictationPipeline] recording started")
    }

    /// Stop capture, transcribe, optionally clean with LLM, paste. Updates status throughout.
    public func stopAndProcess() async {
        guard status == .recording, let box = engineBox else { return }
        engineBox = nil

        // Encode captured PCM to a temp WAV file
        let pcmData = await box.stop()
        guard !pcmData.isEmpty else {
            status = .failed("No audio captured")
            logger?("[DictationPipeline] no audio data")
            return
        }

        let sampleRate: Double = 16_000
        guard let wavURL = writeTempWAV(pcmData: pcmData, sampleRate: sampleRate) else {
            status = .failed("Could not encode audio")
            return
        }
        emit(.encodeDone)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Transcribe
        status = .transcribing
        logger?("[DictationPipeline] transcribing")
        let transcript: String
        do {
            emit(.uploadIssued)
            let result = try await transcriber(
                wavURL,
                TranscriptionConfig(language: nil, sampleRate: Int(sampleRate))
            )
            emit(.transcriptFinal)
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            status = .failed("Transcription failed: \(error.localizedDescription)")
            logger?("[DictationPipeline] transcription error: \(error)")
            return
        }
        guard !transcript.isEmpty else {
            status = .failed("Empty transcript")
            return
        }

        // Optional LLM cleanup
        var finalText = transcript
        if let llm = llmProvider {
            status = .cleaning
            logger?("[DictationPipeline] LLM cleanup")
            let context = AppContextDetector.detect()
            let prompt = cleanupPrompt(transcript: transcript, context: context)
            let config = AIConfig(
                model: llmModel,
                temperature: 0.2,
                maxTokens: 1024,
                systemPrompt: nil
            )
            do {
                let cleaned = try await llm.chat(
                    messages: [ChatMessage(role: .user, content: prompt)],
                    config: config
                )
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finalText = trimmed }
            } catch {
                // LLM cleanup failure is non-fatal — fall back to raw transcript
                logger?("[DictationPipeline] LLM cleanup failed (non-fatal): \(error)")
            }
            // Emit even on non-fatal cleanup failure so per-run signpost
            // counts stay stable when cleanup is enabled.
            emit(.llmCleanupFinal)
        }

        // Paste
        status = .pasting
        logger?("[DictationPipeline] pasting")
        emit(.pasteIssued)
        let pasteResult = paster(finalText)
        switch pasteResult {
        case .axInserted, .clipboardSimulatedV:
            status = .completed
            logger?("[DictationPipeline] completed via \(pasteResult)")
        case .failed(let reason):
            status = .failed("Paste failed: \(reason)")
            logger?("[DictationPipeline] paste failed: \(reason)")
        }
    }

    /// Abort capture without processing.
    public func cancel() async {
        if let box = engineBox {
            engineBox = nil
            _ = await box.stop()
        }
        status = .idle
        logger?("[DictationPipeline] cancelled")
    }

    // MARK: - Private: LLM prompt

    private func cleanupPrompt(transcript: String, context: DictationContext) -> String {
        """
        You are a dictation cleanup assistant. The user just dictated raw transcribed \
        text. Clean it up: fix punctuation, capitalisation, paragraph breaks, common \
        speech artifacts ("um", "you know"). DO NOT add meaning or change wording. \
        Output ONLY the cleaned text — no preamble, no explanation.

        Application context: \(context.rawValue)
        Context-specific formatting: \(context.contextSpecificFormatting)

        Raw transcript:
        \(transcript)
        """
    }

    // MARK: - Private: WAV encoding

    private func writeTempWAV(pcmData: Data, sampleRate: Double) -> URL? {
        let frameCount = pcmData.count / MemoryLayout<Float>.size
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        pcmData.withUnsafeBytes { rawPtr in
            guard let floatPtr = rawPtr.bindMemory(to: Float.self).baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            channelData[0].assign(from: floatPtr, count: frameCount)
        }

        do {
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return url
    }
}

// MARK: - EngineBox

/// Non-isolated box that owns AVAudioEngine state so it can cross MainActor boundaries.
@available(macOS 14.0, *)
private final class EngineBox: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var maxFrames: Int = 0
    private let lock = NSLock()

    // 16 kHz mono Float32 — Whisper's preferred format
    private static let sampleRate: Double = 16_000

    func start(maxSeconds: Int) async throws {
        maxFrames = Int(Self.sampleRate) * maxSeconds
        samples.reserveCapacity(maxFrames)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw DictationError.formatCreationFailed }

        let converter: AVAudioConverter?
        if inputFormat.sampleRate != Self.sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: tapFormat)
        } else {
            converter = nil
        }

        let bufferSize: AVAudioFrameCount = 1600  // 100 ms @ 16 kHz
        let maxF = maxFrames
        let inputSR = inputFormat.sampleRate

        if let conv = converter {
            let convRef = conv
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputSR) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: max(1, cap)) else { return }
                var err: NSError?
                let src = buffer
                let status = convRef.convert(to: converted, error: &err) { _, outStatus in
                    outStatus.pointee = .haveData
                    return src
                }
                if status != .error, converted.frameLength > 0 {
                    self.accumulateSamples(converted, max: maxF)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
                self?.accumulateSamples(buffer, max: maxF)
            }
        }

        try engine.start()
    }

    func stop() async -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let captured: [Float] = lock.withLock {
            let snapshot = samples
            samples = []
            return snapshot
        }
        var data = Data(count: captured.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawPtr in
            guard let dst = rawPtr.bindMemory(to: Float.self).baseAddress else { return }
            dst.assign(from: captured, count: captured.count)
        }
        return data
    }

    private func accumulateSamples(_ buffer: AVAudioPCMBuffer, max maxF: Int) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        let remaining = maxF - samples.count
        guard remaining > 0 else { lock.unlock(); return }
        let take = min(count, remaining)
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: take))
        lock.unlock()
    }
}

// MARK: - Errors

public enum DictationError: Error, Sendable {
    case formatCreationFailed
}
