import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VaultNoteEditorView: View {
    let noteID: UUID
    @ObservedObject var model: VaultViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var didLoad = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var images: [UUID: Data] = [:]
    @State private var pendingDelete: VaultAttachment?
    @State private var confirmNoteDelete = false

    private var note: VaultNote? {
        model.notes.first { $0.id == noteID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: titleBinding, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .accessibilityLabel("Title")

                TextField("Note", text: bodyBinding, axis: .vertical)
                    .lineLimit(6...40)
                    .accessibilityLabel("Note body")

                Text(note?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let note, !note.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Photos")
                            .font(.headline)
                        ForEach(note.attachments) { attachment in
                            photoBlock(attachment)
                        }
                    }
                    .padding(.top, 8)
                }

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.vault)
            }
            .padding(20)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let note {
                    Button {
                        model.setFavorite(id: note.id, favorite: !note.isFavorite)
                    } label: {
                        Image(systemName: note.isFavorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(note.isFavorite ? "Unfavorite" : "Favorite")
                    .tint(Theme.vault)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let note { model.setFavorite(id: note.id, favorite: !note.isFavorite) }
                    } label: {
                        Label(note?.isFavorite == true ? "Unfavorite" : "Favorite", systemImage: note?.isFavorite == true ? "star.slash" : "star")
                    }
                    Button(role: .destructive) { confirmNoteDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.flush()
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.vault, in: Circle())
                }
                .accessibilityLabel("Done")
            }
        }
        .onAppear(perform: loadDraft)
        .task(id: noteID) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            model.recordOpen(id: noteID)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .onDisappear {
            model.flush()
            images.removeAll()
        }
        .confirmationDialog(
            "Remove this photo?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Remove Photo", role: .destructive) {
                if let pendingDelete {
                    model.removePhoto(noteID: noteID, attachmentID: pendingDelete.id)
                    images[pendingDelete.id] = nil
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .alert("Delete this note?", isPresented: $confirmNoteDelete) {
            Button("Delete", role: .destructive) {
                model.moveToTrash(id: noteID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Recently Deleted. You can restore it from there.")
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { newValue in
                title = newValue
                persistDraft()
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { bodyText },
            set: { newValue in
                bodyText = newValue
                persistDraft()
            }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder
    private func photoBlock(_ attachment: VaultAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = images[attachment.id], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(attachment.filename)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .frame(height: 80)
                    .overlay { ProgressView() }
                    .accessibilityLabel("Loading photo")
            }
            Button("Remove Photo", role: .destructive) {
                pendingDelete = attachment
            }
            .font(.subheadline)
        }
    }

    private func loadDraft() {
        guard !didLoad, let note else { return }
        title = note.title
        bodyText = note.body
        didLoad = true
        loadImages(for: note)
    }

    private func persistDraft() {
        guard didLoad, var note else { return }
        note.title = title
        note.body = bodyText
        note.updatedAt = .now
        model.stage(note)
    }

    private func loadImages(for note: VaultNote) {
        for attachment in note.attachments where images[attachment.id] == nil {
            images[attachment.id] = model.loadPhoto(noteID: note.id, attachmentID: attachment.id)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        do {
            guard let imported = try await item.loadTransferable(type: ImportedVaultImage.self) else {
                model.statusMessage = "Couldn't read that photo."
                return
            }
            guard let jpeg = VaultPhotoEncoder.jpegData(from: imported.data) else {
                model.statusMessage = "Couldn't read that photo."
                return
            }
            model.addPhoto(noteID: noteID, filename: "Photo.jpg", imageData: jpeg)
            if let note {
                loadImages(for: note)
            }
        } catch {
            model.statusMessage = "Couldn't read that photo."
        }
    }
}

/// Recompresses a picked photo before encryption so a large original is not held as the stored payload.
enum VaultPhotoEncoder {
    static func jpegData(from raw: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.82) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}

struct ImportedVaultImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ImportedVaultImage(data: data)
        }
    }
}
