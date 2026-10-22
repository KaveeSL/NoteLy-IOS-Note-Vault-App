import SwiftUI
import UIKit

/// The private area uses the same Folders, notes list, and glass controls as Notes.
struct VaultHomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: VaultViewModel
    @ObservedObject var files: VaultFilesViewModel
    @State private var path = NavigationPath()
    @State private var pendingNote: VaultNote?
    @State private var editingFavorites = false
    @State private var openedFile: VaultItem?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !favorites.isEmpty {
                    Section {
                        if editingFavorites {
                            ForEach(favorites) { item in
                                Button {
                                    removeFavorite(item)
                                } label: {
                                    Label(item.title, systemImage: "minus.circle.fill")
                                        .foregroundStyle(.primary)
                                }
                            }
                            .onMove(perform: moveFavorites)
                        } else {
                            favoritesRow
                        }
                    } header: {
                        HStack {
                            Text("Favorites")
                            Spacer()
                            Button(editingFavorites ? "Done" : "Edit") {
                                editingFavorites.toggle()
                            }
                            .font(.subheadline)
                            .textCase(nil)
                        }
                    }
                }
                Section("On My iPhone") {
                    NavigationLink(value: "notes") {
                        vaultFolder(name: "Notes", symbol: "folder.fill", count: model.notes.count)
                    }
                    NavigationLink(value: "files") {
                        vaultFolder(name: "Files", symbol: "folder.fill", count: files.visibleItems.count)
                    }
                    NavigationLink(value: "trash") {
                        vaultFolder(name: "Recently Deleted", symbol: "trash", count: deletedCount)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(VaultCopy.homeTitle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        appState.lockFromButton()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("Lock now")
                    .accessibilityIdentifier("vault.lock")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        VaultSettingsView(settings: appState.settings, autoLock: appState.autoLock)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $files.wantsPhotoPicker, onDismiss: { appState.setSystemUI(false) }) {
                PhotoLibraryPicker { results in
                    Task { await files.importPickerResults(results, removeFromPhotos: false) }
                }
                .onAppear { appState.setSystemUI(true) }
            }
            .alert("Import", isPresented: importDebugPresented) {
                Button("OK", role: .cancel) { files.importDebug = nil }
            } message: {
                Text(files.importDebug ?? "")
            }
            .navigationDestination(for: String.self) { destination in
                if destination == "files" {
                    VaultFilesView(model: files)
                } else if destination == "trash" {
                    VaultTrashView(model: model, files: files)
                } else {
                    vaultNotes
                }
            }
            .navigationDestination(for: UUID.self) { id in
                VaultNoteEditorView(noteID: id, model: model)
            }
            .environment(\.editMode, .constant(editingFavorites ? .active : .inactive))
            .sheet(item: $openedFile) { item in
                VaultItemViewer(item: item, model: files)
            }
        }
        .accessibilityIdentifier("vault.home")
        .interactiveDismissDisabled(true)
        .background(IdleTouchMonitor { appState.registerActivity() })
        .tint(Theme.vault)
        .alert("Delete this note?", isPresented: noteDeletePresented) {
            Button("Delete", role: .destructive) {
                if let pendingNote { model.moveToTrash(id: pendingNote.id) }
                pendingNote = nil
            }
            Button("Cancel", role: .cancel) { pendingNote = nil }
        } message: {
            Text("It moves to Recently Deleted. You can recover it from there.")
        }
        .task {
            await model.load()
            await files.load()
        }
        .onDisappear {
            model.flush()
        }
    }

    private var vaultNotes: some View {
        Group {
            if activeNotes.isEmpty {
                VStack(spacing: 4) {
                    Text("No Notes")
                        .font(.headline)
                    Text("Tap the compose button to start a note.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                List {
                    Section("Today") {
                        ForEach(activeNotes) { note in
                            NavigationLink(value: note.id) {
                                VaultNoteRow(note: note)
                            }
                            .swipeActions {
                                Button {
                                    model.setFavorite(id: note.id, favorite: !note.isFavorite)
                                } label: {
                                    Label(note.isFavorite ? "Unfavorite" : "Favorite", systemImage: "star")
                                }
                                .tint(Theme.vault)
                                Button(role: .destructive) {
                                    pendingNote = note
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Section {
                        Text("\(activeNotes.count) Notes")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Notes")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let status = model.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .notesGlass(in: Capsule())
                        .accessibilityLabel(status)
                }
                HStack {
                    Spacer()
                    Button(action: createNote) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 20))
                            .frame(width: 48, height: 48)
                            .notesGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New note")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var activeNotes: [VaultNote] {
        model.notes.filter { $0.deletedAt == nil }
    }

    private var deletedCount: Int {
        model.notes.filter { $0.deletedAt != nil }.count + files.deletedItems.count
    }

    private var noteDeletePresented: Binding<Bool> {
        Binding(get: { pendingNote != nil }, set: { if !$0 { pendingNote = nil } })
    }

    private func vaultFolder(name: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.vault)
                .frame(width: 28)
            Text(name)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var importDebugPresented: Binding<Bool> {
        Binding(get: { files.importDebug != nil }, set: { if !$0 { files.importDebug = nil } })
    }

    private var favorites: [FavoriteCandidate] {
        let fileItems = files.items.filter { item in
            !files.deletedItems.contains(where: { $0.id == item.id })
        }.map { item in
            FavoriteCandidate(
                id: "file-\(item.id.uuidString)",
                title: item.originalName,
                starred: item.isFavorite,
                order: item.favoriteOrder,
                openCount: item.openCount,
                lastOpened: item.lastOpened,
                systemImage: item.type == .video ? "video.fill" : (item.type == .photo ? "photo.fill" : "doc.fill")
            )
        }
        let noteItems = model.notes.filter { $0.deletedAt == nil }.map { note in
            FavoriteCandidate(
                id: "note-\(note.id.uuidString)",
                title: note.title.isEmpty ? "New Note" : note.title,
                starred: note.isFavorite,
                order: note.favoriteOrder,
                openCount: note.openCount,
                lastOpened: note.lastOpened,
                systemImage: "note.text"
            )
        }
        return FavoriteRanking.rank(fileItems + noteItems, mode: appState.favoriteMode)
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(favorites) { item in
                    Button {
                        openFavorite(item)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.systemImage)
                                .font(.title2)
                                .foregroundStyle(Theme.vault)
                                .frame(width: 64, height: 64)
                                .background(Theme.vault.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Favorite \(item.title)")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func openFavorite(_ item: FavoriteCandidate) {
        let raw = item.id.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        guard let id = UUID(uuidString: raw) else { return }
        if item.id.hasPrefix("note-") {
            path.append(id)
        } else if let file = files.items.first(where: { $0.id == id }) {
            openedFile = file
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func removeFavorite(_ item: FavoriteCandidate) {
        let raw = item.id.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        guard let id = UUID(uuidString: raw) else { return }
        if item.id.hasPrefix("note-") {
            model.removeFavorite(id: id)
        } else {
            files.removeFavorite(id: id)
        }
    }

    private func moveFavorites(from source: IndexSet, to destination: Int) {
        var ordered = favorites
        ordered.move(fromOffsets: source, toOffset: destination)
        let noteIDs = ordered.compactMap { candidate -> UUID? in
            guard candidate.id.hasPrefix("note-") else { return nil }
            return UUID(uuidString: String(candidate.id.dropFirst("note-".count)))
        }
        let fileIDs = ordered.compactMap { candidate -> UUID? in
            guard candidate.id.hasPrefix("file-") else { return nil }
            return UUID(uuidString: String(candidate.id.dropFirst("file-".count)))
        }
        model.reorderFavorites(noteIDs)
        files.reorderFavorites(fileIDs)
    }

    private func createNote() {
        let note = model.createNote()
        path.append(note.id)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func delete(_ note: VaultNote) {
        model.delete(id: note.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private struct VaultTrashView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: VaultViewModel
    @ObservedObject var files: VaultFilesViewModel
    @State private var pendingNote: VaultNote?
    @State private var pendingFile: VaultItem?

    var body: some View {
        List {
            Section("Notes") {
                let notes = model.notes.filter { $0.deletedAt != nil }
                if notes.isEmpty {
                    Text("No deleted notes")
                        .foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    VaultNoteRow(note: note)
                        .swipeActions {
                            Button("Recover") { model.restore(id: note.id) }.tint(Theme.vault)
                            Button("Delete", role: .destructive) { pendingNote = note }
                        }
                }
            }
            Section("Files") {
                if files.deletedItems.isEmpty {
                    Text("No deleted files")
                        .foregroundStyle(.secondary)
                }
                ForEach(files.deletedItems) { item in
                    Text(item.originalName)
                        .swipeActions {
                            Button("Recover") { files.restore(ids: [item.id]) }.tint(Theme.vault)
                            Button("Delete", role: .destructive) { pendingFile = item }
                        }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            Button("Empty") {
                Task { await appState.emptyRecentlyDeleted() }
            }
        }
        .alert("Delete this note permanently?", isPresented: notePresented) {
            Button("Delete", role: .destructive) {
                if let pendingNote { model.delete(id: pendingNote.id) }
                pendingNote = nil
            }
            Button("Cancel", role: .cancel) { pendingNote = nil }
        }
        .alert("Delete this file permanently?", isPresented: filePresented) {
            Button("Delete", role: .destructive) {
                if let pendingFile { files.delete(ids: [pendingFile.id]) }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var notePresented: Binding<Bool> {
        Binding(get: { pendingNote != nil }, set: { if !$0 { pendingNote = nil } })
    }

    private var filePresented: Binding<Bool> {
        Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } })
    }
}

private struct VaultNoteRow: View {
    let note: VaultNote

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(note.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Theme.vault)
            }
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    private var preview: String {
        let text = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "No additional text" : line
    }
}
