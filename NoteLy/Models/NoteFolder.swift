import Foundation
import SwiftData

enum FolderKind: String, Codable {
    case notes
    case deleted
    case custom
}

@Model
final class NoteFolder {
    var id: UUID = UUID()
    var name: String = "Folder"
    var sortOrder: Int = 0
    var isSystem: Bool = false
    var kindRaw: String = FolderKind.custom.rawValue
    var createdAt: Date = Date()
    var parent: NoteFolder?
    @Relationship(deleteRule: .cascade, inverse: \NoteFolder.parent)
    var children: [NoteFolder]? = []
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        isSystem: Bool = false,
        kind: FolderKind = .custom,
        createdAt: Date = .now,
        parent: NoteFolder? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isSystem = isSystem
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.parent = parent
    }

    var kind: FolderKind {
        get { FolderKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class NoteAttachment {
    var id: UUID = UUID()
    var typeRaw: String = "file"
    var fileName: String = ""
    var payload: Data? = nil
    var thumbnail: Data? = nil
    var note: Note?

    init(id: UUID = UUID(), typeRaw: String, fileName: String, payload: Data? = nil, thumbnail: Data? = nil) {
        self.id = id
        self.typeRaw = typeRaw
        self.fileName = fileName
        self.payload = payload
        self.thumbnail = thumbnail
    }
}
