import os
import PhotosUI
import SwiftUI

enum ImportLog {
    private static let logger = Logger(subsystem: "com.notely.notes.kaveesha", category: "import")

    static func step(_ name: String) {
        logger.info("\(name, privacy: .public)")
    }
}

/// System photo picker presented from the vault root. The SwiftUI PhotosPicker was dropping videos.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPick: ([PHPickerResult]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 0
        configuration.filter = .any(of: [.images, .videos, .livePhotos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        ImportLog.step("picker opened")
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, dismiss: dismiss) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        let dismiss: DismissAction
        init(onPick: @escaping ([PHPickerResult]) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            ImportLog.step("items returned \(results.count)")
            onPick(results)
            dismiss()
        }
    }
}
