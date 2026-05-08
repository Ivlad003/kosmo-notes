import Foundation
import Testing
@testable import StorageKit

@Suite("SessionStore shared links")
struct SessionStoreSharedLinksTests {

    private func makeStore() async throws -> (SessionStore, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesSharedLinks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        return (store, tmpDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("availableShareArtifacts returns only files that exist")
    func availableShareArtifactsFiltersMissingFiles() async throws {
        let (store, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let session = try await store.createSession(mode: .meeting, language: nil)
        let dir = await store.sessionDir(for: session.id)

        try Data("audio".utf8).write(to: dir.appendingPathComponent("audio.m4a"))
        try Data("summary".utf8).write(to: dir.appendingPathComponent("summary.md"))

        let artifacts = await store.availableShareArtifacts(for: session.id)

        #expect(artifacts == [.audio, .summary])
    }

    @Test("saveSharedLinksSnapshot writes shared-links.json and loadSharedLinksSnapshot reads it back")
    func sharedLinksSnapshotRoundTrip() async throws {
        let (store, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let session = try await store.createSession(mode: .meeting, language: nil)
        let snapshot = SharedLinksSnapshot(
            sharedAt: Date(timeIntervalSince1970: 1_715_130_000),
            links: [
                SharedLinkRecord(kind: .audio, url: URL(string: "https://example.test/audio")!),
                SharedLinkRecord(kind: .summary, url: URL(string: "https://example.test/summary")!)
            ]
        )

        try await store.saveSharedLinksSnapshot(snapshot, for: session.id)
        let loaded = try await store.loadSharedLinksSnapshot(for: session.id)

        #expect(loaded == snapshot)
    }

    @Test("loadSharedLinksSnapshot returns nil when the sidecar is missing")
    func missingSharedLinksSnapshotReturnsNil() async throws {
        let (store, tmpDir) = try await makeStore()
        defer { cleanup(tmpDir) }

        let session = try await store.createSession(mode: .meeting, language: nil)

        let loaded = try await store.loadSharedLinksSnapshot(for: session.id)

        #expect(loaded == nil)
    }
}
