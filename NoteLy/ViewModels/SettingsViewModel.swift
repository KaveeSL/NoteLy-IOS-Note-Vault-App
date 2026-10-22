import Combine
import Foundation

/// Setup, phrase changes, backup, and erase. Messages from this type are shown on setup
/// or inside the private area, where the feature is already on screen.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var statusMessage: String?
    @Published var isWorking = false
    @Published var panicWipeEnabled: Bool {
        didSet { defaults.set(panicWipeEnabled, forKey: PreferenceKey.panicEnabled) }
    }
    @Published var panicThreshold: Int {
        didSet { defaults.set(panicThreshold, forKey: PreferenceKey.panicThreshold) }
    }
    @Published var includeVaultInBackup: Bool {
        didSet { applyBackupPreference() }
    }

    private let phrases: SecretPhraseServicing
    private let biometric: BiometricAuthenticating
    private let keychain: KeychainServicing
    private let crypto: CryptoServicing
    private let vaultStore: VaultStoring
    private let decoyStore: VaultStoring
    private let backup: VaultBackupServicing
    private let session: VaultSession
    private let defaults: UserDefaults

    init(
        phrases: SecretPhraseServicing,
        biometric: BiometricAuthenticating,
        keychain: KeychainServicing,
        crypto: CryptoServicing,
        vaultStore: VaultStoring,
        decoyStore: VaultStoring,
        backup: VaultBackupServicing,
        session: VaultSession,
        defaults: UserDefaults
    ) {
        self.phrases = phrases
        self.biometric = biometric
        self.keychain = keychain
        self.crypto = crypto
        self.vaultStore = vaultStore
        self.decoyStore = decoyStore
        self.backup = backup
        self.session = session
        self.defaults = defaults
        panicWipeEnabled = defaults.bool(forKey: PreferenceKey.panicEnabled)
        let storedThreshold = defaults.integer(forKey: PreferenceKey.panicThreshold)
        panicThreshold = storedThreshold == 0 ? SecurityConstants.defaultPanicThreshold : storedThreshold
        includeVaultInBackup = defaults.bool(forKey: PreferenceKey.backupOptIn)
    }

    func isVaultConfigured() -> Bool {
        phrases.isVaultConfigured()
    }

    func isDecoyConfigured() -> Bool {
        phrases.isDecoyConfigured()
    }

    func biometryFootnote() -> String? {
        switch biometric.availability() {
        case .ready(let kind):
            switch kind {
            case .faceID, .opticID:
                return "Face ID confirms it's you. Your device passcode works if Face ID doesn't."
            case .touchID:
                return "Touch ID confirms it's you. Your device passcode works if Touch ID doesn't."
            case .none:
                return "Face ID isn't set up. Your device passcode will be used instead."
            @unknown default:
                return "Your device passcode or biometrics will confirm it's you."
            }
        case .passcodeNotSet:
            return "Set a device passcode in the Settings app before turning on the private vault."
        case .unavailable:
            return "This device can't confirm it's you, so the private vault can't be turned on."
        }
    }

    func canOfferVaultSetup() -> Bool {
        if case .passcodeNotSet = biometric.availability() { return false }
        if case .unavailable = biometric.availability() { return false }
        return true
    }

    /// Creates the phrase hash and the random vault key. The phrase is stored only after the key
    /// is in the keychain, and the key is removed again if the hash cannot be saved.
    func setupVault(phrase: String, confirmation: String) async -> String? {
        if case .invalid(let reason) = PhraseValidator.validate(phrase) {
            return reason
        }
        let normalized = SecretPhraseService.normalize(phrase)
        let confirmed = SecretPhraseService.normalize(confirmation)
        if normalized != confirmed {
            return "Those phrases don't match."
        }
        switch biometric.availability() {
        case .passcodeNotSet:
            return "Set a device passcode in the Settings app before turning on the private vault."
        case .unavailable:
            return "This device can't confirm it's you, so the private vault can't be turned on."
        case .ready:
            break
        }

        isWorking = true
        defer { isWorking = false }

        let outcome = await biometric.authenticate(reason: UnlockPrompt.reason)
        guard case .success(let context) = outcome else {
            if case .cancelled = outcome {
                return nil
            }
            return "Couldn't confirm it's you. The private vault was not turned on."
        }

        let key = crypto.generateKey()
        do {
            try keychain.set(
                crypto.keyData(key),
                account: KeychainAccount.vaultKey,
                protection: .biometryCurrentSetOrPasscode,
                context: context
            )
        } catch {
            VaultLog.security.error("Vault key could not be stored")
            return "The private vault couldn't be saved. Try again."
        }

        do {
            try await phrases.setVaultPhrase(phrase)
        } catch {
            try? keychain.remove(KeychainAccount.vaultKey)
            VaultLog.security.error("Vault phrase could not be stored")
            return message(for: error) ?? "The private vault couldn't be saved. Try again."
        }
        statusMessage = "Private vault is on. Open it from search with your phrase."
        return nil
    }

    /// Replaces the phrase after Face ID or the device passcode. The previous phrase is not asked
    /// again, because this screen is already behind that confirmation.
    func changePhrase(newPhrase: String, confirmation: String, decoy: Bool) async -> String? {
        if case .invalid(let reason) = PhraseValidator.validate(newPhrase) {
            return reason
        }
        let normalizedNew = SecretPhraseService.normalize(newPhrase)
        let normalizedConfirm = SecretPhraseService.normalize(confirmation)
        if normalizedNew != normalizedConfirm {
            return "Those phrases don't match."
        }
        isWorking = true
        defer { isWorking = false }
        let outcome = await biometric.authenticate(reason: UnlockPrompt.reason)
        guard case .success = outcome else {
            if case .cancelled = outcome { return nil }
            return "Couldn't confirm it's you."
        }
        do {
            if decoy {
                try await phrases.setDecoyPhrase(newPhrase)
            } else {
                try await phrases.setVaultPhrase(newPhrase)
            }
            statusMessage = "Phrase updated."
            return nil
        } catch {
            return message(for: error) ?? "That phrase couldn't be saved."
        }
    }

    func enableDecoy(phrase: String, confirmation: String) async -> String? {
        if case .invalid(let reason) = PhraseValidator.validate(phrase) {
            return reason
        }
        let normalized = SecretPhraseService.normalize(phrase)
        let confirmed = SecretPhraseService.normalize(confirmation)
        if normalized != confirmed {
            return "Those phrases don't match."
        }
        isWorking = true
        defer { isWorking = false }
        let createdKey = !keychain.contains(KeychainAccount.decoyKey)
        if createdKey {
            let key = crypto.generateKey()
            do {
                try keychain.set(
                    crypto.keyData(key),
                    account: KeychainAccount.decoyKey,
                    protection: .afterFirstUnlockThisDeviceOnly
                )
            } catch {
                VaultLog.security.error("Decoy key could not be stored")
                return "That couldn't be saved. Try again."
            }
        }
        do {
            try await phrases.setDecoyPhrase(phrase)
            statusMessage = "Second phrase saved."
            return nil
        } catch {
            if createdKey {
                try? keychain.remove(KeychainAccount.decoyKey)
            }
            return message(for: error) ?? "That couldn't be saved. Try again."
        }
    }

    func disableDecoy() throws {
        try decoyStore.deleteAll()
        try keychain.remove(KeychainAccount.decoyKey)
        try keychain.remove(KeychainAccount.decoyPhrase)
        statusMessage = "Second phrase removed."
    }

    func exportBackup(password: String, decoy: Bool) async throws -> Data {
        guard password.count >= SecurityConstants.minBackupPasswordLength else {
            throw VaultError.backupFailed
        }
        guard let key = session.key else { throw VaultError.notConfigured }
        let store: VaultStoring = decoy ? decoyStore : vaultStore
        let notes = try store.loadAll(using: key)
        var attachments: [VaultBackupAttachment] = []
        for note in notes {
            for attachment in note.attachments {
                let data = try store.loadAttachment(
                    noteID: note.id,
                    attachmentID: attachment.id,
                    using: key
                )
                attachments.append(
                    VaultBackupAttachment(
                        noteID: note.id,
                        attachmentID: attachment.id,
                        filename: attachment.filename,
                        data: data
                    )
                )
            }
        }
        let payload = VaultBackupPayload(format: 1, notes: notes, attachments: attachments)
        let service = backup
        return try await Task.detached {
            try service.exportPayload(payload, password: password)
        }.value
    }

    func importBackup(data: Data, password: String, decoy: Bool) async throws -> Int {
        guard let key = session.key else { throw VaultError.notConfigured }
        let service = backup
        let payload = try await Task.detached {
            try service.importPayload(data, password: password)
        }.value
        let store: VaultStoring = decoy ? decoyStore : vaultStore
        for note in payload.notes {
            for attachment in note.attachments {
                guard let blob = payload.attachments.first(where: {
                    $0.noteID == note.id && $0.attachmentID == attachment.id
                }) else { continue }
                try store.saveAttachment(
                    noteID: note.id,
                    attachmentID: attachment.id,
                    data: blob.data,
                    using: key
                )
            }
            try store.save(note, using: key)
        }
        return payload.notes.count
    }

    /// Deletes the open area. The real vault erase also removes the decoy. Requires a fresh
    /// biometric check and the matching phrase so a tap alone cannot wipe notes.
    func deleteArea(typedPhrase: String, decoy: Bool) async -> String? {
        isWorking = true
        defer { isWorking = false }
        let outcome = await biometric.authenticate(reason: UnlockPrompt.reason)
        guard case .success = outcome else {
            if case .cancelled = outcome { return nil }
            return "Couldn't confirm it's you."
        }
        let match = await phrases.verify(typedPhrase)
        do {
            if decoy {
                guard match == .decoy else { return "That phrase doesn't match." }
                try decoyStore.deleteAll()
                try keychain.remove(KeychainAccount.decoyKey)
                try keychain.remove(KeychainAccount.decoyPhrase)
            } else {
                guard match == .vault else { return "That phrase doesn't match." }
                try vaultStore.deleteAll()
                try decoyStore.deleteAll()
                try keychain.removeAllVaultItems()
            }
            return nil
        } catch {
            VaultLog.security.error("Private area delete failed")
            return "That couldn't be deleted. Try again."
        }
    }

    func message(for error: Error) -> String? {
        guard let vaultError = error as? VaultError else {
            return "That couldn't be saved. Try again."
        }
        switch vaultError {
        case .phraseTooShort:
            return "Use at least \(SecurityConstants.minPhraseLength) characters."
        case .phraseTooLong:
            return "Use \(SecurityConstants.maxPhraseLength) characters or fewer."
        case .phraseTooWeak:
            return "Choose a phrase that isn't a common word or a simple pattern."
        case .phraseMismatch:
            return "That phrase doesn't match."
        case .phraseConfirmationMismatch:
            return "Those phrases don't match."
        case .decoyPhraseConflicts:
            return "Choose a different phrase."
        case .passcodeNotSet:
            return "Set a device passcode in the Settings app before turning on the private vault."
        case .backupFailed:
            return "Use at least 8 characters for the backup password."
        case .importFailed, .decryptionFailed:
            return "Couldn't open that backup. Check the password and try again."
        case .authenticationFailed:
            return "Couldn't confirm it's you."
        default:
            return "That couldn't be saved. Try again."
        }
    }

    private func applyBackupPreference() {
        defaults.set(includeVaultInBackup, forKey: PreferenceKey.backupOptIn)
        do {
            try vaultStore.setExcludedFromBackup(!includeVaultInBackup)
            try decoyStore.setExcludedFromBackup(!includeVaultInBackup)
            let files = VaultFileStore(directory: VaultFileStore.defaultDirectory(), crypto: crypto)
            try files.applyBackupExclusion(!includeVaultInBackup)
        } catch {
            VaultLog.security.error("Backup flag could not be updated")
            statusMessage = "The backup setting couldn't be saved."
        }
    }
}
