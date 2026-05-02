@preconcurrency import AVFoundation
import Foundation

// MARK: - CaptureSession

/// Top-level coordinator for audio capture.
///
/// Combines `AudioEngine` (mic) and `SCKitAudioCapture` (system audio) into
/// a single API. Both sources feed one `SegmentWriter` which writes 5-second
/// rolling segments to `<sessionDir>/segments/<n>.m4a`.
public actor CaptureSession {

    // MARK: - Config

    public struct Config: Sendable {
        public let micEnabled: Bool
        public let systemAudioEnabled: Bool
        public let sessionDir: URL
        public let segmentDurationSeconds: Double

        public init(
            micEnabled: Bool = true,
            systemAudioEnabled: Bool = false,
            sessionDir: URL,
            segmentDurationSeconds: Double = 5.0
        ) {
            self.micEnabled = micEnabled
            self.systemAudioEnabled = systemAudioEnabled
            self.sessionDir = sessionDir
            self.segmentDurationSeconds = segmentDurationSeconds
        }
    }

    // MARK: - Private state

    private enum RecordingState { case idle, recording, paused, stopped }

    private let config: Config
    private var recordingState: RecordingState = .idle
    private var audioEngine: AudioEngine?
    private var segmentWriter: SegmentWriter?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var scKitBox: SCKitBox?

    // MARK: - Init

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Public API

    public func start() async throws {
        guard recordingState == .idle else { return }

        let writer = try SegmentWriter(
            sessionDir: config.sessionDir,
            segmentDurationSeconds: config.segmentDurationSeconds
        )
        self.segmentWriter = writer

        if config.micEnabled {
            let engine = AudioEngine()
            self.audioEngine = engine
            micTask = try await makeMicTask(engine: engine, writer: writer)
        }

        if config.systemAudioEnabled {
            if #available(macOS 12.3, *) {
                let box = SCKitBox()
                self.scKitBox = box
                systemTask = try await makeSystemTask(box: box, writer: writer)
            }
        }

        recordingState = .recording
    }

    public func pause() async throws {
        guard recordingState == .recording else { return }
        cancelFeedTasks()
        _ = try await segmentWriter?.close()
        segmentWriter = nil
        recordingState = .paused
    }

    public func resume() async throws {
        guard recordingState == .paused else { return }

        let writer = try SegmentWriter(
            sessionDir: config.sessionDir,
            segmentDurationSeconds: config.segmentDurationSeconds
        )
        self.segmentWriter = writer

        if let engine = audioEngine {
            micTask = try await makeMicTask(engine: engine, writer: writer)
        }

        if config.systemAudioEnabled, let box = scKitBox {
            if #available(macOS 12.3, *) {
                systemTask = try await makeSystemTask(box: box, writer: writer)
            }
        }

        recordingState = .recording
    }

    @discardableResult
    public func stop() async throws -> [URL] {
        guard recordingState == .recording || recordingState == .paused else { return [] }

        await audioEngine?.stop()
        if #available(macOS 12.3, *) {
            await scKitBox?.capture.stop()
        }
        cancelFeedTasks()

        let paths = try await segmentWriter?.close() ?? []
        audioEngine = nil
        scKitBox = nil
        segmentWriter = nil
        recordingState = .stopped
        return paths
    }

    // MARK: - Private

    private func cancelFeedTasks() {
        micTask?.cancel()
        systemTask?.cancel()
        micTask = nil
        systemTask = nil
    }

    /// Build a Task that drains the mic stream into the writer.
    /// nonisolated so that the call to engine.start() (AudioEngine actor)
    /// and the resulting AsyncStream never cross into CaptureSession's isolation
    /// domain — avoiding the Swift 6 non-Sendable stream crossing error.
    private nonisolated func makeMicTask(engine: AudioEngine, writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await engine.start()
        // AVAudioPCMBuffer is not Sendable; we assert single-consumer ownership here.
        let box = UncheckedSendableBox(stream)
        return Task.detached {
            for await buffer in box.value {
                try? await writer.append(buffer, source: .mic)
            }
        }
    }

    @available(macOS 12.3, *)
    private nonisolated func makeSystemTask(box: SCKitBox, writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await box.capture.start()
        let streamBox = UncheckedSendableBox(stream)
        return Task.detached {
            for await buffer in streamBox.value {
                try? await writer.append(buffer, source: .system)
            }
        }
    }
}

// MARK: - Helpers

/// Boxes an arbitrary value as @unchecked Sendable.
/// Used to transfer AsyncStream across concurrency domains when the caller
/// guarantees single-consumer exclusive ownership.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Boxes SCKitAudioCapture (macOS 12.3+) so it can be stored as plain `Any`.
@available(macOS 12.3, *)
final class SCKitBox: Sendable {
    let capture = SCKitAudioCapture()
}
