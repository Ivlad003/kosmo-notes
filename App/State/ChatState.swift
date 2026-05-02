import Foundation
import Observation
import AIKit
import StorageKit
import TranscriptionKit

// MARK: - ChatState

/// Observable state for the Chat window.
///
/// Adds session-aware RAG context: FTS5 auto-search attaches the most relevant
/// recorded sessions as system-prompt context before each LLM call. Users can
/// also manually attach sessions via the picker sheet.
///
/// Provider is resolved per-call from `settings.llmProvider` so the user can
/// switch providers between messages without reopening the window.
@available(macOS 14.0, *)
@Observable
@MainActor
final class ChatState {

    // MARK: - Attached session discriminant

    enum AttachedSession: Hashable {
        case manual(SessionRecord)
        case autoFromSearch(SessionRecord, snippet: String)

        var record: SessionRecord {
            switch self {
            case .manual(let r): return r
            case .autoFromSearch(let r, _): return r
            }
        }

        // Hashable / Equatable on session id only — deduplicate by id.
        func hash(into hasher: inout Hasher) { hasher.combine(record.id) }
        static func == (lhs: AttachedSession, rhs: AttachedSession) -> Bool {
            lhs.record.id == rhs.record.id
        }
    }

    // MARK: - Observable state

    var messages: [ChatMessage] = []
    var inputDraft: String = ""
    var isSending: Bool = false
    var lastError: String?

    // Session context controls
    var autoSearchSessions: Bool = true
    var searchDepth: Int = 3
    var attachedSessions: [AttachedSession] = []

    // Live snapshot controls
    var snapshotQuestion: String = ""
    var isSnapshotting: Bool = false

    // MARK: - Dependencies
    // `database` is internal (not private) so ChatView can pass it to SessionPickerSheet.

    private let settings: AppSettings
    let database: AppDatabase
    private let sessionStore: SessionStore
    private let recorder: RecorderState
    // Injectable factory so unit tests can swap WhisperProvider without network.
    private let whisperProviderFactory: @Sendable (String) -> WhisperProvider

    // MARK: - Computed state exposed to the View

    /// True while a recording session is in progress (for input-mode switcher).
    var isRecording: Bool {
        if case .recording = recorder.status { return true }
        return false
    }

    // MARK: - Init

    init(
        settings: AppSettings,
        database: AppDatabase,
        sessionStore: SessionStore,
        recorder: RecorderState,
        whisperProviderFactory: @Sendable @escaping (String) -> WhisperProvider = { WhisperProvider(apiKey: $0) }
    ) {
        self.settings = settings
        self.database = database
        self.sessionStore = sessionStore
        self.recorder = recorder
        self.whisperProviderFactory = whisperProviderFactory
    }

    // MARK: - Actions

    /// Posts the user message. When `autoSearchSessions` is on, runs FTS5
    /// over `inputDraft` first and attaches the top hits as context before
    /// building the system prompt.
    func send() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputDraft = ""
        lastError = nil
        isSending = true
        defer { isSending = false }

        messages.append(ChatMessage(role: .user, content: text))

        do {
            // Auto-attach FTS hits before building the system prompt.
            if autoSearchSessions {
                await attachAutoSearchResults(for: text)
            }

            let systemPrompt = await buildSystemPrompt()
            let reply = try await runProvider(messages: messages, systemPrompt: systemPrompt)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch let error as AIError {
            lastError = friendlyMessage(for: error)
            messages.removeLast()
            inputDraft = text
        } catch {
            lastError = error.localizedDescription
            messages.removeLast()
            inputDraft = text
        }
    }

    /// Clears messages and all attached sessions.
    func clear() {
        messages = []
        attachedSessions = []
        lastError = nil
    }

    /// Looks up a SessionRecord by id and appends a manual attachment.
    func attachSession(_ id: String) async {
        guard !attachedSessions.contains(where: { $0.record.id == id }) else { return }
        do {
            if let record = try await database.session(id: id) {
                attachedSessions.append(.manual(record))
            }
        } catch {
            lastError = "Could not load session: \(error.localizedDescription)"
        }
    }

    /// Bulk manual attach — used by SessionPickerSheet.
    func attachSessions(_ ids: [String]) async {
        for id in ids {
            await attachSession(id)
        }
    }

    /// Removes an attached session by id (manual or auto).
    func detachSession(_ id: String) {
        attachedSessions.removeAll { $0.record.id == id }
    }

