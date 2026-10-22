import Foundation
import CryptoKit

struct VaultBackupAttachment: Codable, Equatable, Sendable {
    var noteID: UUID
    var attachmentID: UUID
    var filename: String
    var data: Data
}

struct VaultBackupPayload: Codable, Equatable, Sendable {
    var format: Int
    var notes: [VaultNote]
    var attachments: [VaultBackupAttachment]
}

protocol VaultBackupServicing: AnyObject, Sendable {
    func exportPayload(_ payload: VaultBackupPayload, password: String) throws -> Data
    func importPayload(_ data: Data, password: String) throws -> VaultBackupPayload
}

/// Password-wrapped copy of the vault for moving to another device.
///
/// The backup password is case-sensitive and is not the search phrase. It is stretched with
/// PBKDF2-HMAC-SHA256 and a random salt stored in the file header. The file holds AES-GCM
/// ciphertext only. The password is not stored. A wrong password fails authentication.
///
/// Layout: `NLBK` | version | iterations UInt32 BE | salt length | salt | chunked AES-GCM payload.
final class VaultBackupService: VaultBackupServicing, @unchecked Sendable {
    private let crypto: CryptoServicing
    private let iterations: Int

    init(crypto: CryptoServicing, iterations: Int = SecurityConstants.pbkdf2Iterations) {
        self.crypto = crypto
        self.iterations = iterations
    }

    func exportPayload(_ payload: VaultBackupPayload, password: String) throws -> Data {
        guard password.count >= SecurityConstants.minBackupPasswordLength else {
            throw VaultError.backupFailed
        }
        let salt = try crypto.randomData(count: SecurityConstants.saltLength)
        let derived = try crypto.pbkdf2(
            password: password,
            salt: salt,
            iterations: iterations,
            outputLength: SecurityConstants.hashLength
        )
        let key = try crypto.key(from: derived)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(payload)
        let cipher = try crypto.encrypt(json, using: key)
        var output = Data()
        output.append(contentsOf: [0x4E, 0x4C, 0x42, 0x4B]) // NLBK
        output.append(1)
        appendUInt32(UInt32(iterations), to: &output)
        output.append(UInt8(salt.count))
        output.append(salt)
        output.append(cipher)
        return output
    }

    func importPayload(_ data: Data, password: String) throws -> VaultBackupPayload {
        guard password.count >= SecurityConstants.minBackupPasswordLength else {
            throw VaultError.importFailed
        }
        guard data.count > 26 else { throw VaultError.importFailed }
        guard data.prefix(4).elementsEqual([0x4E, 0x4C, 0x42, 0x4B]) else {
            throw VaultError.importFailed
        }
        guard data[data.startIndex + 4] == 1 else { throw VaultError.importFailed }
        let iterations = Int(readUInt32(data, at: 5))
        let saltLength = Int(data[data.startIndex + 9])
        guard iterations > 0, saltLength == SecurityConstants.saltLength else {
            throw VaultError.importFailed
        }
        let saltStart = 10
        let saltEnd = saltStart + saltLength
        guard saltEnd <= data.count else { throw VaultError.importFailed }
        let salt = data.subdata(in: saltStart..<saltEnd)
        let cipher = data.subdata(in: saltEnd..<data.count)
        let derived: Data
        do {
            derived = try crypto.pbkdf2(
                password: password,
                salt: salt,
                iterations: iterations,
                outputLength: SecurityConstants.hashLength
            )
        } catch {
            throw VaultError.importFailed
        }
        let key = try crypto.key(from: derived)
        let json: Data
        do {
            json = try crypto.decrypt(cipher, using: key)
        } catch {
            throw VaultError.importFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(VaultBackupPayload.self, from: json)
            guard payload.format == 1 else { throw VaultError.importFailed }
            return payload
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.importFailed
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for byte in data[start..<(start + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
