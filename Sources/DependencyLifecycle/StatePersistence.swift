import Foundation
import StorageKit

/// Persisted snapshot of all 8 (eventually) dependency states.
/// Stored at `<data_dir>/state/dependencies.json` via AtomicWriter.
public struct DependencyStateSnapshot: Codable, Sendable {
    public var dependencies: [String: DependencyStatus]
    public var schemaVersion: Int

    public init(dependencies: [String: DependencyStatus] = [:], schemaVersion: Int = 1) {
        self.dependencies = dependencies
        self.schemaVersion = schemaVersion
    }
}

public actor StatePersistence {
    private let url: URL
    private var cached: DependencyStateSnapshot

    public init(url: URL) throws {
        self.url = url
        // Load on init; treat corrupt-on-read as empty + log
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(DependencyStateSnapshot.self, from: data) {
            self.cached = snap
        } else {
            self.cached = DependencyStateSnapshot(dependencies: [:])
        }
    }

    public func get(_ id: String) -> DependencyStatus? {
        cached.dependencies[id]
    }

    public func update(_ status: DependencyStatus) async throws {
        cached.dependencies[status.id] = status
        try AtomicWriter.writeJSON(cached, to: url)
    }
}
