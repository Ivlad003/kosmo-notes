import Foundation

/// One of the 8 external dependencies has a lifecycle state. v1.0 wires:
/// - `Anthropic` (LLM)
/// - `Ollama` (LLM, local HTTP)
/// - `Deepgram` (transcription)
public enum DependencyState: String, Codable, Sendable {
    case unconfigured   // default; no credentials/endpoint set
    case configured     // credentials set, never tested
    case reachable      // last test/request succeeded
    case degraded       // transient failures (5xx, 429); recovery probe pending
    case unavailable    // persistent failures (4xx auth, DNS, endpoint dead)
}

public struct DependencyStatus: Codable, Sendable {
    public let id: String              // canonical name: "anthropic", "ollama", "deepgram"
    public var state: DependencyState
    public var lastTransition: Date
    public var reason: String?         // human-readable for `degraded` / `unavailable`

    public init(id: String, state: DependencyState, lastTransition: Date, reason: String? = nil) {
        self.id = id
        self.state = state
        self.lastTransition = lastTransition
        self.reason = reason
    }
}

public protocol Dependency: Sendable {
    var id: String { get }
    func test() async throws            // throws on failure
    var current: DependencyStatus { get async }
}
