import Foundation
import Testing
@testable import StorageKit

// MARK: - SessionStoreTests

@Suite("SessionStore tests")
struct SessionStoreTests {

    // MARK: - Helpers

    private func makeStore() async throws -> (SessionStore, AppDatabase, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("JarvisNoteStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        return (store, db, tmpDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func readSessionJSON(from dir: URL) throws -> SessionRecord {
        let url = dir.appendingPathComponent("session.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecord.self, from: data)
    }

    // MARK: - createSession

    @Test("createSession makes the directory and writes session.json with status=recording")
    func createSessionMakesDirAndWritesJSON() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let record = try await store.createSession(mode: .meeting, language: "en-US")

        let dir = await store.sessionDir(for: record.id)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        let onDisk = try readSessionJSON(from: dir)
        #expect(onDisk.id == record.id)
        #expect(onDisk.status == .recording)
        #expect(onDisk.mode == .meeting)
        #expect(onDisk.language == "en-US")
    }

    @Test("createSession inserts record into DB with status=recording")
    func createSessionInsertsIntoDatabase() async throws {
        let (store, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let record = try await store.createSession(mode: .dictation, language: nil)

        let fromDB = try await db.session(id: record.id)
        #expect(fromDB != nil)
        #expect(fromDB?.status == .recording)
        #expect(fromDB?.mode == .dictation)
        #expect(fromDB?.language == nil)
    }

    @Test("createSession generates unique lowercase UUID sids")
    func createSessionGeneratesUniqueSids() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let r1 = try await store.createSession(mode: .meeting, language: nil)
        let r2 = try await store.createSession(mode: .meeting, language: nil)

        #expect(r1.id != r2.id)
        // UUID lowercased: no uppercase letters.
        #expect(r1.id == r1.id.lowercased())
    }

    // MARK: - finalize

    @Test("finalize rewrites session.json atomically with updated status and duration")
    func finalizeRewritesSessionJSON() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let created = try await store.createSession(mode: .meeting, language: nil)
        let finalized = try await store.finalize(id: created.id, status: .complete, durationSecs: 123.4)

        let dir = await store.sessionDir(for: created.id)
        let onDisk = try readSessionJSON(from: dir)

        #expect(onDisk.status == .complete)
        #expect(onDisk.durationSecs == 123.4)
        #expect(finalized.status == .complete)
        #expect(finalized.durationSecs == 123.4)
        // Immutable fields are preserved.
        #expect(onDisk.id == created.id)
        #expect(onDisk.mode == created.mode)
    }

    @Test("finalize updates DB row to match new status and duration")
    func finalizeUpdatesDatabase() async throws {
        let (store, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let created = try await store.createSession(mode: .meeting, language: nil)
        _ = try await store.finalize(id: created.id, status: .failed, durationSecs: 7.0)

        let fromDB = try await db.session(id: created.id)
        #expect(fromDB?.status == .failed)
        #expect(fromDB?.durationSecs == 7.0)
    }

    // MARK: - sessionDir

    @Test("sessionDir returns <rootDir>/<sid> matching actual on-disk path")
    func sessionDirMatchesOnDisk() async throws {
        let (store, _, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let record = try await store.createSession(mode: .meeting, language: nil)
        let expected = await store.sessionDir(for: record.id)

        #expect(FileManager.default.fileExists(atPath: expected.path))
        // The last path component should be the sid.
        #expect(expected.lastPathComponent == record.id)
    }

    // MARK: - indexTranscript / FTS round-trip

    @Test("indexTranscript populates FTS — searchTranscripts returns the right sid")
    func indexTranscriptFTSRoundTrip() async throws {
        let (store, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let record = try await store.createSession(mode: .meeting, language: nil)
        try await store.indexTranscript(sid: record.id, text: "quarterly earnings were above expectations")

        let hits = try await db.searchTranscripts(query: "earnings")
        #expect(hits.count == 1)
        #expect(hits[0].sid == record.id)
    }

    @Test("indexTranscript for multiple sessions: search returns only matching sid")
    func indexTranscriptSearchIsolatedToMatchingSid() async throws {
        let (store, db, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let r1 = try await store.createSession(mode: .meeting, language: nil)
        let r2 = try await store.createSession(mode: .dictation, language: nil)

        try await store.indexTranscript(sid: r1.id, text: "project deadline tomorrow")
        try await store.indexTranscript(sid: r2.id, text: "grocery list apples oranges")

        let hits = try await db.searchTranscripts(query: "deadline")
        #expect(hits.count == 1)
        #expect(hits[0].sid == r1.id)
    }
}
