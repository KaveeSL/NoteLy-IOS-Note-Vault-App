import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum ThumbnailMaker {
    static func jpeg(from url: URL, type: VaultMediaType) async -> Data? {
        switch type {
        case .photo:
            return imageThumbnail(url)
        case .video:
            return await videoThumbnail(url)
        case .pdf:
            return pdfThumbnail(url)
        case .audio, .archive, .document, .other:
            return nil
        }
    }

    static func dimensions(url: URL, type: VaultMediaType) -> (width: Int, height: Int, duration: Double?) {
        switch type {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return (0, 0, nil)
            }
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            return (width, height, nil)
        case .video:
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard let track = asset.tracks(withMediaType: .video).first else {
                return (0, 0, seconds.isFinite ? seconds : nil)
            }
            let size = track.naturalSize.applying(track.preferredTransform)
            return (Int(abs(size.width)), Int(abs(size.height)), seconds.isFinite ? seconds : nil)
        default:
            return (0, 0, nil)
        }
    }

    private static func imageThumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: SecurityConstants.thumbnailMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }

    private static func videoThumbnail(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: SecurityConstants.thumbnailMaxPixel, height: SecurityConstants.thumbnailMaxPixel)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (image, _) = try await generator.image(at: time)
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
        } catch {
            return nil
        }
    }

    private static func pdfThumbnail(_ url: URL) -> Data? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 300, height: 300), for: .mediaBox)
        return image.jpegData(compressionQuality: 0.82)
    }
}

enum LocationStripper {
    /// Rewrites an image without GPS metadata. The encrypted original is left unchanged.
    static func jpegWithoutLocation(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
