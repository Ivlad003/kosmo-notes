@preconcurrency import AVFoundation

// MARK: - AACEncoder
//
// DEVIATION from plan: The plan originally specified Opus encoding. Opus via
// AVAudioConverter requires macOS 14+. Since the deployment target is macOS 12.3+,
// this implementation uses AAC (kAudioFormatMPEG4AAC) instead.
//
// AAC is natively supported on all macOS versions, plays in QuickTime and Safari
// natively, and requires zero additional dependencies. At 96 kbps mono AAC the
// file size is approximately 2× larger than equivalent Opus, which is acceptable
// for v1.0. Segment files are named .m4a (MPEG-4 container).
//
// If Opus is required in a future version, upgrade the deployment target to
// macOS 14+ and switch AVAudioFormat settings to kAudioFormatOpus.

/// Encodes mono Float32 PCM buffers to AAC using AVAudioConverter.
/// Output is raw AAC frames suitable for writing into an .m4a container via AVAssetWriter.
///
/// `AACEncoder` is `Sendable` and can be used across concurrency domains.
/// Each `encode(_:)` call is synchronous — run on a background actor if needed.
public final class AACEncoder: Sendable {

    // MARK: Private state (all immutable after init — Sendable safe)

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat

    // MARK: Init

    /// - Parameters:
    ///   - sampleRate: Input PCM sample rate (must match buffers passed to `encode`).
    ///   - bitrate: AAC bitrate in bits/sec. Default 96_000 (96 kbps mono).
    public init(sampleRate: Double = 48_000, bitrate: Int = 96_000) throws {
        guard let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AACEncoderError.inputFormatCreationFailed
        }

        // AAC output format settings
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]

        guard let outputFmt = AVAudioFormat(settings: outputSettings) else {
            throw AACEncoderError.outputFormatCreationFailed
        }

        guard let conv = AVAudioConverter(from: inputFmt, to: outputFmt) else {
            throw AACEncoderError.converterCreationFailed
        }

        self.inputFormat = inputFmt
        self.outputFormat = outputFmt
        self.converter = conv
    }

    // MARK: Public API

    /// The AAC output `AVAudioFormat` — pass this to AVAssetWriterInput.
    public var aacFormat: AVAudioFormat { outputFormat }

    /// The PCM input `AVAudioFormat` — buffers passed to `encode` must match this.
    public var pcmFormat: AVAudioFormat { inputFormat }

    /// Encode a PCM buffer to raw AAC frame data.
    /// Returns `nil` if the encoder has no output yet (may happen on the first few frames).
    public func encode(_ pcm: AVAudioPCMBuffer) throws -> Data? {
        let outputBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 8,
            maximumPacketSize: converter.maximumOutputPacketSize
        )

        var conversionError: NSError?
        // Use a class-box to avoid captured-var concurrency warning on Bool
        final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
        let inputConsumed = Box(false)
        let inputBuf = pcm

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed.value = true
            outStatus.pointee = .haveData
            return inputBuf
        }

        if let err = conversionError {
            throw AACEncoderError.conversionFailed(underlying: err)
        }

        guard status != .error else {
            throw AACEncoderError.conversionFailed(underlying: NSError(
                domain: "AACEncoder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter returned error status"]
            ))
        }

        guard outputBuffer.byteLength > 0 else {
            return nil
        }

        return Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
    }

    /// Flush any remaining buffered audio from the encoder.
    /// Call once after all PCM buffers have been encoded.
    public func finalize() -> Data? {
        let outputBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 8,
            maximumPacketSize: converter.maximumOutputPacketSize
        )

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }

        guard status != .error, outputBuffer.byteLength > 0 else {
            return nil
        }

        return Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
    }

    // MARK: Output format access (for AVAssetWriter wiring)

    /// Returns the stream basic description for use with AVAssetWriter wiring.
    public var outputAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
    }
}

// MARK: - Errors

public enum AACEncoderError: Error, Sendable {
    case inputFormatCreationFailed
    case outputFormatCreationFailed
    case converterCreationFailed
    case outputBufferCreationFailed
    case conversionFailed(underlying: Error)
}
