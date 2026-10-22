import CryptoKit
import Foundation
import Security

protocol CryptoServicing: AnyObject, Sendable {
    func generateKey() -> SymmetricKey
    func randomData(count: Int) throws -> Data
    /// PBKDF2-HMAC-SHA256. Used for the secret phrase and for backup passwords.
    func pbkdf2(password: String, salt: Data, iterations: Int, outputLength: Int) throws -> Data
    func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data
    func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data
    /// HKDF-SHA256 subkey. The master key stays in the Keychain; index, file, and thumbnail keys are derived.
    func deriveSubkey(_ master: SymmetricKey, purpose: VaultKeyPurpose) -> SymmetricKey
    /// Streams `source` into an encrypted file. Plaintext is read one chunk at a time.
    func encryptFile(
        at source: URL,
        to destination: URL,
        fileID: UUID,
        using key: SymmetricKey,
        shouldContinue: @escaping () -> Bool
    ) throws -> FileSealResult
    func decryptFile(at source: URL, to destination: URL, using key: SymmetricKey) throws
    /// Decrypts only the plaintext byte range needed for playback. Earlier chunks are skipped, not decrypted.
    func plaintextRange(in file: URL, using key: SymmetricKey, offset: Int64, length: Int) throws -> Data
    /// Compares two blobs without returning early on the first different byte.
    func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool
    func keyData(_ key: SymmetricKey) -> Data
    func key(from data: Data) throws -> SymmetricKey
}

/// AES-GCM encryption and PBKDF2 password stretching.
///
/// Ciphertext layout (version 1):
/// `NLV1` | version (1 byte) | chunk count (UInt32 BE) | repeated (length UInt32 BE + AES.GCM combined).
/// Each chunk uses a new random nonce inside `AES.GCM.seal`. A wrong key or a flipped byte fails authentication.
final class CryptoService: CryptoServicing, @unchecked Sendable {
    func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    func randomData(count: Int) throws -> Data {
        guard count > 0 else { throw VaultError.encryptionFailed }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw VaultError.encryptionFailed }
        return Data(bytes)
    }

    /// Stretches a secret so a stolen keychain hash is expensive to guess offline.
    /// CommonCrypto is used because CryptoKit has no PBKDF2 API and the C implementation
    /// avoids a slow per-iteration Swift allocation loop.
    func pbkdf2(password: String, salt: Data, iterations: Int, outputLength: Int = SecurityConstants.hashLength) throws -> Data {
        guard iterations > 0, outputLength > 0, !salt.isEmpty else {
            throw VaultError.encryptionFailed
        }
        let passwordData = Data(password.utf8)
        guard !passwordData.isEmpty else { throw VaultError.encryptionFailed }

        let passwordBytes = [UInt8](passwordData)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: outputLength)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                derived.withUnsafeMutableBufferPointer { derivedBuffer in
                    guard
                        let passwordBase = passwordBuffer.baseAddress,
                        let saltBase = saltBuffer.baseAddress,
                        let derivedBase = derivedBuffer.baseAddress
                    else {
                        return Int32(-1)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        UnsafeRawPointer(passwordBase).assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBase,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBase,
                        outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.encryptionFailed }
        return Data(derived)
    }

    func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let chunks = plaintextChunks(plaintext)
        var sealedChunks: [Data] = []
        sealedChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            sealedChunks.append(try seal(chunk, using: key))
        }
        return pack(sealedChunks)
    }

    func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let chunks = try unpack(ciphertext)
        var plaintext = Data()
        for chunk in chunks {
            plaintext.append(try open(chunk, using: key))
        }
        return plaintext
    }

    /// The whole length is mixed into the accumulator, then every byte is folded in.
    /// A size mismatch cannot return before the loop, and it cannot compare equal just
    /// because the extra bytes are zeros.
    func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let lhsBytes = [UInt8](lhs)
        let rhsBytes = [UInt8](rhs)
        let length = max(lhsBytes.count, rhsBytes.count, 1)
        var diff = UInt32(lhsBytes.count) ^ UInt32(rhsBytes.count)
        for index in 0..<length {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            diff |= UInt32(left ^ right)
        }
        return diff == 0
    }

    func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VaultError.corruptedData }
        return SymmetricKey(data: data)
    }

    // MARK: - Chunks

    private func plaintextChunks(_ plaintext: Data) -> [Data] {
        if plaintext.isEmpty {
            return [Data()]
        }
        var chunks: [Data] = []
        var offset = 0
        while offset < plaintext.count {
            let end = min(offset + SecurityConstants.chunkSize, plaintext.count)
            chunks.append(plaintext.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    /// Threat: nonce reuse would break AES-GCM. `seal` draws a fresh random nonce every call.
    private func seal(_ chunk: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(chunk, using: key)
            guard let combined = sealed.combined else { throw VaultError.encryptionFailed }
            return combined
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.encryptionFailed
        }
    }

    /// Threat: padding-oracle and bit-flipping. Authentication failure becomes a single error
    /// with no plaintext attached.
    private func open(_ combined: Data, using key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    private func pack(_ chunks: [Data]) -> Data {
        var output = Data()
        output.reserveCapacity(chunks.reduce(9) { $0 + 4 + $1.count })
        output.append(contentsOf: [0x4E, 0x4C, 0x56, 0x31]) // NLV1
        output.append(1)
        appendUInt32(UInt32(chunks.count), to: &output)
        for chunk in chunks {
            appendUInt32(UInt32(chunk.count), to: &output)
            output.append(chunk)
        }
        return output
    }

    private func unpack(_ data: Data) throws -> [Data] {
        guard data.count >= 9 else { throw VaultError.corruptedData }
        guard data.prefix(4).elementsEqual([0x4E, 0x4C, 0x56, 0x31]) else {
            throw VaultError.corruptedData
        }
        guard data[data.startIndex + 4] == 1 else { throw VaultError.corruptedData }
        let count = Int(readUInt32(data, at: 5))
        guard count > 0, count <= SecurityConstants.maxChunkCount else {
            throw VaultError.corruptedData
        }
        var offset = 9
        var chunks: [Data] = []
        chunks.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 4 <= data.count else { throw VaultError.corruptedData }
            let length = Int(readUInt32(data, at: offset))
            offset += 4
            // AES-GCM combined is nonce (12) + tag (16) + ciphertext.
            guard length >= 28, offset + length <= data.count else {
                throw VaultError.corruptedData
            }
            let end = offset + length
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        guard offset == data.count else { throw VaultError.corruptedData }
        return chunks
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
