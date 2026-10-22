import XCTest
@testable import NoteLy

final class VaultStoreTests: XCTestCase {
    private var directory: URL!
    private var store: VaultStore!
    private let crypto = CryptoService()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteLyTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(directory: directory, crypto: crypto, excludedFromBackup: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreateUpdateDelete() throws {
        let key = crypto.generateKey()
        var note = VaultNote(title: "Title", body: "Body")
        try store.save(note, using: key)
        var loaded = try store.loadAll(using: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].body, "Body")

        note.body = "Changed"
        note.updatedAt = Date().addingTimeInterval(10)
        try store.save(note, using: key)
        loaded = try store.loadAll(using: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].body, "Changed")

        try store.delete(id: note.id)
        XCTAssertTrue(try store.loadAll(using: key).isEmpty)
    }

    func testWrongKeyCannotRead() throws {
        let note = VaultNote(title: "Hidden", body: "super-secret-body")
        try store.save(note, using: crypto.generateKey())
        XCTAssertThrowsError(try store.loadAll(using: crypto.generateKey())) { error in
            XCTAssertEqual(error as? VaultError, .decryptionFailed)
        }
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let body = "super-secret-body-that-must-not-land-on-disk"
        let note = VaultNote(title: "Hidden", body: body)
        try store.save(note, using: crypto.generateKey())
        let file = try XCTUnwrap(noteFile())
        let cipher = try Data(contentsOf: file)
        XCTAssertNil(cipher.range(of: Data(body.utf8)))
        XCTAssertNil(cipher.range(of: Data("Hidden".utf8)))
    }

    func testAttachmentRoundTripAndCleanup() throws {
        let key = crypto.generateKey()
        let note = VaultNote(title: "Photo note", body: "See photo")
        let payload = Data("jpeg-bytes-not-really".utf8)
        let attachmentID = UUID()
        try store.saveAttachment(noteID: note.id, attachmentID: attachmentID, data: payload, using: key)
        try store.save(note, using: key)
        let opened = try store.loadAttachment(noteID: note.id, attachmentID: attachmentID, using: key)
        XCTAssertEqual(opened, payload)
        try store.delete(id: note.id)
        XCTAssertThrowsError(
            try store.loadAttachment(noteID: note.id, attachmentID: attachmentID, using: key)
        ) { error in
            XCTAssertEqual(error as? VaultError, .itemNotFound)
        }
    }

    func testExcludedFromBackupByDefault() throws {
        let note = VaultNote(title: "A", body: "B")
        try store.save(note, using: crypto.generateKey())
        let file = try XCTUnwrap(noteFile())
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        try store.setExcludedFromBackup(false)
        let optedIn = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(optedIn.isExcludedFromBackup, false)
    }

    func testDeleteAllRemovesFiles() throws {
        try store.save(VaultNote(title: "A", body: "B"), using: crypto.generateKey())
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testBackupRoundTripAndWrongPassword() throws {
        let backup = VaultBackupService(crypto: crypto, iterations: 1_000)
        let note = VaultNote(title: "Moved", body: "Bring me along")
        let attachment = VaultAttachment(filename: "Photo.jpg")
        var stored = note
        stored.attachments = [attachment]
        let payload = VaultBackupPayload(
            format: 1,
            notes: [stored],
            attachments: [
                VaultBackupAttachment(
                    noteID: note.id,
                    attachmentID: attachment.id,
                    filename: "Photo.jpg",
                    data: Data("image-bytes".utf8)
                )
            ]
        )
        let file = try backup.exportPayload(payload, password: "backup-pass")
        XCTAssertNil(file.range(of: Data("Bring me along".utf8)))
        let imported = try backup.importPayload(file, password: "backup-pass")
        XCTAssertEqual(imported, payload)
        XCTAssertThrowsError(try backup.importPayload(file, password: "wrong-password")) { error in
            XCTAssertEqual(error as? VaultError, .importFailed)
        }
        XCTAssertThrowsError(try backup.exportPayload(payload, password: "short")) { error in
            XCTAssertEqual(error as? VaultError, .backupFailed)
        }
    }

    private func noteFile() throws -> URL? {
        let notes = directory.appendingPathComponent("notes", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
        return files.first { $0.pathExtension == "bin" }
    }
}
