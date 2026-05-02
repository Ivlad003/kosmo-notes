@preconcurrency import AVFoundation
import Foundation

// MARK: - MicLevelMeter

/// Minimal RMS-based microphone level meter.
///
/// Runs a SECOND `AVAudioEngine` instance independent of CaptureKit's main
/// recording engine — keeps the recording pipeline untouched and isolates
/// the UI concern. macOS allows multiple input taps on the same default mic.
///
/// Emits a `Double` level in `[0, 1]` via the `onLevel` callback every ~33 ms
/// while running. Levels are clamped + scaled by an empirical factor of 4×
/// to make typical voice land in the 0.2–0.8 range visually.
@available(macOS 14.0, *)
final class MicLevelMeter {
    private let engine = AVAudioEngine()
    private var running = false

    /// Start tapping the default input. Calls `onLevel` on the audio capture
    /// queue; the consumer is responsible for hopping to MainActor for UI.
    func start(onLevel: @escaping @Sendable (Double) -> Void) throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // ~33 ms per buffer at the input's native sample rate.
        let bufferSize = AVAudioFrameCount(max(256, 0.033 * format.sampleRate))

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var sumSquares: Float = 0
            for i in 0..<frames {
                let sample = data[i]
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(frames))
            // Empirical scale: voice peaks ~0.15–0.25 RMS; multiply by 4 so
            // normal speech reaches ~0.6–1.0 on the meter.
            let level = min(1.0, max(0.0, Double(rms) * 4.0))
            onLevel(level)
        }
        try engine.start()
        running = true
    }

    /// Stop tapping and release the input. Safe to call multiple times.
    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
