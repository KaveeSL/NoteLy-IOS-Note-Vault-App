import Combine
import CryptoKit
import Foundation

/// In-memory private notes. Ciphertext stays in `VaultStore`. `wipeMemory()` drops decrypted copies.
@MainActor
final class VaultViewModel: ObservableObject {
    @Published private(set) var notes: [VaultNote] = []
    @Published var statusMessage: String?
    var useDecoyStore = false
    var reauth: ReauthService?
    var risks: RiskLedger?

    private let vaultStore: VaultStoring
    private let decoyStore: VaultStoring
    private let session: VaultSession
    private var staged: VaultNote?
    private var saveTask: Task<Void, Never>?

    init(vaultStore: VaultStoring, decoyStore: VaultStoring, session: VaultSession) {
        self.vaultStore = vaultStore
        self.decoyStore = decoyStore
        self.session = session
    }

    private var store: VaultStoring {
        useDecoyStore ? decoyStore : vaultStore
    }

    func load() async {
        guard let key = session.key else {
            notes = []
            return
        }
        let store = self.store
        let decoy = useDecoyStore
        do {
            let loaded = try await Task.detached {
                if decoy {
                    return try store.seedSamplesIfNeeded(using: key)
                }
                return try store.loadAll(using: key)
            }.value
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            var kept: [VaultNote] = []
            for note in loaded {
                if let deletedAt = note.deletedAt, deletedAt < cutoff {
                    try? store.delete(id: note.id)
                } else {
                    kept.append(note)
                }
            }
            notes = kept
        } catch {
            VaultLog.security.error("Private notes could not be loaded")
            notes = []
            statusMessage = "Couldn't open notes."
        }
    }

    @discardableResult
    func createNote() -> VaultNote {
        let note = VaultNote()
        notes.insert(note, at: 0)
        staged = note
        flush()
        return note
    }

    func stage(_ note: VaultNote) {
        staged = note
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the in-memory draft before a lock wipes it. AES-GCM of one note is short;
    /// phrase stretching, which is the slow step, does not run here.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let staged, let key = session.key else { return }
        do {
            try store.save(staged, using: key)
            if self.staged?.id == staged.id {
                self.staged = nil
            }
        } catch {
            VaultLog.security.error("Private note save failed")
            statusMessage = "Couldn't save this note."
        }
    }

    func moveToTrash(id: UUID) {
        guard var note = currentNote(id: id) else { return }
        note.deletedAt = .now
        note.updatedAt = .now
        stage(note)
        flush()
    }

    func restore(id: UUID) {
        guard var note = currentNote(id: id) else { return }
        note.deletedAt = nil
        note.updatedAt = .now
        stage(note)
        flush()
    }

    func delete(id: UUID) {
        Task { await deleteConfirmed(ids: [id], action: .permanentDelete) }
    }

    func emptyDeleted() {
        let ids = notes.filter { $0.deletedAt != nil }.map(\.id)
        Task { await deleteConfirmed(ids: ids, action: .emptyBin) }
    }

    func eraseDeleted(proof: RiskProof) {
        guard let risks else { return }
        guard (try? risks.require(proof, action: proof.action)) != nil else { return }
        for note in notes where note.deletedAt != nil {
            erase(id: note.id)
        }
    }

    private func deleteConfirmed(ids: [UUID], action: RiskyAction) async {
        guard !ids.isEmpty else { return }
        guard let proof = await reauth?.authorize(action), let risks else {
            statusMessage = "That needs Face ID or the vault passcode."
            return
        }
        do {
            try risks.require(proof, action: action)
        } catch {
            statusMessage = "That needs Face ID or the vault passcode."
            return
        }
        for id in ids {
            erase(id: id)
        }
    }

    private func erase(id: UUID) {
        if staged?.id == id { staged = nil }
        notes.removeAll { $0.id == id }
        do {
            try store.delete(id: id)
        } catch {
            VaultLog.security.error("Private note delete failed")
            statusMessage = "Couldn't delete this note."
        }
    }

    func setFavorite(id: UUID, favorite: Bool) {
        guard var note = currentNote(id: id) else { return }
        note.isFavorite = favorite
        if favorite, note.favoriteOrder == nil {
            note.favoriteOrder = notes.filter(\.isFavorite).count
        }
        stage(note)
        flush()
    }

    func recordOpen(id: UUID) {
        guard var note = currentNote(id: id) else { return }
        note.openCount += 1
        note.lastOpened = .now
        stage(note)
        flush()
    }

    func clearUsage() {
        for index in notes.indices {
            notes[index].openCount = 0
            notes[index].lastOpened = nil
        }
        flushNotes()
    }

    func removeFavorite(id: UUID) {
        guard var note = currentNote(id: id) else { return }
        note.isFavorite = false
        note.favoriteOrder = nil
        note.openCount = 0
        note.lastOpened = nil
        stage(note)
        flush()
    }

    func reorderFavorites(_ ids: [UUID]) {
        for (position, id) in ids.enumerated() {
            guard var note = currentNote(id: id) else { continue }
            note.favoriteOrder = position
            note.isFavorite = true
            stage(note)
        }
        flush()
    }

    private func flushNotes() {
        guard let key = session.key else { return }
        for note in notes {
            try? store.save(note, using: key)
        }
    }

    func addPhoto(noteID: UUID, filename: String, imageData: Data) {
        guard let key = session.key else { return }
        guard var note = currentNote(id: noteID) else { return }
        let attachment = VaultAttachment(filename: filename, type: .photo)
        do {
            try store.saveAttachment(
                noteID: noteID,
                attachmentID: attachment.id,
                data: imageData,
                using: key
            )
            note.attachments.append(attachment)
            note.updatedAt = .now
            stage(note)
            flush()
        } catch {
            try? store.deleteAttachment(noteID: noteID, attachmentID: attachment.id)
            VaultLog.security.error("Photo save failed")
            statusMessage = "Couldn't save that photo."
        }
    }

    func loadPhoto(noteID: UUID, attachmentID: UUID) -> Data? {
        guard let key = session.key else { return nil }
        do {
            return try store.loadAttachment(noteID: noteID, attachmentID: attachmentID, using: key)
        } catch {
            VaultLog.security.error("Photo read failed")
            return nil
        }
    }

    func removePhoto(noteID: UUID, attachmentID: UUID) {
        guard var note = currentNote(id: noteID) else { return }
        note.attachments.removeAll { $0.id == attachmentID }
        note.updatedAt = .now
        do {
            try store.deleteAttachment(noteID: noteID, attachmentID: attachmentID)
        } catch {
            VaultLog.security.error("Photo delete failed")
        }
        stage(note)
        flush()
    }

    /// Drops decrypted notes and the staged draft. The key itself is cleared by `VaultSession`.
    func wipeMemory() {
        saveTask?.cancel()
        saveTask = nil
        staged = nil
        notes = []
        statusMessage = nil
    }

    private func currentNote(id: UUID) -> VaultNote? {
        if staged?.id == id {
            return staged
        }
        return notes.first { $0.id == id }
    }
}

/// Holds the vault key only while the private area is open.
/// CryptoKit does not offer a zeroize API for `SymmetricKey`; locking drops the only reference.
@MainActor
final class VaultSession {
    private(set) var key: SymmetricKey?
    var isOpen: Bool { key != nil }

    func install(_ key: SymmetricKey) {
        self.key = key
    }

    func wipe() {
        key = nil
    }
}
