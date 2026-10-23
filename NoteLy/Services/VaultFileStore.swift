import CryptoKit
import Foundation

protocol VaultFileStoring: AnyObject, Sendable {
    func loadLibrary(using master: SymmetricKey) throws -> VaultLibrarySnapshot
    func saveLibrary(_ library: VaultLibrarySnapshot, using master: SymmetricKey) throws
    func importFile(
        at source: URL,
        name: String,
        folderID: UUID?,
        companionID: UUID?,
        using master: SymmetricKey,
        shouldContinue: @escaping () -> Bool
    ) throws -> VaultItem
    func deleteItem(_ item: VaultItem, proof: RiskProof) throws
    func deleteExpiredItem(_ item: VaultItem) throws
    func thumbnailData(for id: UUID, using master: SymmetricKey) throws -> Data?
    func saveThumbnail(_ data: Data, id: UUID, using master: SymmetricKey) throws
    func encryptedFileURL(for id: UUID) -> URL
    func plaintextCopy(of item: VaultItem, using master: SymmetricKey, to destination: URL) throws
    func exportCopy(of item: VaultItem, using master: SymmetricKey, to destination: URL, proof: RiskProof) throws
    func cleanupOrphans(using master: SymmetricKey) throws
    func deleteAll() throws
    static func purgeTemporaryFiles()
}

/// Encrypted photos, videos, and files under Application Support. Names on disk are UUIDs.
///
/// Threat: leftover plaintext and partial imports. Bytes are written to a `.partial` file and
/// moved into place only after the last chunk authenticates. Launch deletes leftover partials.
final class VaultFileStore: VaultFileStoring, @unchecked Sendable {
    let directory: URL
    var risks: RiskLedger?
    private let crypto: CryptoServicing
    private let fileManager: FileManager

    init(directory: URL, crypto: CryptoServicing, fileManager: FileManager = .default) {
        self.directory = directory
        self.crypto = crypto
        self.fileManager = fileManager
    }

    static func defaultDirectory() -> URL {
        VaultStore.defaultDirectory(subfolder: "Vault")
    }

    /// Folders that may hold a decrypted photo, video, or document while the vault is open.
    /// They are removed on lock and on the next launch. A computer never sees these as the stored copy.
    static let plaintextFolderNames = ["VaultPlayback", "VaultThumbs", "VaultImport", "NoteLyPlain"]

