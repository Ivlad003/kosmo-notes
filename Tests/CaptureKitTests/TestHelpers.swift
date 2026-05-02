// TestHelpers.swift — Synthetic audio buffer helpers shared across CaptureKitTests.
// Kept in a separate file so the AVFoundation extension does not affect
// Swift Testing macro expansion in the test structs.

import AVFoundation

// MARK: - AVAudioPCMBuffer test helpers

extension AVAudioPCMBuffer {
    /// Create a synthetic mono Float32 PCM buffer filled with a sine wave.
    static func sineWave(
        frameCount: AVAudioFrameCount,
        sampleRate: Double = 48_000,
        frequency: Double = 440.0
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frameCount) {
            data[i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        return buffer
    }

    /// Create a silent mono Float32 PCM buffer.
    static func silence(frameCount: AVAudioFrameCount, sampleRate: Double = 48_000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        return buffer
    }
}

// MARK: - MockAudioEngine

/// A test double that produces synthetic PCM buffers without requiring a real microphone.
actor MockAudioEngine {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func start() async -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont
        return stream
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}
