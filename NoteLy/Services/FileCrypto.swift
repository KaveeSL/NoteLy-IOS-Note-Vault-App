import CryptoKit
import Foundation

/// Separate HKDF labels so a file key cannot decrypt the index or a thumbnail.
enum VaultKeyPurpose: String, Sendable {
    case index = "notely.vault.index.v1"
    case content = "notely.vault.content.v1"
    case thumbnail = "notely.vault.thumb.v1"
}

struct FileSealResult: Equatable, Sendable {
    var plaintextSHA256: Data
    var plaintextBytes: Int64
}

/// On-disk layout for large files (version 1):
/// `NLF2` | version (1) | chunk size (UInt32 BE) | file id (16) | salt (16)
/// then repeated: length (UInt32 BE) | AES-GCM combined (nonce || ciphertext || tag).
///
/// Each chunk's authenticated data is the file id, the chunk index, and the per-file salt.
/// Reordering or swapping chunks fails authentication. Plaintext is never held whole.
enum FileCipherFormat {
    static let magic: [UInt8] = [0x4E, 0x4C, 0x46, 0x32] // NLF2
    static let version: UInt8 = 1
    static let headerLength = 41
    static let gcmOverhead = 28
}

extension CryptoService {
    func deriveSubkey(_ master: SymmetricKey, purpose: VaultKeyPurpose) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data("NoteLy-HKDF-v1".utf8),
            info: Data(purpose.rawValue.utf8),
            outputByteCount: 32
        )
    }

    func encryptFile(
        at source: URL,
        to destination: URL,
        fileID: UUID,
        using key: SymmetricKey,
        shouldContinue: @escaping () -> Bool
    ) throws -> FileSealResult {
        let salt = try randomData(count: 16)
        let fileIDData = fileID.vaultBytes
        let temp = destination.appendingPathExtension("partial")
        let manager = FileManager.default
        if manager.fileExists(atPath: temp.path) {
            try? manager.removeItem(at: temp)
        }
        manager.createFile(
            atPath: temp.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }

        var header = Data()
        header.append(contentsOf: FileCipherFormat.magic)
        header.append(FileCipherFormat.version)
        appendUInt32(UInt32(SecurityConstants.fileChunkSize), to: &header)
        header.append(fileIDData)
        header.append(salt)
        try output.write(contentsOf: header)

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        var index: UInt32 = 0
        var total: Int64 = 0
        let chunkSize = SecurityConstants.fileChunkSize
        while true {
            if !shouldContinue() {
                try? output.close()
                try? manager.removeItem(at: temp)
                throw VaultError.importCancelled
            }
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty && index > 0 { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            let sealed = try sealFileChunk(chunk, index: index, fileID: fileIDData, salt: salt, using: key)
            var prefix = Data()
            appendUInt32(UInt32(sealed.count), to: &prefix)
            try output.write(contentsOf: prefix)
            try output.write(contentsOf: sealed)
            index += 1
            if chunk.count < chunkSize { break }
            if index > UInt32(SecurityConstants.maxChunkCount) {
                throw VaultError.encryptionFailed
            }
        }
        try output.close()
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temp, to: destination)
        try applyFileProtection(destination)
        return FileSealResult(plaintextSHA256: Data(hasher.finalize()), plaintextBytes: total)
    }

    func decryptFile(at source: URL, to destination: URL, using key: SymmetricKey) throws {
        let manager = FileManager.default
        let temp = destination.appendingPathExtension("partial")
        if manager.fileExists(atPath: temp.path) {
            try? manager.removeItem(at: temp)
        }
        manager.createFile(
            atPath: temp.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        do {
            try decryptChunkStream(at: source, using: key) { _, plaintext in
                let handle = try FileHandle(forWritingTo: temp)
                try handle.seekToEnd()
                try handle.write(contentsOf: plaintext)
                try handle.close()
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temp, to: destination)
            try applyFileProtection(destination)
        } catch {
            try? manager.removeItem(at: temp)
            throw error
        }
    }

    func plaintextRange(in file: URL, using key: SymmetricKey, offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else { throw VaultError.corruptedData }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try readHeader(handle)
        var produced: Int64 = 0
        var index: UInt32 = 0
        var output = Data()
        let end = offset + Int64(length)
        while produced < end {
            let sealedLength = try readLength(handle)
            guard let sealedLength else { break }
            let plaintextLength = sealedLength - FileCipherFormat.gcmOverhead
            guard plaintextLength >= 0 else { throw VaultError.corruptedData }
            let chunkStart = produced
            let chunkEnd = produced + Int64(plaintextLength)
            if chunkEnd <= offset {
                try handle.seek(toOffset: try handle.offset() + UInt64(sealedLength))
                produced = chunkEnd
                index += 1
                continue
            }
            let sealed = try readExact(handle, count: sealedLength)
            let plain = try openFileChunk(sealed, index: index, header: header, using: key)
            let localStart = Int(max(offset, chunkStart) - chunkStart)
            let localEnd = Int(min(end, chunkEnd) - chunkStart)
            if localStart < localEnd, localEnd <= plain.count {
                output.append(plain.subdata(in: localStart..<localEnd))
            }
            produced = chunkEnd
            index += 1
        }
        return output
    }

    private func decryptChunkStream(
        at source: URL,
        using key: SymmetricKey,
        consume: (UInt32, Data) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let header = try readHeader(handle)
        var index: UInt32 = 0
        while true {
            guard let sealedLength = try readLength(handle) else { break }
            let sealed = try readExact(handle, count: sealedLength)
            let plain = try openFileChunk(sealed, index: index, header: header, using: key)
            try consume(index, plain)
            index += 1
        }
        if index == 0 { throw VaultError.corruptedData }
    }

    private struct FileHeader {
        var chunkSize: UInt32
        var fileID: Data
        var salt: Data
    }

    private func readHeader(_ handle: FileHandle) throws -> FileHeader {
        let bytes = try readExact(handle, count: FileCipherFormat.headerLength)
        guard bytes.prefix(4).elementsEqual(FileCipherFormat.magic) else { throw VaultError.corruptedData }
        guard bytes[4] == FileCipherFormat.version else { throw VaultError.corruptedData }
        let chunkSize = readUInt32(bytes, at: 5)
        guard chunkSize > 0 else { throw VaultError.corruptedData }
        let fileID = bytes.subdata(in: 9..<25)
        let salt = bytes.subdata(in: 25..<41)
        return FileHeader(chunkSize: chunkSize, fileID: fileID, salt: salt)
    }

    private func sealFileChunk(
        _ chunk: Data,
        index: UInt32,
        fileID: Data,
        salt: Data,
        using key: SymmetricKey
    ) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: fileAAD(fileID: fileID, salt: salt, index: index))
            guard let combined = sealed.combined else { throw VaultError.encryptionFailed }
            return combined
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.encryptionFailed
        }
    }

    private func openFileChunk(
        _ combined: Data,
        index: UInt32,
        header: FileHeader,
        using key: SymmetricKey
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: fileAAD(fileID: header.fileID, salt: header.salt, index: index)
            )
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    private func fileAAD(fileID: Data, salt: Data, index: UInt32) -> Data {
        var aad = Data()
        aad.append(fileID)
        var bigEndian = index.bigEndian
        withUnsafeBytes(of: &bigEndian) { aad.append(contentsOf: $0) }
        aad.append(salt)
        return aad
    }

    private func readLength(_ handle: FileHandle) throws -> Int? {
        let bytes = try handle.read(upToCount: 4) ?? Data()
        if bytes.isEmpty { return nil }
        guard bytes.count == 4 else { throw VaultError.corruptedData }
        return Int(readUInt32(bytes, at: 0))
    }

    private func readExact(_ handle: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else { throw VaultError.corruptedData }
        if count == 0 { return Data() }
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw VaultError.corruptedData }
        return data
    }

    private func applyFileProtection(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            throw VaultError.persistenceFailed
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        let bytes = data[start..<(start + 4)]
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}

extension UUID {
    var vaultBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}

extension CryptoServicing {
    func encryptData(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        try encrypt(plaintext, using: key)
    }

    func decryptData(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        try decrypt(ciphertext, using: key)
    }
}
