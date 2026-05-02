import Foundation
import Testing
@testable import StorageKit

@Suite("AtomicWriter")
struct AtomicWriterTests {

    @Test("write and read back small data")
    func writeAndRead_smallData() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let original = Data(repeating: 0xAB, count: 100)
        try AtomicWriter.write(original, to: url)
        let read = try Data(contentsOf: url)
        #expect(original == read)
    }

    @Test("overwrite replaces content")
    func writeOverwrite() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = Data(repeating: 0x01, count: 100)
        let second = Data(repeating: 0x02, count: 50)
        try AtomicWriter.write(first, to: url)
        try AtomicWriter.write(second, to: url)
        let read = try Data(contentsOf: url)
        #expect(second == read)
        #expect(read.count == 50)
    }

    @Test("no leftover tmp files after successful write")
    func writeCreatesNoLeftoverTmpFiles() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = Data(repeating: 0xFF, count: 100)
        try AtomicWriter.write(data, to: url)

        let dir = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tmpFiles = contents.filter {
            $0.hasPrefix(fileName) && $0.contains(".tmp.")
        }
        #expect(tmpFiles.isEmpty, "Found leftover tmp files: \(tmpFiles)")
    }

    @Test("JSON round-trip")
    func writeJSON_roundTrip() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        struct Payload: Codable, Equatable {
            let name: String
            let count: Int
        }
        let original = Payload(name: "jarvis", count: 42)
        try AtomicWriter.writeJSON(original, to: url)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        #expect(original == decoded)
    }

    @Test("write failure cleans up tmp file")
    func writeFailureCleansUpTmp() throws {
        // Write to a path under a non-existent deeply nested directory
        let forbiddenURL = URL(fileURLWithPath: "/System/Volumes/Preboot/cannot-write-here/\(UUID().uuidString)/file.json")
        let data = Data(repeating: 0x00, count: 10)

        #expect(throws: (any Error).self) {
            try AtomicWriter.write(data, to: forbiddenURL)
        }

        // The directory doesn't exist so no tmp file could have been created
        let dir = forbiddenURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let tmpFiles = contents.filter { $0.contains(".tmp.") }
            #expect(tmpFiles.isEmpty, "Found leftover tmp files: \(tmpFiles)")
        }
    }
}
