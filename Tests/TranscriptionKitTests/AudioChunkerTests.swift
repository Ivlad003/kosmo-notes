@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import TranscriptionKit

// MARK: - Test fixtures

/// Synthesize an .m4a file of the requested duration using AVAudioFile,
/// which auto-encodes Float32 PCM to AAC when given AAC output settings.
/// Returns the URL of the written file.
private func writeFakeAudioFile(duration: TimeInterval, sampleRate: Double = 48_000) throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent("audiochunker-fixture-\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        throw NSError(domain: "AudioChunkerTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not build PCM format"])
    }

    // Write 100 ms chunks of sine wave.
    let frameCount: AVAudioFrameCount = AVAudioFrameCount(sampleRate * 0.1)
    let totalChunks = Int(duration / 0.1)
    for chunkIdx in 0..<totalChunks {
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { continue }
        buf.frameLength = frameCount
        if let data = buf.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let t = Double(chunkIdx * Int(frameCount) + i) / sampleRate
                data[i] = Float(sin(2.0 * .pi * 440.0 * t))
            }
        }
        try file.write(from: buf)
    }
    return url
}

private func durationOf(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let dur = try await asset.load(.duration)
    return CMTimeGetSeconds(dur)
}

// MARK: - Tests

@Suite(
    "AudioChunker",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "AVAssetWriter / AVAudioFile encoding crashes the swift-testing process with SIGSEGV on headless macos GH Actions runners. Tests pass locally on Apple Silicon."
    )
)
struct AudioChunkerTests {

    @Test("Single-chunk fast path: audio shorter than maxChunkDuration returns one chunk pointing at the original file")
    func shortAudioIsSingleChunk() async throws {
        let audio = try writeFakeAudioFile(duration: 5.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunk(audioFile: audio, maxChunkDuration: 60.0)

        #expect(chunks.count == 1)
        #expect(chunks[0].url == audio)
        #expect(chunks[0].startTime == 0)
        // AAC encoding rounds duration; allow ±0.2 s slack.
        #expect(abs(chunks[0].duration - 5.0) < 0.5)

        // No temp directory should have been created.
        let temp = chunker.tempDirectory(for: chunks, originalAudioFile: audio)
        #expect(temp == nil)
    }

    @Test("Multi-chunk path: 12 s audio @ 5 s max yields 3 chunks (5+5+2) with correct offsets")
    func longAudioSplitsIntoOrderedChunks() async throws {
        let audio = try writeFakeAudioFile(duration: 12.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunk(audioFile: audio, maxChunkDuration: 5.0)

        #expect(chunks.count == 3)
        #expect(chunks[0].startTime == 0)
        #expect(chunks[1].startTime == 5)
        #expect(chunks[2].startTime == 10)

        // First two chunks should be ~5s, last ~2s. AAC encoding skews
        // duration slightly, so allow ±0.5s slack.
        #expect(abs(chunks[0].duration - 5.0) < 0.5)
        #expect(abs(chunks[1].duration - 5.0) < 0.5)
        #expect(abs(chunks[2].duration - 2.0) < 0.5)

        // Each chunk file should exist and be a decodable .m4a with audio.
        for chunk in chunks {
            #expect(FileManager.default.fileExists(atPath: chunk.url.path))
            let dur = try await durationOf(chunk.url)
            // Exported chunks may differ from source range by ~0.05–0.5 s
            // depending on AAC frame alignment; just confirm > 0.
            #expect(dur > 0.5, "Chunk \(chunk.url.lastPathComponent) duration should be > 0.5s, got \(dur)")
        }

        // Cleanup helper points at the temp dir.
        let temp = chunker.tempDirectory(for: chunks, originalAudioFile: audio)
        #expect(temp != nil)
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    @Test("Exact-multiple duration produces exact N chunks (no leftover)")
    func exactMultipleDuration() async throws {
        let audio = try writeFakeAudioFile(duration: 10.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunk(audioFile: audio, maxChunkDuration: 5.0)

        #expect(chunks.count == 2)
        #expect(chunks[0].startTime == 0)
        #expect(chunks[1].startTime == 5)

        if let temp = chunker.tempDirectory(for: chunks, originalAudioFile: audio) {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
