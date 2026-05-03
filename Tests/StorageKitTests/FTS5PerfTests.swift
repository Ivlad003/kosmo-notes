import Foundation
import Testing
@testable import StorageKit

// MARK: - FTS5PerfTests
//
// AC-12: FTS5 search across 100 sessions × 10k tokens returns matches in
// <50 ms warm cache, <200 ms cold (M-series).
//
// Synthesizes a deterministic corpus, exercises `SessionStore.indexTranscript`
// for each, then measures one cold search (after closing + reopening the
// database to flush page cache) and one warm search (immediately after).
//
// This suite is gated behind `JN_RUN_PERF=1` so the default `swift test` run
// stays fast — corpus generation + 100 inserts dominates wall time, not the
// query under measurement. CI can opt in by exporting the env var.
//
// Toolchain:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//   JN_RUN_PERF=1 swift test --filter FTS5PerfTests

@Suite("FTS5 performance benchmark (AC-12)")
struct FTS5PerfTests {

    // MARK: - Gating

    /// Returns true when the perf suite should be skipped — i.e. when the
    /// opt-in env var is not set. Keeps default `swift test` runs fast.
    private static var isDisabled: Bool {
        ProcessInfo.processInfo.environment["JN_RUN_PERF"] != "1"
    }

    // MARK: - Tunables

    /// Per AC-12: 100 sessions × 10k tokens.
    private static let sessionCount = 100
    private static let tokensPerSession = 10_000

    /// AC-12 thresholds.
    private static let coldBudgetMs: Double = 200
    private static let warmBudgetMs: Double = 50

    // MARK: - Test

