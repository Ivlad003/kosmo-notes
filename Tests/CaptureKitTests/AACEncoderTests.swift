@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

@Suite("AACEncoder tests", .serialized)
struct AACEncoderTests {

    @Test("AACEncoder initializes successfully")
    func initSucceeds() throws {
        let encoder = try AACEncoder(sampleRate: 48_000, bitrate: 96_000)
        #expect(encoder.aacFormat.sampleRate == 48_000)
    }

    @Test("Encode silent buffer returns Data or nil without throwing")
    func encodeSilentBuffer() throws {
        let encoder = try AACEncoder(sampleRate: 48_000)
        guard let buffer = AVAudioPCMBuffer.silence(frameCount: 4800) else {
            Issue.record("Could not create silence buffer")
            return
        }
        // encode() should not throw; it may return nil on first call (encoder priming)
        _ = try encoder.encode(buffer)
    }

    @Test("Encode sine wave buffer returns Data or nil without throwing")
    func encodeSineBuffer() throws {
        let encoder = try AACEncoder(sampleRate: 48_000)
        guard let buffer = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
            Issue.record("Could not create sine buffer")
            return
        }
        _ = try encoder.encode(buffer)
    }

    @Test("Encode multiple buffers accumulates output")
    func encodeMultipleBuffers() throws {
        let encoder = try AACEncoder(sampleRate: 48_000)
        var totalBytes = 0
        // Encode 10 buffers (≈1 s of audio at 48 kHz, 4800 frames = 100 ms each)
        for _ in 0..<10 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            if let data = try encoder.encode(buf) {
                totalBytes += data.count
            }
        }
        // After priming, we expect some encoded output
        // (AAC encoder may buffer a few frames before producing output)
        // We don't assert totalBytes > 0 strictly because the encoder may still
        // be buffering — but finalize should flush it.
        let finalData = encoder.finalize()
        // Either encode() produced some data OR finalize() did — together they cover 1 s
        #expect(totalBytes > 0 || finalData != nil)
    }

    @Test("finalize() does not throw")
    func finalizeDoesNotThrow() throws {
        let encoder = try AACEncoder(sampleRate: 48_000)
        _ = encoder.finalize()
    }

    @Test("outputAudioSettings contains expected keys")
    func outputAudioSettingsKeys() throws {
        let encoder = try AACEncoder(sampleRate: 48_000)
        let settings = encoder.outputAudioSettings
        #expect(settings[AVFormatIDKey] != nil)
        #expect(settings[AVSampleRateKey] != nil)
        #expect(settings[AVNumberOfChannelsKey] != nil)
    }

    // MARK: - Round-trip test: encode PCM → write .m4a → read back and verify audio tracks

    @Test("Round-trip: encode 1s sine → write .m4a → AVAsset has audio track")
    func roundTripWriteM4A() async throws {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputURL = tmpDir.appendingPathComponent("test.m4a")

        // 1 second of audio = 480 frames × 100 ms
        let sampleRate: Double = 48_000
        let framesPerBuffer: AVAudioFrameCount = 4800
        let bufferCount = 10  // 10 × 100 ms = 1 s

        // Set up AVAssetWriter with one AAC audio track
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Feed PCM buffers as CMSampleBuffers
        var sampleOffset: Int64 = 0
        for _ in 0..<bufferCount {
            guard let pcm = AVAudioPCMBuffer.sineWave(frameCount: framesPerBuffer, sampleRate: sampleRate) else { continue }
            if let sb = try pcm.toCMSampleBuffer(sampleOffset: sampleOffset, sampleRate: sampleRate) {
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                input.append(sb)
            }
            sampleOffset += Int64(framesPerBuffer)
        }

        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")

        // Verify the output file exists and has an audio track
        let asset = AVAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count >= 1, "Expected at least 1 audio track, got \(tracks.count)")
    }
}
