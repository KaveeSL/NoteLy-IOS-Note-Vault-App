import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VaultFilesView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: VaultFilesViewModel
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var viewer: VaultItem?
    @State private var exportURL: URL?
    @State private var shareURLs: [URL] = []
    @State private var newFolder = ""
    @State private var showNewFolder = false
    @State private var renameTarget: VaultItem?
    @State private var renameText = ""
    @State private var pendingDelete: VaultItem?
    @State private var pendingFolderDelete: VaultFolder?
    @State private var gateFolder: VaultFolder?
    @State private var gateCode = ""
    @State private var settingPasscode = false
    @State private var renameFolderTarget: VaultFolder?
    @State private var renameFolderText = ""
    @State private var askPlacement = false
    @State private var incoming: IncomingImport?

    private enum IncomingImport {
        case photos, files, camera
    }

    private let columns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if model.gallery && !model.visibleItems.isEmpty {
                if model.filter == .all && !model.childFolders.isEmpty {
                    folderList
                        .frame(height: folderListHeight)
                        .clipped()
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 1) {
                        ForEach(model.visibleItems) { item in
                            cell(item)
                        }
                    }
                    .padding(1)
                }
            } else {
                List {
                    if model.filter == .all && !model.childFolders.isEmpty {
                        Section {
                            ForEach(model.childFolders) { folder in
                                folderLink(folder)
                            }
                        }
                    }
                    Section {
                        if model.visibleItems.isEmpty {
                            emptyFiles
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(model.visibleItems) { item in
                                listRow(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            Text(model.storageSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                .accessibilityLabel(model.storageSummary)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) {
            if let status = model.statusMessage {
                statusBanner(status)
                    .padding(.top, 58)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: model.statusMessage)
        .onAppear { model.filter = .all }
        .navigationTitle(folderTitle)
        .navigationBarBackButtonHidden(model.folderID != nil)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DictationSearchField(text: $model.query, prompt: "Search files")
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .toolbar {
            if model.folderID != nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { model.closeFolder() }
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(folderBackTitle)
                }
            }
            toolbar
        }
        .sheet(item: $viewer) { item in
            VaultItemViewer(item: item, items: swipeStrip(for: item), model: model)
        }
        .confirmationDialog("Add to the vault", isPresented: $askPlacement, titleVisibility: .visible) {
            Button("Move") { startImport(removeOriginal: true) }
            Button("Copy") { startImport(removeOriginal: false) }
            Button("Cancel", role: .cancel) { incoming = nil }
        } message: {
            Text("Move removes the original. Copy leaves it where it is.")
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
                model.importSecurityScoped(urls, removeOriginals: model.removeImportedOriginals)
            }
        }
        .onChange(of: showFiles) { _, presented in
            appState.setSystemUI(presented)
        }
        .onChange(of: showCamera) { _, presented in
            if presented { appState.setSystemUI(true) }
        }
        .sheet(isPresented: sharePresented, onDismiss: {
            appState.setSystemUI(false)
            VaultFileStore.purgeTemporaryFiles()
        }) {
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
        .sheet(isPresented: exportPresented, onDismiss: {
            appState.setSystemUI(false)
            VaultFileStore.purgeTemporaryFiles()
        }) {
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
                model.createFolder(name: newFolder, parent: model.folderID)
                newFolder = ""
            }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
        .alert("Delete this folder?", isPresented: Binding(get: { pendingFolderDelete != nil }, set: { if !$0 { pendingFolderDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingFolderDelete { model.deleteFolder(id: pendingFolderDelete.id) }
                pendingFolderDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFolderDelete = nil }
        } message: {
            Text("Files in this folder stay in the folder you opened it from.")
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

    private var folderBackTitle: String {
        guard let id = model.folderID,
              let folder = model.folders.first(where: { $0.id == id }),
              let parent = folder.parentID,
              let name = model.folders.first(where: { $0.id == parent })?.name else {
            return "Files"
        }
        return name
    }

    private var emptyFiles: some View {
        VStack(spacing: 4) {
            Text(model.filter == .all && model.query.isEmpty ? "No Files" : model.filter.emptyTitle)
                .font(.headline)
            Text(model.filter == .all ? "Photos, videos, and files stay on this iPhone." : "Nothing in this filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 28)
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

    private func folderLink(_ folder: VaultFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isPinned ? "pin.fill" : (folder.hasPasscode ? "lock.fill" : "folder.fill"))
                .foregroundStyle(folder.isPinned ? Theme.accent : Theme.vault)
                .frame(width: 28)
            Text(folder.name)
                .foregroundStyle(Color(.label))
            Spacer()
            Text("\(model.itemCount(in: folder.id))")
                .foregroundStyle(Color(.secondaryLabel))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(folder) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(folder.name), \(model.itemCount(in: folder.id))")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingFolderDelete = folder } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                model.setFolderPinned(id: folder.id, pinned: !folder.isPinned)
            } label: {
                Label(folder.isPinned ? "Unpin" : "Pin", systemImage: folder.isPinned ? "pin.slash" : "pin")
            }
            .tint(folder.isPinned ? Color(.systemGray) : Theme.accent)
            Button {
                renameFolderText = folder.name
                renameFolderTarget = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Color(.systemOrange))
        }
        .contextMenu {
            Button {
                model.setFolderPinned(id: folder.id, pinned: !folder.isPinned)
            } label: {
                Label(folder.isPinned ? "Unpin" : "Pin", systemImage: folder.isPinned ? "pin.slash" : "pin")
            }
            Button {
                settingPasscode = true
                gateCode = ""
                gateFolder = folder
            } label: {
                Label(folder.hasPasscode ? "Change Passcode" : "Set Passcode", systemImage: "lock")
            }
            if folder.hasPasscode {
                Button { model.clearFolderPasscode(id: folder.id) } label: {
                    Label("Remove Passcode", systemImage: "lock.open")
                }
            }
            Button {
                renameFolderText = folder.name
                renameFolderTarget = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { pendingFolderDelete = folder } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func startImport(removeOriginal: Bool) {
        let kind = incoming
        incoming = nil
        askPlacement = false
        switch kind {
        case .photos:
            Task {
                if removeOriginal {
                    guard await model.allowPhotoRemoval() else { return }
                }
                appState.markPermissionExplained(.photos)
                model.removeImportedOriginals = removeOriginal
                model.wantsPhotoPicker = true
            }
        case .files:
            model.removeImportedOriginals = removeOriginal
            showFiles = true
        case .camera:
            appState.markPermissionExplained(.camera)
            showCamera = true
        case nil:
            break
        }
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

    private func swipeStrip(for item: VaultItem) -> [VaultItem] {
        let media = model.visibleItems.filter { $0.type == .photo || $0.type == .video }
        if media.contains(where: { $0.id == item.id }) { return media }
        return [item]
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
                    Text(item.type == .photo ? "Photo" : (item.type == .video ? "Video" : "File"))
                        .lineLimit(1)
                        .foregroundStyle(Color(.label))
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
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

    private func statusBanner(_ status: String) -> some View {
        let failed = status.localizedCaseInsensitiveContains("kept")
            || status.localizedCaseInsensitiveContains("couldn't")
            || status.localizedCaseInsensitiveContains("can't")
            || status.localizedCaseInsensitiveContains("doesn't")
            || status.localizedCaseInsensitiveContains("not enough")
            || status.localizedCaseInsensitiveContains("stayed")
        return HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(failed ? Color.orange : Color.green)
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .notesGlass(in: Capsule())
        .accessibilityLabel(status)
    }

    private var filterBar: some View {
        Picker("Show", selection: $model.filter) {
            ForEach(VaultFileFilter.allCases) { filter in
                Image(systemName: filter.symbol)
                    .accessibilityLabel(filter.rawValue)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func cell(_ item: VaultItem) -> some View {
        Button {
            if model.isSelecting {
                toggle(item)
            } else {
                viewer = item
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ThumbnailView(item: item, model: model)
                            .scaledToFill()
                    }
                    .clipped()
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
                if model.isSelecting {
                    Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            itemMenu(item)
        } preview: {
            Color(.secondarySystemBackground)
                .frame(width: 240, height: 240)
                .overlay {
                    ThumbnailView(item: item, model: model)
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel(item.originalName)
    }

    private var folderList: some View {
        List {
            Section {
                ForEach(model.childFolders) { folder in
                    folderLink(folder)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(model.childFolders.count < 6)
    }

    private var folderListHeight: CGFloat {
        CGFloat(min(model.childFolders.count, 6)) * 56 + 40
    }

    @ViewBuilder
    private func itemMenu(_ item: VaultItem) -> some View {
        Button {
            model.setFavorite(ids: [item.id], favorite: !item.isFavorite)
        } label: {
            Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "heart.slash" : "heart")
        }
        Button {
            renameTarget = item
            renameText = item.originalName
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            Button("Files") { model.move(ids: [item.id], to: nil) }
            ForEach(model.folders) { folder in
                Button(folder.name) { model.move(ids: [item.id], to: folder.id) }
            }
        } label: {
            Label("Move", systemImage: "folder")
        }
        Button { beginExport(item, stripLocation: false) } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        if item.type == .photo {
            Button { beginExport(item, stripLocation: true) } label: {
                Label("Export without location", systemImage: "location.slash")
            }
        }
        Button(role: .destructive) { pendingDelete = item } label: {
            Label("Delete", systemImage: "trash")
        }
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
                    incoming = .photos
                    askPlacement = true
                }
                Button("Files") {
                    incoming = .files
                    askPlacement = true
                }
                Button("Camera") {
                    incoming = .camera
                    askPlacement = true
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

struct ThumbnailView: View {
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
