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

// MARK: - Streamer state machine

@Suite("RTMPStreamer state machine")
struct RTMPStreamerStateTests {

    @Test("Initial state is .idle")
    func initialIdle() async {
        let streamer = RTMPStreamer()
        let state = await streamer.state
        #expect(state == .idle)
    }

    @Test("start with valid config transitions through .connecting to .publishing")
    func startTransitionsToPublishing() async throws {
        let streamer = RTMPStreamer()
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "k")
        try await streamer.start(config: cfg)
        let state = await streamer.state
        #expect(state == .publishing)
    }

    @Test("start with invalid URL throws and leaves state at .idle")
    func startInvalidURLLeavesIdle() async {
        let streamer = RTMPStreamer()
        let cfg = RTMPConfig(rtmpURL: "not-a-url", streamKey: "k")
        await #expect(throws: StreamingError.invalidURL) {
            try await streamer.start(config: cfg)
        }
        let state = await streamer.state
        #expect(state == .idle)
    }

    @Test("start while .publishing throws .alreadyPublishing")
    func doubleStartThrows() async throws {
        let streamer = RTMPStreamer()
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "k")
        try await streamer.start(config: cfg)
        await #expect(throws: StreamingError.alreadyPublishing) {
            try await streamer.start(config: cfg)
        }
    }

    @Test("stop from .publishing returns to .idle")
    func stopReturnsToIdle() async throws {
        let streamer = RTMPStreamer()
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "k")
        try await streamer.start(config: cfg)
        await streamer.stop()
        let state = await streamer.state
        #expect(state == .idle)
    }

    @Test("stop from .idle is a no-op (no throw, stays .idle)")
    func stopFromIdleNoop() async {
        let streamer = RTMPStreamer()
        await streamer.stop()
        let state = await streamer.state
        #expect(state == .idle)
    }

    @Test("state stream emits idle → connecting → publishing on start")
    func stateStreamEmitsTransitions() async throws {
        let streamer = RTMPStreamer()
        let cfg = RTMPConfig(rtmpURL: "rtmp://example.com/live", streamKey: "k")

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

        try await streamer.start(config: cfg)
        let observed = await collector.value
        #expect(observed == [.connecting, .publishing])
    }
}
