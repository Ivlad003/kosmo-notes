import Foundation
import Observation
import StorageKit
import TranscriptionKit

// MARK: - ModeFilter

@available(macOS 14.0, *)
enum ModeFilter: String, CaseIterable, Identifiable {
    case all
    case meeting
    case dictation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        }
    }
}

// MARK: - LibraryState

/// Observable state for the Library window.
///
/// Holds query + filter selection; drives async refresh against the DB.
/// Transcript segments are loaded lazily (only when a session is selected)
/// to avoid reading hundreds of JSONL files at startup.
@available(macOS 14.0, *)
@Observable
@MainActor
final class LibraryState {

    // MARK: - Dependencies

    let database: AppDatabase
    let sessionStore: SessionStore

    // MARK: - Observable state

    var query: String = "" {
        didSet { scheduleRefresh() }
    }

    var modeFilter: ModeFilter = .all {
        didSet { scheduleRefresh() }
    }

    var sessions: [SessionRecord] = []
    var selectedSessionId: String?

    // MARK: - Init

    init(database: AppDatabase, sessionStore: SessionStore) {
        self.database = database
        self.sessionStore = sessionStore
    }

    // MARK: - Data loading

    /// Populate `sessions` from DB using the current query + filter.
    func refresh() async {
        do {
            let raw: [SessionRecord]
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                raw = try await database.listSessions(limit: 200)
            } else {
                // FTS5 search returns hits with sids; hydrate back to full records in parallel.
                let hits = try await database.searchTranscripts(query: trimmed, limit: 100)
                raw = try await withThrowingTaskGroup(of: SessionRecord?.self) { group in
                    for hit in hits {
                        group.addTask { [database] in
                            try await database.session(id: hit.sid)
                        }
                    }
                    var results: [SessionRecord] = []
                    for try await record in group {
                        if let r = record { results.append(r) }
                    }
                    // Re-sort newest-first (TaskGroup ordering is non-deterministic).
                    return results.sorted { $0.recordedAt > $1.recordedAt }
                }
            }

            // Apply mode filter client-side — DB already filters by date; mode is cheap.
            sessions = raw.filter { record in
                switch modeFilter {
                case .all: return true
                case .meeting: return record.mode == .meeting
                case .dictation: return record.mode == .dictation
                }
            }
        } catch {
            // Surfacing DB errors here would require a separate error state; for v0
            // leave sessions unchanged and log to console.
            print("[LibraryState] refresh failed: \(error)")
        }
    }

    /// Read transcript.jsonl for a session and decode line-by-line.
    ///
    /// Returns an empty array (not throws) when transcript.jsonl is missing —
    /// this happens for sessions that never reached the transcription stage.
    func loadSegments(for sid: String) async throws -> [TranscriptSegment] {
        let dir = await sessionStore.sessionDir(for: sid)
        let jsonlURL = dir.appendingPathComponent("transcript.jsonl")

        // Skip reading if the file doesn't exist (transcription incomplete/failed).
        guard (try? jsonlURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize != nil else {
            return []
        }

        let data = try Data(contentsOf: jsonlURL)
        guard !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var segments: [TranscriptSegment] = []

        // JSONL: one JSON object per line.
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let segment = try? decoder.decode(TranscriptSegment.self, from: Data(line)) {
                segments.append(segment)
            }
        }
        return segments
    }

    /// URL for the audio file of a session.
    func audioFileURL(for sid: String) async -> URL {
        let dir = await sessionStore.sessionDir(for: sid)
        return dir.appendingPathComponent("audio.m4a")
    }

    // MARK: - Private

    // Debounce: refresh fires on the next run-loop turn after the last mutation.
    // Avoids a DB round-trip per keystroke while still feeling live.
    private var refreshTask: Task<Void, Never>?

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Yield once to coalesce rapid changes (e.g. filter + query changed together).
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}
