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

        func splitText(_ text: String, fraction: Double) -> (String, String)? {
            let words = text
                .split { $0.isWhitespace || $0.isNewline }
                .map(String.init)

            if words.count > 1 {
                let rawLeftCount = Int(floor(Double(words.count) * fraction))
                let leftCount = min(words.count - 1, max(1, rawLeftCount))
                if leftCount > 0 && leftCount < words.count {
                    return (
                        words[0..<leftCount].joined(separator: " "),
                        words[leftCount..<words.count].joined(separator: " ")
                    )
                }
            }

            let graphemes = Array(text)
            guard graphemes.count > 1 else { return nil }

            let rawLeftCount = Int(floor(Double(graphemes.count) * fraction))
            let leftCount = min(graphemes.count - 1, max(1, rawLeftCount))
            guard leftCount > 0 && leftCount < graphemes.count else { return nil }

            return (
                String(graphemes[0..<leftCount]),
                String(graphemes[leftCount..<graphemes.count])
            )
        }

        // Helper: split a unit at a time t (t between start and end).
        // Prefer word boundaries, then fall back to graphemes so locked time can still promote.
        func splitUnitAt(_ unit: LiveTranscriptUnit, _ t: TimeInterval) -> (LiveTranscriptUnit?, LiveTranscriptUnit?) {
            guard t > unit.start && t < unit.end else { return (unit, nil) }
            let duration = unit.end - unit.start
            guard duration > 0 else { return (unit, nil) }

            let frac = (t - unit.start) / duration
            guard let (leftText, rightText) = splitText(unit.text, fraction: frac) else {
                return (unit, nil)
            }

            let left = LiveTranscriptUnit(start: unit.start, end: t, text: leftText.trimmingCharacters(in: .whitespacesAndNewlines), state: unit.state)
            let right = LiveTranscriptUnit(start: t, end: unit.end, text: rightText.trimmingCharacters(in: .whitespacesAndNewlines), state: unit.state)
            return (left, right)
        }

        // Decide promotion cut: we only promote prefixes that are both older than the mutable horizon
        // and that occur before the incoming result window. This avoids rewriting stable text that lies
        // before the new windowStart while still promoting parts that are effectively locked.
        let promotionCut = min(lockBefore, result.windowStart)

        // Start from existing drafts, but split them at both promotionCut and result.windowStart
        var segments: [LiveTranscriptUnit] = []
        for unit in draftUnits {
            var work: [LiveTranscriptUnit] = [unit]

            // split at promotionCut if inside
            if promotionCut > unit.start && promotionCut < unit.end {
                work = work.flatMap { u -> [LiveTranscriptUnit] in
                    let (left, right) = splitUnitAt(u, promotionCut)
                    return [left, right].compactMap { $0 }
                }
            }

            // split at result.windowStart if inside
            if result.windowStart > unit.start && result.windowStart < unit.end {
                work = work.flatMap { u -> [LiveTranscriptUnit] in
                    let (left, right) = splitUnitAt(u, result.windowStart)
                    return [left, right].compactMap { $0 }
                }
            }

            segments.append(contentsOf: work)
        }

        var promoted: [LiveTranscriptUnit] = []
        var keptDraft: [LiveTranscriptUnit] = []

        for seg in segments {
            if seg.end <= promotionCut {
                promoted.append(LiveTranscriptUnit(start: seg.start, end: seg.end, text: seg.text, state: .stable))
            } else if seg.start >= result.windowStart {
                // This segment falls inside/after the new result window start and will be replaced by the new result.
                continue
            } else {
                // Mutable draft portion that precedes the incoming result windowStart
                keptDraft.append(LiveTranscriptUnit(start: seg.start, end: seg.end, text: seg.text, state: .draft))
            }
        }

        let newDraftText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDraft = LiveTranscriptUnit(
            start: result.windowStart,
            end: result.windowEnd,
            text: newDraftText,
            state: .draft
        )

        return LiveTranscriptState(
            stableUnits: stableUnits + promoted,
            draftUnits: keptDraft + (newDraft.text.isEmpty ? [] : [newDraft]),
            status: status
        )
    }
}
