import Foundation

/// A private note. Only the encrypted file on disk is persisted. Decrypted copies stay in memory.
struct VaultNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var attachments: [VaultAttachment]
    var deletedAt: Date? = nil
    var isFavorite: Bool = false
    var openCount: Int = 0
    var lastOpened: Date? = nil
    var favoriteOrder: Int? = nil

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        attachments: [VaultAttachment] = [],
        deletedAt: Date? = nil,
        isFavorite: Bool = false,
        openCount: Int = 0,
        lastOpened: Date? = nil,
        favoriteOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
        self.openCount = openCount
        self.lastOpened = lastOpened
        self.favoriteOrder = favoriteOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, createdAt, updatedAt, attachments, deletedAt
        case isFavorite, openCount, lastOpened, favoriteOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        attachments = try container.decodeIfPresent([VaultAttachment].self, forKey: .attachments) ?? []
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        openCount = try container.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        favoriteOrder = try container.decodeIfPresent(Int.self, forKey: .favoriteOrder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(openCount, forKey: .openCount)
        try container.encodeIfPresent(lastOpened, forKey: .lastOpened)
        try container.encodeIfPresent(favoriteOrder, forKey: .favoriteOrder)
    }
}

/// Metadata for a photo stored as its own encrypted file. The filename is inside the encrypted note, not the disk name.
struct VaultAttachment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var filename: String
    var type: VaultAttachmentType

    init(id: UUID = UUID(), filename: String, type: VaultAttachmentType = .photo) {
        self.id = id
        self.filename = filename
        self.type = type
    }
}

enum VaultAttachmentType: String, Codable, Equatable, Sendable {
    case photo
}

extension VaultNote {
    /// Harmless notes shown the first time the decoy area is opened.
    static func sampleNotes(now: Date = .now) -> [VaultNote] {
        [
            VaultNote(
                title: "Groceries",
                body: "Milk, oats, coffee, apples.",
                createdAt: now,
                updatedAt: now
            ),
            VaultNote(
                title: "Weekend",
                body: "Walk, farmers market, call family.",
                createdAt: now,
                updatedAt: now
            )
        ]
    }
}
