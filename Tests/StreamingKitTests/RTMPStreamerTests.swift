@preconcurrency import AVFoundation
import Testing
@testable import StreamingKit

// MARK: - Config validation

@Suite("RTMPConfig.validate")
struct RTMPConfigValidateTests {

    @Test("Accepts a well-formed rtmp:// URL with non-empty stream key")
    func acceptsValidConfig() throws {
        let cfg = RTMPConfig(rtmpURL: "rtmp://a.rtmp.example.com/live", streamKey: "abc-123")
        #expect(throws: Never.self) {
            try cfg.validate()
        }
    }

    @Test("Accepts rtmps:// (TLS) too")
    func acceptsRtmps() throws {
        let cfg = RTMPConfig(rtmpURL: "rtmps://secure.example.com/app", streamKey: "k")
        #expect(throws: Never.self) {
            try cfg.validate()
        }
    }

    @Test("Rejects missing scheme")
    func rejectsBareHost() {
        let cfg = RTMPConfig(rtmpURL: "a.example.com/live", streamKey: "k")
        #expect(throws: StreamingError.invalidURL) {
            try cfg.validate()
        }
    }

    @Test("Rejects http:// scheme")
    func rejectsHTTPScheme() {
        let cfg = RTMPConfig(rtmpURL: "http://example.com/live", streamKey: "k")
        #expect(throws: StreamingError.invalidURL) {
            try cfg.validate()
        }
    }

    @Test("Rejects empty stream key")
    func rejectsEmptyKey() {
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "")
        #expect(throws: StreamingError.missingStreamKey) {
            try cfg.validate()
        }
    }

    @Test("Rejects whitespace-only stream key")
    func rejectsWhitespaceKey() {
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "   \n")
        #expect(throws: StreamingError.missingStreamKey) {
            try cfg.validate()
        }
    }
}

// MARK: - State machine (mock transport)

@Suite("RTMPStreamer state machine")
struct RTMPStreamerStateTests {

    private static let validConfig = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "k")

    @Test("Initial state is .idle")
    func initialIdle() async {
        let streamer = RTMPStreamer(transport: MockRTMPTransport())
        let state = await streamer.state
        #expect(state == .idle)
    }

    @Test("start with valid config + succeeding transport ends in .publishing")
    func startTransitionsToPublishing() async throws {
        let mock = MockRTMPTransport(mode: .succeed)
        let streamer = RTMPStreamer(transport: mock)
        try await streamer.start(config: Self.validConfig)
        let state = await streamer.state
        #expect(state == .publishing)
        #expect(mock.calls.connectURL == Self.validConfig.rtmpURL)
        #expect(mock.calls.connectStreamKey == Self.validConfig.streamKey)
        #expect(mock.calls.connectCount == 1)
    }

    @Test("start with invalid URL throws .invalidURL and never reaches transport")
    func startInvalidURLLeavesIdle() async {
        let mock = MockRTMPTransport()
        let streamer = RTMPStreamer(transport: mock)
        let cfg = RTMPConfig(rtmpURL: "not-a-url", streamKey: "k")
        await #expect(throws: StreamingError.invalidURL) {
            try await streamer.start(config: cfg)
        }
        let state = await streamer.state
        #expect(state == .idle)
        #expect(mock.calls.connectCount == 0)
    }

    @Test("start when transport throws transitions to .failed and re-throws")
    func startTransportFailureSurfaces() async {
        let mock = MockRTMPTransport(mode: .fail(.connectionFailed(message: "ECONNREFUSED")))
        let streamer = RTMPStreamer(transport: mock)
        await #expect(throws: StreamingError.self) {
            try await streamer.start(config: Self.validConfig)
        }
        let state = await streamer.state
        if case .failed(let message) = state {
            #expect(message.contains("ECONNREFUSED"))
        } else {
            Issue.record("expected .failed state, got \(state)")
        }
    }

    @Test("start while .publishing throws .alreadyPublishing")
    func doubleStartThrows() async throws {
        let streamer = RTMPStreamer(transport: MockRTMPTransport())
        try await streamer.start(config: Self.validConfig)
        await #expect(throws: StreamingError.alreadyPublishing) {
            try await streamer.start(config: Self.validConfig)
        }
    }

    @Test("stop from .publishing returns to .idle and calls transport.close once")
    func stopReturnsToIdle() async throws {
        let mock = MockRTMPTransport()
        let streamer = RTMPStreamer(transport: mock)
        try await streamer.start(config: Self.validConfig)
        await streamer.stop()
        let state = await streamer.state
        #expect(state == .idle)
        #expect(mock.calls.closeCount == 1)
    }

    @Test("stop from .idle is a no-op (no transport.close call)")
    func stopFromIdleNoop() async {
        let mock = MockRTMPTransport()
        let streamer = RTMPStreamer(transport: mock)
        await streamer.stop()
        let state = await streamer.state
        #expect(state == .idle)
        #expect(mock.calls.closeCount == 0)
    }

    @Test("stop from .failed is a no-op")
    func stopFromFailedNoop() async {
        let mock = MockRTMPTransport(mode: .fail(.connectionFailed(message: "x")))
        let streamer = RTMPStreamer(transport: mock)
        try? await streamer.start(config: Self.validConfig)
        await streamer.stop()
        #expect(mock.calls.closeCount == 0)
    }

    @Test("appendAudio while .publishing forwards to transport")
    func appendAudioForwarded() async throws {
        let mock = MockRTMPTransport()
        let streamer = RTMPStreamer(transport: mock)
        try await streamer.start(config: Self.validConfig)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        let when = AVAudioTime(sampleTime: 0, atRate: 48_000)

        await streamer.appendAudio(buffer, when: when)
        await streamer.appendAudio(buffer, when: when)
        #expect(mock.calls.audioCount == 2)
    }

    @Test("appendAudio while .idle is dropped (no transport call)")
    func appendAudioDroppedWhenIdle() async {
        let mock = MockRTMPTransport()
        let streamer = RTMPStreamer(transport: mock)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        let when = AVAudioTime(sampleTime: 0, atRate: 48_000)

        await streamer.appendAudio(buffer, when: when)
        #expect(mock.calls.audioCount == 0)
    }

    @Test("state stream emits idle → connecting → publishing on start")
    func stateStreamEmitsTransitions() async throws {
        let streamer = RTMPStreamer(transport: MockRTMPTransport())

        // Subscribe BEFORE start so we don't miss the .connecting frame.
        let states = await streamer.states
        let collector = Task<[RTMPStreamer.State], Never> {
            var collected: [RTMPStreamer.State] = []
            for await s in states {
                collected.append(s)
                if collected.count == 2 { break }
            }
            return collected
        }

        try await streamer.start(config: Self.validConfig)
        let observed = await collector.value
        #expect(observed == [.connecting, .publishing])
    }
}
