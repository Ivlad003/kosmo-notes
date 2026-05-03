@preconcurrency import AVFoundation
import Testing
@testable import StreamingKit

@Suite("SampleClock")
struct SampleClockTests {

    @Test("Newly-constructed clock starts at sample-time 0")
    func startsAtZero() {
        let clock = SampleClock()
        #expect(clock.currentSampleTime == 0)
    }

    @Test("advance returns AVAudioTime stamped at the start of the chunk")
    func advanceStampsAtChunkStart() {
        let clock = SampleClock()
        let when = clock.advance(by: 1024, sampleRate: 48_000)
        #expect(when.sampleTime == 0, "first advance reports start-of-chunk = 0")
        #expect(when.sampleRate == 48_000)
    }

    @Test("Successive advances accumulate the sample-time counter")
    func advancesAccumulate() {
        let clock = SampleClock()
        _ = clock.advance(by: 1024, sampleRate: 48_000)
        let second = clock.advance(by: 2048, sampleRate: 48_000)
        let third  = clock.advance(by: 512,  sampleRate: 48_000)
        #expect(second.sampleTime == 1024, "second chunk starts at end of first")
        #expect(third.sampleTime  == 1024 + 2048, "third chunk starts at end of second")
        #expect(clock.currentSampleTime == 1024 + 2048 + 512)
    }

    @Test("reset returns the counter to 0 mid-stream")
    func resetClearsCounter() {
        let clock = SampleClock()
        _ = clock.advance(by: 9_999, sampleRate: 48_000)
        clock.reset()
        #expect(clock.currentSampleTime == 0)
        let next = clock.advance(by: 100, sampleRate: 48_000)
        #expect(next.sampleTime == 0, "first advance after reset starts at 0 again")
    }

    @Test("AVAudioTime preserves whatever sample rate the caller supplies")
    func sampleRatePassedThrough() {
        let clock = SampleClock()
        let at48k = clock.advance(by: 480, sampleRate: 48_000)
        clock.reset()
        let at44k = clock.advance(by: 441, sampleRate: 44_100)
        clock.reset()
        let at16k = clock.advance(by: 160, sampleRate: 16_000)
        #expect(at48k.sampleRate == 48_000)
        #expect(at44k.sampleRate == 44_100)
        #expect(at16k.sampleRate == 16_000)
    }

    @Test("currentSampleTime is read-only — does not advance the counter")
    func snapshotDoesNotAdvance() {
        let clock = SampleClock()
        _ = clock.advance(by: 256, sampleRate: 48_000)
        let a = clock.currentSampleTime
        let b = clock.currentSampleTime
        let c = clock.currentSampleTime
        #expect(a == 256)
        #expect(b == 256)
        #expect(c == 256)
    }
}
