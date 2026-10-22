import XCTest
@testable import NoteLy

final class CryptoServiceTests: XCTestCase {
    private let crypto = CryptoService()

    func testRoundTrip() throws {
        let key = crypto.generateKey()
        let plain = Data("private note body".utf8)
        let sealed = try crypto.encrypt(plain, using: key)
        let opened = try crypto.decrypt(sealed, using: key)
        XCTAssertEqual(opened, plain)
    }

    func testEmptyPlaintextRoundTrip() throws {
        let key = crypto.generateKey()
        let sealed = try crypto.encrypt(Data(), using: key)
        XCTAssertEqual(try crypto.decrypt(sealed, using: key), Data())
    }

    func testWrongKeyFails() throws {
        let plain = Data("secret".utf8)
        let sealed = try crypto.encrypt(plain, using: crypto.generateKey())
        XCTAssertThrowsError(try crypto.decrypt(sealed, using: crypto.generateKey())) { error in
            XCTAssertEqual(error as? VaultError, .decryptionFailed)
        }
    }

    func testNonceIsUnique() throws {
        let key = crypto.generateKey()
        let plain = Data("same plaintext".utf8)
        let first = try crypto.encrypt(plain, using: key)
        let second = try crypto.encrypt(plain, using: key)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try crypto.decrypt(first, using: key), plain)
        XCTAssertEqual(try crypto.decrypt(second, using: key), plain)
    }

    func testChunkBoundaryRoundTrip() throws {
        let key = crypto.generateKey()
        for count in [SecurityConstants.chunkSize, SecurityConstants.chunkSize + 1, 300_000] {
            let plain = Data(repeating: 0xAB, count: count)
            let sealed = try crypto.encrypt(plain, using: key)
            XCTAssertEqual(try crypto.decrypt(sealed, using: key), plain)
        }
    }

    func testTamperFails() throws {
        let key = crypto.generateKey()
        var sealed = try crypto.encrypt(Data("do not flip".utf8), using: key)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try crypto.decrypt(sealed, using: key)) { error in
            XCTAssertEqual(error as? VaultError, .decryptionFailed)
        }
    }

    func testBadHeaderIsCorrupted() throws {
        let key = crypto.generateKey()
        var sealed = try crypto.encrypt(Data("hi".utf8), using: key)
        sealed[0] = 0
        XCTAssertThrowsError(try crypto.decrypt(sealed, using: key)) { error in
            XCTAssertEqual(error as? VaultError, .corruptedData)
        }
    }

    func testConstantTimeEqual() {
        let same = Data([1, 2, 3, 4])
        XCTAssertTrue(crypto.constantTimeEqual(same, same))
        XCTAssertFalse(crypto.constantTimeEqual(same, Data([1, 2, 3, 5])))
        XCTAssertFalse(crypto.constantTimeEqual(same, Data([1, 2, 3, 4, 0])))
        XCTAssertFalse(crypto.constantTimeEqual(Data(), Data([0])))
        XCTAssertTrue(crypto.constantTimeEqual(Data(), Data()))
    }

    func testPBKDF2IsDeterministicAndSensitiveToSalt() throws {
        let salt = Data(repeating: 7, count: 16)
        let otherSalt = Data(repeating: 8, count: 16)
        let first = try crypto.pbkdf2(password: "unlock", salt: salt, iterations: 1_000, outputLength: 32)
        let second = try crypto.pbkdf2(password: "unlock", salt: salt, iterations: 1_000, outputLength: 32)
        let different = try crypto.pbkdf2(password: "unlock", salt: otherSalt, iterations: 1_000, outputLength: 32)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
        XCTAssertEqual(first.count, 32)
    }

    func testProductionIterationFloor() {
        XCTAssertGreaterThanOrEqual(SecurityConstants.pbkdf2Iterations, 100_000)
    }
}
