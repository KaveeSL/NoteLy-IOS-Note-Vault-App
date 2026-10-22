import Combine
import Foundation

/// Filtering for the public notes list. The secret phrase is not checked here.
/// Phrase checks happen only when the user submits search, in `AppState`.
@MainActor
final class NotesListViewModel: ObservableObject {
    @Published private(set) var debouncedQuery = ""
    @Published var selectedTag: String?
    @Published var selectedNoteID: UUID?
    @Published var layout: NoteLayout = .list
    @Published var sort: NoteSort = .edited
    @Published var groupByDate = true
    @Published var searchScope: NoteSearchScope = .folder
    @Published var lockRevision = 0
    @Published var isSelecting = false
    @Published var selection = Set<UUID>()
    private var debounceTask: Task<Void, Never>?

    /// Debounces live filtering so a fast typist does not rebuild the list on every character.
    /// An empty query updates immediately. This never hashes the text.
    func queryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()
        if trimmed.isEmpty {
            debouncedQuery = ""
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            debouncedQuery = trimmed
        }
    }

    func filtered(from notes: [Note]) -> (pinned: [Note], recent: [Note]) {
        var result = notes
        if let selectedTag {
            result = result.filter { $0.colorTag == selectedTag }
        }
        if !debouncedQuery.isEmpty {
            let query = debouncedQuery
            result = result.filter { note in
                note.title.localizedCaseInsensitiveContains(query)
                    || note.body.localizedCaseInsensitiveContains(query)
            }
        }
        let pinned = result
            .filter(\.isPinned)
            .sorted { $0.updatedAt > $1.updatedAt }
        let recent = result
            .filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        return (pinned, recent)
    }

    func grouped(
        from notes: [Note],
        folder: NoteFolder?,
        hashTag: String? = nil,
        smart: SmartFolder? = nil,
        allFolders: Bool = false
    ) -> [NoteGroup] {
        var pool = notes.filter { note in
            if folder?.kind == .deleted && smart == nil && hashTag == nil {
                return note.deletedAt != nil
            }
            guard note.deletedAt == nil else { return false }
            if allFolders || smart != nil || hashTag != nil { return true }
            if searchScope == .all && !debouncedQuery.isEmpty { return true }
            if folder == nil || folder?.kind == .notes {
                return note.folder == nil || note.folder?.kind == .notes
            }
            return note.folder?.id == folder?.id
        }
        if let hashTag {
            pool = pool.filter { $0.tags.contains { $0.caseInsensitiveCompare(hashTag) == .orderedSame } }
        }
        if let smart {
            if !smart.tag.isEmpty {
                pool = pool.filter { $0.tags.contains { $0.caseInsensitiveCompare(smart.tag) == .orderedSame } }
            }
            if smart.pinnedOnly { pool = pool.filter(\.isPinned) }
            if smart.withAttachments {
                pool = pool.filter { ($0.attachments?.isEmpty == false) || $0.drawingData != nil }
            }
            if smart.withChecklists {
                pool = pool.filter { $0.plainText.contains("○") || $0.body.contains("○") }
            }
            if smart.lockedOnly { pool = pool.filter { NoteLocks.contains($0.id) } }
        }
        if let selectedTag {
            pool = pool.filter { $0.colorTag == selectedTag }
        }
        if !debouncedQuery.isEmpty {
            let query = debouncedQuery
            pool = pool.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.body.localizedCaseInsensitiveContains(query)
                    || $0.plainText.localizedCaseInsensitiveContains(query)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        switch sort {
        case .edited: pool.sort { $0.updatedAt > $1.updatedAt }
        case .created: pool.sort { $0.createdAt > $1.createdAt }
        case .title: pool.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if !groupByDate || sort == .title {
            return [NoteGroup(id: "all", title: "Notes", notes: pool)]
        }
        let pinned = pool.filter(\.isPinned)
        let rest = pool.filter { !$0.isPinned }
        var groups: [NoteGroup] = []
        if !pinned.isEmpty {
            groups.append(NoteGroup(id: "pinned", title: "Pinned", notes: pinned))
        }
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return "Previous 7 Days" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 30 { return "Previous 30 Days" }
            return date.formatted(.dateTime.month(.wide).year())
        }
        var order: [String] = []
        var map: [String: [Note]] = [:]
        for note in rest {
            let key = bucket(note.updatedAt)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(note)
        }
        for key in order {
            groups.append(NoteGroup(id: key, title: key, notes: map[key] ?? []))
        }
        return groups
    }
}

enum NoteLayout: String, CaseIterable, Identifiable {
    case list = "List"
    case gallery = "Gallery"
    var id: String { rawValue }
}

enum NoteSort: String, CaseIterable, Identifiable {
    case edited = "Date Edited"
    case created = "Date Created"
    case title = "Title"
    var id: String { rawValue }
}

enum NoteSearchScope: String, CaseIterable, Identifiable {
    case folder = "This Folder"
    case all = "All Notes"
    var id: String { rawValue }
}

struct NoteGroup: Identifiable {
    var id: String
    var title: String
    var notes: [Note]
}
