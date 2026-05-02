import Foundation
import StorageKit

// MARK: - TranscriptStore

/// Persists `TranscriptSegment`s to a session's on-disk sidecars.
///
/// File layout:
///   - `<sessionDir>/transcript.jsonl` — one JSON object per line, only final
///     segments. Append-only during the session.
///   - `<sessionDir>/transcript.txt` — the human-readable plain-text view.
///     Rewritten atomically on every flush from accumulated final segments.
///
/// The store is an actor — concurrent appends from the receive task and
/// `flushTxt` calls from the UI never race.
public actor TranscriptStore {

    // MARK: Stored

    private let sessionDir: URL
    private let jsonlURL: URL
    private let txtURL: URL
    private var jsonlHandle: FileHandle?
    private var allFinals: [TranscriptSegment] = []

    // MARK: Init

    public init(sessionDir: URL) throws {
        self.sessionDir = sessionDir
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        self.jsonlURL = sessionDir.appendingPathComponent("transcript.jsonl")
        self.txtURL = sessionDir.appendingPathComponent("transcript.txt")
    }

    // MARK: Public API

    /// Append one segment. Interim (non-final) segments are dropped — they're
    /// not durable; final segments will replace them.
    public func append(_ segment: TranscriptSegment) throws {
        guard segment.isFinal else { return }
        try writeJSONL(segment)
        allFinals.append(segment)
    }

    /// Atomically rewrite `transcript.txt` from accumulated final segments.
    /// Safe to call repeatedly — last write wins.
    public func flushTxt() throws {
        let combined = allFinals
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let data = Data(combined.utf8)
        try AtomicWriter.write(data, to: txtURL)
    }

    /// Close the JSONL handle and flush the text file. Safe to call multiple
    /// times — subsequent calls are no-ops after the first.
    public func close() throws {
        try jsonlHandle?.synchronize()
        try jsonlHandle?.close()
        jsonlHandle = nil
        try flushTxt()
    }

    /// Snapshot of all final segments persisted so far. Useful for tests
    /// and for re-driving the AI summary stage from a finished session.
    public func segments() -> [TranscriptSegment] {
        allFinals
    }

    // MARK: Private

    private func writeJSONL(_ segment: TranscriptSegment) throws {
        let handle = try jsonlHandleEnsured()
        var data = try JSONEncoder().encode(segment)
        data.append(0x0A)  // newline — JSONL is one object per line
        try handle.write(contentsOf: data)
        // We do NOT fsync per-segment — that would tank throughput on long
        // recordings. The handle is fsync'd in `close()`. On a hard crash,
        // the trailing few segments may be lost; the audio segments still
        // hold the source-of-truth audio for re-transcription.
    }

    private func jsonlHandleEnsured() throws -> FileHandle {
        if let handle = jsonlHandle { return handle }
        if !FileManager.default.fileExists(atPath: jsonlURL.path) {
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: jsonlURL)
        try handle.seekToEnd()
        jsonlHandle = handle
        return handle
    }
}
