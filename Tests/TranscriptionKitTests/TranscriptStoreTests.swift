import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TranscriptStore tests")
struct TranscriptStoreTests {

    private func makeTempSessionDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesTranscriptStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Final segments are written to transcript.jsonl, one per line")
    func finalSegmentsWriteToJSONL() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "hello", confidence: 0.9, isFinal: true))
        try await store.append(TranscriptSegment(start: 1, end: 2, text: "world", confidence: 0.92, isFinal: true))
        try await store.close()

        let jsonl = dir.appendingPathComponent("transcript.jsonl")
        let raw = try String(contentsOf: jsonl, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        let first = try decoder.decode(TranscriptSegment.self, from: Data(lines[0].utf8))
        #expect(first.text == "hello")
        let second = try decoder.decode(TranscriptSegment.self, from: Data(lines[1].utf8))
        #expect(second.text == "world")
    }

    @Test("Interim (non-final) segments are not persisted")
    func interimSegmentsAreDropped() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 0.5, text: "hel", confidence: 0.5, isFinal: false))
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "hello", confidence: 0.9, isFinal: true))
        try await store.close()

        let jsonl = dir.appendingPathComponent("transcript.jsonl")
        let raw = try String(contentsOf: jsonl, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)

        let snapshot = await store.segments()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].text == "hello")
    }

    @Test("flushTxt writes joined finals to transcript.txt")
    func flushTxtWritesJoinedText() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "hello", confidence: 0.9, isFinal: true))
        try await store.append(TranscriptSegment(start: 1, end: 2, text: "world", confidence: 0.9, isFinal: true))
        try await store.flushTxt()

        let txt = dir.appendingPathComponent("transcript.txt")
        let content = try String(contentsOf: txt, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test("close() flushes transcript.txt")
    func closeFlushesTxt() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "alpha", confidence: 0.9, isFinal: true))
        try await store.close()

        let txt = dir.appendingPathComponent("transcript.txt")
        let content = try String(contentsOf: txt, encoding: .utf8)
        #expect(content == "alpha")
    }

    @Test("flushTxt is idempotent — repeated calls produce the same file")
    func flushTxtIsIdempotent() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "one", confidence: 0.9, isFinal: true))
        try await store.flushTxt()
        try await store.flushTxt()
        try await store.flushTxt()

        let txt = dir.appendingPathComponent("transcript.txt")
        let content = try String(contentsOf: txt, encoding: .utf8)
        #expect(content == "one")
    }

    @Test("Empty segments produce empty transcript.txt (no crash)")
    func flushEmptyTxtIsSafe() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.flushTxt()

        let txt = dir.appendingPathComponent("transcript.txt")
        #expect(FileManager.default.fileExists(atPath: txt.path))
        let content = try String(contentsOf: txt, encoding: .utf8)
        #expect(content.isEmpty)
    }

    @Test("Segment text whitespace trimmed in transcript.txt")
    func segmentTextIsTrimmed() async throws {
        let dir = try makeTempSessionDir()
        defer { cleanup(dir) }

        let store = try TranscriptStore(sessionDir: dir)
        try await store.append(TranscriptSegment(start: 0, end: 1, text: "  hello  ", confidence: 0.9, isFinal: true))
        try await store.append(TranscriptSegment(start: 1, end: 2, text: "world\n", confidence: 0.9, isFinal: true))
        try await store.flushTxt()

        let txt = dir.appendingPathComponent("transcript.txt")
        let content = try String(contentsOf: txt, encoding: .utf8)
        #expect(content == "hello world")
    }
}
