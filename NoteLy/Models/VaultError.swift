import Foundation

/// Failures for the private vault. User-facing copy must stay generic on the
/// notes screen. These cases are for control flow inside setup and the vault.
enum VaultError: Error, Equatable, Sendable {
    case notConfigured
    case phraseTooShort
    case phraseTooLong
    case phraseTooWeak
    case phraseMismatch
    case phraseConfirmationMismatch
    case authenticationFailed
    case passcodeNotSet
    case keychainFailed
    case encryptionFailed
    case decryptionFailed
    case corruptedData
    case itemNotFound
    case backupFailed
    case importFailed
    case importCancelled
    case insufficientSpace
    case fileTooLarge
    case decoyPhraseConflicts
    case persistenceFailed
    case photoEncodingFailed
    case authorizationRequired
}
