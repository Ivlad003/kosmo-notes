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
}

public struct LiveTranscriptState: Sendable, Equatable {
    public var stableUnits: [LiveTranscriptUnit]
    public var draftUnits: [LiveTranscriptUnit]
    public var status: LiveTranscriptHealth

    public static let empty = LiveTranscriptState(stableUnits: [], draftUnits: [], status: .healthy)

    public var stableText: String { stableUnits.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
    public var mutableText: String { draftUnits.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
}

extension LiveTranscriptState {
    public func merging(_ result: LiveTranscriptWindowResult, mutableHorizon: TimeInterval) -> LiveTranscriptState {
        let lockBefore = max(0, result.emittedAt - mutableHorizon)
        // splitAt chooses the earliest boundary we should consider stable. When a new window
        // arrives its windowStart may indicate content earlier can be locked; take the
        // minimum with lockBefore to avoid re-writing locked content.
        let splitAt = min(lockBefore, result.windowStart)

        var promoted: [LiveTranscriptUnit] = []
        var keptDraft: [LiveTranscriptUnit] = []

        for unit in draftUnits {
            if unit.end <= splitAt {
                promoted.append(LiveTranscriptUnit(start: unit.start, end: unit.end, text: unit.text, state: .stable))
            } else if unit.start >= splitAt {
                keptDraft.append(unit)
            } else {
                // unit spans the split boundary — split by words proportionally to duration.
                let duration = unit.end - unit.start
                let prefixDuration = splitAt - unit.start
                let words = unit.text.split(separator: " ").map(String.init)
                let prefixCount = max(1, Int(round(Double(words.count) * (prefixDuration / max(0.000001, duration)))))
                let prefixText = words.prefix(prefixCount).joined(separator: " ")
                let suffixText = words.dropFirst(prefixCount).joined(separator: " ")

                promoted.append(LiveTranscriptUnit(start: unit.start, end: splitAt, text: prefixText, state: .stable))
                if !suffixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    keptDraft.append(LiveTranscriptUnit(start: splitAt, end: unit.end, text: suffixText, state: .draft))
                }
            }
        }

        // Remove any kept drafts that overlap the incoming window; the new draft
        // supersedes overlapping content to avoid duplication.
        keptDraft = keptDraft.filter { $0.end <= result.windowStart || $0.start >= result.windowEnd }

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
