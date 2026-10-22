import Foundation
import SwiftData

/// A normal note stored by SwiftData. This model is never used for private vault notes.
@Model
final class Note {
    /// Public identifier. SwiftData also has `persistentModelID`; this UUID is the app's id.
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    /// Raw value of a color tag. Nil means no tag. Kept as a string so the model stays free of UI types.
    var colorTag: String? = nil
    /// Plain text used for search. The editor keeps this in step with the rich body.
    var plainText: String = ""
    var richContent: Data? = nil
    var deletedAt: Date? = nil
    var tags: [String] = []
    var drawingData: Data? = nil
    var folder: NoteFolder?
    @Relationship(deleteRule: .cascade, inverse: \NoteAttachment.note)
    var attachments: [NoteAttachment]? = []

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        colorTag: String? = nil,
        plainText: String = "",
        richContent: Data? = nil,
        deletedAt: Date? = nil,
        tags: [String] = [],
        drawingData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.colorTag = colorTag
        self.plainText = plainText
        self.richContent = richContent
        self.deletedAt = deletedAt
        self.tags = tags
        self.drawingData = drawingData
        self.folder = nil
        self.attachments = []
    }
}
