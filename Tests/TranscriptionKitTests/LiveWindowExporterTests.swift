@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import TranscriptionKit

// MARK: - Test fixtures

/// Synthesize an .m4a file of the requested duration using AVAudioFile,
/// which auto-encodes Float32 PCM to AAC when given AAC output settings.
/// Returns the URL of the written file.
private func writeFakeAudioFile(duration: TimeInterval, sampleRate: Double = 48_000) throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent("livewindow-fixture-\(UUID().uuidString).m4a")
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
        throw NSError(domain: "LiveWindowExporterTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not build PCM format"])
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
    "LiveWindowExporter",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "AVAssetWriter / AVAudioFile encoding crashes the swift-testing process with SIGSEGV on headless macos GH Actions runners. Tests pass locally on Apple Silicon."
    )
)
struct LiveWindowExporterTests {

    @Test("Exports a 10-second window from the middle of a longer file")
    func exportsMiddleWindow() async throws {
        let audio = try writeFakeAudioFile(duration: 30.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        let window = try await exporter.export(audioFile: audio, windowStart: 10.0, windowDuration: 10.0)
        defer { try? FileManager.default.removeItem(at: window) }

        let windowDur = try await durationOf(window)
        // AAC encoding rounds duration; allow ±0.5 s slack.
        #expect(abs(windowDur - 10.0) < 0.5)
    }

    @Test("Exports a window starting at 0")
    func exportsWindowAtStart() async throws {
        let audio = try writeFakeAudioFile(duration: 20.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        let window = try await exporter.export(audioFile: audio, windowStart: 0.0, windowDuration: 5.0)
        defer { try? FileManager.default.removeItem(at: window) }

        let windowDur = try await durationOf(window)
        #expect(abs(windowDur - 5.0) < 0.5)
    }

    @Test("Exports a window that extends past the end (clips to file duration)")
    func exportsWindowPastEnd() async throws {
        let audio = try writeFakeAudioFile(duration: 15.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        let window = try await exporter.export(audioFile: audio, windowStart: 10.0, windowDuration: 20.0)
        defer { try? FileManager.default.removeItem(at: window) }

        let windowDur = try await durationOf(window)
        // Should clip to ~5 seconds (file ends at 15s, start is 10s).
        #expect(abs(windowDur - 5.0) < 0.5)
    }

    @Test("Throws on invalid windowStart (negative)")
    func throwsOnNegativeStart() async throws {
        let audio = try writeFakeAudioFile(duration: 10.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        await #expect(throws: LiveWindowExporter.ExportError.self) {
            _ = try await exporter.export(audioFile: audio, windowStart: -1.0, windowDuration: 5.0)
        }
    }

    @Test("Throws on invalid windowDuration (zero or negative)")
    func throwsOnInvalidDuration() async throws {
        let audio = try writeFakeAudioFile(duration: 10.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        await #expect(throws: LiveWindowExporter.ExportError.self) {
            _ = try await exporter.export(audioFile: audio, windowStart: 0.0, windowDuration: 0.0)
        }
    }

    @Test("Exports consecutive non-overlapping windows")
    func exportsConsecutiveWindows() async throws {
        let audio = try writeFakeAudioFile(duration: 20.0)
        defer { try? FileManager.default.removeItem(at: audio) }

        let exporter = LiveWindowExporter()
        let window1 = try await exporter.export(audioFile: audio, windowStart: 0.0, windowDuration: 5.0)
        defer { try? FileManager.default.removeItem(at: window1) }
        let window2 = try await exporter.export(audioFile: audio, windowStart: 5.0, windowDuration: 5.0)
        defer { try? FileManager.default.removeItem(at: window2) }

        let dur1 = try await durationOf(window1)
        let dur2 = try await durationOf(window2)
        #expect(abs(dur1 - 5.0) < 0.5)
        #expect(abs(dur2 - 5.0) < 0.5)
    }
}
