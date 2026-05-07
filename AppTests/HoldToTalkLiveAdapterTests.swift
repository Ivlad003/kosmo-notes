import Foundation
import Testing
import TranscriptionKit
@testable import KosmoNotes

@available(macOS 14.0, *)
private actor SinkBox {
    private(set) var received: [String] = []

    func append(_ text: String) {
        received.append(text)
    }
}

@available(macOS 14.0, *)
private actor EngineBox {
    private(set) var finishCalls: [(TimeInterval, TranscriptionConfig)] = []
    private let state: LiveTranscriptState

    init(state: LiveTranscriptState) {
        self.state = state
    }

    func finish(now: TimeInterval, config: TranscriptionConfig) async throws {
        finishCalls.append((now, config))
    }

    func snapshot() async -> LiveTranscriptState {
        state
    }
}

@available(macOS 14.0, *)
@MainActor
@Test func holdToTalkLiveAdapter_flushesFinalTranscriptToSink() async {
    let engine = EngineBox(
        state: LiveTranscriptState(
            stableUnits: [.init(start: 0, end: 2, text: "ship", state: .stable)],
            draftUnits: [.init(start: 2, end: 4, text: "it", state: .draft)],
            status: .healthy
        )
    )
    let sink = SinkBox()
    let adapter = HoldToTalkLiveAdapter(
        engine: .init(
            finish: { now, config in
                try await engine.finish(now: now, config: config)
            },
            snapshot: {
                await engine.snapshot()
            }
        ),
        configSource: { TranscriptionConfig(language: "en", sampleRate: 16_000) },
        nowSource: { 42 },
        sink: { text in
            await sink.append(text)
        }
    )

    await adapter.stopAndFlush()

    let calls = await engine.finishCalls
    #expect(calls.count == 1)
    #expect(calls.first?.0 == 42)
    #expect(calls.first?.1.language == "en")
    #expect(calls.first?.1.sampleRate == 16_000)
    #expect(adapter.stableText == "ship")
    #expect(adapter.mutableText == "it")
    #expect(adapter.health == .healthy)
    #expect(await sink.received == ["ship it"])
}