    @Test(
        "AC-12: 100 sessions × 10k tokens — cold <200ms, warm <50ms",
        .disabled(if: FTS5PerfTests.isDisabled, "Set JN_RUN_PERF=1 to opt in")
    )
    func searchPerfWithinBudgets() async throws {
        // Stable working directory we control — survives close+reopen of the DB.
        let tmpDir = URL.temporaryDirectory.appendingPathComponent(
            "KosmoNotesFTS5Perf-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("sessions.sqlite")
        let recordingsDir = tmpDir.appendingPathComponent("recordings")

        // Seed the corpus on a fresh DB instance.
        try await seedCorpus(dbURL: dbURL, recordingsDir: recordingsDir)

        // Pick a query token guaranteed to appear in the indexed corpus.
        // `searchTermInCorpus` is stable across runs because the corpus
        // generator is deterministic.
        let query = Self.searchTermInCorpus

        // ---- Cold measurement ----
        // Close + reopen the DB to drop page-cache state. GRDB's DatabasePool
        // holds connections internally; releasing it lets the OS reclaim its
        // buffers. We additionally drop the (separately allocated) recordings
        // store. macOS still caches at the VFS layer, but a fresh DatabasePool
        // forces a clean B-tree walk per FTS5 segment.
        let coldDb = try AppDatabase(path: dbURL)
        // Note: schema already migrated by seed step; migrate() is idempotent.
        try await coldDb.migrate()

        let coldStart = ContinuousClock.now
        let coldHits = try await coldDb.searchTranscripts(query: query, limit: 50)
        let coldElapsed = ContinuousClock.now - coldStart
        let coldMs = Self.milliseconds(coldElapsed)

        #expect(!coldHits.isEmpty, "Cold search should return at least one hit for query '\(query)'")

        // ---- Warm measurement ----
        // Same connection, immediately after — page cache + FTS5 segment
        // metadata are now hot. This is the realistic interactive case.
        let warmStart = ContinuousClock.now
        let warmHits = try await coldDb.searchTranscripts(query: query, limit: 50)
        let warmElapsed = ContinuousClock.now - warmStart
        let warmMs = Self.milliseconds(warmElapsed)

        #expect(warmHits.count == coldHits.count, "Warm result count should equal cold result count")

        // Always log the numbers so CI / dev runs surface real data even on pass.
        // Using stderr (FileHandle) to bypass any swift-testing output buffering.
        let report = """
            [AC-12 FTS5PerfTests] sessions=\(Self.sessionCount) tokens/session=\(Self.tokensPerSession) \
            query='\(query)' hits=\(coldHits.count) cold=\(String(format: "%.2f", coldMs))ms \
            (budget \(Self.coldBudgetMs)ms) warm=\(String(format: "%.2f", warmMs))ms \
            (budget \(Self.warmBudgetMs)ms)
            """
        FileHandle.standardError.write(Data((report + "\n").utf8))

        // ---- Budget assertions ----
        #expect(
            coldMs < Self.coldBudgetMs,
            "Cold FTS5 search took \(coldMs) ms, budget is \(Self.coldBudgetMs) ms"
        )
        #expect(
            warmMs < Self.warmBudgetMs,
            "Warm FTS5 search took \(warmMs) ms, budget is \(Self.warmBudgetMs) ms"
        )
    }

    // MARK: - Corpus

    /// Inserts `sessionCount` sessions, each with `tokensPerSession` tokens of
    /// pseudo-English text into the FTS5 index. Uses the public SessionStore
    /// API end-to-end (createSession → indexTranscript → finalize) so the
    /// path under test is the production write path.
    private func seedCorpus(dbURL: URL, recordingsDir: URL) async throws {
        let db = try AppDatabase(path: dbURL)
        try await db.migrate()
        let store = try SessionStore(rootDir: recordingsDir, database: db)

        for sessionIndex in 0..<Self.sessionCount {
            let record = try await store.createSession(mode: .meeting, language: "en-US")
            let text = Self.generateTranscript(
                sessionIndex: sessionIndex,
                tokenCount: Self.tokensPerSession
            )
            try await store.indexTranscript(sid: record.id, text: text)
            try await store.finalize(
                id: record.id,
                status: .complete,
                durationSecs: Double(Self.tokensPerSession) / 2.5  // ~rough words-per-second
            )
        }
        // db / store go out of scope here; the DatabasePool will be torn down
        // when the actor is deallocated, releasing GRDB's WAL connections.
    }

    // MARK: - Deterministic pseudo-English generator

    /// A fixed Lorem-Ipsum-style vocabulary. Real FTS5 selectivity matters,
    /// so we want enough variety that token postings lists are non-trivial.
    private static let baseLexicon: [String] = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
        "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
        "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
        "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
        "velit", "esse", "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint",
        "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui", "officia",
        "deserunt", "mollit", "anim", "id", "laborum", "the", "quick", "brown", "fox",
        "jumps", "over", "lazy", "dog", "meeting", "discussion", "agenda", "decision",
        "stakeholder", "roadmap", "milestone", "deliverable", "blocker", "dependency",
        "estimate", "deadline", "scope", "review", "feedback", "iteration", "retro",
        "standup", "demo", "release", "sprint", "backlog", "ticket", "issue", "bug",
        "feature", "epic", "story", "task", "owner", "priority", "severity", "label",
    ]

    /// Per-session unique token. Including the index in every transcript both
    /// keeps the corpus realistic (sessions vary) and gives us a deterministic
    /// search target for the perf test below.
    private static func sessionToken(_ index: Int) -> String {
        // 4-digit zero-padded so token shape is uniform: e.g. "session0042".
        "session\(String(format: "%04d", index))"
    }

    /// We pick a token that appears in roughly half the corpus so the search
    /// has real work to do (index lookups + multiple result rows + snippet
    /// rendering) — measuring a no-hit query understates the warm-path cost.
    /// "milestone" is in `baseLexicon` and gets sprinkled deterministically.
    fileprivate static let searchTermInCorpus = "milestone"

    /// Deterministic per-session text. Uses a SplitMix-style integer hash so
    /// no allocation per token is needed beyond the final string. Token order
    /// varies session-to-session, vocabulary stays constant — i.e. the FTS
    /// index has real variety in postings without ballooning the dictionary.
    private static func generateTranscript(sessionIndex: Int, tokenCount: Int) -> String {
        // Heuristic capacity: average token length ~6 + 1 separator → 7 bytes.
        var out = String()
        out.reserveCapacity(tokenCount * 7)

        // Per-session unique token so each session has distinct content.
        let unique = sessionToken(sessionIndex)

        // Seed depends on session index → reproducible corpus.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(sessionIndex) &* 0xBF58_476D_1CE4_E5B9

        let lexCount = UInt64(baseLexicon.count)

        for tokenIndex in 0..<tokenCount {
            // SplitMix64 step — fast deterministic pseudo-random.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z &>> 31)

            // Sprinkle the per-session unique token every ~250 tokens so each
            // session has a clearly identifiable marker in the index.
            if tokenIndex % 250 == 0 {
                out.append(unique)
            } else {
                let idx = Int(z % lexCount)
                out.append(baseLexicon[idx])
            }

            if tokenIndex < tokenCount - 1 {
                out.append(" ")
            }
        }
        return out
    }

    // MARK: - Time conversion

    private static func milliseconds(_ duration: ContinuousClock.Duration) -> Double {
        // Duration components: seconds (Int64) + attoseconds (Int64).
        let comps = duration.components
        return Double(comps.seconds) * 1_000.0 + Double(comps.attoseconds) / 1_000_000_000_000_000.0
    }
}
