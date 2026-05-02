import AVFoundation
import Foundation

// MARK: - AudioSource

/// Identifies which capture source produced a PCM buffer.
public enum AudioSource: Sendable {
    /// Microphone input (track 0 in the segment .m4a).
    case mic
    /// System audio (whole-system SCKit mixdown — track 1 in the segment .m4a).
    case system
}

// MARK: - SegmentWriter

/// Writes 5-second rolling segments to `<sessionDir>/segments/<n>.m4a`.
///
/// Each segment is an MPEG-4 file written via `AVAssetWriter` with up to 2 audio inputs:
///   - Track 0: mic PCM (AAC-encoded via AVAssetWriterInput)
///   - Track 1: system audio PCM (AAC-encoded, only present when system audio is active)
///
/// Crash-safety: each segment is finalized (fsync'd by AVAssetWriter on `finishWriting()`)
/// before the next one opens. Maximum data loss on SIGKILL is one partially-written
/// segment (≤5 s).
public actor SegmentWriter {

    // MARK: Types

    public enum SegmentWriterError: Error, Sendable {
        case segmentsDirCreationFailed(underlying: Error)
        case assetWriterCreationFailed(underlying: Error)
        case assetWriterInputCreationFailed
        case assetWriterStartFailed
        case assetWriterFinishFailed
    }

    // MARK: Private state

    private let sessionDir: URL
    private let segmentsDir: URL
    private let segmentDuration: Double
    private let sampleRate: Double

    private var segmentIndex: Int = 0
    private var segmentPaths: [URL] = []

    // Current segment state
    private var assetWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var segmentSampleCount: Int64 = 0

    // MARK: Init

    public init(sessionDir: URL, segmentDurationSeconds: Double = 5.0, sampleRate: Double = 48_000) throws {
        self.sessionDir = sessionDir
        self.segmentDuration = segmentDurationSeconds
        self.sampleRate = sampleRate
        self.segmentsDir = sessionDir.appendingPathComponent("segments")

        do {
            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        } catch {
            throw SegmentWriterError.segmentsDirCreationFailed(underlying: error)
        }

        // Resume after pause: find the highest existing segment index and start after it.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: segmentsDir.path)) ?? []
        let maxIndex = existing
            .compactMap { name -> Int? in
                guard name.hasSuffix(".m4a") else { return nil }
                return Int(name.dropLast(4))
            }
            .max()
        self.segmentIndex = maxIndex.map { $0 + 1 } ?? 0
    }

    // MARK: Public API

    /// Append a PCM buffer from the given source. Opens a new segment if needed.
    public func append(_ pcmBuffer: AVAudioPCMBuffer, source: AudioSource) async throws {
        if assetWriter == nil {
            try openNewSegment()
        }

        switch source {
        case .mic:
            appendBuffer(pcmBuffer, to: micInput, sampleOffset: segmentSampleCount)
        case .system:
            appendBuffer(pcmBuffer, to: systemInput, sampleOffset: segmentSampleCount)
        }

        segmentSampleCount += Int64(pcmBuffer.frameLength)
        let elapsed = Double(segmentSampleCount) / sampleRate

        if elapsed >= segmentDuration {
            try await rollSegment()
        }
    }

    /// Finalize the current segment and return all segment paths (in order).
    public func close() async throws -> [URL] {
        try await finalizeCurrentSegment()
        return segmentPaths
    }

    // MARK: Private helpers

    private func openNewSegment() throws {
        let url = segmentsDir.appendingPathComponent("\(segmentIndex).m4a")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw SegmentWriterError.assetWriterCreationFailed(underlying: error)
        }

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]

        // Track 0 — mic
        let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        mInput.expectsMediaDataInRealTime = true

        // Track 1 — system audio (2-track output per AC-5)
        let sInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        sInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(mInput), writer.canAdd(sInput) else {
            throw SegmentWriterError.assetWriterInputCreationFailed
        }
        writer.add(mInput)
        writer.add(sInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        micInput = mInput
        systemInput = sInput
        segmentSampleCount = 0
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer, to input: AVAssetWriterInput?, sampleOffset: Int64) {
        guard let input = input, input.isReadyForMoreMediaData else { return }
        guard let sampleBuffer = buffer.toCMSampleBuffer(sampleOffset: sampleOffset, sampleRate: sampleRate) else { return }
        input.append(sampleBuffer)
    }

    private func rollSegment() async throws {
        try await finalizeCurrentSegment()
        segmentIndex += 1
    }

    private func finalizeCurrentSegment() async throws {
        guard let writer = assetWriter else { return }

        let url = segmentsDir.appendingPathComponent("\(segmentIndex).m4a")

        micInput?.markAsFinished()
        systemInput?.markAsFinished()

        await writer.finishWriting()

        assetWriter = nil
        micInput = nil
        systemInput = nil

        if writer.status == .completed {
            segmentPaths.append(url)
        }
    }
}

// MARK: - AVAudioPCMBuffer → CMSampleBuffer conversion

extension AVAudioPCMBuffer {

    /// Convert a mono Float32 PCM buffer to a `CMSampleBuffer` suitable for AVAssetWriterInput.
    ///
    /// Uses `CMBlockBufferCreateWithMemoryBlock` to wrap the PCM data directly,
    /// avoiding a copy when possible.
    func toCMSampleBuffer(sampleOffset: Int64, sampleRate: Double) -> CMSampleBuffer? {
        guard let channelData = self.floatChannelData else { return nil }
        let frameCount = Int(self.frameLength)
        guard frameCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDescription = formatDesc else { return nil }

        let dataSize = frameCount * 4  // 4 bytes per Float32 frame
        var blockBuffer: CMBlockBuffer?

        // Allocate block buffer memory
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }

        // Copy PCM data into the block buffer
        let copyStatus = channelData[0].withMemoryRebound(to: UInt8.self, capacity: dataSize) { srcPtr in
            CMBlockBufferReplaceDataBytes(
                with: srcPtr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard copyStatus == noErr else { return nil }

        let pts = CMTime(value: sampleOffset, timescale: CMTimeScale(sampleRate))

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
