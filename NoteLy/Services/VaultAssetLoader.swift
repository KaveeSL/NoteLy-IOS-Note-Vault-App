import AVFoundation
import CryptoKit
import Foundation

/// Decrypts video chunks into `AVAssetResourceLoadingRequest` buffers.
///
/// No plaintext file is written. If a player cannot use this loader, `VaultVideoPlayer`
/// falls back to a temp file under `temporaryDirectory/VaultPlayback/` and deletes it
/// when playback ends, when the vault locks, and on the next launch.
final class VaultAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let contentType: String
    private let contentLength: Int64
    private let key: SymmetricKey
    private let crypto: CryptoServicing

    init(fileURL: URL, contentType: String, contentLength: Int64, key: SymmetricKey, crypto: CryptoServicing) {
        self.fileURL = fileURL
        self.contentType = contentType
        self.contentLength = contentLength
        self.key = key
        self.crypto = crypto
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let offset = dataRequest.requestedOffset
        let length = dataRequest.requestedLength
        do {
            let data = try crypto.plaintextRange(in: fileURL, using: key, offset: offset, length: length)
            dataRequest.respond(with: data)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
        return true
    }
}