    static func purgeTemporaryFiles() {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        for name in plaintextFolderNames {
            let root = temporary.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: root.path) {
                try? manager.removeItem(at: root)
            }
        }
        if let loose = try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            let media = Set(["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v", "pdf", "caf", "bin"])
            for url in loose where media.contains(url.pathExtension.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                if UUID(uuidString: stem) != nil {
                    try? manager.removeItem(at: url)
                }
            }
        }
        let vault = defaultDirectory()
        for folder in ["files", "thumbs"] {
            let dir = vault.appendingPathComponent(folder, isDirectory: true)
            guard let names = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in names where url.pathExtension == "partial" || url.lastPathComponent.hasSuffix(".enc.partial") {
                try? manager.removeItem(at: url)
            }
        }
    }

    func loadLibrary(using master: SymmetricKey) throws -> VaultLibrarySnapshot {
        try prepare()
        let url = indexURL
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        do {
            let cipher = try Data(contentsOf: url)
            let plain = try crypto.decrypt(cipher, using: crypto.deriveSubkey(master, purpose: .index))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VaultLibrarySnapshot.self, from: plain)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    func saveLibrary(_ library: VaultLibrarySnapshot, using master: SymmetricKey) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(library)
        let cipher = try crypto.encrypt(plain, using: crypto.deriveSubkey(master, purpose: .index))
        let temp = indexURL.appendingPathExtension("partial")
        do {
            try cipher.write(to: temp, options: [.atomic, .completeFileProtection])
            if fileManager.fileExists(atPath: indexURL.path) {
                try fileManager.removeItem(at: indexURL)
            }
            try fileManager.moveItem(at: temp, to: indexURL)
            try exclude(indexURL)
        } catch let error as VaultError {
            try? fileManager.removeItem(at: temp)
            throw error
        } catch {
            try? fileManager.removeItem(at: temp)
            throw VaultError.persistenceFailed
        }
    }

    func importFile(
        at source: URL,
        name: String,
        folderID: UUID?,
        companionID: UUID?,
        using master: SymmetricKey,
        shouldContinue: @escaping () -> Bool
    ) throws -> VaultItem {
        try prepare()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let size = Int64(values.fileSize ?? 0)
        if size > SecurityConstants.maxImportFileBytes {
            throw VaultError.fileTooLarge
        }
        try ensureSpace(for: size)
        let head = try readHead(source)
        let kind = InputValidators.mediaType(filename: name, head: head)
        let id = UUID()
        let destination = encryptedFileURL(for: id)
        let sealed = try crypto.encryptFile(
            at: source,
            to: destination,
            fileID: id,
            using: crypto.deriveSubkey(master, purpose: .content),
            shouldContinue: shouldContinue
        )
        try exclude(destination)
        return VaultItem(
            id: id,
            originalName: InputValidators.sanitizedFilename(name),
            type: kind.0,
            utType: kind.1,
            size: sealed.plaintextBytes,
            createdAt: values.creationDate ?? .now,
            plaintextSHA256: sealed.plaintextSHA256.base64EncodedString(),
            companionID: companionID
        ).placing(folderID: folderID)
    }

    func deleteItem(_ item: VaultItem, proof: RiskProof) throws {
        guard proof.action == .permanentDelete || proof.action == .emptyBin else {
            throw VaultError.authorizationRequired
        }
        guard let risks else { throw VaultError.authorizationRequired }
        try risks.require(proof, action: proof.action)
        try deleteExpiredItem(item)
    }

    func deleteExpiredItem(_ item: VaultItem) throws {
        try bestEffortOverwrite(encryptedFileURL(for: item.id))
        if item.hasThumbnail {
            try bestEffortOverwrite(thumbnailURL(item.id))
        }
    }

    func thumbnailData(for id: UUID, using master: SymmetricKey) throws -> Data? {
        let url = thumbnailURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let cipher = try Data(contentsOf: url)
        return try crypto.decrypt(cipher, using: crypto.deriveSubkey(master, purpose: .thumbnail))
    }

    func saveThumbnail(_ data: Data, id: UUID, using master: SymmetricKey) throws {
        try prepare()
        let cipher = try crypto.encrypt(data, using: crypto.deriveSubkey(master, purpose: .thumbnail))
        let url = thumbnailURL(id)
        try cipher.write(to: url, options: [.atomic, .completeFileProtection])
        try exclude(url)
    }

    func encryptedFileURL(for id: UUID) -> URL {
        filesDirectory.appendingPathComponent("\(id.uuidString).enc")
    }

    func plaintextCopy(of item: VaultItem, using master: SymmetricKey, to destination: URL) throws {
        try crypto.decryptFile(
            at: encryptedFileURL(for: item.id),
            to: destination,
            using: crypto.deriveSubkey(master, purpose: .content)
        )
    }

    func exportCopy(of item: VaultItem, using master: SymmetricKey, to destination: URL, proof: RiskProof) throws {
        guard proof.action == .export else { throw VaultError.authorizationRequired }
        guard let risks else { throw VaultError.authorizationRequired }
        try risks.require(proof, action: .export)
        try plaintextCopy(of: item, using: master, to: destination)
    }

    func cleanupOrphans(using master: SymmetricKey) throws {
        try prepare()
        let library = try loadLibrary(using: master)
        let known = Set(library.items.map(\.id.uuidString))
        for folder in [filesDirectory, thumbsDirectory] {
            let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in urls {
                if url.pathExtension == "partial" || url.lastPathComponent.contains(".partial") {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                let stem = url.deletingPathExtension().lastPathComponent
                if !known.contains(stem) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    func deleteAll() throws {
        for folder in [filesDirectory, thumbsDirectory] where fileManager.fileExists(atPath: folder.path) {
            try? fileManager.removeItem(at: folder)
        }
        if fileManager.fileExists(atPath: indexURL.path) {
            try? fileManager.removeItem(at: indexURL)
        }
    }

    // MARK: - Paths

    private var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    private var thumbsDirectory: URL { directory.appendingPathComponent("thumbs", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("index.enc") }

    private func thumbnailURL(_ id: UUID) -> URL {
        thumbsDirectory.appendingPathComponent("\(id.uuidString).enc")
    }

    private func prepare() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try fileManager.createDirectory(
                at: filesDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try fileManager.createDirectory(
                at: thumbsDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            throw VaultError.persistenceFailed
        }
        try exclude(directory)
        try exclude(filesDirectory)
        try exclude(thumbsDirectory)
    }

    /// Ciphertext stays in Application Support, so the Files app cannot open it.
    /// When backup is on, the encrypted bytes are included. The key stays in the keychain and is not backed up.
    func applyBackupExclusion(_ excluded: Bool) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        if let names = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in names {
                try setExcluded(url, excluded: excluded)
            }
        }
        try setExcluded(directory, excluded: excluded)
    }

    private func exclude(_ url: URL) throws {
        try setExcluded(url, excluded: Self.backupExcludedByDefault())
    }

    static func backupExcludedByDefault() -> Bool {
        !UserDefaults.standard.bool(forKey: PreferenceKey.backupOptIn)
    }

    private func setExcluded(_ url: URL, excluded: Bool) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        do {
            try mutable.setResourceValues(values)
        } catch {
            throw VaultError.persistenceFailed
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        }
    }

    private func ensureSpace(for bytes: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        if free < bytes + SecurityConstants.importHeadroomBytes {
            throw VaultError.insufficientSpace
        }
    }

    private func readHead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 32) ?? Data()
    }

    /// Best effort. SSD wear leveling can keep old blocks. Encryption is the real control:
    /// deleting the key makes the ciphertext unreadable.
    private func bestEffortOverwrite(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 8_000_000 {
            let noise = try? crypto.randomData(count: size)
            try? noise?.write(to: url, options: .atomic)
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VaultError.persistenceFailed
        }
    }
}

private extension VaultItem {
    func placing(folderID: UUID?) -> VaultItem {
        var copy = self
        copy.folderID = folderID
        return copy
    }
}
