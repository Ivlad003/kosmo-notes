import Testing
@testable import TranscriptionKit

@Test func merge_rewrites_only_mutable_tail() {
    var state = LiveTranscriptState.empty
    state = state.merging(
        LiveTranscriptWindowResult(
            windowStart: 0,
            windowEnd: 15,
            text: "hello brave new",
            emittedAt: 15
        ),
        mutableHorizon: 10
    )
    state = state.merging(
        LiveTranscriptWindowResult(
            windowStart: 5,
            windowEnd: 20,
            text: "brave new world",
            emittedAt: 20
        ),
        mutableHorizon: 10
    )

    #expect(state.stableText == "hello")
    #expect(state.mutableText == "brave new world")
}

@Test func merge_never_rewrites_stable_prefix() {
    let state = LiveTranscriptState(
        stableUnits: [.init(start: 0, end: 10, text: "locked", state: .stable)],
        draftUnits: [.init(start: 10, end: 20, text: "draft", state: .draft)],
        status: .healthy
    )

    let merged = state.merging(
        LiveTranscriptWindowResult(
            windowStart: 8,
            windowEnd: 25,
            text: "attempted rewrite",
            emittedAt: 25
        ),
        mutableHorizon: 10
    )

    #expect(merged.stableText == "locked")
}
