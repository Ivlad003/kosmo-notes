import Foundation

// MARK: - ReconnectClock

/// Abstraction over wall-clock sleeping, so tests can verify backoff schedule
/// without paying real wall-clock time.
public protocol ReconnectClock: Sendable {
    func sleep(seconds: Double) async
}

// MARK: - SystemClock

/// Production clock — delegates to `Task.sleep`.
public struct SystemClock: ReconnectClock {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - ReconnectingSession

/// A resilient wrapper around a sequence of `WebSocketTransport` connections.
///
/// On receive failure the session reopens a fresh transport using the injected
/// factory, replays the last 5-second audio ring buffer to the new transport,
/// then resumes normal operation. After 5 consecutive failures it finishes the
/// events stream and surfaces the final error.
///
/// The `events` stream is stable across reconnects — the consumer iterates one
/// stream end-to-end; each reconnect is transparent except for a brief gap.
public actor ReconnectingSession {

    // MARK: Public surface

    /// Single stable stream of transcript events — survives reconnects.
    public nonisolated let events: AsyncStream<TranscriptSegment>

    // MARK: Configuration

    /// Exponential backoff delays in seconds: 250ms → 500ms → 1s → 2s → 4s.
    /// After five consecutive failures the session gives up.
    static let backoffSchedule: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]
    static let maxRetries = 5

    // MARK: Private state

    private let continuation: AsyncStream<TranscriptSegment>.Continuation
    private let transportFactory: @Sendable () -> any WebSocketTransport
    private let parser: TranscriptionEventParser
    private let clock: any ReconnectClock

    /// Ring buffer: tuples of (wallClockDate, audioData).
    /// Entries older than 5 s are pruned before each reconnect replay.
    private var ringBuffer: [(timestamp: Date, data: Data)] = []
    private static let ringBufferWindow: TimeInterval = 5.0

    /// The active transport. Replaced on each reconnect.
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    // MARK: Init

    public init(
        transportFactory: @escaping @Sendable () -> any WebSocketTransport,
        parser: TranscriptionEventParser,
        clock: any ReconnectClock = SystemClock()
    ) {
        let (stream, cont) = AsyncStream<TranscriptSegment>.makeStream()
        self.events = stream
        self.continuation = cont
        self.transportFactory = transportFactory
        self.parser = parser
        self.clock = clock
    }

    // MARK: Public API

    /// Send raw PCM bytes to the active transport and push to the ring buffer.
    public func send(_ pcm: Data) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        guard let t = transport else { throw TranscriptionError.sendFailed(message: "no active transport") }
        do {
            try await t.send(.data(pcm))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
        // Buffer every chunk; prune old entries so we only keep last 5 s.
        let now = Date()
        ringBuffer.append((timestamp: now, data: pcm))
        pruneRingBuffer(before: now.addingTimeInterval(-Self.ringBufferWindow))
    }

    /// Send a text control message (e.g. CloseStream) to the active transport.
    public func send(text: String) async throws {
        if closed { throw TranscriptionError.alreadyClosed }
        guard let t = transport else { throw TranscriptionError.sendFailed(message: "no active transport") }
        do {
            try await t.send(.text(text))
        } catch {
            throw TranscriptionError.sendFailed(message: "\(error)")
        }
    }

    /// Graceful close. Flushes and terminates the events stream.
    public func finish(closeMessage: String? = nil) async throws {
        if closed { return }
        closed = true

        if let msg = closeMessage, let t = transport {
            try? await t.send(.text(msg))
        }

        // Allow receive task to drain final segments from close-ack.
        try? await Task.sleep(nanoseconds: 200_000_000)

        receiveTask?.cancel()
        transport?.close(code: .normalClosure)
        continuation.finish()
    }

    /// Abrupt close — drops in-flight segments.
    public func cancel() {
        if closed { return }
        closed = true
        receiveTask?.cancel()
        transport?.close(code: .abnormalClosure)
        continuation.finish()
    }

    // MARK: Internal bootstrap

    /// Opens the first transport and starts the receive/reconnect loop.
    func start() {
        guard receiveTask == nil, !closed else { return }
        let firstTransport = transportFactory()
        self.transport = firstTransport
        launchReceiveTask(consecutiveFailures: 0)
    }

    // MARK: Private — receive loop

    private func launchReceiveTask(consecutiveFailures: Int) {
        let cont = continuation
        let parser = self.parser

        receiveTask = Task.detached { [weak self] in
            guard let self else { return }

            // Drain messages from the current transport until it fails or is cancelled.
            let currentTransport: any WebSocketTransport
            if let t = await self.transport {
                currentTransport = t
            } else {
                return
            }

            while !Task.isCancelled {
                let message: WebSocketMessage
                do {
                    message = try await currentTransport.receive()
                } catch {
                    // Receive failed — decide whether to reconnect or give up.
                    if Task.isCancelled { break }
                    await self.handleReceiveFailure(
                        consecutiveFailures: consecutiveFailures,
                        cont: cont,
                        parser: parser
                    )
                    return  // launchReceiveTask re-entry handles the rest.
                }
                let segments = parser.parse(message)
                for segment in segments {
                    cont.yield(segment)
                }
            }
        }
    }

    private func handleReceiveFailure(
        consecutiveFailures: Int,
        cont: AsyncStream<TranscriptSegment>.Continuation,
        parser: TranscriptionEventParser
    ) async {
        if closed { return }

        let nextFailureCount = consecutiveFailures + 1

        guard nextFailureCount <= Self.maxRetries else {
            // Exhausted retries — finish the stream.
            cont.finish()
            closed = true
            return
        }

        // Wait before reconnecting. Index is failures-1 because first failure
        // uses index 0 of the schedule.
        let backoffIndex = min(nextFailureCount - 1, Self.backoffSchedule.count - 1)
        let delay = Self.backoffSchedule[backoffIndex]
        await clock.sleep(seconds: delay)

        if closed { return }

        // Close the stale transport before opening a fresh one.
        transport?.close(code: .abnormalClosure)

        let freshTransport = transportFactory()
        self.transport = freshTransport

        // Replay ring buffer contents (entries within the last 5 s) to the
        // new transport so Deepgram can re-process any audio it may have missed.
        let now = Date()
        pruneRingBuffer(before: now.addingTimeInterval(-Self.ringBufferWindow))
        for entry in ringBuffer {
            try? await freshTransport.send(.data(entry.data))
        }

        launchReceiveTask(consecutiveFailures: nextFailureCount)
    }

    // MARK: Helpers

    private func pruneRingBuffer(before cutoff: Date) {
        ringBuffer.removeAll { $0.timestamp < cutoff }
    }

    // MARK: Test seams

    /// Insert a ring-buffer entry with a back-dated timestamp. Used by tests to
    /// verify that chunks older than the 5-s window are pruned before replay.
    func injectStaleRingBufferEntry(data: Data, age: TimeInterval) {
        let timestamp = Date().addingTimeInterval(-age)
        ringBuffer.append((timestamp: timestamp, data: data))
    }
}

// MARK: - TranscriptionError additions

extension TranscriptionError {
    /// Maximum reconnect retries exceeded.
    public static let maxRetriesExceeded = TranscriptionError.receiveFailed(message: "max retries exceeded")
}
