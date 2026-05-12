import Foundation
import Observation
import os
import TranscriptionKit

private let adapterLog = Logger(subsystem: "dev.kosmonotes.studio", category: "HoldToTalkAdapter")

/// App-side bridge around `LiveTranscriptEngine` for hold-to-talk flows.
/// The current dictation-style paths still capture via `DictationPipeline`,
/// but this adapter defines the final-sink seam those paths can share once
/// live audio attach/ingest hooks exist.
@available(macOS 14.0, *)
@MainActor
@Observable
final class HoldToTalkLiveAdapter {
    typealias Sink = @MainActor @Sendable (String) async -> Void
    typealias ConfigSource = @MainActor @Sendable () -> TranscriptionConfig
    typealias NowSource = @MainActor @Sendable () -> TimeInterval

    struct Engine: Sendable {
        let finish: @Sendable (TimeInterval, TranscriptionConfig) async throws -> Void
        let snapshot: @Sendable () async -> LiveTranscriptState
    }

    var stableText: String = ""
    var mutableText: String = ""
    var health: LiveTranscriptHealth = .healthy

    /// Set to `true` when `stopAndFlush()` called `sink` with a non-empty
    /// transcript. Callers MUST check this after `stopAndFlush()` returns
    /// to distinguish "produced text" from "silent failure".
    var didFlush: Bool = false

    /// Last error from `finish()`, preserved after `stopAndFlush()` so
    /// callers can surface it in UI alerts. `nil` if the flush succeeded.
    var lastFlushError: Error?

    private let engine: Engine
    private let configSource: ConfigSource
    private let nowSource: NowSource
    private let sink: Sink

    init(
        engine: Engine,
        configSource: @escaping ConfigSource,
        nowSource: @escaping NowSource = { ProcessInfo.processInfo.systemUptime },
        sink: @escaping Sink
    ) {
        self.engine = engine
        self.configSource = configSource
        self.nowSource = nowSource
        self.sink = sink
    }

    convenience init(
        engine: LiveTranscriptEngine,
        configSource: @escaping ConfigSource,
        nowSource: @escaping NowSource = { ProcessInfo.processInfo.systemUptime },
        sink: @escaping Sink
    ) {
        self.init(
            engine: Engine(
                finish: { now, config in
                    try await engine.finish(now: now, config: config)
                },
                snapshot: {
                    await engine.snapshot()
                }
            ),
            configSource: configSource,
            nowSource: nowSource,
            sink: sink
        )
    }

    func refresh() async {
        apply(snapshot: await engine.snapshot())
    }

    func stopAndFlush() async {
        didFlush = false
        lastFlushError = nil

        var flushError: Error?
        do {
            try await engine.finish(nowSource(), configSource())
        } catch {
            flushError = error
            adapterLog.error("HoldToTalkAdapter.stopAndFlush: engine.finish threw — \(error.localizedDescription, privacy: .public)")
            lastFlushError = error
        }

        let snapshot = await engine.snapshot()
        apply(snapshot: snapshot, overridingError: flushError)

        let finalText = Self.finalText(for: snapshot)
        guard !finalText.isEmpty else {
            if let err = flushError {
                adapterLog.error("HoldToTalkAdapter.stopAndFlush: no transcript produced — error: \(err.localizedDescription, privacy: .public)")
            } else if case .failed(let reason) = snapshot.status {
                adapterLog.error("HoldToTalkAdapter.stopAndFlush: no transcript produced — engine state: failed(\(reason, privacy: .public))")
            } else {
                adapterLog.warning("HoldToTalkAdapter.stopAndFlush: no transcript produced — audio may be empty or too short")
            }
            return
        }
        adapterLog.info("HoldToTalkAdapter.stopAndFlush: flushing \(finalText.count) chars to sink")
        await sink(finalText)
        didFlush = true
    }

    private func apply(snapshot: LiveTranscriptState, overridingError: Error? = nil) {
        stableText = snapshot.stableText
        mutableText = snapshot.mutableText
        health = snapshot.status

        if let overridingError, snapshot.status == .healthy {
            health = .failed(lastError: overridingError.localizedDescription)
        }
    }

    private static func finalText(for snapshot: LiveTranscriptState) -> String {
        [snapshot.stableText, snapshot.mutableText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
