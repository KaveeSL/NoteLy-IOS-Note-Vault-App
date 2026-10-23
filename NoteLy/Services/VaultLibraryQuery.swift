import Foundation

enum VaultFileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case files = "Files"
    var id: String { rawValue }

    var emptyTitle: String {
        switch self {
        case .all: return "No Files"
        case .photos: return "No Photos"
        case .videos: return "No Videos"
        case .files: return "No Files"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "photo"
        case .videos: return "video"
        case .files: return "doc"
        }
    }
}

enum VaultFileSort: String, CaseIterable, Identifiable {
    case imported = "Date Added"
    case created = "Date Created"
    case name = "Name"
    case size = "Size"
    var id: String { rawValue }
}

enum VaultLibraryQuery {
    static func apply(
        items: [VaultItem],
        trash: Set<UUID>,
        folderID: UUID?,
        filter: VaultFileFilter,
        favoritesOnly: Bool,
        sort: VaultFileSort,
        ascending: Bool,
        query: String
    ) -> [VaultItem] {
        var result = items.filter { item in
            guard !trash.contains(item.id) else { return false }
            if filter == .all {
                return item.folderID == folderID
            }
            return true
        }
        switch filter {
        case .all: break
        case .photos: result = result.filter { $0.type == .photo }
        case .videos: result = result.filter { $0.type == .video }
        case .files: result = result.filter(\.type.isFile)
        }
        if favoritesOnly {
            result = result.filter(\.isFavorite)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            result = result.filter { $0.originalName.localizedCaseInsensitiveContains(needle) }
        }
        result.sort { lhs, rhs in
            let ordered: Bool
            switch sort {
            case .imported: ordered = lhs.importedAt < rhs.importedAt
            case .created: ordered = lhs.createdAt < rhs.createdAt
            case .name: ordered = lhs.originalName.localizedStandardCompare(rhs.originalName) == .orderedAscending
            case .size: ordered = lhs.size < rhs.size
            }
            return ascending ? ordered : !ordered
        }
        return result
    }

    static func counts(items: [VaultItem], trash: Set<UUID>, folderID: UUID?) -> [VaultFileFilter: Int] {
        let visible = items.filter { $0.folderID == folderID && !trash.contains($0.id) }
        return [
            .all: visible.count,
            .photos: visible.filter { $0.type == .photo }.count,
            .videos: visible.filter { $0.type == .video }.count,
            .files: visible.filter(\.type.isFile).count
        ]
    }
}
