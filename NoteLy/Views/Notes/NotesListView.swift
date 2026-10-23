import SwiftData
import SwiftUI
import UIKit

struct NotesListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \NoteFolder.sortOrder) private var folders: [NoteFolder]
    @ObservedObject var viewModel: NotesListViewModel
    @ObservedObject private var preferences = NotesPreferences.shared
    @State private var path = NavigationPath()
    @State private var selectedFolder: NoteFolder?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderError: String?
    @State private var renameTarget: NoteFolder?
    @State private var renameText = ""
    @State private var showSmartFolder = false
    @State private var showQuickNote = false
    @State private var openedSmartFolder: SmartFolder?
    @State private var openedTag: String?
    @State private var moveNote: Note?
    @State private var folderToMove: NoteFolder?
    @State private var shareText: String?
    @State private var editingFolders = false
    @State private var pendingDelete: Note?
    @State private var pendingErase: Note?
    @State private var pendingFolder: NoteFolder?
    @State private var showSettings = false
    @State private var lockRemovalID: UUID?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    folderList
                } content: {
                    notesPage(folder: selectedFolder ?? defaultFolder, pushes: false)
                } detail: {
                    if let id = viewModel.selectedNoteID, let note = notes.first(where: { $0.id == id }) {
                        NoteEditorView(note: note, folders: folders.filter { $0.kind != .deleted })
                    } else {
                        ContentUnavailableView("Select a note", systemImage: "note.text", description: Text("Your note will show up here."))
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    folderList
                        .navigationDestination(for: UUID.self) { id in
                            if let folder = folders.first(where: { $0.id == id }) {
                                notesPage(folder: folder, pushes: true)
                            } else if let note = notes.first(where: { $0.id == id }) {
                                NoteEditorView(note: note, folders: folders.filter { $0.kind != .deleted })
                            }
                        }
                        .navigationDestination(item: $openedSmartFolder) { smart in
                            notesPage(folder: defaultFolder, pushes: true, smart: smart, allFolders: true)
                        }
                        .navigationDestination(item: $openedTag) { tag in
                            notesPage(folder: defaultFolder, pushes: true, hashTag: tag, allFolders: true)
                        }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: viewModel.layout)
        .onAppear {
            ensureFolders()
            purgeDeleted()
            #if DEBUG
            appState.seedUITestNotesIfNeeded(context: modelContext, existingCount: notes.count)
            #endif
        }
        .alert("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { softDelete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It moves to Recently Deleted. You can restore it from there.")
        }
        .alert("Delete this note permanently?", isPresented: Binding(get: { pendingErase != nil }, set: { if !$0 { pendingErase = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingErase { erase(pendingErase) }
                pendingErase = nil
            }
            Button("Cancel", role: .cancel) { pendingErase = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .onChange(of: lockRemovalID) { _, id in
            guard let id else { return }
            Task {
                let outcome = await appState.biometric.authenticate(reason: UnlockPrompt.reason)
                if case .success = outcome {
                    NoteLocks.set(id, locked: false)
                    viewModel.lockRevision += 1
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                lockRemovalID = nil
            }
        }
        .alert("Delete this folder?", isPresented: Binding(get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingFolder { deleteFolder(pendingFolder) }
                pendingFolder = nil
            }
            Button("Cancel", role: .cancel) { pendingFolder = nil }
        } message: {
            Text("Notes in this folder move back to Notes.")
        }
    }

    private var defaultFolder: NoteFolder? {
        folders.first { $0.kind == .notes }
    }

    private var folderList: some View {
        List {
            Section {
                ForEach(rootFolders) { folder in
                    folderRow(folder)
                        .deleteDisabled(folder.isSystem || folder.kind == .deleted)
                        .moveDisabled(folder.isSystem || folder.kind == .deleted)
                }
            }
            if !preferences.smartFolders.isEmpty {
                Section("Smart Folders") {
                    ForEach(preferences.smartFolders) { folder in
                        Button {
                            openedSmartFolder = folder
                        } label: {
                            folderLabel(name: folder.name, symbol: "gearshape.fill", count: nil)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                preferences.smartFolders.removeAll { $0.id == folder.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Button("#\(tag)") { openedTag = tag }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .tint(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(FolderEditMode(editing: editingFolders))
        .navigationTitle("Folders")
        .navigationDestination(isPresented: $showSettings) {
            NotesSettingsView(viewModel: viewModel)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showNewFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
                Button(editingFolders ? "Done" : "Edit") {
                    withAnimation(.smooth(duration: 0.25)) { editingFolders.toggle() }
                }
                .contextMenu {
                    Button("New Smart Folder") { showSmartFolder = true }
                    Button("Quick Note") { showQuickNote = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            NotesBottomBar(viewModel: viewModel, showsCompose: true, showsMove: false) {
                createNote(in: defaultFolder)
            } onMove: {}
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Save") { createFolder() }
        } message: {
            Text(folderError ?? "Folders keep related notes together.")
        }
        .alert("Rename Folder", isPresented: renamePresented) {
            TextField("Folder name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") { commitRename() }
        }
        .sheet(isPresented: $showSmartFolder) {
            SmartFolderSheet { folder in
                preferences.smartFolders.append(folder)
            }
        }
        .sheet(isPresented: $showQuickNote) {
            QuickNoteSheet { text in
                saveQuickNote(text)
            }
        }
        .sheet(item: $moveNote) { note in
            NavigationStack {
                List(folders.filter { $0.kind != .deleted }) { folder in
                    Button(folder.name) {
                        note.folder = folder
                        note.updatedAt = .now
                        try? modelContext.save()
                        moveNote = nil
                    }
                }
                .navigationTitle("Move Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { moveNote = nil } }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $folderToMove) { folder in
            NavigationStack {
                let destinations = folders.filter { $0.kind != .deleted && $0.id != folder.id }
                Group {
                    if destinations.isEmpty {
                        ContentUnavailableView("No other folder", systemImage: "folder", description: Text("Add a folder, then move these notes into it."))
                    } else {
                        List(destinations) { destination in
                            Button {
                                moveNotes(from: folder, to: destination)
                            } label: {
                                Label(destination.name, systemImage: destination.kind == .notes ? "folder.fill" : "folder")
                            }
                        }
                    }
                }
                .navigationTitle("Move")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { folderToMove = nil } }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: sharePresented) {
            if let shareText {
                ActivityShare(text: shareText)
                    .ignoresSafeArea()
            }
        }
    }

    private var sharePresented: Binding<Bool> {
        Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var rootFolders: [NoteFolder] {
        folders.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var tags: [String] {
        Array(Set(notes.flatMap(\.tags))).sorted()
    }

    @ViewBuilder
    private func folderRow(_ folder: NoteFolder) -> some View {
        let count = count(in: folder)
        if horizontalSizeClass == .regular {
            Button {
                selectedFolder = folder
            } label: {
                folderLabel(folder, count: count)
            }
            .buttonStyle(.borderless)
            .folderSlideActions(folder: folder, share: { shareFolder(folder) }, move: { folderToMove = folder }, delete: { pendingFolder = folder })
            .contextMenu { folderMenu(folder) }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Button {
                path.append(folder.id)
            } label: {
                HStack(spacing: 8) {
                    folderLabel(folder, count: count)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.borderless)
            .folderSlideActions(folder: folder, share: { shareFolder(folder) }, move: { folderToMove = folder }, delete: { pendingFolder = folder })
            .contextMenu { folderMenu(folder) }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: NoteFolder) -> some View {
        if folder.kind != .deleted {
            Button { shareFolder(folder) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { folderToMove = folder } label: { Label("Move", systemImage: "folder") }
        }
        if folder.kind != .deleted && !folder.isSystem {
            Button {
                renameText = folder.name
                renameTarget = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { pendingFolder = folder } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func folderLabel(_ folder: NoteFolder, count: Int) -> some View {
        folderLabel(name: folder.name, symbol: folder.kind == .deleted ? "trash" : "folder.fill", count: count)
    }

    private func folderLabel(name: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            if let count {
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func count(in folder: NoteFolder) -> Int {
        if folder.kind == .deleted {
            return notes.filter { $0.deletedAt != nil }.count
        }
        return notes.filter { note in
            note.deletedAt == nil && (note.folder?.id == folder.id || (folder.kind == .notes && note.folder == nil))
        }.count
    }

    private func emptyNotes(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func notesPage(
        folder: NoteFolder?,
        pushes: Bool,
        smart: SmartFolder? = nil,
        hashTag: String? = nil,
        allFolders: Bool = false
    ) -> some View {
        let _ = viewModel.lockRevision
        let groups = viewModel.grouped(from: notes, folder: folder, hashTag: hashTag, smart: smart, allFolders: allFolders)
        let visible = groups.flatMap(\.notes)
        let title = smart?.name ?? hashTag.map { "#\($0)" } ?? folder?.name ?? "Notes"
        return Group {
            if viewModel.layout == .gallery {
                if visible.isEmpty {
                    emptyNotes(viewModel.debouncedQuery.isEmpty ? "No Notes" : "No matching notes", viewModel.debouncedQuery.isEmpty ? "Capture a thought. It stays on this device." : "Try a different word.")
                } else {
                    gallery(visible, folder: folder, pushes: pushes)
                }
            } else {
                List {
                    if notes.isEmpty && folder?.kind != .deleted {
                        emptyNotes("No Notes", "Capture a thought. It stays on this device.")
                    } else if visible.isEmpty {
                        emptyNotes("No matching notes", "Try a different word.")
                    } else {
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.notes, id: \.persistentModelID) { note in
                                    noteLink(note, folder: folder, pushes: pushes)
                                }
                            }
                        }
                    }
                    if !visible.isEmpty {
                        Section {
                            Text("\(visible.count) Notes")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .toolbar { notesToolbar(folder: folder) }
        .safeAreaInset(edge: .bottom) {
            if folder?.kind != .deleted {
                NotesBottomBar(
                    viewModel: viewModel,
                    showsCompose: smart == nil && hashTag == nil,
                    showsMove: viewModel.isSelecting
                ) {
                    createNote(in: folder)
                } onMove: {
                    moveSelection(in: folder)
                }
            }
        }
    }

    private func gallery(_ visible: [Note], folder: NoteFolder?, pushes: Bool) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(visible, id: \.persistentModelID) { note in
                    Button {
                        open(note, pushes: pushes)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(note.title.isEmpty ? "New Note" : note.title).font(.headline).lineLimit(1)
                                Spacer()
                                Text(note.updatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                            }
                            Text(NoteLocks.contains(note.id) ? "This note is locked" : preview(note))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                        .padding(14)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            Text("\(visible.count) Notes")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .background(Theme.groupedBackground)
    }

    @ViewBuilder
    private func noteLink(_ note: Note, folder: NoteFolder?, pushes: Bool) -> some View {
        if pushes {
            Button {
                if viewModel.isSelecting {
                    toggleSelection(note)
                } else {
                    path.append(note.id)
                }
            } label: {
                NoteRowView(note: note, query: viewModel.debouncedQuery, locked: isLocked(note))
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if folder?.kind == .deleted {
                    Button { pendingErase = note } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Color(red: 1, green: 0.231, blue: 0.188))
                    Button { recover(note) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(Theme.accent)
                } else {
                    Button { pendingDelete = note } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Color(red: 1, green: 0.231, blue: 0.188))
                    Button { toggleLock(note) } label: {
                        Label(NoteLocks.contains(note.id) ? "Unlock" : "Lock", systemImage: NoteLocks.contains(note.id) ? "lock.open" : "lock")
                    }
                    .tint(.orange)
                    Button { moveNote = note } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(Color(red: 0.486, green: 0.361, blue: 0.988))
                }
            }
            .swipeActions(edge: .leading) {
                if folder?.kind != .deleted {
                    Button {
                        togglePin(note)
                    } label: {
                        Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(note.isPinned ? Color(.systemGray) : Theme.accent)
                }
            }
            .contextMenu { rowMenu(note, folder: folder) }
        } else {
            Button {
                viewModel.selectedNoteID = note.id
            } label: {
                NoteRowView(note: note, query: viewModel.debouncedQuery, locked: isLocked(note))
            }
            .buttonStyle(.plain)
            .listRowBackground(viewModel.selectedNoteID == note.id ? Theme.selection : Theme.cardBackground)
        }
    }

    @ViewBuilder
    private func rowMenu(_ note: Note, folder: NoteFolder?) -> some View {
        if folder?.kind == .deleted {
            Button { recover(note) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { pendingErase = note } label: { Label("Delete", systemImage: "trash") }
        } else {
            Button { togglePin(note) } label: {
                Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
            }
            .tint(note.isPinned ? Color(.systemGray) : Theme.accent)
            Button { toggleLock(note) } label: { Label(NoteLocks.contains(note.id) ? "Unlock" : "Lock", systemImage: NoteLocks.contains(note.id) ? "lock.open" : "lock") }
            Button { moveNote = note } label: { Label("Move", systemImage: "folder") }
            Button { duplicate(note) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { pendingDelete = note } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ToolbarContentBuilder
    private func notesToolbar(folder: NoteFolder?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                withAnimation(.smooth(duration: 0.35)) {
                    viewModel.layout = viewModel.layout == .list ? .gallery : .list
                }
            } label: {
                Image(systemName: viewModel.layout == .list ? "square.grid.2x2" : "list.bullet")
            }
            .accessibilityLabel(viewModel.layout == .list ? "View as Gallery" : "View as List")
            Menu {
                Button {
                    withAnimation(.smooth(duration: 0.35)) {
                        viewModel.layout = viewModel.layout == .list ? .gallery : .list
                    }
                } label: {
                    Label(viewModel.layout == .list ? "View as Gallery" : "View as List", systemImage: viewModel.layout == .list ? "square.grid.2x2" : "list.bullet")
                }
                Button {
                    viewModel.isSelecting.toggle()
                    if !viewModel.isSelecting { viewModel.selection.removeAll() }
                } label: {
                    Label(viewModel.isSelecting ? "Done Selecting" : "Select Notes", systemImage: "checkmark.circle")
                }
                Menu {
                    Picker("Sort By", selection: $viewModel.sort) {
                        ForEach(NoteSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                Toggle("Group By Date", isOn: $viewModel.groupByDate)
                if folder?.kind == .deleted {
                    Button(role: .destructive) { eraseAllDeleted() } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("View options")
        }
    }

    private func preview(_ note: Note) -> String {
        let text = note.body.isEmpty ? note.plainText : note.body
        return text.isEmpty ? "No additional text" : text
    }

    private func ensureFolders() {
        for folder in folders where folder.kind == .notes || folder.kind == .deleted {
            folder.isSystem = true
        }
        if !folders.contains(where: { $0.kind == .notes }) {
            modelContext.insert(NoteFolder(name: "Notes", sortOrder: 0, isSystem: true, kind: .notes))
        }
        if !folders.contains(where: { $0.kind == .deleted }) {
            modelContext.insert(NoteFolder(name: "Recently Deleted", sortOrder: 1, isSystem: true, kind: .deleted))
        }
        try? modelContext.save()
    }

    private func purgeDeleted() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for note in notes where note.deletedAt.map({ $0 < cutoff }) == true {
            modelContext.delete(note)
        }
        try? modelContext.save()
    }

    private func createFolder() {
        let existing = folders.map(\.name)
        switch InputValidators.folderName(newFolderName, existing: existing) {
        case .valid(let name):
            let folder = NoteFolder(name: name, sortOrder: folders.count, kind: .custom)
            modelContext.insert(folder)
            try? modelContext.save()
            newFolderName = ""
            folderError = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .invalid(let message):
            folderError = message
            showNewFolder = true
        }
    }

    private func commitRename() {
        guard let folder = renameTarget else { return }
        let existing = folders.filter { $0.id != folder.id }.map(\.name)
        switch InputValidators.folderName(renameText, existing: existing) {
        case .valid(let name):
            folder.name = name
            try? modelContext.save()
            renameTarget = nil
        case .invalid:
            break
        }
    }

    private func saveQuickNote(_ text: String) {
        let note = Note()
        note.folder = defaultFolder
        note.plainText = text
        note.title = InputValidators.noteTitle(from: text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        note.body = lines.dropFirst().joined(separator: "\n")
        note.tags = text.split(whereSeparator: \.isWhitespace).compactMap { word -> String? in
            guard word.hasPrefix("#"), word.count > 1 else { return nil }
            return InputValidators.tag(String(word)).value
        }
        modelContext.insert(note)
        try? modelContext.save()
        open(note, pushes: horizontalSizeClass != .regular)
    }

    private func toggleSelection(_ note: Note) {
        if viewModel.selection.contains(note.id) {
            viewModel.selection.remove(note.id)
        } else {
            viewModel.selection.insert(note.id)
        }
    }

    private func moveSelection(in folder: NoteFolder?) {
        guard let note = notes.first(where: { viewModel.selection.contains($0.id) }) else { return }
        moveNote = note
    }

    private func isLocked(_ note: Note) -> Bool {
        _ = viewModel.lockRevision
        return NoteLocks.contains(note.id)
    }

    private func toggleLock(_ note: Note) {
        if NoteLocks.contains(note.id) {
            lockRemovalID = note.id
        } else {
            NoteLocks.set(note.id, locked: true)
            viewModel.lockRevision += 1
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func shareFolder(_ folder: NoteFolder) {
        let items = notes(in: folder)
        let pages = items.map { note in
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = title.isEmpty ? "New Note" : title
            return "\(heading)\n\(note.body)"
        }
        shareText = pages.isEmpty ? folder.name : ([folder.name] + pages).joined(separator: "\n\n")
    }

    private func notes(in folder: NoteFolder) -> [Note] {
        notes.filter { note in
            if folder.kind == .deleted { return note.deletedAt != nil }
            return note.deletedAt == nil && (note.folder?.id == folder.id || (folder.kind == .notes && note.folder == nil))
        }
    }

    private func moveNotes(from folder: NoteFolder, to destination: NoteFolder) {
        for note in notes(in: folder) {
            note.folder = destination
            note.updatedAt = .now
            if destination.kind == .deleted {
                note.deletedAt = note.deletedAt ?? .now
            } else {
                note.deletedAt = nil
            }
        }
        try? modelContext.save()
        folderToMove = nil
    }

    private func deleteFolder(_ folder: NoteFolder) {
        guard !folder.isSystem else { return }
        for note in notes where note.folder?.id == folder.id {
            note.folder = defaultFolder
        }
        modelContext.delete(folder)
        try? modelContext.save()
    }

    private func createNote(in folder: NoteFolder?) {
        let note = Note()
        note.folder = folder?.kind == .notes ? folder : (folder ?? defaultFolder)
        if note.folder?.kind == .deleted { note.folder = defaultFolder }
        modelContext.insert(note)
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        open(note, pushes: horizontalSizeClass != .regular)
    }

    private func open(_ note: Note, pushes: Bool) {
        if pushes {
            path.append(note.id)
        } else {
            viewModel.selectedNoteID = note.id
        }
    }

    private func togglePin(_ note: Note) {
        note.isPinned.toggle()
        note.updatedAt = .now
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func softDelete(_ note: Note) {
        note.deletedAt = .now
        note.isPinned = false
        note.updatedAt = .now
        if viewModel.selectedNoteID == note.id { viewModel.selectedNoteID = nil }
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func recover(_ note: Note) {
        note.deletedAt = nil
        note.folder = defaultFolder
        note.updatedAt = .now
        try? modelContext.save()
    }

    private func erase(_ note: Note) {
        modelContext.delete(note)
        try? modelContext.save()
    }

    private func eraseAllDeleted() {
        for note in notes where note.deletedAt != nil {
            modelContext.delete(note)
        }
        try? modelContext.save()
    }

    private func duplicate(_ note: Note) {
        let copy = Note(title: note.title, body: note.body, isPinned: false, colorTag: note.colorTag)
        copy.plainText = note.plainText
        copy.richContent = note.richContent
        copy.tags = note.tags
        copy.folder = note.folder
        modelContext.insert(copy)
        try? modelContext.save()
    }
}

/// Edit mode is applied only while editing. Leaving it set to inactive blocks the folder swipe.
private struct FolderEditMode: ViewModifier {
    let editing: Bool

    func body(content: Content) -> some View {
        if editing {
            content.environment(\.editMode, .constant(.active))
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func folderSlideActions(
        folder: NoteFolder,
        share: @escaping () -> Void,
        move: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        if folder.kind == .deleted {
            self
        } else {
            self
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !folder.isSystem {
                        Button(role: .destructive, action: delete) {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button(action: move) {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(Color(red: 0.486, green: 0.361, blue: 0.988))
                    Button(action: share) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(Color(red: 0.0, green: 0.478, blue: 1))
                }
        }
    }
}

private struct ActivityShare: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Notes search pill and the round compose button beside it.
struct NotesStyleSearchBar: View {
    @Binding var text: String
    var prompt: String
    var onCompose: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            DictationSearchField(text: $text, prompt: prompt)
            Button(action: onCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New note")
        }
    }
}

/// Search capsule on the left, circular compose button on the right. The note count stays in the list.
private struct NotesBottomBar: View {
    @ObservedObject var viewModel: NotesListViewModel
    var showsCompose: Bool
    var showsMove: Bool
    var onCompose: () -> Void
    var onMove: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            NotesSearchField(viewModel: viewModel)
            if showsMove {
                Button("Move", action: onMove)
                    .disabled(viewModel.selection.isEmpty)
            }
            if showsCompose {
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background(Color(.systemBackground), in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
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

/// Search sits on the bottom bar, beside the new-note button, the way Notes places it.
private struct NotesSearchField: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: NotesListViewModel

    var body: some View {
        DictationSearchField(text: $appState.searchText, prompt: "Search") {
            Task { await appState.handleSearchSubmit(appState.searchText) }
        }
        .onChange(of: appState.searchText) { _, newValue in
            viewModel.queryChanged(newValue)
        }
        .accessibilityLabel("Search notes")
    }
}
