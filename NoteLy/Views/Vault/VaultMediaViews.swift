import AVFoundation
import AVKit
import ImageIO
import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct VaultItemViewer: View {
    let items: [VaultItem]
    @ObservedObject var model: VaultFilesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var position: Int?
    @State private var showInfo = false

    init(item: VaultItem, items strip: [VaultItem]? = nil, model: VaultFilesViewModel) {
        let pages: [VaultItem]
        if let strip, !strip.isEmpty {
            pages = strip
        } else {
            pages = [item]
        }
        self.items = pages
        let start = pages.firstIndex(where: { $0.id == item.id }) ?? 0
        _position = State(initialValue: start)
        self.model = model
    }

    private var current: VaultItem {
        let index = position ?? 0
        if items.indices.contains(index) { return items[index] }
        return items[0]
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        VaultGalleryPage(item: item, active: position == offset, model: model)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(offset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current.type == .photo ? "Photo" : (current.type == .video ? "Video" : "File"))
                            .font(.headline)
                        if items.count > 1 {
                            Text("\(min((position ?? 0) + 1, items.count)) of \(items.count)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Info")
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showInfo) {
                NavigationStack {
                    List {
                        LabeledContent("Name", value: current.originalName)
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: current.size, countStyle: .file))
                        LabeledContent("Added", value: current.importedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .navigationTitle("Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showInfo = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
        .onAppear { updateRotation() }
        .onChange(of: position) { _, _ in updateRotation() }
        .onDisappear {
            AppOrientation.apply(.portrait)
            VaultFileStore.purgeTemporaryFiles()
        }
    }

    private func updateRotation() {
        if current.type == .photo || current.type == .video {
            AppOrientation.apply(.allButUpsideDown)
        } else {
            AppOrientation.apply(.portrait)
        }
    }
}

private struct VaultGalleryPage: View {
    let item: VaultItem
    let active: Bool
    @ObservedObject var model: VaultFilesViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var pdfData: Data?
    @State private var previewURL: URL?
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if failed {
                ContentUnavailableView("File can't be opened", systemImage: "exclamationmark.triangle")
            } else {
                content
            }
        }
        .task(id: active) {
            if active {
                await open()
                if active { model.recordOpen(id: item.id) }
            } else {
                release()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player?.pause() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .photo:
            if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView().tint(.white)
            }
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .onAppear { if active { player.play() } }
            } else {
                ProgressView().tint(.white)
            }
        case .pdf:
            if let pdfData {
                PDFKitView(data: pdfData)
            } else {
                ProgressView().tint(.white)
            }
        case .audio, .archive, .document, .other:
            if let previewURL {
                QuickLookPreview(url: previewURL)
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    private func open() async {
        release()
        failed = false
        do {
            switch item.type {
            case .photo:
                let url = try await model.materialize(item, stripLocation: false)
                guard active, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                previewURL = url
                image = downsampled(url)
            case .pdf:
                let url = try await model.materialize(item, stripLocation: false)
                guard active, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                previewURL = url
                pdfData = try Data(contentsOf: url)
            case .video:
                let url = try await model.materialize(item, stripLocation: false)
                guard active, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                previewURL = url
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
                let created = AVPlayer(playerItem: AVPlayerItem(url: url))
                created.isMuted = false
                player = created
                if active { created.play() }
            case .audio, .archive, .document, .other:
                let url = try await model.materialize(item, stripLocation: false)
                guard active, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                previewURL = url
            }
        } catch {
            failed = true
        }
    }

    private func release() {
        player?.pause()
        player = nil
        pdfData = nil
        image = nil
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
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
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteLyPlain", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent("\(UUID().uuidString).mov")
                try? FileManager.default.copyItem(at: url, to: copy)
                onCapture(copy, "Video.mov")
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteLyPlain", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
                try? data.write(to: url, options: .completeFileProtection)
                onCapture(url, "Photo.jpg")
            }
            dismiss()
        }
    }
}
