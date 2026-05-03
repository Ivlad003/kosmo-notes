@preconcurrency import AVFoundation
import Foundation

// MARK: - SampleClock

/// Single-writer monotonic sample-time counter used by `AudioStreamingBridge`
/// (and any future audio source that needs to mint `AVAudioTime` values for a
/// raw-PCM publish path).
///
/// Why this exists: HaishinKit's `IOStream.append(_:when:)` overload needs an
/// `AVAudioTime` per buffer — a count of samples since the start of the stream
/// at a given sample rate. Capture pipelines that produce `AVAudioPCMBuffer`s
/// without timestamps (mic via AVAudioEngine, system audio via SCKit) need
/// SOMETHING to mint timestamps from. A monotonic frame counter anchored at 0
/// per stream is the simplest correct answer — every chunk gets a timestamp at
/// the *start* of the chunk, exactly like FFmpeg's PTS convention.
///
/// Lock note: this class is `@unchecked Sendable` and uses `NSLock` so the tee
/// callback can advance it from a non-isolated drain task. The lock is held
/// for nanoseconds — well within real-time budgets.
public final class SampleClock: @unchecked Sendable {

    private let lock = NSLock()
    private var sampleTime: Int64 = 0

    public init() {}

    /// Reset to 0. Called at the start of every new RTMP publish so each
    /// stream gets its own zero-based timeline.
    public func reset() {
        lock.lock(); sampleTime = 0; lock.unlock()
    }

    /// Advance by `frames` and return an `AVAudioTime` stamped at the *start*
    /// of the chunk (sample time BEFORE advancing). HaishinKit / FFmpeg both
    /// treat the timestamp as the chunk's leading edge, so a 1024-frame chunk
    /// at sampleTime=4096 reports as `[4096, 5120)` to the muxer.
    public func advance(by frames: Int, sampleRate: Double) -> AVAudioTime {
        lock.lock()
        let start = sampleTime
        sampleTime += Int64(frames)
        lock.unlock()
        return AVAudioTime(sampleTime: start, atRate: sampleRate)
    }

    /// Current sample-time without advancing. Diagnostic / test helper —
    /// production callers should always go through `advance(by:sampleRate:)`
    /// to keep the counter monotonic.
    public var currentSampleTime: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sampleTime
    }
}
