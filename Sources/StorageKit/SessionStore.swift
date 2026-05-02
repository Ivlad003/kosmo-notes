import Foundation

// MARK: - SessionStore

/// Coordinates the filesystem sidecar layout and the SQLite index for sessions.
///
/// Filesystem is source of truth (per stack invariant). Every mutation writes
/// session.json atomically first, then updates the DB. A rebuild can re-derive
/// the DB from the sidecars.
public actor SessionStore {

    private let rootDir: URL
    private let database: AppDatabase

    public init(rootDir: URL, database: AppDatabase) throws {
        self.rootDir = rootDir
        self.database = database
        // Ensure the root directory exists before any session is created.
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    // MARK: - Create

    /// Create a new recording session: make the directory, write session.json, insert into DB.
    @discardableResult
    public func createSession(mode: SessionMode, language: String?) async throws -> SessionRecord {
        let sid = UUID().uuidString.lowercased()
        let dir = sessionDir(for: sid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let record = SessionRecord(
            id: sid,
            recordedAt: Date(),
            durationSecs: 0,
            mode: mode,
            language: language,
            status: .recording
        )
        try writeSessionJSON(record, to: dir)
        try await database.insertSession(record)
        return record
    }

    // MARK: - Finalize

    /// Atomically rewrite session.json with the new status + duration, then update the DB row.
    @discardableResult
    public func finalize(
        id: String,
        status: SessionStatus,
        durationSecs: TimeInterval
    ) async throws -> SessionRecord {
        // Read the existing JSON to preserve recordedAt / mode / language.
        let dir = sessionDir(for: id)
        let existing = try readSessionJSON(from: dir)
        let updated = SessionRecord(
            id: existing.id,
            recordedAt: existing.recordedAt,
            durationSecs: durationSecs,
            mode: existing.mode,
            language: existing.language,
            status: status
        )
        try writeSessionJSON(updated, to: dir)
        try await database.updateSession(updated)
        return updated
    }

    // MARK: - FTS

    /// Index transcript text into FTS5. Call after transcript.txt is flushed to disk.
    public func indexTranscript(sid: String, text: String) async throws {
        try await database.indexTranscript(sid: sid, text: text)
    }

    // MARK: - Paths

    public func sessionDir(for id: String) -> URL {
        rootDir.appendingPathComponent(id)
    }

    /// Root directory holding all session subdirectories. Exposed so callers
    /// (e.g. Library "Clear All") can sweep entries that were never indexed
    /// in the DB — typically aborted-mid-record sessions.
    public var recordingsRoot: URL {
        rootDir
    }

    // MARK: - Private helpers

    private func writeSessionJSON(_ record: SessionRecord, to dir: URL) throws {
        let url = dir.appendingPathComponent("session.json")
        try AtomicWriter.writeJSON(record, to: url)
    }

    private func readSessionJSON(from dir: URL) throws -> SessionRecord {
        let url = dir.appendingPathComponent("session.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecord.self, from: data)
    }
}
