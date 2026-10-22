import Foundation
import LocalAuthentication
@testable import NoteLy

/// Test double. Stores bytes in a dictionary and never prompts.
final class InMemoryKeychain: KeychainServicing, @unchecked Sendable {
    private(set) var storage: [String: Data] = [:]

    func set(_ data: Data, account: String, protection: KeychainProtection, context: LAContext?) throws {
        storage[account] = data
    }

    func data(for account: String, context: LAContext?) throws -> Data? {
        storage[account]
    }

    func remove(_ account: String) throws {
        storage[account] = nil
    }

    func contains(_ account: String) -> Bool {
        storage[account] != nil
    }

    func removeAllVaultItems() throws {
        for account in KeychainAccount.all {
            storage[account] = nil
        }
    }
}
