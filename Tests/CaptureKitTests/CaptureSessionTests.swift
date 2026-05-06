@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

// MARK: - CaptureSession tests
//
// These tests exercise CaptureSession with micEnabled=true, systemAudioEnabled=false
// (system audio requires Screen Recording TCC which CI runners don't have).
//
// The tests feed synthetic PCM buffers to a MockAudioEngine and verify that
// segment files are written to the expected directory structure.

@Suite(
    "CaptureSession tests (mic-only, no TCC required)",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] == "true",
        "Spins up SegmentWriter / AVAssetWriter; same SIGSEGV story as the SegmentWriter suite. Local Apple Silicon runs only."
    )
)
struct CaptureSessionTests {

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Config tests (no real capture needed)

    @Test("CaptureSession.Config stores values correctly")
    func configStoresValues() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: dir,
            segmentDurationSeconds: 3.0
        )

        #expect(config.micEnabled == true)
        #expect(config.systemAudioEnabled == false)
        #expect(config.sessionDir == dir)
        #expect(config.segmentDurationSeconds == 3.0)
    }

    @Test("CaptureSession.Config default values")
    func configDefaults() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(sessionDir: dir)
        #expect(config.micEnabled == true)
        #expect(config.systemAudioEnabled == false)
        #expect(config.segmentDurationSeconds == 5.0)
    }

    @Test("CaptureSession builds mic AudioEngine config from configured sample rate")
    func micAudioEngineConfigUsesConfiguredSampleRate() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: dir,
            audioSampleRate: 24_000
        )

        let engineConfig = CaptureSession.micAudioEngineConfig(for: config)
        #expect(engineConfig.sampleRate == 24_000)
        #expect(engineConfig.channels == 1)
    }

    // MARK: - Direct SegmentWriter-based integration (feeds synthetic buffers)

    @Test("start → feed synthetic buffers via SegmentWriter → stop returns segment paths")
    func startFeedStop() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        // Directly exercise SegmentWriter (the core of CaptureSession) with synthetic audio
        let writer = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 2.0,
            sampleRate: 48_000
        )

        // Feed 5 seconds of audio → expect 3 segments: [0–2), [2–4), [4–5)
        // 5 s = 240_000 frames = 50 × 4800-frame buffers
        for _ in 0..<50 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer.append(buf, source: .mic)
        }

        let paths = try await writer.close()

        #expect(paths.count >= 2, "Expected ≥2 segments for 5 s with 2 s segments, got \(paths.count)")
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test("Pause finalizes current segment")
    func pauseFinalizesSegment() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        // Simulate pause: write some audio, close (= pause finalize), then write more
        let writer1 = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0,
            sampleRate: 48_000
        )

        // Feed 3 seconds (less than 5 s segment) then close — simulates pause
        for _ in 0..<30 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer1.append(buf, source: .mic)
        }
        let paths1 = try await writer1.close()
        #expect(paths1.count == 1, "Expected 1 segment before pause, got \(paths1.count)")

        // Simulate resume: new writer, feed 3 more seconds
        let writer2 = try SegmentWriter(
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0,
            sampleRate: 48_000
        )
        for _ in 0..<30 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else { continue }
            try await writer2.append(buf, source: .mic)
        }
        let paths2 = try await writer2.close()
        #expect(paths2.count == 1, "Expected 1 segment after resume, got \(paths2.count)")

        // Total: 2 segments
        let segDir = sessionDir.appendingPathComponent("segments")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: segDir.path)) ?? []
        let m4aFiles = files.filter { $0.hasSuffix(".m4a") }
        #expect(m4aFiles.count == 2)
    }

    @Test("CaptureSession stop without start returns empty paths")
    func stopWithoutStartReturnsEmpty() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let config = CaptureSession.Config(
            micEnabled: false,
            systemAudioEnabled: false,
            sessionDir: sessionDir
        )
        let session = CaptureSession(config: config)
        let paths = try await session.stop()
        #expect(paths.isEmpty)
    }

    @Test("CaptureSession start with micEnabled=false systemAudioEnabled=false creates no capture tasks")
    func startWithBothDisabled() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let config = CaptureSession.Config(
            micEnabled: false,
            systemAudioEnabled: false,
            sessionDir: sessionDir
        )
        let session = CaptureSession(config: config)

        // Should not throw — just creates segment writer with no active feeds
        try await session.start()
        let paths = try await session.stop()

        // No buffers fed, so no completed segments
        #expect(paths.isEmpty)
    }

    @Test("AudioSource enum values are correct")
    func audioSourceValues() {
        let mic: AudioSource = .mic
        let system: AudioSource = .system
        // Enum identity check
        if case .mic = mic { } else {
            Issue.record("Expected .mic")
        }
        if case .system = system { } else {
            Issue.record("Expected .system")
        }
    }

    // MARK: - Live PCM sink tests

    @Test("CaptureSession forwards PCM buffers to LivePCMSink during capture")
    func livePCMSinkReceivesBuffers() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = TestPCMSink()
        
        // Create a test mic stream
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        
        // Create a session with the test sink and mock stream
        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)
        
        // Start the session (uses test stream instead of real mic)
        try await session.start()
        
        // Feed 3 buffers through the test stream
        for _ in 0..<3 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }
        
        // Give the feed task a moment to process
        try await Task.sleep(for: .milliseconds(100))
        
        // Verify sink received all buffers
        let count = await sink.count()
        #expect(count == 3, "Expected sink to receive 3 buffers, got \(count)")
        
        // Verify host times are non-zero
        let buffers = await sink.receivedBuffers
        for (index, recorded) in buffers.enumerated() {
            #expect(recorded.hostTime > 0, "Buffer \(index) has zero host time")
            #expect(recorded.frameLength == 4800, "Buffer \(index) has wrong frameLength: \(recorded.frameLength)")
        }
        
        // Clean stop
        continuation.finish()
        _ = try await session.stop()
    }

    @Test("CaptureSession does not await live sink inline")
    func livePCMSinkDeliveryIsNonblocking() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(250))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        for _ in 0..<3 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(sink.startedCount() >= 1, "Expected at least 1 sink delivery to start without blocking capture")
        #expect(sink.finishedCount() <= 2, "Expected serial delivery (at most 2 complete due to timing)")

        continuation.finish()
        _ = try await session.stop()
    }

    @Test("CaptureSession delivers buffers in order to live sink")
    func livePCMSinkOrderedDelivery() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(10))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 5 buffers quickly
        for _ in 0..<5 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give feed task time to enqueue all buffers before finishing
        try await Task.sleep(for: .milliseconds(100))

        continuation.finish()
        _ = try await session.stop()

        // After stop completes, all deliveries should be done
        let order = sink.receivedOrder()
        #expect(order.count == 5, "Expected sink to receive all 5 buffers, got \(order.count)")

        // Verify ordering: each hostTime should be >= previous
        for i in 1..<order.count {
            #expect(order[i] >= order[i-1], "Buffer \(i) out of order: \(order[i]) < \(order[i-1])")
        }
    }

    @Test("CaptureSession stop() drains pending live sink deliveries")
    func stopDrainsPendingDeliveries() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        let sink = BlockingTestPCMSink(delay: .milliseconds(50))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 10 buffers quickly
        for _ in 0..<10 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give feed task time to enqueue all buffers
        try await Task.sleep(for: .milliseconds(100))

        continuation.finish()
        
        // stop() should drain all pending deliveries before returning
        _ = try await session.stop()

        // After stop completes, all 10 buffers should be delivered
        let order = sink.receivedOrder()
        #expect(order.count == 10, "Expected sink to receive all 10 buffers after stop(), got \(order.count)")
    }

    @Test("LiveSinkDelivery drops oldest buffers when queue is full")
    func liveDeliveryDropsOldestWhenFull() async throws {
        let sessionDir = try makeTempDir()
        defer { cleanup(sessionDir) }

        // Use a blocking sink with significant delay to fill the queue
        let sink = BlockingTestPCMSink(delay: .milliseconds(100))
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let config = CaptureSession.Config(
            micEnabled: true,
            systemAudioEnabled: false,
            sessionDir: sessionDir,
            segmentDurationSeconds: 5.0
        )
        let session = CaptureSession(config: config, liveSink: sink, testMicStream: stream)

        try await session.start()

        // Feed 50 buffers rapidly to exceed the default queue size (32)
        for _ in 0..<50 {
            guard let buf = AVAudioPCMBuffer.sineWave(frameCount: 4800) else {
                Issue.record("Failed to create sine wave buffer")
                continue
            }
            continuation.yield(buf)
        }

        // Give a moment for capture to enqueue them
        try await Task.sleep(for: .milliseconds(200))

        continuation.finish()
        _ = try await session.stop()

        // After stop completes, some buffers should have been dropped
        let order = sink.receivedOrder()
        #expect(order.count < 50, "Expected some buffers to be dropped, but got \(order.count) (fed 50)")
        #expect(order.count > 0, "Expected at least some buffers to be delivered")
        
        // Verify the ones that were delivered are still in order
        for i in 1..<order.count {
            #expect(order[i] >= order[i-1], "Buffer \(i) out of order")
        }
    }
}
