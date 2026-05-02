import Foundation
import GRDB

// MARK: - Domain types

public enum SessionMode: String, Sendable, Codable, Equatable {
    case meeting
    case dictation
    case voiceNote

    /// Human-friendly display name for UI.
    public var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        case .voiceNote: return "Voice Note"
        }
    }

    /// SF Symbol name for menus / library list / details. Stable strings.
    public var iconName: String {
        switch self {
        case .meeting: return "person.2"
        case .dictation: return "keyboard"
        case .voiceNote: return "note.text"
        }
    }
}

public enum SessionStatus: String, Sendable, Codable, Equatable {
    case recording
    case transcribing
    case complete
    case failed
}

public struct SessionRecord: Sendable, Codable, Equatable {
    public let id: String
    public let recordedAt: Date
    public let durationSecs: TimeInterval
    public let mode: SessionMode
    public let language: String?
    public let status: SessionStatus

    public init(
        id: String,
        recordedAt: Date,
        durationSecs: TimeInterval,
        mode: SessionMode,
        language: String?,
        status: SessionStatus
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSecs = durationSecs
        self.mode = mode
        self.language = language
        self.status = status
    }
}

public struct SearchHit: Sendable, Equatable {
    public let sid: String
    public let snippet: String

    public init(sid: String, snippet: String) {
        self.sid = sid
        self.snippet = snippet
    }
}

// MARK: - AppDatabase

// Named AppDatabase rather than Database to avoid shadowing GRDB.Database,
// which is used in write/read closure parameters throughout this file.
public actor AppDatabase {

    private let pool: DatabasePool

    /// Open (or create) the SQLite database at `path`. Does NOT run migrations.
    public init(path: URL) throws {
        var config = Configuration()
        // WAL allows concurrent readers while the recorder writes.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        self.pool = try DatabasePool(path: path.path, configuration: config)
    }

    // MARK: - Schema

    /// Apply schema migrations. Idempotent — safe to call multiple times.
    public func migrate() async throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id            TEXT    PRIMARY KEY,
                    recorded_at   REAL    NOT NULL,
                    duration_secs REAL    NOT NULL DEFAULT 0,
                    mode          TEXT    NOT NULL,
                    language      TEXT,
                    status        TEXT    NOT NULL
                );
                CREATE INDEX idx_sessions_recorded_at ON sessions(recorded_at DESC);
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                    sid UNINDEXED,
                    text,
                    tokenize = 'porter unicode61'
                );
                """)
        }
        // v2: per-session embeddings for semantic search. One row per session,
        // packed as a Float32 LE blob. We deliberately avoid sqlite-vec / sqlite-vss
        // for v1.0 to keep the deps light — cosine similarity in Swift is plenty
        // fast under the hundreds-of-sessions ceiling we expect on a single Mac.
        migrator.registerMigration("v2_embeddings") { db in
            try db.execute(sql: """
                CREATE TABLE session_embeddings (
                    sid         TEXT    PRIMARY KEY,
                    vector      BLOB    NOT NULL,
                    model       TEXT    NOT NULL,
                    indexed_at  REAL    NOT NULL,
                    FOREIGN KEY(sid) REFERENCES sessions(id) ON DELETE CASCADE
                );
                """)
        }
        try migrator.migrate(pool)
    }

    // MARK: - Sessions

    public func insertSession(_ s: SessionRecord) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, recorded_at, duration_secs, mode, language, status)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [s.id, s.recordedAt.timeIntervalSince1970,
                            s.durationSecs, s.mode.rawValue, s.language, s.status.rawValue]
            )
        }
    }

    public func updateSession(_ s: SessionRecord) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET recorded_at = ?, duration_secs = ?, mode = ?, language = ?, status = ?
                    WHERE id = ?
                    """,
                arguments: [s.recordedAt.timeIntervalSince1970,
                            s.durationSecs, s.mode.rawValue, s.language, s.status.rawValue,
                            s.id]
            )
        }
    }

    public func session(id: String) async throws -> SessionRecord? {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
            return rows.first.map(Self.rowToRecord)
        }
    }

    /// Returns sessions ordered newest-first (by recorded_at DESC).
    public func listSessions(limit: Int = 100) async throws -> [SessionRecord] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM sessions ORDER BY recorded_at DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map(Self.rowToRecord)
        }
    }

    // MARK: - FTS

    public func indexTranscript(sid: String, text: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO transcripts_fts (sid, text) VALUES (?, ?)",
                arguments: [sid, text]
            )
        }
    }

    /// Full-text search. Returns up to `limit` hits with a snippet from the matching text.
    public func searchTranscripts(query: String, limit: Int = 50) async throws -> [SearchHit] {
        // Build a safe FTS5 pattern from user input; bail early on blank input.
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
        return try await pool.read { db in
            // snippet() col index 1 = the "text" column (0-based, sid is col 0).
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT sid,
                           snippet(transcripts_fts, 1, '<b>', '</b>', '…', 10) AS snip
                    FROM transcripts_fts
                    WHERE transcripts_fts MATCH ?
                    LIMIT ?
                    """,
                arguments: [pattern.rawPattern, limit]
            )
            return rows.map { SearchHit(sid: $0["sid"], snippet: $0["snip"]) }
        }
    }

    // MARK: - Embeddings

    /// Insert or replace the embedding vector for a session.
    public func upsertEmbedding(sid: String, vector: Data, model: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_embeddings (sid, vector, model, indexed_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(sid) DO UPDATE SET
                        vector = excluded.vector,
                        model = excluded.model,
                        indexed_at = excluded.indexed_at
                    """,
                arguments: [sid, vector, model, Date().timeIntervalSince1970]
            )
        }
    }

    /// Read all stored embeddings as `(sid, vectorData, model)` tuples. The caller
    /// unpacks vectorData via `EmbeddingMath.unpack` and computes cosine similarity.
    /// Returns rows in undefined order.
    public func allEmbeddings() async throws -> [(sid: String, vector: Data, model: String)] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT sid, vector, model FROM session_embeddings"
            )
            return rows.map { row -> (sid: String, vector: Data, model: String) in
                (sid: row["sid"], vector: row["vector"], model: row["model"])
            }
        }
    }

    /// Returns true when an embedding exists for `sid`. Used to skip re-indexing.
    public func hasEmbedding(sid: String) async throws -> Bool {
        try await pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM session_embeddings WHERE sid = ? LIMIT 1",
                arguments: [sid]
            )
            return row != nil
        }
    }

    // MARK: - Helpers

    private static func rowToRecord(_ row: Row) -> SessionRecord {
        // recorded_at is stored as Unix epoch (REAL). Convert at the boundary.
        let epoch: Double = row["recorded_at"]
        return SessionRecord(
            id: row["id"],
            recordedAt: Date(timeIntervalSince1970: epoch),
            durationSecs: row["duration_secs"],
            mode: SessionMode(rawValue: row["mode"]) ?? .meeting,
            language: row["language"],
            status: SessionStatus(rawValue: row["status"]) ?? .failed
        )
    }
}
