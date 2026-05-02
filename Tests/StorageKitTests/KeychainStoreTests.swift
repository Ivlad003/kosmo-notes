import Foundation
import Testing
@testable import StorageKit

@Suite("KeychainStore")
struct KeychainStoreTests {

    private let store = KeychainStore()

    @Test("set → get → remove round trip")
    func roundTrip() throws {
        let account = "test-\(UUID().uuidString)"
        let value = "super-secret-api-key-\(UUID().uuidString)"
        defer { try? store.remove(account: account) }

        try store.set(value, account: account)
        let retrieved = try store.get(account: account)
        #expect(retrieved == value)

        try store.remove(account: account)
        let afterRemove = try store.contains(account: account)
        #expect(afterRemove == false)
    }

    @Test("get on missing account returns nil")
    func getMissingAccount() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? store.remove(account: account) }

        let result = try store.get(account: account)
        #expect(result == nil)
    }

    @Test("overwrite returns new value")
    func overwrite() throws {
        let account = "test-\(UUID().uuidString)"
        let valueA = "value-A-\(UUID().uuidString)"
        let valueB = "value-B-\(UUID().uuidString)"
        defer { try? store.remove(account: account) }

        try store.set(valueA, account: account)
        try store.set(valueB, account: account)
        let retrieved = try store.get(account: account)
        #expect(retrieved == valueB)
    }

    @Test("multiple accounts do not interfere")
    func multipleAccounts() throws {
        let account1 = "test-\(UUID().uuidString)"
        let account2 = "test-\(UUID().uuidString)"
        let value1 = "key-one-\(UUID().uuidString)"
        let value2 = "key-two-\(UUID().uuidString)"
        defer {
            try? store.remove(account: account1)
            try? store.remove(account: account2)
        }

        try store.set(value1, account: account1)
        try store.set(value2, account: account2)

        #expect(try store.get(account: account1) == value1)
        #expect(try store.get(account: account2) == value2)
        #expect(try store.get(account: account1) != value2)
        #expect(try store.get(account: account2) != value1)
    }
}
