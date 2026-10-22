import Foundation
import CryptoKit

protocol VaultStoring: AnyObject, Sendable {
    func loadAll(using key: SymmetricKey) throws -> [VaultNote]
    func save(_ note: VaultNote, using key: SymmetricKey) throws
    func delete(id: UUID) throws
    func saveAttachment(noteID: UUID, attachmentID: UUID, data: Data, using key: SymmetricKey) throws
    func loadAttachment(noteID: UUID, attachmentID: UUID, using key: SymmetricKey) throws -> Data
    func deleteAttachment(noteID: UUID, attachmentID: UUID) throws
    func deleteAll() throws
    /// `true` keeps every vault file out of iCloud and Finder backups. This is the default.
    func setExcludedFromBackup(_ excluded: Bool) throws
    /// Writes harmless sample notes the first time the decoy folder is opened.
    func seedSamplesIfNeeded(using key: SymmetricKey) throws -> [VaultNote]
}

/// Encrypted files under Application Support. Titles are not used as filenames.
///
/// Threat: backups and leftover plaintext. Note JSON and photo bytes are AES-GCM ciphertext.
/// Each file is excluded from backup unless the user opts in. Opting in copies ciphertext only;
/// the key is `ThisDeviceOnly` and does not travel with the backup.
final class VaultStore: VaultStoring, @unchecked Sendable {
    let directory: URL
    private let crypto: CryptoServicing
    private let fileManager: FileManager
    private let flagLock = NSLock()
    private var excludedFromBackup: Bool

    init(
        directory: URL,
        crypto: CryptoServicing,
        fileManager: FileManager = .default,
        excludedFromBackup: Bool = true
    ) {
        self.directory = directory
        self.crypto = crypto
        self.fileManager = fileManager
        self.excludedFromBackup = excludedFromBackup
    }

    static func defaultDirectory(subfolder: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NoteLy", isDirectory: true)
            .appendingPathComponent(subfolder, isDirectory: true)
    }

    func loadAll(using key: SymmetricKey) throws -> [VaultNote] {
        try prepareDirectories()
        let files = try noteFiles()
        var notes: [VaultNote] = []
        var failures = 0
        for file in files {
            do {
                let cipher = try Data(contentsOf: file)
                let plain = try crypto.decrypt(cipher, using: key)
                notes.append(try makeDecoder().decode(VaultNote.self, from: plain))
            } catch {
                failures += 1
            }
        }
        if notes.isEmpty, failures > 0 {
            VaultLog.security.error("Vault notes could not be decrypted")
            throw VaultError.decryptionFailed
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ note: VaultNote, using key: SymmetricKey) throws {
        try prepareDirectories()
        let plain = try makeEncoder().encode(note)
        let cipher = try crypto.encrypt(plain, using: key)
        let url = noteURL(note.id)
        do {
            try cipher.write(to: url, options: writeOptions)
        } catch {
            throw VaultError.persistenceFailed
        }
        try applyBackupPolicy(to: url)
    }

    func delete(id: UUID) throws {
        let note = noteURL(id)
        if fileManager.fileExists(atPath: note.path) {
            do {
                try fileManager.removeItem(at: note)
            } catch {
                throw VaultError.persistenceFailed
            }
        }
        let folder = attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                throw VaultError.persistenceFailed
            }
        }
    }

    func saveAttachment(noteID: UUID, attachmentID: UUID, data: Data, using key: SymmetricKey) throws {
        try prepareDirectories()
        let url = attachmentURL(noteID: noteID, attachmentID: attachmentID)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cipher = try crypto.encrypt(data, using: key)
            try cipher.write(to: url, options: writeOptions)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.persistenceFailed
        }
        try applyBackupPolicy(to: url.deletingLastPathComponent())
        try applyBackupPolicy(to: url)
    }

    func loadAttachment(noteID: UUID, attachmentID: UUID, using key: SymmetricKey) throws -> Data {
        let url = attachmentURL(noteID: noteID, attachmentID: attachmentID)
        guard fileManager.fileExists(atPath: url.path) else { throw VaultError.itemNotFound }
        do {
            let cipher = try Data(contentsOf: url)
            return try crypto.decrypt(cipher, using: key)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    func deleteAttachment(noteID: UUID, attachmentID: UUID) throws {
        let url = attachmentURL(noteID: noteID, attachmentID: attachmentID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    func setExcludedFromBackup(_ excluded: Bool) throws {
        flagLock.lock()
        excludedFromBackup = excluded
        flagLock.unlock()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw VaultError.persistenceFailed
        }
        var urls = [directory]
        for case let url as URL in enumerator {
            urls.append(url)
        }
        for url in urls {
            try applyBackupPolicy(to: url, excluded: excluded)
        }
    }

    func seedSamplesIfNeeded(using key: SymmetricKey) throws -> [VaultNote] {
        try prepareDirectories()
        let marker = directory.appendingPathComponent(".seeded")
        if fileManager.fileExists(atPath: marker.path) {
            return try loadAll(using: key)
        }
        let existing = try loadAll(using: key)
        if !existing.isEmpty {
            try writeSeedMarker(marker)
            return existing
        }
        let samples = VaultNote.sampleNotes()
        for sample in samples {
            try save(sample, using: key)
        }
        try writeSeedMarker(marker)
        return samples.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Paths

    private var notesDirectory: URL {
        directory.appendingPathComponent("notes", isDirectory: true)
    }

    private var attachmentsDirectory: URL {
        directory.appendingPathComponent("attachments", isDirectory: true)
    }

    private func noteURL(_ id: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(id.uuidString).bin")
    }

    private func attachmentURL(noteID: UUID, attachmentID: UUID) -> URL {
        attachmentsDirectory
            .appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent("\(attachmentID.uuidString).bin")
    }

    private func noteFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: notesDirectory.path) else { return [] }
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: notesDirectory,
                includingPropertiesForKeys: nil
            )
            return urls.filter { $0.pathExtension == "bin" }
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    private func prepareDirectories() throws {
        do {
            try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        } catch {
            throw VaultError.persistenceFailed
        }
        try applyBackupPolicy(to: directory)
        try applyBackupPolicy(to: notesDirectory)
        try applyBackupPolicy(to: attachmentsDirectory)
    }

    private func writeSeedMarker(_ url: URL) throws {
        do {
            try Data().write(to: url, options: writeOptions)
        } catch {
            throw VaultError.persistenceFailed
        }
        try applyBackupPolicy(to: url)
    }

    private var writeOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    private func backupExcludedFlag() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return excludedFromBackup
    }

    private func applyBackupPolicy(to url: URL) throws {
        try applyBackupPolicy(to: url, excluded: backupExcludedFlag())
    }

    private func applyBackupPolicy(to url: URL, excluded: Bool) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        do {
            try mutable.setResourceValues(values)
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
