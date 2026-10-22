import Foundation
import UniformTypeIdentifiers

enum InputValidators {
    static func folderName(_ raw: String, existing: [String]) -> ValidationResult<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .invalid("Enter a folder name.")
        }
        if trimmed.count > 50 {
            return .invalid("Use 50 characters or fewer.")
        }
        if raw != trimmed {
            return .invalid("Remove spaces at the start or end.")
        }
        let key = trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if existing.contains(where: { $0.lowercased(with: Locale(identifier: "en_US_POSIX")) == key }) {
            return .invalid("A folder with that name already exists here.")
        }
        return .valid(trimmed)
    }

    static func tag(_ raw: String) -> ValidationResult<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if body.isEmpty || body.count > 40 {
            return .invalid("Tags use 1 to 40 characters.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if body.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .invalid("Tags use letters, numbers, and underscore.")
        }
        return .valid(body.lowercased(with: Locale(identifier: "en_US_POSIX")))
    }

    static func noteTitle(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 { return trimmed }
        return String(trimmed.prefix(100))
    }

    static func noteIsEmpty(title: String, body: String, attachmentCount: Int, hasDrawing: Bool) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachmentCount == 0
            && !hasDrawing
    }

    static func withinNoteBudget(textBytes: Int, attachmentBytes: Int) -> Bool {
        textBytes + attachmentBytes <= 5 * 1024 * 1024
    }

    /// Drops path pieces and control characters. The original name is metadata only.
    static func sanitizedFilename(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let scalars = base.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != "\\" && scalar != ":"
        }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "File" }
        if name.count > 255 { name = String(name.prefix(255)) }
        return name
    }

    static func mediaType(filename: String, head: Data) -> (VaultMediaType, String) {
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return (.photo, UTType.jpeg.identifier) }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (.photo, UTType.png.identifier) }
        if head.starts(with: Data("GIF8".utf8)) { return (.photo, UTType.gif.identifier) }
        if head.starts(with: Data("%PDF".utf8)) { return (.pdf, UTType.pdf.identifier) }
        if head.count >= 12, head.subdata(in: 4..<8).elementsEqual(Data("ftyp".utf8)) {
            let brand = head.subdata(in: 8..<12)
            if brand.elementsEqual(Data("heic".utf8)) || brand.elementsEqual(Data("heix".utf8)) || brand.elementsEqual(Data("mif1".utf8)) {
                return (.photo, UTType.heic.identifier)
            }
            return (.video, UTType.mpeg4Movie.identifier)
        }
        let ext = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return (.photo, type.identifier) }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return (.video, type.identifier) }
            if type.conforms(to: .pdf) { return (.pdf, type.identifier) }
            if type.conforms(to: .audio) { return (.audio, type.identifier) }
            if type.conforms(to: .archive) || type.conforms(to: .zip) { return (.archive, type.identifier) }
            return (.other, type.identifier)
        }
        return (.other, UTType.data.identifier)
    }
}
