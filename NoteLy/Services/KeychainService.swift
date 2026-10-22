import Foundation
import LocalAuthentication
import Security

/// How a keychain item may be read.
enum KeychainProtection: Sendable {
    /// Salted phrase hashes. No biometric prompt. Stays on this device and requires a passcode.
    case passcodeThisDeviceOnly
    /// Vault encryption key. Current Face ID / Touch ID set, or the device passcode.
    /// `.biometryCurrentSet` drops the biometric path when faces or fingers change.
    /// `.or` + `.devicePasscode` keeps the passcode fallback required by the unlock flow.
    /// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` keeps the item out of backups and off other devices.
    case biometryCurrentSetOrPasscode
    /// Unlocked-device storage with no biometric gate.
    /// Production vault keys must not use this. The decoy key does, so the decoy area does not
    /// prompt for Face ID. UI tests also use it because the simulator may not have a passcode.
    case afterFirstUnlockThisDeviceOnly
}

protocol KeychainServicing: AnyObject, Sendable {
    func set(_ data: Data, account: String, protection: KeychainProtection, context: LAContext?) throws
    func data(for account: String, context: LAContext?) throws -> Data?
    func remove(_ account: String) throws
    /// Presence check that must not show a biometric prompt.
    func contains(_ account: String) -> Bool
    func removeAllVaultItems() throws
}

extension KeychainServicing {
    func set(_ data: Data, account: String, protection: KeychainProtection) throws {
        try set(data, account: account, protection: protection, context: nil)
    }

    func data(for account: String) throws -> Data? {
        try data(for: account, context: nil)
    }
}

/// Keychain wrapper. Items are not synchronizable. Callers never log the returned bytes.
final class KeychainService: KeychainServicing, @unchecked Sendable {
    private let service: String

    init(service: String = KeychainAccount.service) {
        self.service = service
    }

    func set(_ data: Data, account: String, protection: KeychainProtection, context: LAContext?) throws {
        try remove(account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrSynchronizable as String] = false
        switch protection {
        case .passcodeThisDeviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .biometryCurrentSetOrPasscode:
            query[kSecAttrAccessControl as String] = try makeBiometricAccessControl()
            if let context {
                query[kSecUseAuthenticationContext as String] = context
            }
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            VaultLog.security.error("Keychain save failed")
            throw VaultError.keychainFailed
        }
    }

    func data(for account: String, context: LAContext?) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            VaultLog.security.error("Keychain read failed")
            throw VaultError.keychainFailed
        }
        guard let data = item as? Data else { throw VaultError.keychainFailed }
        return data
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            VaultLog.security.error("Keychain delete failed")
            throw VaultError.keychainFailed
        }
    }

    /// `kSecUseAuthenticationUIFail` returns `errSecInteractionNotAllowed` when the item exists
    /// but would require Face ID. That still means the item is present, and it does not prompt.
    func contains(_ account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        default:
            return false
        }
    }

    func removeAllVaultItems() throws {
        for account in KeychainAccount.all {
            try remove(account)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func makeBiometricAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],
            &error
        ) else {
            VaultLog.security.error("Access control creation failed")
            throw VaultError.keychainFailed
        }
        return access
    }
}
