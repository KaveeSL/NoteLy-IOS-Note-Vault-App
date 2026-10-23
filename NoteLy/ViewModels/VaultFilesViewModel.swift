import AVFoundation
import CoreTransferable
import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers


enum DuplicateChoice: Sendable {
    case skip
    case keepBoth
}

struct ImportProgress: Equatable {
    var title: String
    var completed: Int
    var total: Int
    var failures: [String]
}

struct DuplicatePrompt: Identifiable, Equatable {
    var id: UUID
    var name: String
}

@MainActor
final class VaultFilesViewModel: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published private(set) var folders: [VaultFolder] = []
    @Published var filter: VaultFileFilter = .all
    @Published var sort: VaultFileSort = .imported
    @Published var sortAscending = false
    @Published var favoritesOnly = false
    @Published var query = ""
    @Published var folderID: UUID?
    /// Set just before the picker opens. Move deletes the original after a successful import.
    var removeImportedOriginals = false
    @Published var isSelecting = false
    @Published var selection: Set<UUID> = []
    @Published var importProgress: ImportProgress?
    @Published var duplicatePrompt: DuplicatePrompt?
    @Published var statusMessage: String? {
        didSet { armStatusDismissal() }
    }
    @Published var storageSummary = ""
    @Published var gallery = true
    @Published var unlockedFolders: Set<UUID> = []
    @Published var wantsPhotoPicker = false
    @Published var importDebug: String?
    var reauth: ReauthService?
    var risks: RiskLedger?

    private let store: VaultFileStoring
    private let crypto: CryptoServicing
    private let session: VaultSession
    private let cache = NSCache<NSString, UIImage>()
    private var importTask: Task<Void, Never>?
    private var statusDismissal: Task<Void, Never>?
    private let importGate = ImportGate()
    private var duplicateContinuation: CheckedContinuation<DuplicateChoice, Never>?
    private var library = VaultLibrarySnapshot.empty

    init(store: VaultFileStoring, crypto: CryptoServicing, session: VaultSession) {
        self.store = store
        self.crypto = crypto
        self.session = session
    }

    var deletedItems: [VaultItem] {
        let ids = Set(library.trash.map(\.id))
        return items.filter { ids.contains($0.id) }
    }

    /// Every file still in the vault, including files that live inside folders.
    var keptItemCount: Int {
        let deleted = Set(library.trash.map(\.id))
        return items.filter { !deleted.contains($0.id) }.count
    }

    var visibleItems: [VaultItem] {
        VaultLibraryQuery.apply(
            items: items,
            trash: Set(library.trash.map(\.id)),
            folderID: folderID,
            filter: filter,
            favoritesOnly: favoritesOnly,
            sort: sort,
            ascending: sortAscending,
            query: query
        )
    }

    var filterCounts: [VaultFileFilter: Int] {
        VaultLibraryQuery.counts(items: items, trash: Set(library.trash.map(\.id)), folderID: folderID)
    }

    func load() async {
        guard let key = session.key else {
            items = []
            folders = []
            return
        }
        let store = self.store
        do {
            let loaded = try await Task.detached {
                try store.cleanupOrphans(using: key)
                return try store.loadLibrary(using: key)
            }.value
            library = loaded
            items = loaded.items
            folders = loaded.folders
            purgeExpiredTrash()
            refreshSummary()
        } catch {
            VaultLog.security.error("Private files could not be opened")
            statusMessage = "Couldn't open files."
        }
    }

    func wipe() {
        importTask?.cancel()
        importTask = nil
        duplicateContinuation?.resume(returning: .skip)
        duplicateContinuation = nil
        cache.removeAllObjects()
        items = []
        folders = []
        library = .empty
        selection = []
        isSelecting = false
        folderID = nil
        unlockedFolders = []
        importProgress = nil
        VaultFileStore.purgeTemporaryFiles()
    }

    func deleteStoredFiles() {
        try? store.deleteAll()
        wipe()
    }

    func importPickerResults(_ results: [PHPickerResult], removeFromPhotos: Bool) async {
        wantsPhotoPicker = false
        guard !results.isEmpty else { return }
        importTask?.cancel()
        importGate.stop()
        importGate.reset()
        let task = Task {
            var identifiers: [String] = []
            var failures: [String] = []
            importProgress = ImportProgress(title: "Importing", completed: 0, total: results.count, failures: [])
            for (index, result) in results.enumerated() {
                if Task.isCancelled || !importGate.isRunning { break }
                importProgress?.title = "Importing \(index + 1) of \(results.count)"
                var step = "items returned"
                do {
                    let copies = try await Self.copyProviderFiles(result.itemProvider) { title in
                        self.importProgress?.title = title
                    }
                    step = "copied to temp"
                    for copy in copies {
                        step = "encrypted"
                        try await importTemp(copy.url, name: copy.name, folderID: folderID)
                        step = "index saved"
                        ImportLog.step("thumbnail made")
                        secureDelete(copy.url)
                    }
                    if let identifier = result.assetIdentifier {
                        identifiers.append(identifier)
                    }
                } catch is CancellationError {
                    break
                } catch VaultError.importCancelled {
                    break
                } catch {
                    let message = "Stopped at \(step)."
                    failures.append(message)
                    importDebug = message
                    ImportLog.step("failed at \(step)")
                    VaultLog.security.error("Photo import failed")
                }
                importProgress?.completed = index + 1
                importProgress?.failures = failures
            }
            if !failures.isEmpty {
                importDebug = failures.joined(separator: " ")
            }
            importProgress = nil
            if removeFromPhotos {
                if identifiers.isEmpty {
                    statusMessage = "Saved. Originals stayed in Photos"
                } else {
                    await removeFromPhotoLibrary(identifiers)
                }
            }
            await load()
        }
        importTask = task
        await task.value
    }

    private static func copyProviderFiles(
        _ provider: NSItemProvider,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> [(url: URL, name: String)] {
        var copies: [(url: URL, name: String)] = []
        for type in typeIdentifiers(provider) {
            let copy = try await copyFile(provider, type: type, progress: progress)
            copies.append(copy)
        }
        if copies.isEmpty { throw VaultError.importFailed }
        return copies
    }

    private static func typeIdentifiers(_ provider: NSItemProvider) -> [String] {
        let image = UTType.image.identifier
        let movie = UTType.movie.identifier
        let hasImage = provider.hasItemConformingToTypeIdentifier(image)
        let hasMovie = provider.hasItemConformingToTypeIdentifier(movie)
        if hasImage && hasMovie { return [image, movie] }
        if hasMovie { return [movie] }
        if hasImage { return [image] }
        return provider.registeredTypeIdentifiers
    }

    private static func copyFile(
        _ provider: NSItemProvider,
        type: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> (url: URL, name: String) {
        ImportLog.step("file loading")
        return try await withCheckedThrowingContinuation { continuation in
            let observed = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: VaultError.importFailed)
                    return
                }
                let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "dat") : url.pathExtension
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultImport", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    ImportLog.step("file loaded")
                    try FileManager.default.copyItem(at: url, to: destination)
                    ImportLog.step("copied to temp")
                    let base = provider.suggestedName ?? "Photo"
                    let name = base.contains(".") ? base : "\(base).\(ext)"
                    continuation.resume(returning: (destination, name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            DispatchQueue.main.async {
                let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                    let fraction = observed.fractionCompleted
                    if observed.isCancelled || observed.isFinished {
                        timer.invalidate()
                        return
                    }
                    if fraction > 0, fraction < 1 {
                        Task { @MainActor in progress("Downloading \(Int(fraction * 100))%") }
                    }
                }
                observed.cancellationHandler = { timer.invalidate() }
            }
        }
    }

    func importSecurityScoped(_ urls: [URL], removeOriginals: Bool = false) {
        guard !urls.isEmpty else { return }
        importGate.stop()
        importGate.reset()
        importTask = Task {
            importProgress = ImportProgress(title: "Importing", completed: 0, total: urls.count, failures: [])
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let temp = try copyToTemp(url)
                    try await importTemp(temp, name: url.lastPathComponent, folderID: folderID)
                    secureDelete(temp)
                    if removeOriginals {
                        try? FileManager.default.removeItem(at: url)
                    }
                } catch VaultError.importCancelled {
                    break
                } catch {
                    failures.append(message(for: error))
                }
                importProgress?.completed = index + 1
                importProgress?.failures = failures
            }
            importProgress = nil
            await load()
        }
    }

    func importCameraFile(_ url: URL, filename: String) {
        importGate.stop()
        importGate.reset()
        importTask = Task {
            importProgress = ImportProgress(title: "Saving", completed: 0, total: 1, failures: [])
            do {
                try await importTemp(url, name: filename, folderID: folderID)
            } catch {
                statusMessage = message(for: error)
            }
            secureDelete(url)
            importProgress = nil
            await load()
        }
    }

    func cancelImport() {
        importGate.stop()
        importTask?.cancel()
        duplicateContinuation?.resume(returning: .skip)
        duplicateContinuation = nil
    }

    func resolveDuplicate(_ choice: DuplicateChoice) {
        duplicateContinuation?.resume(returning: choice)
        duplicateContinuation = nil
        duplicatePrompt = nil
    }

    func createFolder(name: String, parent: UUID? = nil) {
        let existing = folders.filter { $0.parentID == parent }.map(\.name)
        guard case .valid(let clean) = InputValidators.folderName(name, existing: existing) else {
            if case .invalid(let reason) = InputValidators.folderName(name, existing: existing) {
                statusMessage = reason
            }
            return
        }
        folders.append(VaultFolder(name: clean, parentID: parent))
        library.folders = folders
        persist()
    }

    var childFolders: [VaultFolder] {
        folders.filter { $0.parentID == folderID }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func closeFolder() {
        guard let id = folderID, let folder = folders.first(where: { $0.id == id }) else {
            folderID = nil
            return
        }
        folderID = folder.parentID
    }

    func itemCount(in folderID: UUID) -> Int {
        let deleted = Set(library.trash.map(\.id))
        let ids = descendantFolderIDs(of: folderID)
        return items.filter { item in
            guard let id = item.folderID else { return false }
            return ids.contains(id) && !deleted.contains(item.id)
        }.count
    }

    private func armStatusDismissal() {
        statusDismissal?.cancel()
        guard statusMessage != nil else { return }
        statusDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    private func descendantFolderIDs(of root: UUID, seen: Set<UUID> = []) -> Set<UUID> {
        if seen.contains(root) { return [] }
        var ids: Set<UUID> = [root]
        var next = seen
        next.insert(root)
        for folder in folders where folder.parentID == root {
            ids.formUnion(descendantFolderIDs(of: folder.id, seen: next))
        }
        return ids
    }

    func allowPhotoRemoval() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
            return status == .authorized || status == .limited
        }
        if current == .authorized || current == .limited {
            return true
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
        return false
    }

    func protectFolder(id: UUID, passcode: String) {
        let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 32 else {
            statusMessage = "Use 4 to 32 characters."
            return
        }
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        do {
            let salt = try crypto.randomData(count: 16)
            let hash = try crypto.pbkdf2(
                password: trimmed,
                salt: salt,
                iterations: SecurityConstants.pbkdf2Iterations,
                outputLength: SecurityConstants.hashLength
            )
            folders[index].passcodeSalt = salt
            folders[index].passcodeHash = hash
            library.folders = folders
            unlockedFolders.insert(id)
            persist()
        } catch {
            statusMessage = "Couldn't set that folder passcode."
        }
    }

    func matchesFolderPasscode(id: UUID, passcode: String) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }),
              let salt = folder.passcodeSalt,
              let hash = folder.passcodeHash,
              let derived = try? crypto.pbkdf2(
                password: passcode,
                salt: salt,
                iterations: SecurityConstants.pbkdf2Iterations,
                outputLength: SecurityConstants.hashLength
              ) else { return false }
        return crypto.constantTimeEqual(derived, hash)
    }

    func clearFolderPasscode(id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].passcodeSalt = nil
        folders[index].passcodeHash = nil
        library.folders = folders
        unlockedFolders.remove(id)
        persist()
    }

    func renameFolder(id: UUID, name: String) {
        let existing = folders.filter { $0.id != id }.map(\.name)
        guard case .valid(let clean) = InputValidators.folderName(name, existing: existing),
              let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = clean
        library.folders = folders
        persist()
    }

    func deleteFolder(id: UUID) {
        Task { await deleteFolderConfirmed(id: id) }
    }

    func deleteFolderConfirmed(id: UUID) async {
        guard let proof = await reauth?.authorize(.deleteFolder), let risks else {
            statusMessage = "That needs Face ID or the vault passcode."
            return
        }
        do {
            try risks.require(proof, action: .deleteFolder)
        } catch {
            statusMessage = "That needs Face ID or the vault passcode."
            return
        }
        let parent = folders.first(where: { $0.id == id })?.parentID
        folders.removeAll { $0.id == id }
        for index in folders.indices where folders[index].parentID == id {
            folders[index].parentID = parent
        }
        for index in items.indices where items[index].folderID == id {
            items[index].folderID = parent
        }
        library.folders = folders
        library.items = items
        unlockedFolders.remove(id)
        persist()
    }

    func setFolderPinned(id: UUID, pinned: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isPinned = pinned
        library.folders = folders
        persist()
    }

    func move(ids: Set<UUID>, to folder: UUID?) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].folderID = folder
        }
        library.items = items
        selection = []
        isSelecting = false
        persist()
    }

    func setFavorite(ids: Set<UUID>, favorite: Bool) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].isFavorite = favorite
        }
        library.items = items
        persist()
    }

    func renameItem(id: UUID, name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].originalName = InputValidators.sanitizedFilename(name)
        library.items = items
        persist()
    }

    func moveToTrash(ids: Set<UUID>) {
        let now = Date()
        for id in ids where !library.trash.contains(where: { $0.id == id }) {
            library.trash.append(VaultTrashEntry(id: id, deletedAt: now))
        }
        selection = []
        isSelecting = false
        persist()
    }

    func restore(ids: Set<UUID>) {
        library.trash.removeAll { ids.contains($0.id) }
        persist()
    }

    func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let expired = Set(library.trash.filter { $0.deletedAt < cutoff }.map(\.id))
        guard !expired.isEmpty else { return }
        library.trash.removeAll { expired.contains($0.id) }
        let doomed = items.filter { expired.contains($0.id) }
        items.removeAll { expired.contains($0.id) }
        library.items = items
        persist()
        let store = self.store
        Task.detached {
            for item in doomed {
                try? store.deleteExpiredItem(item)
            }
        }
    }

    func delete(ids: Set<UUID>) {
        Task { await deleteConfirmed(ids: ids, action: .permanentDelete) }
    }

    func emptyTrash() {
        Task { await deleteConfirmed(ids: Set(deletedItems.map(\.id)), action: .emptyBin) }
    }

    func eraseDeleted(proof: RiskProof) {
        let ids = Set(deletedItems.map(\.id))
        guard !ids.isEmpty, let risks, (try? risks.require(proof, action: proof.action)) != nil else { return }
        let doomed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        library.trash.removeAll { ids.contains($0.id) }
        library.items = items
        persist()
        let store = self.store
        for item in doomed {
            try? store.deleteItem(item, proof: proof)
        }
    }

    private func deleteConfirmed(ids: Set<UUID>, action: RiskyAction) async {
        guard !ids.isEmpty else { return }
        guard let proof = await reauth?.authorize(action) else {
            statusMessage = "That needs Face ID or the vault passcode."
            return
        }
        let doomed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        library.trash.removeAll { ids.contains($0.id) }
        library.items = items
        selection = []
        isSelecting = false
        persist()
        let store = self.store
        for item in doomed {
            try? store.deleteItem(item, proof: proof)
        }
    }

    func thumbnail(for item: VaultItem) async -> UIImage? {
        let keyName = item.id.uuidString as NSString
        if let cached = cache.object(forKey: keyName) { return cached }
        if let image = await loadThumbnail(item) {
            cache.setObject(image, forKey: keyName)
            return image
        }
        guard item.type == .photo || item.type == .video else { return nil }
        await regenerateThumbnail(for: item)
        if let image = await loadThumbnail(item) {
            cache.setObject(image, forKey: keyName)
            return image
        }
        return nil
    }

    func recordOpen(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].openCount += 1
        items[index].lastOpened = .now
        library.items = items
        persist()
    }

    func clearUsage() {
        for index in items.indices {
            items[index].openCount = 0
            items[index].lastOpened = nil
        }
        library.items = items
        persist()
    }

    func removeFavorite(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite = false
        items[index].favoriteOrder = nil
        items[index].openCount = 0
        items[index].lastOpened = nil
        library.items = items
        persist()
    }

    func exportFiles(_ chosen: [VaultItem]) async throws -> [URL] {
        guard let proof = await reauth?.authorize(.export) else { throw VaultError.authorizationRequired }
        var urls: [URL] = []
        for item in chosen {
            urls.append(try await writeExport(item, stripLocation: false, proof: proof))
        }
        return urls
    }

    func reorderFavorites(_ order: [UUID]) {
        for (position, id) in order.enumerated() {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].favoriteOrder = position
            items[index].isFavorite = true
        }
        library.items = items
        persist()
    }

    private func loadThumbnail(_ item: VaultItem) async -> UIImage? {
        guard item.hasThumbnail, let master = session.key else { return nil }
        let store = self.store
        let data = try? await Task.detached {
            try store.thumbnailData(for: item.id, using: master)
        }.value
        guard let data else { return nil }
        return UIImage(data: data)
    }

    private func regenerateThumbnail(for item: VaultItem) async {
        guard let master = session.key else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (item.originalName as NSString).pathExtension
        let destination = folder.appendingPathComponent(item.id.uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
        let store = self.store
        do {
            try await Task.detached {
                try store.plaintextCopy(of: item, using: master, to: destination)
            }.value
            if let jpeg = await ThumbnailMaker.jpeg(from: destination, type: item.type) {
                try await Task.detached {
                    try store.saveThumbnail(jpeg, id: item.id, using: master)
                }.value
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].hasThumbnail = true
                    library.items = items
                    persist()
                }
            }
        } catch {
            ImportLog.step("thumbnail rebuild failed")
        }
        secureDelete(destination)
    }

    func playbackAsset(for item: VaultItem) -> (AVURLAsset, VaultAssetLoader)? {
        guard let master = session.key else { return nil }
        let key = crypto.deriveSubkey(master, purpose: .content)
        let loader = VaultAssetLoader(
            fileURL: store.encryptedFileURL(for: item.id),
            contentType: item.utType,
            contentLength: item.size,
            key: key,
            crypto: crypto
        )
        guard let url = URL(string: "notely-vault://\(item.id.uuidString)") else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "notely.vault.playback"))
        return (asset, loader)
    }

    func materialize(_ item: VaultItem, stripLocation: Bool) async throws -> URL {
        guard let master = session.key else { throw VaultError.notConfigured }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPlayback", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (item.originalName as NSString).pathExtension
        let destination = folder.appendingPathComponent(item.id.uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
        let store = self.store
        try await Task.detached {
            try store.plaintextCopy(of: item, using: master, to: destination)
        }.value
        if stripLocation, item.type == .photo, let jpeg = LocationStripper.jpegWithoutLocation(from: destination) {
            try jpeg.write(to: destination, options: .completeFileProtection)
        }
        return destination
    }

    func exportFile(_ item: VaultItem, stripLocation: Bool) async throws -> URL {
        guard let proof = await reauth?.authorize(.export) else { throw VaultError.authorizationRequired }
        return try await writeExport(item, stripLocation: stripLocation, proof: proof)
    }

    private func writeExport(_ item: VaultItem, stripLocation: Bool, proof: RiskProof) async throws -> URL {
        guard let master = session.key else { throw VaultError.notConfigured }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPlayback", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (item.originalName as NSString).pathExtension
        let destination = folder.appendingPathComponent(item.id.uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
        let store = self.store
        try await Task.detached {
            try store.exportCopy(of: item, using: master, to: destination, proof: proof)
        }.value
        if stripLocation, item.type == .photo, let jpeg = LocationStripper.jpegWithoutLocation(from: destination) {
            try jpeg.write(to: destination, options: .completeFileProtection)
        }
        return destination
    }

    func freeSpaceText() -> String {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    // MARK: - Import internals

    private func importTemp(_ url: URL, name: String, folderID: UUID?) async throws {
        guard let master = session.key else { throw VaultError.notConfigured }
        let digest = try sha256(of: url)
        if items.contains(where: { $0.plaintextSHA256 == digest }) {
            let choice = await askDuplicate(name: name)
            if choice == .skip { return }
        }
        if Task.isCancelled || !importGate.isRunning { throw VaultError.importCancelled }
        let store = self.store
        let gate = importGate
        var item = try await Task.detached {
            try store.importFile(
                at: url,
                name: name,
                folderID: folderID,
                companionID: nil,
                using: master,
                shouldContinue: { gate.isRunning }
            )
        }.value
        let meta = ThumbnailMaker.dimensions(url: url, type: item.type)
        item.pixelWidth = meta.width == 0 ? nil : meta.width
        item.pixelHeight = meta.height == 0 ? nil : meta.height
        item.duration = meta.duration
        if let jpeg = await ThumbnailMaker.jpeg(from: url, type: item.type) {
            try await Task.detached {
                try store.saveThumbnail(jpeg, id: item.id, using: master)
            }.value
            item.hasThumbnail = true
            ImportLog.step("thumbnail made")
        }
        ImportLog.step("encrypted")
        items.append(item)
        library.items = items
        persist()
        refreshSummary()
    }

    private func askDuplicate(name: String) async -> DuplicateChoice {
        await withCheckedContinuation { continuation in
            duplicateContinuation = continuation
            duplicatePrompt = DuplicatePrompt(id: UUID(), name: InputValidators.sanitizedFilename(name))
        }
    }

    private func persist() {
        guard let master = session.key else { return }
        let snapshot = library
        let store = self.store
        do {
            try store.saveLibrary(snapshot, using: master)
            ImportLog.step("index saved")
        } catch {
            VaultLog.security.error("Private file index could not be saved")
            statusMessage = "Couldn't save changes."
        }
    }

    private func refreshSummary() {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        storageSummary = "\(items.count) items · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(freeSpaceText()) free"
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: SecurityConstants.fileChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if chunk.count < SecurityConstants.fileChunkSize { break }
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    private func copyToTemp(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteLyPlain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let destination = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private func secureDelete(_ url: URL) {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 8_000_000 {
            try? Data(count: size).write(to: url, options: .atomic)
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeFromPhotoLibrary(_ identifiers: [String]) async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else {
            statusMessage = "Saved. Originals stayed in Photos"
            return
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                } completionHandler: { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: VaultError.importFailed)
                    }
                }
            }
            statusMessage = "Removed from Photos"
        } catch {
            statusMessage = "Photos kept the originals"
        }
    }

    private func message(for error: Error) -> String {
        guard let vault = error as? VaultError else { return "That file couldn't be imported." }
        switch vault {
        case .insufficientSpace: return "Not enough free space."
        case .fileTooLarge: return "That file is over the size limit."
        case .decryptionFailed, .corruptedData: return "File can't be opened."
        case .importCancelled: return "Import cancelled."
        default: return "That file couldn't be imported."
        }
    }
}

final class ImportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
    func reset() {
        lock.lock()
        running = true
        lock.unlock()
    }
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try VaultTempFile.copy(received.file))
        }
    }
}

