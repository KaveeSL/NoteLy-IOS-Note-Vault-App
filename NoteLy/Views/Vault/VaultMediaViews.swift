import AVFoundation
import AVKit
import ImageIO
import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct VaultItemViewer: View {
    let item: VaultItem
    @ObservedObject var model: VaultFilesViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var pdfData: Data?
    @State private var previewURL: URL?
    @State private var player: AVPlayer?
    @State private var loader: VaultAssetLoader?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    ContentUnavailableView("File can't be opened", systemImage: "exclamationmark.triangle")
                } else {
                    content
                }
            }
            .navigationTitle(item.originalName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(item.isFavorite ? "Unfavorite" : "Favorite") {
                        model.setFavorite(ids: [item.id], favorite: !item.isFavorite)
                    }
                }
            }
        }
        .task { await open() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                player?.pause()
            }
        }
        .onDisappear { closeTemps() }
        .task(id: item.id) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            model.recordOpen(id: item.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .photo:
            if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView()
            }
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            } else {
                ProgressView()
            }
        case .pdf:
            if let pdfData {
                PDFKitView(data: pdfData)
            } else {
                ProgressView()
            }
        case .audio, .archive, .document, .other:
            if let previewURL {
                QuickLookPreview(url: previewURL)
            } else {
                ProgressView()
            }
        }
    }

    private func open() async {
        do {
            switch item.type {
            case .photo:
                let url = try await model.materialize(item, stripLocation: false)
                previewURL = url
                image = downsampled(url)
            case .pdf:
                let url = try await model.materialize(item, stripLocation: false)
                previewURL = url
                pdfData = try Data(contentsOf: url)
            case .video:
                let url = try await model.materialize(item, stripLocation: false)
                previewURL = url
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
                let created = AVPlayer(playerItem: AVPlayerItem(url: url))
                created.isMuted = false
                player = created
            case .audio, .archive, .document, .other:
                previewURL = try await model.materialize(item, stripLocation: false)
            }
        } catch {
            failed = true
        }
    }

    private func close() {
        player?.pause()
        closeTemps()
        dismiss()
    }

    private func closeTemps() {
        player?.pause()
        player = nil
        loader = nil
        pdfData = nil
        image = nil
        VaultFileStore.purgeTemporaryFiles()
        previewURL = nil
    }

    private func downsampled(_ url: URL) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(base * value.magnification, 1), 5)
                    }
                    .onEnded { _ in base = scale }
            )
            .onTapGesture(count: 2) {
                scale = scale > 1 ? 1 : 2
                base = scale
            }
            .accessibilityLabel("Photo")
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = UIImagePickerController.availableMediaTypes(for: .camera) ?? ["public.image"]
        picker.delegate = context.coordinator
        picker.cameraCaptureMode = .photo
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (URL, String) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (URL, String) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
                try? FileManager.default.copyItem(at: url, to: copy)
                onCapture(copy, "Video.mov")
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
                try? data.write(to: url, options: .completeFileProtectionUnlessOpen)
                onCapture(url, "Photo.jpg")
            }
            dismiss()
        }
    }
}
