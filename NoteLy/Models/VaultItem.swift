import Foundation

enum VaultMediaType: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case pdf
    case audio
    case archive
    case document
    case other

    var isFile: Bool { self != .photo && self != .video }
}

struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var originalName: String
    var type: VaultMediaType
    var utType: String
    var size: Int64
    var createdAt: Date
    var importedAt: Date
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var folderID: UUID?
    var isFavorite: Bool
    var plaintextSHA256: String
    /// Set when a Live Photo's video is stored as its own encrypted file.
    var companionID: UUID?
    var hasThumbnail: Bool
    var openCount: Int = 0
    var lastOpened: Date? = nil
    var favoriteOrder: Int? = nil

    init(
        id: UUID = UUID(),
        originalName: String,
        type: VaultMediaType,
        utType: String,
        size: Int64,
        createdAt: Date = .now,
        importedAt: Date = .now,
        duration: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        folderID: UUID? = nil,
        isFavorite: Bool = false,
        plaintextSHA256: String,
        companionID: UUID? = nil,
        hasThumbnail: Bool = false,
        openCount: Int = 0,
        lastOpened: Date? = nil,
        favoriteOrder: Int? = nil
    ) {
        self.id = id
        self.originalName = originalName
        self.type = type
        self.utType = utType
        self.size = size
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folderID = folderID
        self.isFavorite = isFavorite
        self.plaintextSHA256 = plaintextSHA256
        self.companionID = companionID
        self.hasThumbnail = hasThumbnail
        self.openCount = openCount
        self.lastOpened = lastOpened
        self.favoriteOrder = favoriteOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, originalName, type, utType, size, createdAt, importedAt, duration
        case pixelWidth, pixelHeight, folderID, isFavorite, plaintextSHA256, companionID, hasThumbnail
        case openCount, lastOpened, favoriteOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalName = try container.decode(String.self, forKey: .originalName)
        type = try container.decode(VaultMediaType.self, forKey: .type)
        utType = try container.decode(String.self, forKey: .utType)
        size = try container.decode(Int64.self, forKey: .size)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        plaintextSHA256 = try container.decode(String.self, forKey: .plaintextSHA256)
        companionID = try container.decodeIfPresent(UUID.self, forKey: .companionID)
        hasThumbnail = try container.decodeIfPresent(Bool.self, forKey: .hasThumbnail) ?? false
        openCount = try container.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        favoriteOrder = try container.decodeIfPresent(Int.self, forKey: .favoriteOrder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(originalName, forKey: .originalName)
        try container.encode(type, forKey: .type)
        try container.encode(utType, forKey: .utType)
        try container.encode(size, forKey: .size)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(plaintextSHA256, forKey: .plaintextSHA256)
        try container.encodeIfPresent(companionID, forKey: .companionID)
        try container.encode(hasThumbnail, forKey: .hasThumbnail)
        try container.encode(openCount, forKey: .openCount)
        try container.encodeIfPresent(lastOpened, forKey: .lastOpened)
        try container.encodeIfPresent(favoriteOrder, forKey: .favoriteOrder)
    }
}

struct VaultFolder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Salted hash of an extra folder passcode. Nil means the folder opens with the vault.
    var passcodeSalt: Data? = nil
    var passcodeHash: Data? = nil

    var hasPasscode: Bool { passcodeHash != nil }

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, passcodeSalt: Data? = nil, passcodeHash: Data? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.passcodeSalt = passcodeSalt
        self.passcodeHash = passcodeHash
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, passcodeSalt, passcodeHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        passcodeSalt = try container.decodeIfPresent(Data.self, forKey: .passcodeSalt)
        passcodeHash = try container.decodeIfPresent(Data.self, forKey: .passcodeHash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(passcodeSalt, forKey: .passcodeSalt)
        try container.encodeIfPresent(passcodeHash, forKey: .passcodeHash)
    }
}

struct VaultTrashEntry: Codable, Equatable, Sendable {
    var id: UUID
    var deletedAt: Date
}

struct VaultLibrarySnapshot: Codable, Equatable, Sendable {
    var items: [VaultItem]
    var folders: [VaultFolder]
    var trash: [VaultTrashEntry]

    init(items: [VaultItem], folders: [VaultFolder], trash: [VaultTrashEntry] = []) {
        self.items = items
        self.folders = folders
        self.trash = trash
    }

    static let empty = VaultLibrarySnapshot(items: [], folders: [], trash: [])

    enum CodingKeys: String, CodingKey {
        case items, folders, trash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([VaultItem].self, forKey: .items)
        folders = try container.decode([VaultFolder].self, forKey: .folders)
        trash = try container.decodeIfPresent([VaultTrashEntry].self, forKey: .trash) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(folders, forKey: .folders)
        try container.encode(trash, forKey: .trash)
    }
}
