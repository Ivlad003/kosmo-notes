@preconcurrency import AVFoundation
import Foundation
import os

private let captureSessionLog = Logger(subsystem: "dev.kosmonotes.studio", category: "CaptureSession")

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
        /// When set, system audio is captured from this Core Audio input device
        /// (e.g. BlackHole 2ch loopback) instead of SCKit's whole-system mixdown.
        /// Lets users avoid the speaker → mic echo loop by routing system audio
        /// through a virtual device that the mic doesn't pick up.
        public let systemAudioDeviceUID: String?

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
            audioCodec: AudioCodecChoice = .heAAC,
            systemAudioDeviceUID: String? = nil
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
            self.systemAudioDeviceUID = systemAudioDeviceUID
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
    /// Optional fan-out for every PCM buffer (mic + system) **after** it lands
    /// in the segment writer. The intended consumer is StreamingKit's
    /// RTMPStreamer: tee the live audio into an RTMP publish without disturbing
    /// the disk-recording path. Always called from the same Task.detached that
    /// drains the AsyncStream — single-consumer, so the closure is free to
    /// dispatch onto its own actor without re-locking. nil = no tee, no cost.
    private let audioTee: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Optional fan-out for every screen-video CMSampleBuffer. Wired into
    /// ScreenRecorder when screen recording is enabled; nil = no tee.
    private let videoTee: (@Sendable (CMSampleBuffer) -> Void)?
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
    /// Capture for the user-selected loopback device (BlackHole etc).
    /// Mutually exclusive with `scKitBox` / `tapBoxAny` — when set, system
    /// audio comes from this device instead of SCKit's whole-system mixdown.
    private var deviceAudioCapture: DeviceAudioCapture?

    // MARK: - Init

    public init(
        config: Config,
        audioTee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        videoTee: (@Sendable (CMSampleBuffer) -> Void)? = nil
    ) {
        self.config = config
        self.audioTee = audioTee
        self.videoTee = videoTee
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
            // Three system-audio source paths, picked in order of preference:
            //   1. Custom loopback device (BlackHole etc) — set explicitly via
            //      Settings, eliminates speaker → mic echo.
            //   2. Per-process Core Audio Tap (14.4+) — captures audio from
            //      specific bundle IDs.
            //   3. SCKit whole-system mixdown — captures everything that's
            //      currently playing, including from speakers (echo-prone).
            var systemStarted = false

            if let deviceUID = config.systemAudioDeviceUID, !deviceUID.isEmpty {
                do {
                    let capture = DeviceAudioCapture(config: .init(deviceUID: deviceUID))
                    self.deviceAudioCapture = capture
                    systemTask = try await makeDeviceCaptureTask(capture: capture, writer: writer)
                    systemStarted = true
                    captureSessionLog.info("CaptureSession.start: system audio via custom device UID=\(deviceUID, privacy: .public)")
                } catch {
                    captureSessionLog.error("CaptureSession.start: device capture failed (\(error.localizedDescription, privacy: .public)) — falling back to SCKit")
                    self.deviceAudioCapture = nil
                }
            }

            if !systemStarted, config.useProcessTap, #available(macOS 14.4, *) {
                do {
                    let box = TapBox()
                    self.tapBoxAny = box
                    systemTask = try await makeTapTask(box: box, bundleIDs: config.processTapBundleIDs, writer: writer)
                    systemStarted = true
                } catch {
                    self.tapBoxAny = nil
                }
            }
            if !systemStarted, #available(macOS 12.3, *) {
                let box = SCKitBox()
                self.scKitBox = box
                systemTask = try await makeSystemTask(box: box, writer: writer)
            }
        }

        if config.screenRecordingEnabled, let outputURL = config.screenOutputURL {
            if #available(macOS 12.3, *) {
                let recorder = ScreenRecorder(videoTee: videoTee)
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

        if config.systemAudioEnabled {
            // Restart whichever system-audio path was originally chosen.
            if let capture = deviceAudioCapture {
                systemTask = try await makeDeviceCaptureTask(capture: capture, writer: writer)
            } else if #available(macOS 14.4, *), let box = tapBoxAny as? TapBox {
                systemTask = try await makeTapTask(box: box, bundleIDs: config.processTapBundleIDs, writer: writer)
            } else if let box = scKitBox, #available(macOS 12.3, *) {
                systemTask = try await makeSystemTask(box: box, writer: writer)
            }
        }

        recordingState = .recording
    }

    /// Live-mute the mic without tearing down capture. Forwards to the
    /// underlying AudioEngine's tap-side mute flag — see AudioEngine.setMuted.
    /// No-op when the session has no mic track (systemAudioOnly recordings).
    public func setMicMuted(_ muted: Bool) async {
        await audioEngine?.setMuted(muted)
    }

    /// Current mic mute state. False when capture isn't running yet.
    public var isMicMuted: Bool {
        get async { await audioEngine?.isMuted ?? false }
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
        await deviceAudioCapture?.stop()
        cancelFeedTasks()

        // Stop screen recorder. Best-effort in the sense that we don't surface
        // its error to the caller (audio finalization must complete regardless),
        // but we DO log it so silent failures stop being invisible.
        if #available(macOS 12.3, *) {
            do {
                _ = try await screenRecorder?.stop()
            } catch {
                captureSessionLog.error("CaptureSession.stop: screenRecorder.stop threw — \(error.localizedDescription, privacy: .public)")
            }
        }
        screenRecorder = nil

        let paths = try await segmentWriter?.close() ?? []
        audioEngine = nil
        scKitBox = nil
        tapBoxAny = nil
        deviceAudioCapture = nil
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
        let tee = audioTee
        return Task.detached {
            var bufferIndex = 0
            for await buffer in box.value {
                bufferIndex += 1
                do {
                    try await writer.append(buffer, source: .mic)
                    if bufferIndex == 1 || bufferIndex % 50 == 0 {
                        captureSessionLog.info("CaptureSession.mic: appended buffer #\(bufferIndex, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
                    }
                } catch {
                    captureSessionLog.error("CaptureSession.mic: writer.append threw — \(error.localizedDescription, privacy: .public) (buffer #\(bufferIndex, privacy: .public))")
                }
                tee?(buffer)
            }
            captureSessionLog.info("CaptureSession.mic: stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    @available(macOS 12.3, *)
    private nonisolated func makeSystemTask(box: SCKitBox, writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await box.capture.start()
        let streamBox = UncheckedSendableBox(stream)
        let tee = audioTee
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(SCKit): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                tee?(buffer)
            }
            captureSessionLog.info("CaptureSession.system(SCKit): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    /// Drain DeviceAudioCapture's PCM stream into the segment writer as the
    /// system-audio source. nonisolated mirrors the other makeXTask helpers
    /// so the AsyncStream never crosses CaptureSession's actor boundary.
    private nonisolated func makeDeviceCaptureTask(capture: DeviceAudioCapture, writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await capture.start()
        let streamBox = UncheckedSendableBox(stream)
        let tee = audioTee
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                do {
                    try await writer.append(buffer, source: .system)
                    if bufferIndex == 1 || bufferIndex % 50 == 0 {
                        captureSessionLog.info("CaptureSession.system(Device): appended buffer #\(bufferIndex, privacy: .public)")
                    }
                } catch {
                    captureSessionLog.error("CaptureSession.system(Device): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                tee?(buffer)
            }
            captureSessionLog.info("CaptureSession.system(Device): stream ended after \(bufferIndex, privacy: .public) buffers")
        }
    }

    @available(macOS 14.4, *)
    private nonisolated func makeTapTask(box: TapBox, bundleIDs: [String], writer: SegmentWriter) async throws -> Task<Void, Never> {
        let stream = try await box.tap.start(bundleIDs: bundleIDs)
        let streamBox = UncheckedSendableBox(stream)
        let tee = audioTee
        return Task.detached {
            var bufferIndex = 0
            for await buffer in streamBox.value {
                bufferIndex += 1
                do {
                    try await writer.append(buffer, source: .system)
                } catch {
                    captureSessionLog.error("CaptureSession.system(Tap): writer.append threw — \(error.localizedDescription, privacy: .public)")
                }
                tee?(buffer)
            }
            captureSessionLog.info("CaptureSession.system(Tap): stream ended after \(bufferIndex, privacy: .public) buffers")
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
