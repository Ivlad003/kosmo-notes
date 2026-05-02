import Foundation
import Testing
@testable import DependencyLifecycle

@Suite("StatePersistence")
struct DependencyLifecycleTests {

    private func makeTempURL() -> URL {
        URL.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    @Test("fresh instance returns nil for any id")
    func initialStateIsUnconfigured() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let persistence = try StatePersistence(url: url)
        let result = await persistence.get("anthropic")
        #expect(result == nil)
    }

    @Test("update then get returns stored state")
    func updateAndGet() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let persistence = try StatePersistence(url: url)
        let status = DependencyStatus(id: "anthropic", state: .configured, lastTransition: Date())
        try await persistence.update(status)
        let retrieved = await persistence.get("anthropic")
        #expect(retrieved?.state == .configured)
        #expect(retrieved?.id == "anthropic")
    }

    @Test("state transitions persist through each step")
    func transition() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let persistence = try StatePersistence(url: url)
        let id = "anthropic"
        let now = Date()

        // unconfigured → configured
        try await persistence.update(DependencyStatus(id: id, state: .configured, lastTransition: now))
        #expect((await persistence.get(id))?.state == .configured)

        // configured → reachable
        try await persistence.update(DependencyStatus(id: id, state: .reachable, lastTransition: now))
        #expect((await persistence.get(id))?.state == .reachable)

        // reachable → degraded
        try await persistence.update(DependencyStatus(id: id, state: .degraded, lastTransition: now, reason: "503 from API"))
        let afterDegrade = await persistence.get(id)
        #expect(afterDegrade?.state == .degraded)
        #expect(afterDegrade?.reason == "503 from API")

        // degraded → reachable (recovery)
        try await persistence.update(DependencyStatus(id: id, state: .reachable, lastTransition: now))
        #expect((await persistence.get(id))?.state == .reachable)
    }

    @Test("corrupt file treated as empty snapshot")
    func corruptFileTreatedAsEmpty() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF]).write(to: url)
        let persistence = try StatePersistence(url: url)
        let result = await persistence.get("anthropic")
        #expect(result == nil)
    }

    @Test("two instances reading same URL share state")
    func twoStatePersistencesShareDisk() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let instanceA = try StatePersistence(url: url)
        let status = DependencyStatus(id: "deepgram", state: .reachable, lastTransition: Date())
        try await instanceA.update(status)

        let instanceB = try StatePersistence(url: url)
        let retrieved = await instanceB.get("deepgram")
        #expect(retrieved?.state == .reachable)
        #expect(retrieved?.id == "deepgram")
    }
}
