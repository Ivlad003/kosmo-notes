import Foundation
import Testing
import SharingKit
import StorageKit
@testable import KosmoNotes

@MainActor
@Suite("Library share logic")
struct LibraryShareLogicTests {

    private func makeStore() async throws -> (AppDatabase, SessionStore, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        return (db, store, tmpDir)
    }

    @Test("snapshot(from:) keeps only non-nil URLs in artifact order")
    func snapshotFromShareResultKeepsStableOrder() {
        let result = SharingService.ShareResult(
            audioURL: URL(string: "https://example.test/audio")!,
            videoURL: URL(string: "https://example.test/video")!,
            summaryURL: nil,
            transcriptURL: URL(string: "https://example.test/transcript")!
        )

        let snapshot = SessionSharePlanning.snapshot(
            from: result,
            sharedAt: Date(timeIntervalSince1970: 1_715_130_000)
        )

        #expect(snapshot.links.map(\.kind) == [.audio, .video, .transcript])
    }

    @Test("validatedSelection rejects an empty artifact list")
    func validatedSelectionRejectsEmptySelection() {
        #expect(throws: SessionSharePlanning.SelectionError.self) {
            try SessionSharePlanning.validatedSelection([])
        }
    }

    @Test("sharedLinks returns nil when shared-links.json is invalid")
    func sharedLinksReturnsNilForCorruptSidecar() async throws {
        let (db, store, tmpDir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let session = try await store.createSession(mode: .meeting, language: nil)
        let dir = await store.sessionDir(for: session.id)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("shared-links.json"))

        let state = LibraryState(database: db, sessionStore: store, settings: nil)
        let loaded = await state.sharedLinks(for: session.id)

        #expect(loaded == nil)
    }
}
