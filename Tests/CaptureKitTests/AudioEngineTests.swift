import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureKit

// MARK: - Tests

@Suite("AudioEngine synthetic-buffer tests (no real mic required)")
struct AudioEngineTests {

    @Test("Synthetic sine wave buffer has correct frame count")
    func sineWaveBufferFrameCount() {
        let frameCount: AVAudioFrameCount = 4800
        let buffer = AVAudioPCMBuffer.sineWave(frameCount: frameCount)
        #expect(buffer != nil)
        #expect(buffer?.frameLength == frameCount)
    }

    @Test("Synthetic sine wave buffer has non-zero samples")
    func sineWaveBufferNonZero() {
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800),
              let data = buf.floatChannelData?[0] else {
            Issue.record("Failed to create sine buffer")
            return
        }
        let hasNonZero = (0..<Int(buf.frameLength)).contains { data[$0] != 0.0 }
        #expect(hasNonZero)
    }

    @Test("Silence buffer has all-zero samples")
    func silenceBufferIsZero() {
        guard let buf = AVAudioPCMBuffer.silence(frameCount: 4800),
              let data = buf.floatChannelData?[0] else {
            Issue.record("Failed to create silence buffer")
            return
        }
        let allZero = (0..<Int(buf.frameLength)).allSatisfy { data[$0] == 0.0 }
        #expect(allZero)
    }

    @Test("MockAudioEngine delivers fed buffers via AsyncStream")
    func mockEngineDeliversBuffers() async {
        let engine = MockAudioEngine()
        let stream = await engine.start()

        let bufferCount = 3
        Task {
            for _ in 0..<bufferCount {
                if let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) {
                    await engine.feed(buf)
                }
            }
            await engine.stop()
        }

        var received = 0
        for await _ in stream {
            received += 1
        }
        #expect(received == bufferCount)
    }

    @Test("AVAudioPCMBuffer toCMSampleBuffer produces non-nil result")
    func toCMSampleBufferProducesResult() {
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
            Issue.record("Could not create buffer")
            return
        }
        let result = buf.toCMSampleBuffer(sampleOffset: 0, sampleRate: 48_000)
        // Should produce a valid CMSampleBuffer for a non-empty buffer
        #expect(result != nil)
    }

    @Test("AVAudioPCMBuffer toCMSampleBuffer preserves frame count")
    func toCMSampleBufferFrameCount() {
        let frameCount: AVAudioFrameCount = 4800
        guard let buf = AVAudioPCMBuffer.sineWave(frameCount: frameCount) else { return }
        guard let sb = buf.toCMSampleBuffer(sampleOffset: 0, sampleRate: 48_000) else { return }
        #expect(CMSampleBufferGetNumSamples(sb) == Int(frameCount))
    }

    @Test("AudioEngine.start throws or succeeds without crashing (CI-safe)")
    func audioEngineStartIsSafe() async {
        let engine = AudioEngine()
        do {
            _ = try await engine.start()
            await engine.stop()
        } catch {
            // Expected on CI — no mic. Pass.
        }
    }
}
