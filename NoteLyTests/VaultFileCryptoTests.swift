import CryptoKit
import XCTest
@testable import NoteLy

final class VaultFileCryptoTests: XCTestCase {
    private let crypto = CryptoService()

    func testSubkeysDiffer() {
        let master = crypto.generateKey()
        let index = crypto.deriveSubkey(master, purpose: .index)
        let content = crypto.deriveSubkey(master, purpose: .content)
        let thumb = crypto.deriveSubkey(master, purpose: .thumbnail)
        XCTAssertNotEqual(crypto.keyData(index), crypto.keyData(content))
        XCTAssertNotEqual(crypto.keyData(content), crypto.keyData(thumb))
        XCTAssertEqual(crypto.keyData(index), crypto.keyData(crypto.deriveSubkey(master, purpose: .index)))
    }

    func testFileRoundTripSizes() throws {
        let key = crypto.deriveSubkey(crypto.generateKey(), purpose: .content)
        let sizes = [1_024, SecurityConstants.fileChunkSize - 1, SecurityConstants.fileChunkSize, SecurityConstants.fileChunkSize + 1]
        for size in sizes {
            try assertRoundTrip(count: size, key: key)
        }
    }

    func testFiftyMegabyteRoundTrip() throws {
        let key = crypto.deriveSubkey(crypto.generateKey(), purpose: .content)
        try assertRoundTrip(count: 50 * 1024 * 1024, key: key)
    }

    func testWrongKeyAndTamperFail() throws {
        let key = crypto.deriveSubkey(crypto.generateKey(), purpose: .content)
        let source = try makeFile(count: 4_000)
        let sealed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let opened = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sealed)
            try? FileManager.default.removeItem(at: opened)
        }
        _ = try crypto.encryptFile(at: source, to: sealed, fileID: UUID(), using: key, shouldContinue: { true })
        XCTAssertThrowsError(try crypto.decryptFile(at: sealed, to: opened, using: crypto.generateKey()))
        var bytes = try Data(contentsOf: sealed)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: sealed)
        XCTAssertThrowsError(try crypto.decryptFile(at: sealed, to: opened, using: key)) { error in
            XCTAssertEqual(error as? VaultError, .decryptionFailed)
        }
    }

    func testPlaintextRangeSkipsEarlierChunks() throws {
        let key = crypto.deriveSubkey(crypto.generateKey(), purpose: .content)
        let count = SecurityConstants.fileChunkSize + 32
        let source = try makeFile(count: count)
        let sealed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sealed)
        }
        _ = try crypto.encryptFile(at: source, to: sealed, fileID: UUID(), using: key, shouldContinue: { true })
        let plain = try Data(contentsOf: source)
        let offset = SecurityConstants.fileChunkSize
        let slice = try crypto.plaintextRange(in: sealed, using: key, offset: Int64(offset), length: 32)
        XCTAssertEqual(slice, plain.subdata(in: offset..<(offset + 32)))
    }

    func testIndexRoundTripAndOrphanCleanup() throws {
        let master = crypto.generateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = VaultFileStore(directory: directory, crypto: crypto)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeFile(count: 2_048)
        defer { try? FileManager.default.removeItem(at: source) }
        let item = try store.importFile(at: source, name: "notes.pdf", folderID: nil, companionID: nil, using: master, shouldContinue: { true })
        var library = try store.loadLibrary(using: master)
        library.items = [item]
        try store.saveLibrary(library, using: master)
        let orphan = store.encryptedFileURL(for: UUID())
        try Data("orphan".utf8).write(to: orphan)
        try store.cleanupOrphans(using: master)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.encryptedFileURL(for: item.id).path))
        let loaded = try store.loadLibrary(using: master)
        XCTAssertEqual(loaded.items.map(\.id), [item.id])
        XCTAssertEqual(loaded.items.first?.type, .pdf)
    }

    private func assertRoundTrip(count: Int, key: SymmetricKey) throws {
        let source = try makeFile(count: count)
        let sealed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let opened = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sealed)
            try? FileManager.default.removeItem(at: opened)
        }
        let result = try crypto.encryptFile(at: source, to: sealed, fileID: UUID(), using: key, shouldContinue: { true })
        XCTAssertEqual(result.plaintextBytes, Int64(count))
        try crypto.decryptFile(at: sealed, to: opened, using: key)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: opened))
    }

    private func makeFile(count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var remaining = count
        let block = Data(repeating: 0x5A, count: min(count, 1024 * 1024))
        while remaining > 0 {
            let size = min(remaining, block.count)
            try handle.write(contentsOf: block.prefix(size))
            remaining -= size
        }
        try handle.close()
        return url
    }
}
