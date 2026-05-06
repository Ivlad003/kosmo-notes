import Testing
import TranscriptionKit
@testable import KosmoNotes

@available(macOS 14.0, *)
private actor SnapshotBox {
    let state: LiveTranscriptState

    init(_ state: LiveTranscriptState) {
        self.state = state
    }

    func snapshot() -> LiveTranscriptState {
        state
    }
}

@available(macOS 14.0, *)
@Test func recorderLiveAdapter_mapsHealthySnapshot() async {
    let box = SnapshotBox(
        LiveTranscriptState(
            stableUnits: [.init(start: 0, end: 8, text: "stable words", state: .stable)],
            draftUnits: [.init(start: 8, end: 12, text: "draft tail", state: .draft)],
            status: .healthy
        )
    )
    let adapter = RecorderLiveAdapter(snapshotSource: { await box.snapshot() })

    let display = await adapter.displayState()

    #expect(display.stableText == "stable words")
    #expect(display.mutableText == "draft tail")
    #expect(display.statusText == nil)
    #expect(display.isDelayed == false)
    #expect(display.shouldSurface == true)
}

@available(macOS 14.0, *)
@Test func recorderLiveAdapter_surfacesDelayedHealthWithoutText() async {
    let box = SnapshotBox(
        LiveTranscriptState(
            stableUnits: [],
            draftUnits: [],
            status: .delayed
        )
    )
    let adapter = RecorderLiveAdapter(snapshotSource: { await box.snapshot() })

    let display = await adapter.displayState()

    #expect(display.stableText.isEmpty)
    #expect(display.mutableText.isEmpty)
    #expect(display.statusText == "Live transcript delayed")
    #expect(display.isDelayed == true)
    #expect(display.shouldSurface == true)
}

@available(macOS 14.0, *)
@Test func recorderLiveAdapter_keepsTranscriptWhenEngineFails() async {
    let box = SnapshotBox(
        LiveTranscriptState(
            stableUnits: [.init(start: 0, end: 5, text: "locked", state: .stable)],
            draftUnits: [.init(start: 5, end: 9, text: "tail", state: .draft)],
            status: .failed(lastError: "network timeout")
        )
    )
    let adapter = RecorderLiveAdapter(snapshotSource: { await box.snapshot() })

    let display = await adapter.displayState()

    #expect(display.stableText == "locked")
    #expect(display.mutableText == "tail")
    #expect(display.statusText == "Live transcript unavailable")
    #expect(display.isDelayed == false)
    #expect(display.shouldSurface == true)
}

@available(macOS 14.0, *)
@Test func recorderLiveAdapter_canSurfaceExplicitUnavailableMessage() async {
    let adapter = RecorderLiveAdapter(unavailableMessage: "Live transcript unavailable with Deepgram")

    let display = await adapter.displayState()

    #expect(display.stableText.isEmpty)
    #expect(display.mutableText.isEmpty)
    #expect(display.statusText == "Live transcript unavailable with Deepgram")
    #expect(display.isDelayed == false)
    #expect(display.shouldSurface == true)
}
