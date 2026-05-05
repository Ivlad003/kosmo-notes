import Foundation
import os

private let whisperLog = Logger(subsystem: "dev.kosmonotes.studio", category: "WhisperProvider")

// MARK: - WhisperProvider

/// `BatchTranscriptionProvider` for OpenAI's Whisper API
/// (`POST https://api.openai.com/v1/audio/transcriptions`).
///
/// Whisper accepts a single audio file (m4a, mp3, mp4, mpeg, mpga, wav, webm),
/// returns the full transcript as JSON. For `whisper-1` we request
/// `verbose_json` to get per-segment start/end timestamps; the
/// `gpt-4o-transcribe` family rejects `verbose_json` (HTTP 400 with
/// `unsupported_value` on `response_format`) and only supports `json` /
/// `text`, so we fall back to `json` and synthesize a single full-text
/// segment in the parser. Trade-off: gpt-4o models have higher accuracy
/// but no segment-level timing, so transcripts lose `[mm:ss]` markers.
///
/// **Length limits & auto-chunking.** OpenAI imposes:
/// - 25 MB per upload (all models).
/// - 1400 s per request (gpt-4o-transcribe / gpt-4o-mini-transcribe).
///
/// For recordings beyond `maxChunkDuration` (default 1200 s, well under
/// the 1400 s gpt-4o ceiling and the 25 MB body limit at our 96 kbps AAC),
/// `transcribe(audioFile:config:)` automatically slices the input via
/// `AudioChunker`, transcribes each chunk, and merges results with
/// segment timestamps shifted by each chunk's offset. Temp chunk files
/// are cleaned up before return.
public final class WhisperProvider: BatchTranscriptionProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Stored

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let maxChunkDuration: TimeInterval
    private let httpClient: HTTPClient

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = WhisperProvider.defaultEndpoint,
        model: String = "whisper-1",
        maxChunkDuration: TimeInterval = 1200,
        httpClient: @escaping HTTPClient = WhisperProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.maxChunkDuration = maxChunkDuration
        self.httpClient = httpClient
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: BatchTranscriptionProvider

    public func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        let chunker = AudioChunker()
        let chunks: [AudioChunker.Chunk]
        do {
            chunks = try await chunker.chunk(audioFile: audioFile, maxChunkDuration: maxChunkDuration)
        } catch {
            // If chunking fails (corrupt asset, no audio tracks, etc.), don't
            // hide the failure behind a fallback that the API will reject anyway.
            // Surface a clean error so the user sees what really broke.
            whisperLog.error("WhisperProvider.transcribe: chunker failed — \(error.localizedDescription, privacy: .public)")
            throw TranscriptionError.sendFailed(message: "Could not prepare audio for upload: \(error.localizedDescription)")
        }

        // Single-chunk fast path: no temp dir, no merging, no cleanup.
        if chunks.count == 1, chunks[0].url == audioFile {
            return try await transcribeSingle(audioFile: audioFile, config: config)
        }

        whisperLog.info("WhisperProvider.transcribe: chunked \(audioFile.lastPathComponent, privacy: .public) into \(chunks.count, privacy: .public) parts (max \(self.maxChunkDuration, privacy: .public) s each)")

        // Multi-chunk path. Always clean up the temp dir on exit, even on throw.
        let tempDir = chunker.tempDirectory(for: chunks, originalAudioFile: audioFile)
        defer {
            if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        }

        var mergedSegments: [TranscriptSegment] = []
        var mergedTexts: [String] = []
        var totalDuration: TimeInterval = 0
        var detectedLanguage: String? = nil

        for (idx, chunk) in chunks.enumerated() {
            whisperLog.info("WhisperProvider.transcribe: uploading chunk \(idx + 1, privacy: .public)/\(chunks.count, privacy: .public) (start=\(chunk.startTime, privacy: .public)s dur=\(chunk.duration, privacy: .public)s)")
            let result = try await transcribeSingle(audioFile: chunk.url, config: config)
            let offset = chunk.startTime
            for seg in result.segments {
                mergedSegments.append(TranscriptSegment(
                    start: seg.start + offset,
                    end: seg.end + offset,
                    text: seg.text,
                    confidence: seg.confidence,
                    isFinal: seg.isFinal,
                    speaker: seg.speaker
                ))
            }
            // Trim to avoid double-spaces between chunks.
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { mergedTexts.append(trimmed) }
            totalDuration = max(totalDuration, offset + result.duration)
            if detectedLanguage == nil { detectedLanguage = result.language }
        }

        return BatchTranscriptResult(
            language: detectedLanguage,
            duration: totalDuration,
            segments: mergedSegments,
            text: mergedTexts.joined(separator: " ")
        )
    }

    /// Transcribe a single (already-bounded) audio file. Used both by the
    /// single-chunk fast path and as the inner call for each chunk in the
    /// multi-chunk path.
    private func transcribeSingle(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            throw TranscriptionError.sendFailed(message: "Could not read audio file: \(error.localizedDescription)")
        }

        let request = try Self.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            audioData: audioData,
            audioFilename: audioFile.lastPathComponent,
            config: config
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw TranscriptionError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.receiveFailed(message: "Non-HTTP response from Whisper API")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parse(data: data)
        case 401:
            // Log the actual response body so users debugging via Console.app
            // see the exact OpenAI message ("Invalid API key", "model not
            // available to your tier", etc). The user-facing alert text comes
            // from TranscriptionError.errorDescription which already mentions
            // the gpt-4o-transcribe org-verification gotcha.
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            whisperLog.error("Whisper 401 with model=\(self.model, privacy: .public). Response body: \(body, privacy: .public)")
            throw TranscriptionError.authenticationFailed
        default:
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            whisperLog.error("Whisper \(httpResponse.statusCode, privacy: .public) with model=\(self.model, privacy: .public). Response body: \(body, privacy: .public)")
            throw TranscriptionError.receiveFailed(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    // MARK: - Multipart request builder (internal for tests)

    static func buildRequest(
        endpoint: URL,
        apiKey: String,
        model: String,
        audioData: Data,
        audioFilename: String,
        config: TranscriptionConfig
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model
        appendField(name: "model", value: model, boundary: boundary, into: &body)
        // response_format — verbose_json gives per-segment timing on `whisper-1`
        // (legacy Large-v2). The newer `gpt-4o-transcribe` family rejects
        // verbose_json with HTTP 400 (response_format = unsupported_value), so
        // fall back to plain `json` for any model whose name doesn't start with
        // "whisper". `parse(...)` handles both response shapes.
        let responseFormat = model.hasPrefix("whisper") ? "verbose_json" : "json"
        appendField(name: "response_format", value: responseFormat, boundary: boundary, into: &body)
        // language (optional — omit for auto-detect)
        if let language = config.language {
            appendField(name: "language", value: language, boundary: boundary, into: &body)
        }
        // file
        appendFile(name: "file", filename: audioFilename, mimeType: mimeType(for: audioFilename), data: audioData, boundary: boundary, into: &body)
        // closing
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    // MARK: - Response parser (internal for tests)

    static func parse(data: Data) throws -> BatchTranscriptResult {
        let response: WhisperResponse
        do {
            response = try JSONDecoder().decode(WhisperResponse.self, from: data)
        } catch {
            throw TranscriptionError.decodingFailed(message: error.localizedDescription)
        }

        let segments: [TranscriptSegment]
        if let raw = response.segments, !raw.isEmpty {
            segments = raw.map { seg in
                // Whisper's `no_speech_prob` is "probability that this segment is silence/noise".
                // Approximate confidence as 1 - no_speech_prob, clamped to [0, 1].
                let confidence = max(0.0, min(1.0, 1.0 - (seg.noSpeechProb ?? 0)))
                return TranscriptSegment(
                    start: seg.start,
                    end: seg.end,
                    text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: confidence,
                    isFinal: true,
                    speaker: nil
                )
            }
        } else {
            // Text-only response — synthesize a single segment.
            segments = [
                TranscriptSegment(
                    start: 0,
                    end: response.duration ?? 0,
                    text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: 0.9,
                    isFinal: true,
                    speaker: nil
                ),
            ]
        }

        return BatchTranscriptResult(
            language: response.language,
            duration: response.duration ?? 0,
            segments: segments,
            text: response.text
        )
    }

    // MARK: - Helpers

    private static func appendField(name: String, value: String, boundary: String, into body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private static func appendFile(name: String, filename: String, mimeType: String, data: Data, boundary: String, into body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "m4a", "mp4": return "audio/m4a"
        case "mp3", "mpga": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "ogg", "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Whisper JSON model (private)

private struct WhisperResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [WhisperSegment]?
}

private struct WhisperSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
    let noSpeechProb: Double?

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case noSpeechProb = "no_speech_prob"
    }
}
