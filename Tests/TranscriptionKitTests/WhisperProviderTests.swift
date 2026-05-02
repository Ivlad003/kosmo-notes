import Foundation
import Testing
@testable import TranscriptionKit

// MARK: - Multipart request building

@Suite("WhisperProvider request builder")
struct WhisperProviderRequestTests {

    @Test("Builds POST with bearer auth + multipart Content-Type")
    func buildsAuthAndContentType() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-test-1234",
            model: "whisper-1",
            audioData: Data([0x00, 0x01, 0x02]),
            audioFilename: "audio.m4a",
            config: TranscriptionConfig()
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url == WhisperProvider.defaultEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-1234")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"))
    }

    @Test("Includes model field in body")
    func includesModelField() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-x",
            model: "whisper-1",
            audioData: Data([0x00]),
            audioFilename: "a.m4a",
            config: TranscriptionConfig()
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("name=\"model\""))
        #expect(body.contains("whisper-1"))
    }

    @Test("Always requests verbose_json response format")
    func requestsVerboseJSON() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-x",
            model: "whisper-1",
            audioData: Data([0x00]),
            audioFilename: "a.m4a",
            config: TranscriptionConfig()
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("name=\"response_format\""))
        #expect(body.contains("verbose_json"))
    }

    @Test("Includes language field when config.language is set")
    func includesLanguageWhenSet() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-x",
            model: "whisper-1",
            audioData: Data([0x00]),
            audioFilename: "a.m4a",
            config: TranscriptionConfig(language: "uk")
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("name=\"language\""))
        #expect(body.contains("uk"))
    }

    @Test("Omits language field when config.language is nil (auto-detect)")
    func omitsLanguageWhenNil() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-x",
            model: "whisper-1",
            audioData: Data([0x00]),
            audioFilename: "a.m4a",
            config: TranscriptionConfig(language: nil)
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("name=\"language\""))
    }

    @Test("File field uses correct mime type for .m4a")
    func mimeTypeForM4A() throws {
        let request = try WhisperProvider.buildRequest(
            endpoint: WhisperProvider.defaultEndpoint,
            apiKey: "sk-x",
            model: "whisper-1",
            audioData: Data([0x00]),
            audioFilename: "test.m4a",
            config: TranscriptionConfig()
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("Content-Type: audio/m4a"))
        #expect(body.contains("filename=\"test.m4a\""))
    }
}

// MARK: - Response parsing

@Suite("WhisperProvider response parser")
struct WhisperProviderParserTests {

    @Test("Parses verbose_json with segments")
    func parsesVerboseJSON() throws {
        let json = """
        {
          "task": "transcribe",
          "language": "english",
          "duration": 3.2,
          "text": "hello world goodbye",
          "segments": [
            {"start": 0.0, "end": 1.5, "text": "hello world", "no_speech_prob": 0.05},
            {"start": 1.5, "end": 3.2, "text": "goodbye", "no_speech_prob": 0.10}
          ]
        }
        """
        let result = try WhisperProvider.parse(data: Data(json.utf8))
        #expect(result.language == "english")
        #expect(result.duration == 3.2)
        #expect(result.text == "hello world goodbye")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "hello world")
        #expect(result.segments[0].start == 0.0)
        #expect(result.segments[0].end == 1.5)
        #expect(abs(result.segments[0].confidence - 0.95) < 0.001)
        #expect(result.segments[1].text == "goodbye")
    }

    @Test("Parses text-only response (no segments) into a single segment")
    func parsesTextOnly() throws {
        let json = """
        {
          "text": "just some text",
          "language": "uk",
          "duration": 1.5
        }
        """
        let result = try WhisperProvider.parse(data: Data(json.utf8))
        #expect(result.text == "just some text")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "just some text")
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 1.5)
    }

    @Test("Throws decodingFailed on malformed JSON")
    func malformedJSONThrows() {
        #expect(throws: TranscriptionError.self) {
            try WhisperProvider.parse(data: Data("{bogus".utf8))
        }
    }

    @Test("Trims whitespace from segment text")
    func trimsWhitespace() throws {
        let json = """
        {
          "text": "hi",
          "duration": 1.0,
          "segments": [
            {"start": 0, "end": 1, "text": "  hi  \\n", "no_speech_prob": 0.0}
          ]
        }
        """
        let result = try WhisperProvider.parse(data: Data(json.utf8))
        #expect(result.segments[0].text == "hi")
    }
}

// MARK: - End-to-end via mock HTTP client

@Suite("WhisperProvider end-to-end with mock HTTP")
struct WhisperProviderE2ETests {

    /// Helper: write a tmp audio file with arbitrary bytes for upload.
    private func makeTempAudioFile(bytes: Data = Data([0x01, 0x02, 0x03])) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("whisper-test-\(UUID().uuidString).m4a")
        try bytes.write(to: url)
        return url
    }

    @Test("Successful 200 response yields parsed segments")
    func successfulResponse() async throws {
        let audio = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let mockResponse = """
        {"text":"hi","language":"en","duration":1.0,"segments":[{"start":0,"end":1,"text":"hi","no_speech_prob":0.05}]}
        """

        let provider = WhisperProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(url: WhisperProvider.defaultEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(mockResponse.utf8), resp)
        })

        let result = try await provider.transcribe(audioFile: audio, config: TranscriptionConfig(language: "en"))
        #expect(result.text == "hi")
        #expect(result.language == "en")
        #expect(result.segments.count == 1)
    }

    @Test("401 response throws authenticationFailed")
    func unauthorized() async throws {
        let audio = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let provider = WhisperProvider(apiKey: "sk-bad", httpClient: { _ in
            let resp = HTTPURLResponse(url: WhisperProvider.defaultEndpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{\"error\":\"invalid_api_key\"}".utf8), resp)
        })

        await #expect(throws: TranscriptionError.self) {
            _ = try await provider.transcribe(audioFile: audio, config: TranscriptionConfig())
        }
    }

    @Test("500 response throws receiveFailed with body")
    func serverError() async throws {
        let audio = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let provider = WhisperProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(url: WhisperProvider.defaultEndpoint, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data("internal server error".utf8), resp)
        })

        await #expect(throws: TranscriptionError.self) {
            _ = try await provider.transcribe(audioFile: audio, config: TranscriptionConfig())
        }
    }

    @Test("Audio file body is sent in the multipart request")
    func audioFileSent() async throws {
        let audio = try makeTempAudioFile(bytes: Data("AUDIO_BYTES".utf8))
        defer { try? FileManager.default.removeItem(at: audio) }

        // Capture the request the provider sends
        final class Box: @unchecked Sendable {
            var captured: URLRequest?
        }
        let box = Box()

        let provider = WhisperProvider(apiKey: "sk-x", httpClient: { request in
            box.captured = request
            let resp = HTTPURLResponse(url: WhisperProvider.defaultEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"text\":\"\",\"duration\":0}".utf8), resp)
        })

        _ = try await provider.transcribe(audioFile: audio, config: TranscriptionConfig())

        let body = box.captured?.httpBody ?? Data()
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyString.contains("AUDIO_BYTES"))
    }
}
