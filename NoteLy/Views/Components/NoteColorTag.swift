import SwiftUI

/// Color tags for public notes. Stored on `Note.colorTag` as the raw value.
enum NoteColorTag: String, CaseIterable, Identifiable {
    case yellow
    case green
    case blue
    case pink
    case purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }

    var color: Color {
        switch self {
        case .yellow: return Color(red: 0.93, green: 0.70, blue: 0.19)
        case .green: return Color(red: 0.22, green: 0.62, blue: 0.45)
        case .blue: return Color(red: 0.24, green: 0.48, blue: 0.86)
        case .pink: return Color(red: 0.86, green: 0.38, blue: 0.55)
        case .purple: return Color(red: 0.49, green: 0.38, blue: 0.78)
        }
    }

    static func resolve(_ raw: String?) -> NoteColorTag? {
        guard let raw else { return nil }
        return NoteColorTag(rawValue: raw)
    }
}