struct PickedImage: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImage(url: try VaultTempFile.copy(received.file))
        }
    }
}

struct VaultTempFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            VaultTempFile(url: try copy(received.file))
        }
    }

    static func copy(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteLyPlain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let destination = folder
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        return destination
    }
}

#if DEBUG
extension VaultFilesViewModel {
    /// Sample folders and photos for the screenshot guide. Debug launches only.
    func seedGuideSamples() {
        guard let master = session.key else { return }
        let trip = VaultFolder(name: "Trip")
        let receipts = VaultFolder(name: "Receipts")
        folders = [trip, receipts]
        library = .empty
        library.folders = folders
        items = []
        let specs: [(GuidePicture, String, UUID?)] = [
            (.harbor, "Harbor.jpg", nil),
            (.window, "Window.jpg", nil),
            (.sunset, "Sunset.jpg", trip.id)
        ]
        for spec in specs {
            guard let url = spec.0.write(named: spec.1) else { continue }
            defer { try? FileManager.default.removeItem(at: url) }
            guard var item = try? store.importFile(
                at: url,
                name: spec.1,
                folderID: spec.2,
                companionID: nil,
                using: master,
                shouldContinue: { true }
            ) else { continue }
            let meta = ThumbnailMaker.dimensions(url: url, type: item.type)
            item.pixelWidth = meta.width == 0 ? nil : meta.width
            item.pixelHeight = meta.height == 0 ? nil : meta.height
            if let jpeg = UIImage(contentsOfFile: url.path)?.jpegData(compressionQuality: 0.8) {
                try? store.saveThumbnail(jpeg, id: item.id, using: master)
                item.hasThumbnail = true
            }
            items.append(item)
        }
        library.items = items
        persist()
        refreshSummary()
    }
}

