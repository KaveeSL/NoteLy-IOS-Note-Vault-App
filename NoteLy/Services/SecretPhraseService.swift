import Foundation

enum PhraseMatch: Equatable, Sendable {
    case none
    case vault
    case decoy
}

protocol SecretPhraseServicing: AnyObject, Sendable {
    func isVaultConfigured() -> Bool
    func isDecoyConfigured() -> Bool
    func setVaultPhrase(_ phrase: String) async throws
    func setDecoyPhrase(_ phrase: String) async throws
    func changeVaultPhrase(from current: String, to newPhrase: String) async throws
    func changeDecoyPhrase(from current: String, to newPhrase: String) async throws
    func verify(_ phrase: String) async -> PhraseMatch
    func deleteAll() throws
}

/// Salted PBKDF2 hashes of the secret phrases. The phrase itself is never stored.
///
/// Normalization, applied before every hash and check: trim whitespace and newlines, then
/// lowercase with the POSIX locale. " My Phrase " and "my phrase" match. The locale is fixed
/// so changing the device language cannot change the hash.
///
/// The hash runs only when a vault exists and the normalized text is between 8 and 64
/// characters. Everyday short searches stay fast. Whether a vault exists is disclosed in
/// Settings; the phrase is the secret. When a vault exists, a decoy hash is always evaluated
/// too (a random placeholder until the user sets one) so turning decoy on does not change
/// how long a search submit takes.
final class SecretPhraseService: SecretPhraseServicing, @unchecked Sendable {
    private let keychain: KeychainServicing
    private let crypto: CryptoServicing
    private let iterations: Int

    init(
        keychain: KeychainServicing,
        crypto: CryptoServicing,
        iterations: Int = SecurityConstants.pbkdf2Iterations
    ) {
        self.keychain = keychain
        self.crypto = crypto
        self.iterations = iterations
    }

    static func normalize(_ phrase: String) -> String {
        PhraseValidator.normalize(phrase)
    }

    func isVaultConfigured() -> Bool {
        keychain.contains(KeychainAccount.vaultPhrase)
    }

    func isDecoyConfigured() -> Bool {
        guard let record = try? loadRecord(account: KeychainAccount.decoyPhrase) else { return false }
        return record.isActive
    }

    func setVaultPhrase(_ phrase: String) async throws {
        try await offMain { try self.storeVaultPhrase(phrase) }
    }

    func setDecoyPhrase(_ phrase: String) async throws {
        try await offMain { try self.storeDecoyPhrase(phrase) }
    }

    func changeVaultPhrase(from current: String, to newPhrase: String) async throws {
        let match = await verify(current)
        guard match == .vault else { throw VaultError.phraseMismatch }
        try await setVaultPhrase(newPhrase)
    }

    func changeDecoyPhrase(from current: String, to newPhrase: String) async throws {
        let match = await verify(current)
        guard match == .decoy else { throw VaultError.phraseMismatch }
        try await setDecoyPhrase(newPhrase)
    }

    /// Threat: interactive guessing from the search field, and accidental unlock while typing.
    /// Call this only after the user submits search. A mismatch is `.none`, the same result as
    /// "no vault" and as a keychain read error, so the notes screen has nothing special to show.
    func verify(_ phrase: String) async -> PhraseMatch {
        await offMain { self.evaluate(phrase) }
    }

    func deleteAll() throws {
        try keychain.remove(KeychainAccount.vaultPhrase)
        try keychain.remove(KeychainAccount.decoyPhrase)
    }

    #if DEBUG
    /// UI-test hook. Stores a phrase hash without `WhenPasscodeSet`, because the simulator
    /// may not have a passcode. Uses fewer iterations so the test launch stays short.
    /// `verify` reads the iteration count from this record. Not compiled into Release.
    /// The phrase is supplied by the test process; this method does not contain one.
    func configureForUITest(phrase: String) throws {
        let normalized = try validated(phrase)
        let record = try makeRecord(for: normalized, isActive: true, iterations: 10_000)
        try save(record, account: KeychainAccount.vaultPhrase, protection: .afterFirstUnlockThisDeviceOnly)
        let placeholderPassword = try crypto.randomData(count: SecurityConstants.hashLength).base64EncodedString()
        let placeholder = try makeRecord(for: placeholderPassword, isActive: false, iterations: 10_000)
        try save(placeholder, account: KeychainAccount.decoyPhrase, protection: .afterFirstUnlockThisDeviceOnly)
    }
    #endif

    // MARK: - Synchronous work (background queue)

