import Foundation
import os

private let geminiLog = Logger(subsystem: "dev.kosmonotes.studio", category: "GeminiAudioProvider")

// MARK: - GeminiAudioProvider

/// `BatchTranscriptionProvider` adapter over Google Gemini's audio-aware
/// `generateContent` endpoint.
///
/// Unlike Whisper / Deepgram (speech-only ASR), Gemini ingests the raw audio
/// alongside a text prompt and returns a single multimodal response. We ask
/// for a strict JSON schema (language + segments + full text) so the rest of
/// KosmoNotes (TranscriptStore, FTS, summary) can consume it the same way.
///
/// Limits:
/// - Inline base64 audio is fine up to a few MB; for longer recordings the
///   File API is the correct path. v1 of this provider uses inline only —
///   long-meeting support arrives when we wire the resumable upload.
/// - Gemini 2.5 Flash supports up to ~8h of audio context, so the bottleneck
///   is the inline-payload limit, not the model.
public final class GeminiAudioProvider: BatchTranscriptionProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum GeminiError: Error, Sendable {
        case audioReadFailed(underlying: Error)
        case audioTooLargeForInline(bytes: Int)
        case invalidEndpoint
        case unexpectedResponse(status: Int, body: String?)
        case parseFailed(underlying: Error)
        case noTranscript(safetyBlocked: Bool)
    }

    /// Maximum bytes we'll inline-base64 into a single request. Google's
    /// documented hard ceiling is ~20 MB; we cap at 18 MB to leave headroom
    /// for the rest of the JSON envelope. Beyond this, callers should
    /// transcode or chunk before retrying.
    public static let inlineAudioByteCap = 18 * 1024 * 1024

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let httpClient: HTTPClient

    public init(
        apiKey: String,
        model: String = "gemini-2.5-flash",
        endpoint: URL? = nil,
        httpClient: @escaping HTTPClient = GeminiAudioProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint ?? URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        self.httpClient = httpClient
    }

    public func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        geminiLog.info("GeminiAudioProvider.transcribe: file=\(audioFile.lastPathComponent, privacy: .public) model=\(self.model, privacy: .public) language=\(config.language ?? "auto", privacy: .public)")

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            geminiLog.error("GeminiAudioProvider: failed to read audio file — \(error.localizedDescription, privacy: .public)")
            throw GeminiError.audioReadFailed(underlying: error)
        }
        guard audioData.count <= Self.inlineAudioByteCap else {
            geminiLog.error("GeminiAudioProvider: audio is \(audioData.count, privacy: .public) bytes, over the inline cap")
            throw GeminiError.audioTooLargeForInline(bytes: audioData.count)
        }

        let mimeType = mimeType(for: audioFile)
        let prompt = buildPrompt(language: config.language)
        let body = buildRequestBody(mimeType: mimeType, audioBase64: audioData.base64EncodedString(), prompt: prompt)

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw GeminiError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600  // long meetings can take a minute or two
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await httpClient(request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.unexpectedResponse(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            geminiLog.error("GeminiAudioProvider: HTTP \(http.statusCode, privacy: .public) — \(bodyStr ?? "<nil>", privacy: .public)")
            throw GeminiError.unexpectedResponse(status: http.statusCode, body: bodyStr)
        }

        return try Self.parse(data: data)
    }

    // MARK: - Defaults

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: - Request building

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "wav":               return "audio/wav"
        case "mp3":               return "audio/mpeg"
        case "ogg", "opus":       return "audio/ogg"
        case "flac":              return "audio/flac"
        case "webm":              return "audio/webm"
        default:                  return "audio/mp4"
        }
    }

    private func buildPrompt(language: String?) -> String {
        let langClause: String
        if let l = language, !l.isEmpty, l.lowercased() != "auto" {
            langClause = "The audio is primarily in language code \"\(l)\". Output transcript in that same language without translating."
        } else {
            langClause = "Detect the spoken language and output transcript in the same language without translating."
        }
        return """
        Transcribe the attached audio precisely. \(langClause)

        Return ONLY a single JSON object matching this schema, with no surrounding markdown, no commentary, no code fences:
        {
          "language": "<detected BCP-47 code>",
          "segments": [
            { "start": <seconds, number>, "end": <seconds, number>, "text": "<utterance>" }
          ],
          "full_text": "<entire transcript joined>"
        }

        Rules:
        - Segment by natural pauses or speaker turns; aim for 5–15 s per segment.
        - "start" / "end" are seconds from the start of the audio (floating point).
        - Use punctuation and capitalization native to the language. Preserve filler words and meaning, but skip pure background noise.
        - If you can't transcribe a portion, omit that segment rather than guessing.
        """
    }

    private func buildRequestBody(mimeType: String, audioBase64: String, prompt: String) -> [String: Any] {
        return [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt],
                        ["inline_data": [
                            "mime_type": mimeType,
                            "data": audioBase64,
                        ]],
                    ],
                ],
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 65536,
                "responseMimeType": "application/json",
            ],
        ]
    }

    // MARK: - Response parsing

    /// Parse Gemini `generateContent` JSON into a `BatchTranscriptResult`.
    static func parse(data: Data) throws -> BatchTranscriptResult {
        struct Envelope: Decodable {
            let candidates: [Candidate]?
            let promptFeedback: PromptFeedback?
        }
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Part: Decodable {
            let text: String?
        }
        struct PromptFeedback: Decodable {
            let blockReason: String?
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            geminiLog.error("GeminiAudioProvider.parse: top-level JSON decode failed — \(error.localizedDescription, privacy: .public)")
            throw GeminiError.parseFailed(underlying: error)
        }

        if let blocked = envelope.promptFeedback?.blockReason, !blocked.isEmpty {
            geminiLog.error("GeminiAudioProvider.parse: prompt blocked by safety — \(blocked, privacy: .public)")
            throw GeminiError.noTranscript(safetyBlocked: true)
        }

        guard let raw = envelope.candidates?.first?.content?.parts?.first?.text,
              !raw.isEmpty else {
            throw GeminiError.noTranscript(safetyBlocked: false)
        }

        // Gemini sometimes wraps the JSON in ```json … ``` even when we ask
        // for raw — strip a leading code fence if present.
        let cleaned = stripMarkdownFence(raw)

        struct Inner: Decodable {
            let language: String?
            let segments: [InnerSegment]?
            let full_text: String?
        }
        struct InnerSegment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        let inner: Inner
        do {
            inner = try JSONDecoder().decode(Inner.self, from: Data(cleaned.utf8))
        } catch {
            geminiLog.error("GeminiAudioProvider.parse: inner JSON decode failed — \(error.localizedDescription, privacy: .public). raw head: \(String(cleaned.prefix(200)), privacy: .public)")
            throw GeminiError.parseFailed(underlying: error)
        }

        let segments: [TranscriptSegment] = (inner.segments ?? []).map { s in
            TranscriptSegment(
                start: s.start,
                end: s.end,
                text: s.text,
                confidence: 1.0,
                isFinal: true,
                speaker: nil
            )
        }
        let duration = segments.last?.end ?? 0
        let fullText = inner.full_text
            ?? segments.map { $0.text }.joined(separator: " ")

        return BatchTranscriptResult(
            language: inner.language,
            duration: duration,
            segments: segments,
            text: fullText
        )
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
