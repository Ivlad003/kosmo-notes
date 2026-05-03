import Foundation

// MARK: - DeepgramBatchProvider

/// `BatchTranscriptionProvider` adapter over Deepgram's REST endpoint
/// `https://api.deepgram.com/v1/listen`. Used by RecorderState when the user
/// picks Deepgram in Settings — uploads the whole `audio.m4a` after Stop and
/// gets back a single transcript with word-level timestamps.
///
/// This is intentionally separate from the streaming `DeepgramProvider`: same
/// vendor, same auth, completely different I/O shape. The streaming provider
/// stays for v1.1 when capture grows a PCM tee.
public final class DeepgramBatchProvider: BatchTranscriptionProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let httpClient: HTTPClient

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/listen")!,
        model: String = "nova-2",
        httpClient: @escaping HTTPClient = DeepgramBatchProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.httpClient = httpClient
    }

    public func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        // Build URL: /v1/listen?model=…&punctuate=true[&language=…]
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        if let language = config.language, !language.isEmpty, language.lowercased() != "auto" {
            items.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw DeepgramBatchError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            throw DeepgramBatchError.audioReadFailed(underlying: error)
        }
        request.httpBody = audioData

        let (data, response) = try await httpClient(request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepgramBatchError.unexpectedResponse(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw DeepgramBatchError.unexpectedResponse(status: http.statusCode, body: body)
        }

        return try Self.parse(data: data)
    }

    // MARK: - Defaults

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: - Parsing

    /// Parse Deepgram batch JSON into a `BatchTranscriptResult`.
    /// Schema: `results.channels[0].alternatives[0]` carries the transcript
    /// + word-level timing; `metadata.duration` carries the audio length.
    static func parse(data: Data) throws -> BatchTranscriptResult {
        struct Envelope: Decodable {
            let results: ResultsBlock
            let metadata: MetadataBlock?
        }
        struct ResultsBlock: Decodable {
            let channels: [Channel]
        }
        struct Channel: Decodable {
            let alternatives: [Alternative]
            let detected_language: String?
        }
        struct Alternative: Decodable {
            let transcript: String
            let words: [Word]?
        }
        struct Word: Decodable {
            let start: Double
            let end: Double
            let punctuated_word: String?
            let word: String
        }
        struct MetadataBlock: Decodable {
            let duration: Double?
        }

        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw DeepgramBatchError.parseFailed(underlying: error)
        }

        guard let channel = env.results.channels.first,
              let alt = channel.alternatives.first else {
            throw DeepgramBatchError.noTranscript
        }

        let duration = env.metadata?.duration ?? 0
        let language = channel.detected_language

        // Group words into ~5 s "segments" so the Library transcript view stays
        // readable — Deepgram returns one word per timestamp, which would make
        // 1000-row tables for a 20-min meeting.
        let words = alt.words ?? []
        var segments: [TranscriptSegment] = []
        if words.isEmpty {
            // No word-level timing: synthesize a single segment.
            segments.append(TranscriptSegment(
                start: 0,
                end: duration,
                text: alt.transcript,
                confidence: 1.0,
                isFinal: true,
                speaker: nil
            ))
        } else {
            var cursor = 0
            while cursor < words.count {
                let segmentStart = words[cursor].start
                let cutoff = segmentStart + 5.0
                var endIndex = cursor
                while endIndex < words.count && words[endIndex].end <= cutoff {
                    endIndex += 1
                }
                if endIndex == cursor { endIndex = cursor + 1 }
                let chunk = words[cursor..<endIndex]
                let text = chunk
                    .map { $0.punctuated_word ?? $0.word }
                    .joined(separator: " ")
                let segmentEnd = chunk.last?.end ?? segmentStart
                segments.append(TranscriptSegment(
                    start: segmentStart,
                    end: segmentEnd,
                    text: text,
                    confidence: 1.0,
                    isFinal: true,
                    speaker: nil
                ))
                cursor = endIndex
            }
        }

        return BatchTranscriptResult(
            language: language,
            duration: duration,
            segments: segments,
            text: alt.transcript
        )
    }
}

// MARK: - Errors

public enum DeepgramBatchError: Error, Sendable {
    case invalidEndpoint
    case audioReadFailed(underlying: Error)
    case unexpectedResponse(status: Int, body: String?)
    case parseFailed(underlying: Error)
    case noTranscript
}
