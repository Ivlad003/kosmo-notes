@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioCodecChoice

/// Public codec choice for capture configuration. Mirror of the user's
/// AppSettings.AudioCodec but kept inside CaptureKit so library consumers
/// (tests, callers from other targets) don't need to import App-level types.
public enum AudioCodecChoice: String, Sendable {
    case aac        // AAC-LC (kAudioFormatMPEG4AAC)
    case heAAC      // HE-AAC v1 (kAudioFormatMPEG4AAC_HE) — ~50% smaller for voice
    case opus       // Opus — silently downgraded to HE-AAC in .m4a containers

    var formatID: AudioFormatID {
        switch self {
        case .aac:   return kAudioFormatMPEG4AAC
        case .heAAC: return kAudioFormatMPEG4AAC_HE
        case .opus:  return kAudioFormatOpus
        }
    }
}

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
        /// When true, a ScreenRecorder is started alongside audio capture.
        public let screenRecordingEnabled: Bool
        /// Where ScreenRecorder writes screen.mp4; ignored when screenRecordingEnabled is false.
        public let screenOutputURL: URL?
        /// When true and the OS is macOS 14.4+, system audio is captured via
        /// per-process Core Audio Taps targeting `processTapBundleIDs`. Falls
        /// back to SCKit whole-system mixdown on older OS or any tap failure.
        public let useProcessTap: Bool
        /// Bundle IDs to capture when `useProcessTap` is on. Only running apps
        /// match — apps launched after `start()` are not added retroactively.
        public let processTapBundleIDs: [String]
        /// Use HEVC for screen.mp4. ~50 % smaller at same quality.
        public let videoUseHEVC: Bool
        /// Video bitrate in bits/sec.
        public let videoBitrate: Int
        /// Audio bitrate in bits/sec for both audio.m4a (segmented) and screen.mp4.
        public let audioBitrate: Int
        /// Audio sample rate Hz.
        public let audioSampleRate: Int
        /// Audio codec (`aac` / `heAAC` / `opus`). Opus falls back to HE-AAC when
        /// the .m4a container can't carry it. Only AAC-family codecs work in .m4a.
        public let audioCodec: AudioCodecChoice

        public init(
            micEnabled: Bool = true,
            systemAudioEnabled: Bool = false,
            sessionDir: URL,
            segmentDurationSeconds: Double = 5.0,
            screenRecordingEnabled: Bool = false,
            screenOutputURL: URL? = nil,
            useProcessTap: Bool = false,
            processTapBundleIDs: [String] = [],
            videoUseHEVC: Bool = true,
            videoBitrate: Int = 2_000_000,
            audioBitrate: Int = 48_000,
            audioSampleRate: Int = 48_000,
            audioCodec: AudioCodecChoice = .heAAC
        ) {
            self.micEnabled = micEnabled
            self.systemAudioEnabled = systemAudioEnabled
            self.sessionDir = sessionDir
            self.segmentDurationSeconds = segmentDurationSeconds
            self.screenRecordingEnabled = screenRecordingEnabled
            self.screenOutputURL = screenOutputURL
            self.useProcessTap = useProcessTap
            self.processTapBundleIDs = processTapBundleIDs
            self.videoUseHEVC = videoUseHEVC
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.audioSampleRate = audioSampleRate
            self.audioCodec = audioCodec
        }
    }

    /// Helper used at SegmentWriter construction time. Pulled out to keep the
    /// `try` site short.
    private static func formatIDForCodec(config: Config) -> AudioFormatID {
        config.audioCodec.formatID
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
    private var screenRecorder: ScreenRecorder?
    /// Stored as `AnyObject?` because `TapBox` is `@available(macOS 14.4, *)` —
    /// stricter than the package's macOS 14.0 deployment target. Cast at the
    /// use site under `#available(macOS 14.4, *)`.
    private var tapBoxAny: AnyObject?

    // MARK: - Init

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Public API

    public func start() async throws {
        guard recordingState == .idle else { return }

        let writer = try SegmentWriter(
            sessionDir: config.sessionDir,
            segmentDurationSeconds: config.segmentDurationSeconds,
            sampleRate: Double(config.audioSampleRate),
            audioFormatID: Self.formatIDForCodec(config: config),
            audioBitrate: config.audioBitrate
        )
        self.segmentWriter = writer

        if config.micEnabled {
            let engine = AudioEngine()
            self.audioEngine = engine
            micTask = try await makeMicTask(engine: engine, writer: writer)
        }

        if config.systemAudioEnabled {
            // Try the per-process Core Audio Tap path first when configured + 14.4+.
            // On any failure (no matching processes, kernel errors, etc.) we fall back
            // to SCKit's whole-system mixdown so a misconfigured tap never hard-fails
            // the entire recording.
            var tapStarted = false
            if config.useProcessTap, #available(macOS 14.4, *) {
                do {
                    let box = TapBox()
                    self.tapBoxAny = box
                    systemTask = try await makeTapTask(box: box, bundleIDs: config.processTapBundleIDs, writer: writer)
                    tapStarted = true
                } catch {
                    self.tapBoxAny = nil
                    // Fall through to SCKit fallback.
                }
            }
            if !tapStarted, #available(macOS 12.3, *) {
                let box = SCKitBox()
                self.scKitBox = box
                systemTask = try await makeSystemTask(box: box, writer: writer)
            }
        }

        if config.screenRecordingEnabled, let outputURL = config.screenOutputURL {
            if #available(macOS 12.3, *) {
                let recorder = ScreenRecorder()
                let srConfig = ScreenRecorder.Config(
                    outputURL: outputURL,
                    useHEVC: config.videoUseHEVC,
                    videoBitrate: config.videoBitrate,
                    audioBitrate: config.audioBitrate,
                    audioSampleRate: config.audioSampleRate
                )
                try await recorder.start(config: srConfig)
                self.screenRecorder = recorder
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
            segmentDurationSeconds: config.segmentDurationSeconds,
            sampleRate: Double(config.audioSampleRate),
            audioFormatID: Self.formatIDForCodec(config: config),
            audioBitrate: config.audioBitrate
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
        if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
            await box.tap.stop()
        }
        cancelFeedTasks()

        // Stop screen recorder (best-effort; don't let it block audio finalization).
        if #available(macOS 12.3, *) {
            try? await screenRecorder?.stop()
        }
        screenRecorder = nil

        let paths = try await segmentWriter?.close() ?? []
        audioEngine = nil
        scKitBox = nil
        tapBoxAny = nil
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

    @available(macOS 14.4, *)
    private nonisolated func makeTapTask(box: TapBox, bundleIDs: [String], writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await box.tap.start(bundleIDs: bundleIDs)
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

/// Boxes CoreAudioTap (macOS 14.4+) so the per-process tap can be stored
/// without the @available constraint leaking onto stored properties.
@available(macOS 14.4, *)
final class TapBox: Sendable {
    let tap = CoreAudioTap()
}
