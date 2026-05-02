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
///
/// Vision: when the user message contains timestamp patterns (0:30, 1:23:45,
/// "at minute 5", "на 3 хвилині"), ChatState extracts frames from screen.mp4
/// of attached sessions and appends them as image parts (cap: 3 frames/send).
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
    /// building the system prompt. Scans for timestamp patterns and extracts
    /// frames from attached sessions' screen.mp4 (cap: 3 frames).
    func send() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputDraft = ""
        lastError = nil
        isSending = true
        defer { isSending = false }

        // Auto-attach FTS hits before building the system prompt.
        if autoSearchSessions {
            await attachAutoSearchResults(for: text)
        }

        // Extract vision frames for any timestamp mentions in the user message.
        let (imageParts, frameFooter) = await extractFramesForTimestamps(in: text)

        // Build the user message: text + any image parts + optional footer.
        var parts: [ChatMessage.Part] = [.text(text)]
        parts.append(contentsOf: imageParts)
        if !frameFooter.isEmpty {
            parts.append(.text(frameFooter))
        }
        messages.append(ChatMessage(role: .user, parts: parts))

        do {
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
        case .ollama:
            let endpoint = URL(string: settings.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
            let mode: OllamaProvider.APIMode = settings.ollamaApiMode == .native ? .native : .openaiCompat
            let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
            return try OllamaProvider(
                endpoint: endpoint,
                apiMode: mode,
                bearerToken: bearer.isEmpty ? nil : bearer
            )
        }
    }

    private func makeConfig(systemPrompt: String?) -> AIConfig {
        let model: String
        switch settings.llmProvider {
        case .anthropic: model = AnthropicProvider.defaultModel
        case .openai:    model = OpenAIProvider.defaultModel
        case .ollama:    model = settings.ollamaModel
        }
        return AIConfig(model: model, systemPrompt: systemPrompt)
    }

    // MARK: - Private: vision frame extraction

    /// Parse timestamp patterns from `text`, extract ≤3 frames from attached
    /// sessions' screen.mp4, and return the image parts + a human-readable footer.
    private func extractFramesForTimestamps(in text: String) async -> ([ChatMessage.Part], String) {
        let timestamps = parseTimestamps(from: text)
        guard !timestamps.isEmpty else { return ([], "") }

        // Collect sessions that have a screen.mp4 sidecar.
        let sessionsWithVideo: [(id: String, videoURL: URL)] = await withTaskGroup(
            of: (String, URL?).self
        ) { group in
            for attachment in attachedSessions {
                let id = attachment.record.id
                group.addTask {
                    let dir = await self.sessionStore.sessionDir(for: id)
                    let videoURL = dir.appendingPathComponent("screen.mp4")
                    guard FileManager.default.fileExists(atPath: videoURL.path) else { return (id, nil) }
                    return (id, videoURL)
                }
            }
            var results: [(String, URL?)] = []
            for await pair in group { results.append(pair) }
            return results
        }.compactMap { (id, url) -> (id: String, videoURL: URL)? in
            guard let url else { return nil }
            return (id: id, videoURL: url)
        }

        guard !sessionsWithVideo.isEmpty else { return ([], "") }

        var imageParts: [ChatMessage.Part] = []
        var footerLines: [String] = []
        let maxFrames = 3

        // For each timestamp, try to extract a frame from the first session that has video.
        outer: for seconds in timestamps {
            for session in sessionsWithVideo {
                guard imageParts.count < maxFrames else { break outer }
                do {
                    let jpegData = try await FrameExtractor.extractFrame(at: seconds, from: session.videoURL)
                    imageParts.append(.image(jpegData: jpegData, mimeType: "image/jpeg"))
                    let label = formatTimestamp(seconds)
                    let shortId = String(session.id.prefix(8))
                    footerLines.append("frame from session \(shortId) at \(label)")
                    break  // one frame per timestamp (first session wins)
                } catch {
                    // Skip silently — the session might be audio-only or too short.
                    continue
                }
            }
        }

        guard !imageParts.isEmpty else { return ([], "") }
        let footer = "\n\n[Attached: \(footerLines.joined(separator: ", "))]"
        return (imageParts, footer)
    }

    /// Parse all timestamp-like patterns from a string and return seconds values.
    ///
    /// Supported:
    ///   `12:34`        → m:ss
    ///   `0:12:34`      → h:mm:ss
    ///   `at minute 5`  → 5 * 60
    ///   `на 3 хвилині` / `на 3 хвилини` / `на 3 хвилинах` → 3 * 60
    private func parseTimestamps(from text: String) -> [TimeInterval] {
        var results: [TimeInterval] = []
        var seen = Set<TimeInterval>()

        func add(_ t: TimeInterval) {
            guard t >= 0, !seen.contains(t) else { return }
            seen.insert(t)
            results.append(t)
        }

        // h:mm:ss  (e.g. 1:23:45)
        let hmmss = try? NSRegularExpression(pattern: #"\b(\d+):(\d{2}):(\d{2})\b"#)
        if let matches = hmmss?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let h = Int(substring(text, range: m.range(at: 1))) ?? 0
                let min = Int(substring(text, range: m.range(at: 2))) ?? 0
                let sec = Int(substring(text, range: m.range(at: 3))) ?? 0
                add(TimeInterval(h * 3600 + min * 60 + sec))
            }
        }

        // m:ss  (e.g. 5:32) — must NOT be part of an h:mm:ss match already seen.
        let mss = try? NSRegularExpression(pattern: #"(?<!\d:)\b(\d+):(\d{2})\b(?!:\d)"#)
        if let matches = mss?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let min = Int(substring(text, range: m.range(at: 1))) ?? 0
                let sec = Int(substring(text, range: m.range(at: 2))) ?? 0
                add(TimeInterval(min * 60 + sec))
            }
        }

        // English: "at minute N" or "minute N"
        let enMin = try? NSRegularExpression(pattern: #"\b(?:at )?minute (\d+)\b"#, options: .caseInsensitive)
        if let matches = enMin?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let n = Int(substring(text, range: m.range(at: 1))) ?? 0
                add(TimeInterval(n * 60))
            }
        }

        // Ukrainian: "на N хвилині/хвилини/хвилинах"
        let ukMin = try? NSRegularExpression(pattern: #"\bна (\d+) хвилин(?:і|и|ах)\b"#)
        if let matches = ukMin?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for m in matches {
                let n = Int(substring(text, range: m.range(at: 1))) ?? 0
                add(TimeInterval(n * 60))
            }
        }

        return results
    }

    private func substring(_ text: String, range: NSRange) -> String {
        guard let r = Range(range, in: text) else { return "" }
        return String(text[r])
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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
