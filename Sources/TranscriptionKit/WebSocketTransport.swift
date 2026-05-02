import Foundation

// MARK: - WebSocketMessage

/// A message sent or received on a WebSocket.
///
/// Mirrors `URLSessionWebSocketTask.Message` but is provider-agnostic so tests
/// can inject a mock transport without depending on URLSession internals.
public enum WebSocketMessage: Sendable, Equatable {
    case data(Data)
    case text(String)
}

// MARK: - WebSocketCloseCode

public enum WebSocketCloseCode: Sendable {
    case normalClosure
    case abnormalClosure
}

// MARK: - WebSocketTransport

/// Abstraction over a WebSocket connection. The real impl wraps
/// `URLSessionWebSocketTask`; tests inject a `MockWebSocketTransport`.
///
/// Conformers must be thread-safe (Sendable) — `send`, `receive`, and `close`
/// may be called from independent tasks.
public protocol WebSocketTransport: Sendable {
    func send(_ message: WebSocketMessage) async throws
    /// Block until one message arrives. Throws on connection close or error.
    func receive() async throws -> WebSocketMessage
    func close(code: WebSocketCloseCode)
}

// MARK: - URLSessionWebSocketTransport

/// Production transport using `URLSessionWebSocketTask`.
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {

    private let task: URLSessionWebSocketTask

    public init(url: URL, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        self.task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .data(let d):
            try await task.send(.data(d))
        case .text(let s):
            try await task.send(.string(s))
        }
    }

    public func receive() async throws -> WebSocketMessage {
        let message = try await task.receive()
        switch message {
        case .data(let d):
            return .data(d)
        case .string(let s):
            return .text(s)
        @unknown default:
            throw TranscriptionError.receiveFailed(message: "Unknown WebSocket message kind")
        }
    }

    public func close(code: WebSocketCloseCode) {
        let urlCode: URLSessionWebSocketTask.CloseCode
        switch code {
        case .normalClosure: urlCode = .normalClosure
        case .abnormalClosure: urlCode = .abnormalClosure
        }
        task.cancel(with: urlCode, reason: nil)
    }
}
