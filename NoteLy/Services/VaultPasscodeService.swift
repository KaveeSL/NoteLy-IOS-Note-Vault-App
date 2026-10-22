import CryptoKit
import Foundation

/// A vault passcode is a 6-digit code chosen in the app. It is not the iPhone passcode.
/// The digits are never stored. A salted hash checks them, and a separate wrap holds the vault key.
final class VaultPasscodeService {
    private let keychain: KeychainServicing
    private let crypto: CryptoServicing
    private let iterations: Int

    init(keychain: KeychainServicing, crypto: CryptoServicing, iterations: Int = SecurityConstants.pbkdf2Iterations) {
        self.keychain = keychain
        self.crypto = crypto
        self.iterations = iterations
    }

    func isConfigured() -> Bool {
        keychain.contains(KeychainAccount.vaultPasscode)
    }

    func save(passcode: String, keyData: Data) throws {
        try save(passcode: passcode, keyData: keyData, style: .pin6)
    }

    func save(passcode: String, keyData: Data, style: VaultPasscodeStyle) throws {
        let secret = try PasscodeRules.normalized(passcode, style: style)
        let salt = try crypto.randomData(count: SecurityConstants.saltLength)
        let derived = try crypto.pbkdf2(password: secret, salt: salt, iterations: iterations, outputLength: SecurityConstants.hashLength)
        let wrappingKey = try crypto.key(from: derived)
        let sealed = try crypto.encrypt(keyData, using: wrappingKey)
        var blob = Data()
        blob.append(salt)
        blob.append(sealed)
        try keychain.set(blob, account: KeychainAccount.vaultPasscode, protection: .passcodeThisDeviceOnly)
        try keychain.set(Data(style.rawValue.utf8), account: KeychainAccount.passcodeStyle, protection: .afterFirstUnlockThisDeviceOnly)
    }

    func currentStyle() -> VaultPasscodeStyle {
        guard let data = try? keychain.data(for: KeychainAccount.passcodeStyle),
              let raw = String(data: data, encoding: .utf8),
              let style = VaultPasscodeStyle(rawValue: raw) else {
            return .pin6
        }
        return style
    }

    func unlock(passcode: String) throws -> Data {
        let secret = try PasscodeRules.normalized(passcode, style: currentStyle())
        guard let blob = try keychain.data(for: KeychainAccount.vaultPasscode), blob.count > SecurityConstants.saltLength else {
            throw VaultError.decryptionFailed
        }
        let salt = blob.prefix(SecurityConstants.saltLength)
        let sealed = blob.dropFirst(SecurityConstants.saltLength)
        let derived = try crypto.pbkdf2(password: secret, salt: Data(salt), iterations: iterations, outputLength: SecurityConstants.hashLength)
        let wrappingKey = try crypto.key(from: derived)
        return try crypto.decrypt(Data(sealed), using: wrappingKey)
    }

    func change(from current: String, to newPasscode: String, keyData: Data) throws {
        let style = currentStyle()
        _ = try unlock(passcode: current)
        try save(passcode: newPasscode, keyData: keyData, style: style)
    }

    func saveRecovery(words: [String], keyData: Data) throws {
        let salt = try crypto.randomData(count: SecurityConstants.saltLength)
        let derived = try crypto.pbkdf2(
            password: RecoveryKey.joined(words),
            salt: salt,
            iterations: iterations,
            outputLength: SecurityConstants.hashLength
        )
        let wrappingKey = try crypto.key(from: derived)
        let sealed = try crypto.encrypt(keyData, using: wrappingKey)
        var blob = Data()
        blob.append(salt)
        blob.append(sealed)
        try keychain.set(blob, account: KeychainAccount.recoveryWrap, protection: .passcodeThisDeviceOnly)
    }
}
