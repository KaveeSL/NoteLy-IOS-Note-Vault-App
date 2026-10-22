import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VaultFilesView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: VaultFilesViewModel
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var removeFromPhotos = false
    @State private var viewer: VaultItem?
    @State private var exportURL: URL?
    @State private var shareURLs: [URL] = []
    @State private var newFolder = ""
    @State private var showNewFolder = false
    @State private var renameTarget: VaultItem?
    @State private var renameText = ""
    @State private var pendingDelete: VaultItem?
    @State private var gateFolder: VaultFolder?
    @State private var gateCode = ""
    @State private var settingPasscode = false
    @State private var renameFolderTarget: VaultFolder?
    @State private var renameFolderText = ""
    @State private var explainPhotos = false
    @State private var explainCamera = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if model.gallery {
                ScrollView {
                    if model.folderID == nil, !model.folders.isEmpty {
                        folderSection
                    }
                    if model.visibleItems.isEmpty {
                        emptyFiles
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(model.visibleItems) { item in
                                cell(item)
                            }
                        }
                        .padding(1)
                    }
                }
            } else {
                List {
                    if model.folderID == nil, !model.folders.isEmpty {
                        Section {
                            ForEach(model.folders) { folder in
                                Button { open(folder) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: folder.hasPasscode ? "lock.fill" : "folder.fill")
                                            .foregroundStyle(Theme.vault)
                                        Text(folder.name)
                                        Spacer()
                                        Text("\(model.itemCount(in: folder.id))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        if model.visibleItems.isEmpty {
                            emptyFiles
                        } else {
                            ForEach(model.visibleItems) { item in
                                listRow(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            Text(model.storageSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                .accessibilityLabel(model.storageSummary)
        }
        .navigationTitle(folderTitle)
        .searchable(text: $model.query, prompt: "Search files")
        .background(SearchFieldTraits())
        .toolbar { toolbar }
        .sheet(item: $viewer) { item in
            VaultItemViewer(item: item, model: model)
        }
        .sheet(isPresented: $explainPhotos) {
            PermissionPrimer(
                symbol: "photo.on.rectangle",
                title: "Photos stay in the vault",
                message: "The photo picker opens only when you choose to import. NoteLy does not upload the library.",
                confirmTitle: "Choose photos",
                onConfirm: {
                    appState.markPermissionExplained(.photos)
                    explainPhotos = false
                    model.wantsPhotoPicker = true
                },
                onCancel: { explainPhotos = false }
            )
        }
        .sheet(isPresented: $explainCamera) {
            PermissionPrimer(
                symbol: "camera",
                title: "Camera for private capture",
                message: "The camera is used only when you take a photo or scan into the vault. You can say no.",
                confirmTitle: "Continue",
                onConfirm: {
                    appState.markPermissionExplained(.camera)
                    explainCamera = false
                    showCamera = true
                },
                onCancel: { explainCamera = false }
            )
        }
        .sheet(isPresented: $showCamera, onDismiss: { appState.setSystemUI(false) }) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                CameraCaptureView { url, name in
                    model.importCameraFile(url, filename: name)
                }
            } else {
                ContentUnavailableView("No camera", systemImage: "camera", description: Text("This device can't capture a photo."))
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            appState.setSystemUI(false)
            if case .success(let urls) = result {
                model.importSecurityScoped(urls)
            }
        }
        .onChange(of: showFiles) { _, presented in
            appState.setSystemUI(presented)
        }
        .onChange(of: showCamera) { _, presented in
            if presented { appState.setSystemUI(true) }
        }
        .sheet(isPresented: sharePresented, onDismiss: { appState.setSystemUI(false) }) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Exported files leave the protected vault.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                    ShareLink(items: shareURLs) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .padding()
                .navigationTitle("Export")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { shareURLs = [] }
                    }
                }
            }
            .onAppear { appState.setSystemUI(true) }
        }
        .sheet(isPresented: exportPresented, onDismiss: { appState.setSystemUI(false) }) {
            if let exportURL {
                NavigationStack {
                    VStack(spacing: 16) {
                        Text("Exported files leave the protected vault.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                        ShareLink(item: exportURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding()
                    .navigationTitle("Export")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { self.exportURL = nil }
                        }
                    }
                }
                .onAppear { appState.setSystemUI(true) }
            }
        }
        .confirmationDialog("Already saved", isPresented: duplicatePresented, titleVisibility: .visible) {
            Button("Keep Both") { model.resolveDuplicate(.keepBoth) }
            Button("Skip", role: .cancel) { model.resolveDuplicate(.skip) }
        } message: {
            Text(model.duplicatePrompt?.name ?? "This file is already in the vault.")
        }
        .alert(settingPasscode ? "Folder Passcode" : "Unlock Folder", isPresented: gatePresented) {
            SecureField("Passcode", text: $gateCode)
            Button(settingPasscode ? "Save" : "Unlock") { commitGate() }
            Button("Cancel", role: .cancel) {
                gateFolder = nil
                gateCode = ""
            }
        } message: {
            Text(settingPasscode
                 ? "This extra passcode is stored inside the vault. Use 4 to 32 characters."
                 : "This folder has its own passcode.")
        }
        .alert("Rename Folder", isPresented: renameFolderPresented) {
            TextField("Name", text: $renameFolderText)
            Button("Save") {
                if let renameFolderTarget {
                    model.renameFolder(id: renameFolderTarget.id, name: renameFolderText)
                }
                renameFolderTarget = nil
            }
            Button("Cancel", role: .cancel) { renameFolderTarget = nil }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") {
                model.createFolder(name: newFolder)
                newFolder = ""
            }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
        .alert("Delete this file?", isPresented: deletePresented) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    model.moveToTrash(ids: [pendingDelete.id])
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It moves to Recently Deleted. You can recover it from there.")
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renameTarget {
                    model.renameItem(id: renameTarget.id, name: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .overlay {
            if let progress = model.importProgress, model.duplicatePrompt == nil {
                ImportProgressSheet(progress: progress) { model.cancelImport() }
            }
        }
        .overlay(alignment: .bottom) {
            if let status = model.statusMessage {
                Text(status)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .notesGlass(in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .onDisappear {
            if exportURL != nil {
                VaultFileStore.purgeTemporaryFiles()
                exportURL = nil
            }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var folderTitle: String {
        if let folderID = model.folderID, let folder = model.folders.first(where: { $0.id == folderID }) {
            return folder.name
        }
        return "Files"
    }

    private var emptyFiles: some View {
        ContentUnavailableView(
            model.filter == .all && model.query.isEmpty ? "No private files" : model.filter.emptyTitle,
            systemImage: model.filter == .videos ? "video" : "photo.on.rectangle",
            description: Text(model.filter == .all ? "Photos, videos, and files you add here stay encrypted on this device." : "Nothing in this filter.")
        )
        .frame(minHeight: 240)
    }

    private func exportSelection() {
        let chosen = model.items.filter { model.selection.contains($0.id) }
        Task {
            do {
                let urls = try await model.exportFiles(chosen)
                shareURLs = urls
                if !urls.isEmpty { appState.setSystemUI(true) }
            } catch {
                model.statusMessage = "File can't be opened."
            }
        }
    }

    private var gatePresented: Binding<Bool> {
        Binding(get: { gateFolder != nil }, set: { if !$0 { gateFolder = nil; gateCode = "" } })
    }

    private var renameFolderPresented: Binding<Bool> {
        Binding(get: { renameFolderTarget != nil }, set: { if !$0 { renameFolderTarget = nil } })
    }

    private var folderSection: some View {
        VStack(spacing: 0) {
            ForEach(model.folders) { folder in
                Button {
                    open(folder)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: folder.hasPasscode ? "lock.fill" : "folder.fill")
                            .foregroundStyle(Theme.vault)
                            .frame(width: 28)
                        Text(folder.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(model.itemCount(in: folder.id))")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(folder.hasPasscode ? "Change Passcode" : "Set Passcode") {
                        settingPasscode = true
                        gateCode = ""
                        gateFolder = folder
                    }
                    if folder.hasPasscode {
                        Button("Remove Passcode") { model.clearFolderPasscode(id: folder.id) }
                    }
                    Button("Rename") {
                        renameFolderText = folder.name
                        renameFolderTarget = folder
                    }
                    Button("Delete", role: .destructive) { model.deleteFolder(id: folder.id) }
                }
                if folder.id != model.folders.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func open(_ folder: VaultFolder) {
        if folder.hasPasscode && !model.unlockedFolders.contains(folder.id) {
            settingPasscode = false
            gateCode = ""
            gateFolder = folder
        } else {
            withAnimation(.smooth(duration: 0.3)) {
                model.folderID = folder.id
            }
        }
    }

    private func commitGate() {
        guard let folder = gateFolder else { return }
        if settingPasscode {
            model.protectFolder(id: folder.id, passcode: gateCode)
        } else if model.matchesFolderPasscode(id: folder.id, passcode: gateCode) {
            model.unlockedFolders.insert(folder.id)
            model.folderID = folder.id
        } else {
            model.statusMessage = "That folder passcode doesn't match."
        }
        gateFolder = nil
        gateCode = ""
    }

    private func listRow(_ item: VaultItem) -> some View {
        Button {
            if model.isSelecting {
                toggle(item)
            } else {
                viewer = item
            }
        } label: {
            HStack(spacing: 12) {
                ThumbnailView(item: item, model: model)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.originalName)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.importedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.vault)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .contextMenu { itemMenu(item) }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            if model.folderID != nil {
                HStack {
                    Button("All Files") {
                        withAnimation(.smooth(duration: 0.3)) { model.folderID = nil }
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            Picker("Filter", selection: $model.filter) {
                ForEach(VaultFileFilter.allCases) { filter in
                    Text("\(filter.rawValue) \(model.filterCounts[filter] ?? 0)").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .accessibilityLabel("File type")
        }
        .padding(.vertical, 8)
    }

    private func cell(_ item: VaultItem) -> some View {
        Button {
            if model.isSelecting {
                toggle(item)
            } else {
                viewer = item
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                ThumbnailView(item: item, model: model)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.vault)
                            .padding(6)
                    }
                    if model.isSelecting {
                        Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.vault)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                Text(item.originalName)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { itemMenu(item) }
        .accessibilityLabel(item.originalName)
    }

    @ViewBuilder
    private func itemMenu(_ item: VaultItem) -> some View {
        Button(item.isFavorite ? "Unfavorite" : "Favorite") {
            model.setFavorite(ids: [item.id], favorite: !item.isFavorite)
        }
        Button("Rename") {
            renameTarget = item
            renameText = item.originalName
        }
        Menu("Move") {
            Button("Files") { model.move(ids: [item.id], to: nil) }
            ForEach(model.folders) { folder in
                Button(folder.name) { model.move(ids: [item.id], to: folder.id) }
            }
        }
        Button("Export") { beginExport(item, stripLocation: false) }
        if item.type == .photo {
            Button("Export without location") { beginExport(item, stripLocation: true) }
        }
        Button("Delete", role: .destructive) { pendingDelete = item }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button(model.isSelecting ? "Done" : "Select") {
                model.isSelecting.toggle()
                if !model.isSelecting { model.selection = [] }
            }
            Button { showNewFolder = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("New Folder")
            Menu {
                Section("Sort By") {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(VaultFileSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                    Picker("Order", selection: $model.sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                }
                Section("View As") {
                    Picker("View As", selection: $model.gallery) {
                        Text("Grid").tag(true)
                        Text("List").tag(false)
                    }
                }
                Section {
                    Toggle("Favorites Only", isOn: $model.favoritesOnly)
                }
            } label: {
                Image(systemName: model.favoritesOnly || model.filter != .all ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Sort and view")
            Menu {
                Button("Photos or Videos") {
                    if appState.needsPermissionExplanation(.photos) {
                        explainPhotos = true
                    } else {
                        model.wantsPhotoPicker = true
                    }
                }
                Button("Files") { showFiles = true }
                Button("Camera") {
                    if appState.needsPermissionExplanation(.camera) {
                        explainCamera = true
                    } else {
                        showCamera = true
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
        }
        if model.isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Delete", role: .destructive) { model.moveToTrash(ids: model.selection) }
                    .disabled(model.selection.isEmpty)
                Button("Export") { exportSelection() }
                    .disabled(model.selection.isEmpty)
                Menu("Move") {
                    Button("Files") { model.move(ids: model.selection, to: nil) }
                    ForEach(model.folders) { folder in
                        Button(folder.name) { model.move(ids: model.selection, to: folder.id) }
                    }
                }
                .disabled(model.selection.isEmpty)
                Button("Favorite") { model.setFavorite(ids: model.selection, favorite: true) }
                    .disabled(model.selection.isEmpty)
            }
        }
    }

    private func toggle(_ item: VaultItem) {
        var next = model.selection
        if next.contains(item.id) {
            next.remove(item.id)
        } else {
            next.insert(item.id)
        }
        model.selection = next
    }

    private func beginExport(_ item: VaultItem, stripLocation: Bool) {
        Task {
            do {
                exportURL = try await model.exportFile(item, stripLocation: stripLocation)
            } catch {
                model.statusMessage = "File can't be opened."
            }
        }
    }

    private var exportPresented: Binding<Bool> {
        Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })
    }

    private var sharePresented: Binding<Bool> {
        Binding(get: { !shareURLs.isEmpty }, set: { if !$0 { shareURLs = [] } })
    }

    private var duplicatePresented: Binding<Bool> {
        Binding(
            get: { model.duplicatePrompt != nil },
            set: { if !$0 { model.resolveDuplicate(.skip) } }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
}

private struct ThumbnailView: View {
    let item: VaultItem
    @ObservedObject var model: VaultFilesViewModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if item.type == .photo || item.type == .video {
                ShimmerPreview()
            } else {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(Theme.vault)
            }
            if item.type == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                        if let duration = item.duration {
                            Text(Self.clock(duration))
                                .font(.caption2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.35))
                }
            }
        }
        .clipped()
        .task(id: item.id) {
            image = await model.thumbnail(for: item)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var symbol: String {
        switch item.type {
        case .photo: return "photo"
        case .video: return "video"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        case .document, .other: return "doc"
        }
    }
}

private struct ShimmerPreview: View {
    @State private var phase = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase ? 80 : -80)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = true }
            }
            .accessibilityLabel("Loading preview")
    }
}

private struct ImportProgressSheet: View {
    let progress: ImportProgress
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.total == 0 ? 0 : Double(progress.completed) / Double(progress.total))
            Text(progress.title).font(.headline)
            if !progress.failures.isEmpty {
                Text(progress.failures.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
        .accessibilityElement(children: .combine)
    }
}

extension VaultItem: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
