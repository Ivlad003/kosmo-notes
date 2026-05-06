import Foundation

public enum LiveTranscriptUnitState: Sendable, Equatable {
    case draft
    case stable
}

public struct LiveTranscriptUnit: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let state: LiveTranscriptUnitState

    public init(start: TimeInterval, end: TimeInterval, text: String, state: LiveTranscriptUnitState) {
        self.start = start
        self.end = end
        self.text = text
        self.state = state
    }
}

public enum LiveTranscriptHealth: Sendable, Equatable {
    case healthy
    case delayed
    case failed(lastError: String)
}

public struct LiveTranscriptWindowResult: Sendable, Equatable {
    public let windowStart: TimeInterval
    public let windowEnd: TimeInterval
    public let text: String
    public let emittedAt: TimeInterval

    public init(windowStart: TimeInterval, windowEnd: TimeInterval, text: String, emittedAt: TimeInterval) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.text = text
        self.emittedAt = emittedAt
    }
}

public struct LiveTranscriptState: Sendable, Equatable {
    public var stableUnits: [LiveTranscriptUnit]
    public var draftUnits: [LiveTranscriptUnit]
    public var status: LiveTranscriptHealth

    public init(stableUnits: [LiveTranscriptUnit], draftUnits: [LiveTranscriptUnit], status: LiveTranscriptHealth) {
        self.stableUnits = stableUnits
        self.draftUnits = draftUnits
        self.status = status
    }

    public static let empty = LiveTranscriptState(stableUnits: [], draftUnits: [], status: .healthy)

    public var stableText: String { stableUnits.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var mutableText: String { draftUnits.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension LiveTranscriptState {
    public func merging(_ result: LiveTranscriptWindowResult, mutableHorizon: TimeInterval) -> LiveTranscriptState {
        let lockBefore = max(0, result.emittedAt - mutableHorizon)

        let promoted = draftUnits
            .filter { $0.end <= lockBefore }
            .map { LiveTranscriptUnit(start: $0.start, end: $0.end, text: $0.text, state: .stable) }

        let keptDraft = draftUnits.filter { $0.end > lockBefore && $0.end <= result.windowStart }
        let newDraft = LiveTranscriptUnit(
            start: result.windowStart,
            end: result.windowEnd,
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .draft
        )

        return LiveTranscriptState(
            stableUnits: stableUnits + promoted,
            draftUnits: keptDraft + (newDraft.text.isEmpty ? [] : [newDraft]),
            status: status
        )
    }
}