private enum GuidePicture {
    case harbor
    case sunset
    case window

    func write(named name: String) -> URL? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800))
        let image = renderer.image { context in
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
            switch self {
            case .harbor:
                drawGradient(in: bounds, colors: [
                    UIColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1),
                    UIColor(red: 0.05, green: 0.28, blue: 0.55, alpha: 1)
                ], context: context.cgContext)
                UIColor(red: 1, green: 0.92, blue: 0.55, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 520, y: 90, width: 120, height: 120)).fill()
                UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 0.9).setFill()
                let sail = UIBezierPath()
                sail.move(to: CGPoint(x: 250, y: 520))
                sail.addLine(to: CGPoint(x: 390, y: 280))
                sail.addLine(to: CGPoint(x: 400, y: 520))
                sail.close()
                sail.fill()
            case .sunset:
                drawGradient(in: bounds, colors: [
                    UIColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1),
                    UIColor(red: 0.45, green: 0.12, blue: 0.38, alpha: 1)
                ], context: context.cgContext)
                UIColor(red: 1, green: 0.78, blue: 0.28, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 280, y: 430, width: 240, height: 240)).fill()
            case .window:
                UIColor(red: 0.93, green: 0.88, blue: 0.8, alpha: 1).setFill()
                UIBezierPath(rect: bounds).fill()
                UIColor(red: 0.55, green: 0.78, blue: 0.95, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 180, y: 80, width: 440, height: 460), cornerRadius: 8).fill()
                UIColor(red: 0.25, green: 0.55, blue: 0.32, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 300, y: 560, width: 200, height: 160)).fill()
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func drawGradient(in bounds: CGRect, colors: [UIColor], context: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.minY),
            end: CGPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )
    }
}
#endif
