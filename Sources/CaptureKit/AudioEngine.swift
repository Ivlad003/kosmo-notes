@preconcurrency import AVFoundation

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
    /// Throws if the audio engine cannot start (e.g. no input device).
    public func start() async throws -> sending AsyncStream<AVAudioPCMBuffer> {
        // Stop any existing session
        if engine != nil {
            await stop()
        }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Desired tap format: mono float32 at configured sample rate
        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: false
        ) else {
            throw AudioEngineError.formatCreationFailed
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        // bufferSize: 4800 frames @ 48 kHz ≈ 100 ms
        let bufferSize: AVAudioFrameCount = 4800
        let cont = continuation
        let targetFormat = tapFormat
        let inputSampleRate = inputFormat.sampleRate

        if inputFormat.sampleRate != config.sampleRate || inputFormat.channelCount != config.channels {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioEngineError.converterCreationFailed
            }
            let converterRef = converter

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputSampleRate
                ) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, frameCapacity)) else {
                    return
                }
                var error: NSError?
                // Use a local copy reference to avoid captured-var warnings
                let src = buffer
                let status = converterRef.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return src
                }
                if status != .error, converted.frameLength > 0 {
                    cont.yield(converted)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { buffer, _ in
                cont.yield(buffer)
            }
        }

        try engine.start()
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
