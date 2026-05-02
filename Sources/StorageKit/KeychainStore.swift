import Foundation
@preconcurrency import KeychainAccess

public struct KeychainStore: @unchecked Sendable {
    /// The Keychain service name. Locked to bundle identifier "dev.jarvisnote.studio"
    /// per design §13 — must NEVER change post-ship (Keychain entries are tied to it).
    public static let service = "dev.jarvisnote.studio"

    private let keychain: Keychain

    public init() {
        self.keychain = Keychain(service: Self.service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
            .synchronizable(false)
    }

    public func get(account: String) throws -> String? {
        return try keychain.get(account)
    }

    public func set(_ value: String, account: String) throws {
        try keychain.set(value, key: account)
    }

    public func remove(account: String) throws {
        try keychain.remove(account)
    }

    public func contains(account: String) throws -> Bool {
        return try keychain.get(account) != nil
    }
}
