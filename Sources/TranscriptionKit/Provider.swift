import Foundation

// MARK: - TranscriptionProvider

/// Provider protocol for streaming speech-to-text.
///
/// One provider may serve many sessions. Each call to `openSession` returns
/// an independent `TranscriptionSession` — its own connection, its own
/// transcript event stream.
public protocol TranscriptionProvider: Sendable {
    func openSession(config: TranscriptionConfig) async throws -> TranscriptionSession
}

// MARK: - TranscriptionSession

/// A single live transcription connection.
///
/// Lifecycle:
///   1. Caller obtains a session via `provider.openSession(config:)`.
///   2. Caller iterates `events` (an `AsyncStream<TranscriptSegment>`) on one task.
///   3. Caller calls `send(_:)` repeatedly with raw PCM bytes (linear16,
///      sample rate / channels per `TranscriptionConfig`).
///   4. Caller calls `finish()` when the audio stream ends; the session
///      flushes any final segments, closes the WebSocket cleanly, and
///      finishes `events`.
///   5. On error or cancellation, `cancel()` aborts immediately.
///
/// `TranscriptionSession` is an actor so the underlying transport is never
/// touched from two contexts at once.
public actor TranscriptionSession {

    // MARK: Public surface

    /// Stream of transcript events. Backpressure-free; if the consumer stalls,
    /// the buffer grows.
    public nonisolated let events: AsyncStream<TranscriptSegment>

    // MARK: Private state

    private let continuation: AsyncStream<TranscriptSegment>.Continuation
    private let transport: any WebSocketTransport
    private let parser: TranscriptionEventParser
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    // MARK: Init

    init(transport: any WebSocketTransport, parser: TranscriptionEventParser) {
        let (stream, cont) = AsyncStream<TranscriptSegment>.makeStream()
        self.events = stream
        self.continuation = cont
        self.transport = transport
        self.parser = parser
    }

    // MARK: Public API

    public func send(_ pcm: Data) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        do {
            try await transport.send(.data(pcm))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    public func send(text: String) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        do {
            try await transport.send(.text(text))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    /// Graceful close. Waits briefly for the server to flush final segments,
    /// then closes the WebSocket and finishes the event stream.
    public func finish(closeMessage: String? = nil) async throws {
        if closed { return }
        closed = true

        if let msg = closeMessage {
            try? await transport.send(.text(msg))
        }

        // Allow the receive task to drain final segments emitted in response
        // to the close message. 200 ms is generous; Deepgram typically responds
        // within ~50 ms.
        try? await Task.sleep(nanoseconds: 200_000_000)

        receiveTask?.cancel()
        transport.close(code: .normalClosure)
        continuation.finish()
    }

    /// Abrupt close. Drops any in-flight segments.
    public func cancel() {
        if closed { return }
        closed = true
        receiveTask?.cancel()
        transport.close(code: .abnormalClosure)
        continuation.finish()
    }

    // MARK: Internal — receive loop

    /// Start the background receive task. Called by the provider after
    /// constructing the session.
    func startReceiving() {
        guard receiveTask == nil else { return }
        let cont = continuation
        let parser = self.parser
        let transport = self.transport
        receiveTask = Task.detached {
            while !Task.isCancelled {
                let message: WebSocketMessage
                do {
                    message = try await transport.receive()
                } catch {
                    break
                }
                let segments = parser.parse(message)
                for segment in segments {
                    cont.yield(segment)
                }
            }
            cont.finish()
        }
    }
}

// MARK: - TranscriptionEventParser

/// Provider-specific WebSocket-message → `[TranscriptSegment]` decoder.
///
/// Defined as a struct rather than a protocol so it crosses actor boundaries
/// without Sendable-protocol-existential ceremony.
public struct TranscriptionEventParser: Sendable {
    public typealias Parse = @Sendable (WebSocketMessage) -> [TranscriptSegment]
    private let parser: Parse

    public init(_ parser: @escaping Parse) {
        self.parser = parser
    }

    public func parse(_ message: WebSocketMessage) -> [TranscriptSegment] {
        parser(message)
    }
}