    /// Captures the last ~60 s of the active recording via Whisper, then sends
    /// a message with the snapshot transcript as context.
    func sendSnapshot() async {
        guard case .recording(let sid) = recorder.status else {
            lastError = "Not currently recording — start a recording to use live snapshot."
            return
        }
        let q = snapshotQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let openaiKey = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openaiKey.isEmpty else {
            lastError = "OpenAI API key required for live snapshot (set in Settings)."
            return
        }

        isSnapshotting = true
        defer { isSnapshotting = false }

        let language = settings.summaryLanguage == "auto" ? nil : settings.summaryLanguage
        let maker = SnapshotMaker(sessionStore: sessionStore, whisperProviderFactory: whisperProviderFactory)

        do {
            let snapshotText = try await maker.snapshot(
                sessionId: sid,
                apiKey: openaiKey,
                language: language
            )
            let userMessage = ChatMessage(
                role: .user,
                content: "[Live snapshot — last ~60 seconds of the active recording]\n\(snapshotText)\n\n---\n\nQuestion: \(q)"
            )
            messages.append(userMessage)
            snapshotQuestion = ""

            let reply = try await runProvider(messages: messages, systemPrompt: nil)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch {
            lastError = "Snapshot failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private: provider dispatch

    /// Shared send-to-LLM path used by both `send()` and `sendSnapshot()`.
    private func runProvider(messages: [ChatMessage], systemPrompt: String?) async throws -> String {
        let provider = try makeProvider()
        let config = makeConfig(systemPrompt: systemPrompt)
        return try await provider.chat(messages: messages, config: config)
    }

    private func makeProvider() throws -> any AIProvider {
        switch settings.llmProvider {
        case .anthropic:
            let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw AIError.authenticationFailed }
            return AnthropicProvider(apiKey: key)
        case .openai:
            let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw AIError.authenticationFailed }
            return OpenAIProvider(apiKey: key)
        }
    }

    private func makeConfig(systemPrompt: String?) -> AIConfig {
        let model: String
        switch settings.llmProvider {
        case .anthropic: model = AnthropicProvider.defaultModel
        case .openai:    model = OpenAIProvider.defaultModel
        }
        return AIConfig(model: model, systemPrompt: systemPrompt)
    }

    // MARK: - Private: auto-search

    /// Runs FTS5 over `query`, fetches matching SessionRecords in parallel,
    /// and appends `.autoFromSearch` entries (deduplicated by id).
    private func attachAutoSearchResults(for query: String) async {
        let hits: [SearchHit]
        do {
            hits = try await database.searchTranscripts(query: query, limit: searchDepth)
        } catch {
            // FTS failure is non-fatal; proceed without auto-context.
            return
        }
        guard !hits.isEmpty else { return }

        // Fetch SessionRecords in parallel for all hits.
        var records: [(SearchHit, SessionRecord)] = []
        await withTaskGroup(of: (SearchHit, SessionRecord?).self) { group in
            for hit in hits {
                group.addTask {
                    let record = try? await self.database.session(id: hit.sid)
                    return (hit, record)
                }
            }
            for await (hit, record) in group {
                if let record {
                    records.append((hit, record))
                }
            }
        }

        // Preserve FTS ranking order; deduplicate against already-attached sessions.
        let orderedHits = hits.compactMap { hit in records.first(where: { $0.0.sid == hit.sid }) }
        for (hit, record) in orderedHits {
            guard !attachedSessions.contains(where: { $0.record.id == record.id }) else { continue }
            attachedSessions.append(.autoFromSearch(record, snippet: hit.snippet))
        }
    }

    // MARK: - Private: system prompt

    /// Builds the session-context system prompt from all attached sessions.
    /// Returns nil when there are no attached sessions.
    private func buildSystemPrompt() async -> String? {
        guard !attachedSessions.isEmpty else { return nil }

        var prompt = """
        You are a helpful assistant that has access to the user's audio recording transcripts.
        Reference these recordings when relevant; cite by recorded_at if you do.

        == Attached sessions ==

        """

        let isoFormatter = ISO8601DateFormatter()
        for attachment in attachedSessions {
            let record = attachment.record
            let transcriptText = await loadTranscript(for: record)
            let dateStr = isoFormatter.string(from: record.recordedAt)
            let durStr = String(format: "%.0f", record.durationSecs)
            let langStr = record.language ?? "auto"
            prompt += "\n[\(dateStr) · \(record.mode.rawValue) · \(durStr)s · \(langStr)]\n"
            prompt += transcriptText
            prompt += "\n"
        }

        return prompt
    }

    /// Reads `transcript.txt` from the session directory; falls back to
    /// concatenating `transcript.jsonl` lines. Returns empty string if both missing.
    private func loadTranscript(for record: SessionRecord) async -> String {
        let dir = await sessionStore.sessionDir(for: record.id)

        // Preferred: pre-built transcript.txt
        let txtURL = dir.appendingPathComponent("transcript.txt")
        if let text = try? String(contentsOf: txtURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: parse transcript.jsonl
        let jsonlURL = dir.appendingPathComponent("transcript.jsonl")
        guard let raw = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return "" }

        let decoder = JSONDecoder()
        let lines = raw.components(separatedBy: .newlines)
        let segments: [String] = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let seg = try? decoder.decode(TranscriptSegment.self, from: data) else { return nil }
            return seg.text
        }
        return segments.joined(separator: " ")
    }

    // MARK: - Private: error formatting

    private func friendlyMessage(for error: AIError) -> String {
        switch error {
        case .authenticationFailed:
            return "API key is missing or invalid. Check Settings → AI Providers."
        case .rateLimited:
            return "Rate limited by the provider. Wait a moment and try again."
        case .invalidEndpoint:
            return "Invalid provider endpoint."
        case .sendFailed(let msg):
            return "Request failed: \(msg)"
        case .decodingFailed(let msg):
            return "Could not parse the provider response: \(msg)"
        }
    }
}
