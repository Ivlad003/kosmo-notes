@preconcurrency import AVFoundation
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

// MARK: - ScreenRecorder

/// Captures the full screen + optional system audio via SCStream, writing a
/// single `screen.mp4` via AVAssetWriter (H.264 video + AAC audio).
///
/// TCC requirement: Screen Recording permission must be granted before `start()`
/// or SCStream will throw userDeclined. The first call implicitly triggers the
/// macOS TCC prompt.
///
/// - Note: Requires macOS 12.3+.
@available(macOS 12.3, *)
public actor ScreenRecorder: NSObject {

    // MARK: - Config

    public struct Config: Sendable {
        public let outputURL: URL
        public let captureSystemAudio: Bool
        public let frameRate: Int
        public let scaleFactor: CGFloat

        public init(
            outputURL: URL,
            captureSystemAudio: Bool = true,
            frameRate: Int = 24,
            scaleFactor: CGFloat = 1.0
        ) {
            self.outputURL = outputURL
            self.captureSystemAudio = captureSystemAudio
            self.frameRate = frameRate
            self.scaleFactor = scaleFactor
        }
    }

    // MARK: - Private state

    private var config: Config?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var streamOutput: ScreenStreamOutput?
    private var firstSampleTime: CMTime?

    // MARK: - Init

    public override init() {}

    // MARK: - Public API

    public func start(config: Config) async throws {
        self.config = config

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw ScreenRecorderError.noDisplayAvailable
        }

        let width = Int(CGFloat(display.width) * config.scaleFactor)
        let height = Int(CGFloat(display.height) * config.scaleFactor)

        // Configure SCStream for video + optional audio.
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(config.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = config.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true  // may be ignored on macOS 26+
        streamConfig.sampleRate = 48_000
        streamConfig.channelCount = 1

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // Set up AVAssetWriter targeting the output URL.
        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }
        let assetWriter = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        self.writer = assetWriter

        // Video input: H.264, real-time.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        self.videoInput = vInput

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        self.pixelBufferAdaptor = adaptor
        assetWriter.add(vInput)

        // Audio input: AAC 48 kHz mono, real-time (only when captureSystemAudio).
        if config.captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            self.audioInput = aInput
            assetWriter.add(aInput)
        }

        assetWriter.startWriting()

        // Wire stream output delegate (separate @unchecked Sendable class per codebase pattern).
        let output = ScreenStreamOutput(recorder: self)
        self.streamOutput = output

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        if config.captureSystemAudio {
            try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        }
        try await scStream.startCapture()
        self.stream = scStream
    }

    /// Stop capture, finalize the MP4, and return the output URL.
    @discardableResult
    public func stop() async throws -> URL {
        guard let scStream = stream else { throw ScreenRecorderError.notStarted }
        try? await scStream.stopCapture()
        stream = nil
        streamOutput = nil

        guard let w = writer, let cfg = config else { throw ScreenRecorderError.notStarted }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await w.finishWriting()

        if w.status == .failed, let err = w.error {
            throw ScreenRecorderError.writeFailed(underlying: err)
        }

        return cfg.outputURL
    }

    // MARK: - Internal: called from ScreenStreamOutput

    /// Routes a sample buffer from the stream delegate into the correct writer input.
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        // CMSampleBuffer is not Sendable; wrap in an unchecked-Sendable box.
        // The delegate callback owns the buffer for the duration of the closure
        // call, so the cross-actor hop is safe in practice.
        let box = SBBox(buffer: sampleBuffer, type: type)
        Task { await self._handleSampleBuffer(box.buffer, ofType: box.type) }
    }

    private func _handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        guard let w = writer else { return }

        // Start the writer session on the very first sample to anchor PTS at .zero.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstSampleTime == nil {
            firstSampleTime = pts
            w.startSession(atSourceTime: pts)
        }

        switch type {
        case .screen:
            guard let vInput = videoInput, vInput.isReadyForMoreMediaData else { return }
            // Extract pixel buffer and append with offset PTS.
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let offsetPTS = CMTimeSubtract(pts, firstSampleTime!)
            pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: offsetPTS)

        case .audio:
            guard let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
            // For audio we copy with adjusted PTS to match video timeline origin.
            if let adjusted = sampleBuffer.copyWithAdjustedPTS(offset: firstSampleTime!) {
                aInput.append(adjusted)
            }

        @unknown default:
            break
        }
    }
}

// MARK: - SBBox

/// Sendable wrapper for `CMSampleBuffer` + `SCStreamOutputType`.
/// CMSampleBuffer is not Sendable; the box lets us hop the buffer across
/// the actor boundary. SCStream owns the buffer for the duration of the
/// delegate call, so the unchecked-sendability is safe in practice.
@available(macOS 12.3, *)
private final class SBBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let type: SCStreamOutputType
    init(buffer: CMSampleBuffer, type: SCStreamOutputType) {
        self.buffer = buffer
        self.type = type
    }
}

// MARK: - ScreenStreamOutput (SCStreamOutput delegate)

@available(macOS 12.3, *)
private final class ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

    private weak var recorder: ScreenRecorder?

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        recorder?.handleSampleBuffer(sampleBuffer, ofType: type)
    }
}

// MARK: - CMSampleBuffer PTS adjustment

private extension CMSampleBuffer {
    /// Return a copy of this sample buffer with all timing adjusted by subtracting `offset`.
    func copyWithAdjustedPTS(offset: CMTime) -> CMSampleBuffer? {
        let sampleCount = CMSampleBufferGetNumSamples(self)
        var timingInfos = [CMSampleTimingInfo](repeating: .invalid, count: sampleCount)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: sampleCount, arrayToFill: &timingInfos, entriesNeededOut: nil)

        // Subtract the first-sample offset so audio is time-aligned with video (both start at .zero).
        for i in 0..<sampleCount {
            timingInfos[i].presentationTimeStamp = CMTimeSubtract(timingInfos[i].presentationTimeStamp, offset)
            if CMTIME_IS_VALID(timingInfos[i].decodeTimeStamp) {
                timingInfos[i].decodeTimeStamp = CMTimeSubtract(timingInfos[i].decodeTimeStamp, offset)
            }
        }

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: sampleCount,
            sampleTimingArray: &timingInfos,
            sampleBufferOut: &adjusted
        )
        return adjusted
    }
}

// MARK: - Errors

@available(macOS 12.3, *)
public enum ScreenRecorderError: Error, Sendable {
    case noDisplayAvailable
    case notStarted
    case writeFailed(underlying: Error)
}

#else

// Stub for platforms where ScreenCaptureKit is unavailable.
@available(macOS 12.3, *)
public actor ScreenRecorder: NSObject {
    public struct Config: Sendable {
        public let outputURL: URL
        public let captureSystemAudio: Bool
        public let frameRate: Int
        public let scaleFactor: CGFloat
        public init(outputURL: URL, captureSystemAudio: Bool = true, frameRate: Int = 24, scaleFactor: CGFloat = 1.0) {
            self.outputURL = outputURL; self.captureSystemAudio = captureSystemAudio
            self.frameRate = frameRate; self.scaleFactor = scaleFactor
        }
    }
    public override init() {}
    public func start(config: Config) async throws { throw ScreenRecorderError.noDisplayAvailable }
    public func stop() async throws -> URL { throw ScreenRecorderError.noDisplayAvailable }
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {}
}

public enum ScreenRecorderError: Error, Sendable {
    case noDisplayAvailable
    case notStarted
    case writeFailed(underlying: Error)
}

#endif
