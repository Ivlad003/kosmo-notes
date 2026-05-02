@preconcurrency import AVFoundation
import Foundation
import os

// MARK: - AudioEngine

/// Unified-log channel for capture-engine diagnostics. Filterable via
/// `log show --predicate 'subsystem == "dev.jarvisnote.studio"' --info` or in
/// Console.app. Emits at .info for routine state changes and .error for the
/// silent-failure modes (degenerate input format, zero buffers in N seconds).
private let audioEngineLog = Logger(subsystem: "dev.jarvisnote.studio", category: "AudioEngine")

/// Real-time-thread-safe counter incremented by the tap closure. The actor
/// can't be touched from the audio render thread, so the closure increments
/// this `NSLock`-guarded counter directly and the actor polls it.
private final class TapBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0
    private var _totalFrames: Int = 0

    func increment(frames: Int) {
        lock.lock()
        _count += 1
        _totalFrames += frames
        lock.unlock()
    }

    var snapshot: (count: Int, totalFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_count, _totalFrames)
    }
}

// MARK: - AudioEngine

/// Captures microphone input via AVAudioEngine.
///
/// Delivers ~100 ms buffers of mono Float32 PCM at 48 kHz via an AsyncStream.
/// Safe to use from Swift concurrency contexts — all mutable state is actor-isolated.
public actor AudioEngine {

    // MARK: Public types

    public struct Config: Sendable {
        public let sampleRate: Double
        public let channels: AVAudioChannelCount

        public init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    // MARK: Private state

    private let config: Config
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // MARK: Init

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Public API

    /// Start mic capture. Returns an AsyncStream of PCM buffers (~100 ms / 4800 frames each).
    /// Throws if the audio engine cannot start (e.g. no input device, or no buffers
    /// arrive within 3 s of the tap being installed — the silent-TCC failure mode).
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        // Stop any existing session
        if engine != nil {
            await stop()
        }

        audioEngineLog.info("AudioEngine.start: requested sampleRate=\(self.config.sampleRate, privacy: .public) channels=\(self.config.channels, privacy: .public)")

        let engine = AVAudioEngine()
        self.engine = engine

        // Desired output format the rest of the pipeline expects.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: false
        ) else {
            audioEngineLog.error("AudioEngine.start: failed to build target AVAudioFormat")
            throw AudioEngineError.formatCreationFailed
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        // Touch inputNode BEFORE prepare/start so AVAudioEngine instantiates
        // its underlying AUHAL — otherwise engine.start() throws an
        // "inputNode != nullptr || outputNode != nullptr" assertion because
        // no nodes are in use yet. Just reading the property is enough.
        let inputNode = engine.inputNode

        // NOTE: setVoiceProcessingEnabled(true) (Apple's AEC + AGC + NS) was
        // tried here as a fix for the speaker → mic echo loop you get when
        // recording mic + system audio without headphones. It works, but it
        // forces VoiceProcessingIO into mono 16 kHz with aggressive AGC that
        // dropped mic gain to inaudible levels and broke our 48 kHz capture
        // pipeline. Rolled back; the recommended workaround for echo is
        // headphones (zero code, perfect cancellation).

        // Force AUHAL to bind the default input device by preparing + starting
        // the engine BEFORE installing the tap. Querying inputNode.outputFormat
        // at engine-creation time (the obvious order) returns 0 input streams
        // for ad-hoc-signed apps with freshly-granted Mic TCC — the audio HAL
        // hasn't routed the mic yet. A tap installed against that degenerate
        // format never fires its callback, so segments arrive at 0 bytes.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            audioEngineLog.error("AudioEngine.start: engine.start() threw — \(error.localizedDescription, privacy: .public)")
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            throw AudioEngineError.engineStartFailed(underlying: error)
        }
        audioEngineLog.info("AudioEngine.start: engine running, polling input format")

        // Poll for the input bus format to stabilize. After mic-permission
        // grant the AUHAL typically needs 1–3 polls to bind. Polling at 10 ms
        // (was 50 ms) shaves the worst-case "first words eaten" window from
        // ~150 ms down to ~30 ms while keeping the same 1 s ceiling
        // (now 100 attempts × 10 ms instead of 20 × 50 ms).
        var inputFormat = inputNode.outputFormat(forBus: 0)
        var attempts = 0
        while (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) && attempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            inputFormat = inputNode.outputFormat(forBus: 0)
            attempts += 1
        }
        audioEngineLog.info("AudioEngine.start: input format after \(attempts, privacy: .public) polls — sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")

        // If still degenerate after 1 s, mic isn't routed. Fail clearly
        // instead of silently writing 0-byte segments.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            audioEngineLog.error("AudioEngine.start: input format never bound (channels=0 or sampleRate=0 after 1 s)")
            engine.stop()
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            throw AudioEngineError.engineStartFailed(underlying: NSError(
                domain: "AudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Default input device did not bind within 1 s. Microphone permission may be denied or no input device is available."]
            ))
        }

        // bufferSize: 4800 frames @ 48 kHz ≈ 100 ms.
        let bufferSize: AVAudioFrameCount = 4800
        let cont = continuation
        let converterCache = ConverterCache()
        let counter = TapBufferCounter()

        // Install with the validated input format. Convert lazily in the
        // callback to the target format only when they don't already match.
        // The closure runs on the audio render thread — keep it real-time-safe:
        // no actor hops, no allocations beyond the converted PCM buffer, and
        // os.Logger is lock-free at the .debug level.
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            counter.increment(frames: Int(buffer.frameLength))
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate == targetFormat.sampleRate
                && bufferFormat.channelCount == targetFormat.channelCount
                && bufferFormat.commonFormat == targetFormat.commonFormat {
                cont.yield(buffer)
                return
            }
            guard let converter = converterCache.converter(from: bufferFormat, to: targetFormat) else {
                audioEngineLog.error("AudioEngine.tap: converter creation failed")
                return
            }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / bufferFormat.sampleRate
            ) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, frameCapacity)) else {
                return
            }
            var error: NSError?
            let src = buffer
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return src
            }
            if status != .error, converted.frameLength > 0 {
                cont.yield(converted)
            }
        }
        audioEngineLog.info("AudioEngine.start: tap installed, awaiting first buffer")

        // Wait up to 3 s for the tap callback to actually fire. If it doesn't,
        // the audio HAL never routed real audio to our process — typically a
        // stale/ambiguous TCC entry on ad-hoc-signed dev builds. Failing here
        // yields a clear error message instead of letting the recording finish
        // with zero segments and a misleading "check Microphone permission"
        // message in RecorderState.
        let deadline = Date().addingTimeInterval(3.0)
        while counter.snapshot.count == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let snap = counter.snapshot
        if snap.count == 0 {
            audioEngineLog.error("AudioEngine.start: tap callback did not fire within 3 s — TCC trust likely stale; tccutil reset Microphone dev.jarvisnote.studio + relaunch")
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            continuation.finish()
            self.continuation = nil
            throw AudioEngineError.engineStartFailed(underlying: NSError(
                domain: "AudioEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Microphone tap installed but no audio buffers arrived in 3 s. macOS reports permission as granted, but the audio HAL is not delivering data to this build. Run `tccutil reset Microphone dev.jarvisnote.studio`, relaunch the app, and grant the prompt again."]
            ))
        }
        audioEngineLog.info("AudioEngine.start: first buffers received — count=\(snap.count, privacy: .public) totalFrames=\(snap.totalFrames, privacy: .public)")

        return stream
    }

    /// Stop mic capture, remove tap, finish the stream.
    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
        engine = nil
        continuation = nil
    }
}

// MARK: - Errors

public enum AudioEngineError: Error, Sendable {
    case formatCreationFailed
    case converterCreationFailed
    case engineStartFailed(underlying: Error)
}

// MARK: - ConverterCache

/// Small reference holder for an AVAudioConverter that gets built on demand
/// when the first PCM buffer arrives. Used by AudioEngine's tap callback,
/// which runs on a real-time audio thread — building once and reusing.
private final class ConverterCache: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func converter(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        if let existing = converter,
           let cachedSource = sourceFormat,
           cachedSource.sampleRate == source.sampleRate,
           cachedSource.channelCount == source.channelCount,
           cachedSource.commonFormat == source.commonFormat {
            return existing
        }
        let new = AVAudioConverter(from: source, to: target)
        converter = new
        sourceFormat = source
        return new
    }
}
