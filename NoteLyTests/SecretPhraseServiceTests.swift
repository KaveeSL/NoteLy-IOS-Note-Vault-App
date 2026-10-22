import XCTest
@testable import NoteLy

final class SecretPhraseServiceTests: XCTestCase {
    private var keychain: InMemoryKeychain!
    private var service: SecretPhraseService!

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychain()
        service = SecretPhraseService(keychain: keychain, crypto: CryptoService(), iterations: 1_000)
    }

    func testNormalizationAndVerify() throws {
        try service.storeVaultPhrase("  Harbor-Lantern ")
        XCTAssertEqual(service.evaluate("harbor-lantern"), .vault)
        XCTAssertEqual(service.evaluate("HARBOR-LANTERN"), .vault)
        XCTAssertEqual(service.evaluate("  harbor-lantern\n"), .vault)
        XCTAssertEqual(service.evaluate("not-the-phrase"), .none)
    }

    func testAsyncVerifyMatches() async throws {
        try service.storeVaultPhrase("harbor-lantern")
        let match = await service.verify("Harbor-Lantern")
        XCTAssertEqual(match, .vault)
    }

    func testTooShortAndTooLong() {
        XCTAssertThrowsError(try service.storeVaultPhrase("short")) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooShort)
        }
        let longPhrase = String(repeating: "a", count: SecurityConstants.maxPhraseLength + 1)
        XCTAssertThrowsError(try service.storeVaultPhrase(longPhrase)) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooLong)
        }
    }

    func testPlaintextIsNotStored() throws {
        try service.storeVaultPhrase("harbor-lantern")
        let blob = keychain.storage.values.reduce(into: Data()) { $0.append($1) }
        XCTAssertNil(blob.range(of: Data("harbor-lantern".utf8)))
        let stored = try XCTUnwrap(keychain.storage[KeychainAccount.vaultPhrase])
        let record = try JSONDecoder().decode(PhraseCredential.self, from: stored)
        XCTAssertEqual(record.salt.count, SecurityConstants.saltLength)
        XCTAssertEqual(record.hash.count, SecurityConstants.hashLength)
        XCTAssertGreaterThanOrEqual(record.iterations, 1_000)
        XCTAssertTrue(record.isActive)
    }

    func testChangingPhraseInvalidatesTheOldOne() throws {
        try service.storeVaultPhrase("harbor-lantern")
        XCTAssertEqual(service.evaluate("harbor-lantern"), .vault)
        try service.storeVaultPhrase("next-phrase")
        XCTAssertEqual(service.evaluate("harbor-lantern"), .none)
        XCTAssertEqual(service.evaluate("next-phrase"), .vault)
    }

    func testDecoyDoesNotOpenTheVault() throws {
        try service.storeVaultPhrase("harbor-lantern")
        try service.storeDecoyPhrase("decoy-phrase")
        XCTAssertEqual(service.evaluate("decoy-phrase"), .decoy)
        XCTAssertEqual(service.evaluate("harbor-lantern"), .vault)
        XCTAssertTrue(service.isDecoyConfigured())
    }

    func testDecoyCannotReuseVaultPhrase() throws {
        try service.storeVaultPhrase("harbor-lantern")
        XCTAssertThrowsError(try service.storeDecoyPhrase("harbor-lantern")) { error in
            XCTAssertEqual(error as? VaultError, .decoyPhraseConflicts)
        }
    }

    func testPlaceholderDecoyDoesNotMatch() throws {
        try service.storeVaultPhrase("harbor-lantern")
        XCTAssertFalse(service.isDecoyConfigured())
        XCTAssertEqual(service.evaluate("anything"), .none)
        XCTAssertEqual(service.evaluate("harbor-lantern"), .vault)
    }

    func testShortSearchDoesNotRequireAVault() {
        XCTAssertEqual(service.evaluate("hi"), .none)
        XCTAssertFalse(service.isVaultConfigured())
    }

    func testChangeVaultPhraseRejectsAWrongCurrentPhrase() async {
        try? service.storeVaultPhrase("harbor-lantern")
        do {
            try await service.changeVaultPhrase(from: "nope-nope", to: "another")
            XCTFail("Expected a mismatch")
        } catch let error as VaultError {
            XCTAssertEqual(error, .phraseMismatch)
        } catch {
            XCTFail("Unexpected error")
        }
        XCTAssertEqual(service.evaluate("harbor-lantern"), .vault)
    }

    func testWeakPhrasesAreRejected() {
        XCTAssertThrowsError(try service.storeVaultPhrase("password")) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooWeak)
        }
        XCTAssertThrowsError(try service.storeVaultPhrase("abcdefgh")) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooWeak)
        }
        XCTAssertThrowsError(try service.storeVaultPhrase("aaaaaaaa")) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooWeak)
        }
        XCTAssertThrowsError(try service.storeVaultPhrase("shopping")) { error in
            XCTAssertEqual(error as? VaultError, .phraseTooWeak)
        }
    }
}

final class AttemptLimiterTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "NoteLyTests.attempts.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testCooldownAfterFiveFailuresInTheWindow() {
        let limiter = AttemptLimiter(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<4 {
            limiter.recordFailure(now: start.addingTimeInterval(TimeInterval(index)))
            XCTAssertFalse(limiter.isCoolingDown(now: start.addingTimeInterval(TimeInterval(index))))
        }
        limiter.recordFailure(now: start.addingTimeInterval(4))
        XCTAssertTrue(limiter.isCoolingDown(now: start.addingTimeInterval(4)))
        XCTAssertFalse(limiter.isCoolingDown(now: start.addingTimeInterval(4 + SecurityConstants.cooldownDuration + 1)))
        XCTAssertEqual(limiter.consecutiveFailures(), 5)
        limiter.reset()
        XCTAssertEqual(limiter.consecutiveFailures(), 0)
        XCTAssertFalse(limiter.isCoolingDown(now: start.addingTimeInterval(4)))
    }

    func testOldFailuresFallOutOfTheWindow() {
        let limiter = AttemptLimiter(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<4 {
            limiter.recordFailure(now: start.addingTimeInterval(TimeInterval(index)))
        }
        let later = start.addingTimeInterval(SecurityConstants.failureWindow + 30)
        limiter.recordFailure(now: later)
        XCTAssertFalse(limiter.isCoolingDown(now: later))
    }
}