    func storeVaultPhrase(_ phrase: String) throws {
        let normalized = try validated(phrase)
        if let decoy = try? loadRecord(account: KeychainAccount.decoyPhrase), decoy.isActive {
            let decoyDerived = try crypto.pbkdf2(
                password: normalized,
                salt: decoy.salt,
                iterations: decoy.iterations,
                outputLength: SecurityConstants.hashLength
            )
            if crypto.constantTimeEqual(decoyDerived, decoy.hash) {
                throw VaultError.decoyPhraseConflicts
            }
        }
        let record = try makeRecord(for: normalized, isActive: true)
        try save(record, account: KeychainAccount.vaultPhrase)
        if (try? loadRecord(account: KeychainAccount.decoyPhrase)) == nil {
            let placeholderPassword = try crypto.randomData(count: SecurityConstants.hashLength).base64EncodedString()
            let placeholder = try makeRecord(for: placeholderPassword, isActive: false)
            try save(placeholder, account: KeychainAccount.decoyPhrase)
        }
    }

    func storeDecoyPhrase(_ phrase: String) throws {
        let normalized = try validated(phrase)
        if let vault = try? loadRecord(account: KeychainAccount.vaultPhrase) {
            let vaultDerived = try crypto.pbkdf2(
                password: normalized,
                salt: vault.salt,
                iterations: vault.iterations,
                outputLength: SecurityConstants.hashLength
            )
            if crypto.constantTimeEqual(vaultDerived, vault.hash) {
                throw VaultError.decoyPhraseConflicts
            }
        }
        let record = try makeRecord(for: normalized, isActive: true)
        try save(record, account: KeychainAccount.decoyPhrase)
    }

    func evaluate(_ phrase: String) -> PhraseMatch {
        let normalized = Self.normalize(phrase)
        guard
            normalized.count >= SecurityConstants.minPhraseLength,
            normalized.count <= SecurityConstants.maxPhraseLength,
            let vault = try? loadRecord(account: KeychainAccount.vaultPhrase)
        else {
            return .none
        }
        do {
            let vaultDerived = try crypto.pbkdf2(
                password: normalized,
                salt: vault.salt,
                iterations: vault.iterations,
                outputLength: SecurityConstants.hashLength
            )
            let decoy = try loadRecord(account: KeychainAccount.decoyPhrase) ?? PhraseCredential(
                iterations: vault.iterations,
                salt: try crypto.randomData(count: SecurityConstants.saltLength),
                hash: Data(repeating: 0, count: SecurityConstants.hashLength),
                isActive: false
            )
            let decoyDerived = try crypto.pbkdf2(
                password: normalized,
                salt: decoy.salt,
                iterations: decoy.iterations,
                outputLength: SecurityConstants.hashLength
            )
            let vaultMatch = crypto.constantTimeEqual(vaultDerived, vault.hash)
            let decoyEqual = crypto.constantTimeEqual(decoyDerived, decoy.hash)
            let decoyMatch = decoyEqual && decoy.isActive
            if vaultMatch { return .vault }
            if decoyMatch { return .decoy }
            return .none
        } catch {
            VaultLog.security.error("Phrase check could not finish")
            return .none
        }
    }

    // MARK: - Records

    private func validated(_ phrase: String) throws -> String {
        if let error = PhraseValidator.storageError(for: phrase) {
            throw error
        }
        return Self.normalize(phrase)
    }

    private func makeRecord(
        for normalizedPhrase: String,
        isActive: Bool,
        iterations: Int? = nil
    ) throws -> PhraseCredential {
        let rounds = iterations ?? self.iterations
        let salt = try crypto.randomData(count: SecurityConstants.saltLength)
        let hash = try crypto.pbkdf2(
            password: normalizedPhrase,
            salt: salt,
            iterations: rounds,
            outputLength: SecurityConstants.hashLength
        )
        return PhraseCredential(iterations: rounds, salt: salt, hash: hash, isActive: isActive)
    }

    private func save(
        _ record: PhraseCredential,
        account: String,
        protection: KeychainProtection = .passcodeThisDeviceOnly
    ) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        try keychain.set(data, account: account, protection: protection)
    }

    private func loadRecord(account: String) throws -> PhraseCredential? {
        guard let data = try keychain.data(for: account) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(PhraseCredential.self, from: data)
        } catch {
            throw VaultError.corruptedData
        }
    }
}

/// Salt, stretched hash, and the iteration count used to produce it.
/// `isActive` is false for the decoy placeholder so a random hash cannot open the decoy area.
struct PhraseCredential: Codable, Equatable, Sendable {
    var iterations: Int
    var salt: Data
    var hash: Data
    var isActive: Bool
}

private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
