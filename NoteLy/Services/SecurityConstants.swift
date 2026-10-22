import Foundation

/// Shared security parameters. Phrase length and KDF cost live here so tests can assert the floor
/// without copying magic numbers.
enum SecurityConstants {
    /// PBKDF2-HMAC-SHA256 iterations. Must stay at or above 100_000.
    static let pbkdf2Iterations = 120_000
    static let saltLength = 16
    static let hashLength = 32
    static let minPhraseLength = 8
    static let maxPhraseLength = 64
    static let minBackupPasswordLength = 8
    /// Plaintext chunk size for private notes before AES-GCM. Each chunk gets a fresh nonce.
    static let chunkSize = 256 * 1024
    /// Plaintext chunk size for vault files. Videos stay on disk and are never loaded whole.
    static let fileChunkSize = 1024 * 1024
    static let maxChunkCount = 100_000
    /// Default cap for one imported file. Checked again against free disk space.
    static let maxImportFileBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let importHeadroomBytes: Int64 = 32 * 1024 * 1024
    static let thumbnailMaxPixel: Int = 300
    static let maxFailedAttempts = 5
    static let failureWindow: TimeInterval = 10 * 60
    static let cooldownDuration: TimeInterval = 5 * 60
    static let defaultPanicThreshold = 5
}

enum PreferenceKey {
    static let onboardingComplete = "notely.onboarding.completed"
    static let autoLock = "notely.vault.autolock"
    static let backupOptIn = "notely.vault.backupOptIn"
    static let panicEnabled = "notely.vault.panicEnabled"
    static let panicThreshold = "notely.vault.panicThreshold"
    static let decoySeeded = "notely.vault.decoySeeded"
    static let faceIDEnabled = "notely.vault.faceID"
    static let reauthPolicy = "notely.vault.reauth"
    static let favoriteMode = "notely.vault.favoriteMode"
}

enum KeychainAccount {
    static let service = "com.notely.notes.vault"
    static let vaultPhrase = "vault.phrase"
    static let decoyPhrase = "decoy.phrase"
    static let vaultKey = "vault.key"
    static let decoyKey = "decoy.key"
    static let vaultPasscode = "vault.passcode"
    static let passcodeStyle = "vault.passcode.style"
    static let recoveryWrap = "vault.recovery"

    static let all = [vaultPhrase, decoyPhrase, vaultKey, decoyKey, vaultPasscode, passcodeStyle, recoveryWrap]
}
