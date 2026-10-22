import SwiftUI
import UIKit

struct NoteRowView: View {
    let note: Note
    var query: String = ""
    var locked = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(highlighted(displayTitle))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Pinned")
                    }
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Locked")
                    }
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Text(locked ? "This note is locked" : subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !locked, let attachment = note.attachments?.first, let data = attachment.thumbnail ?? attachment.payload, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayTitle: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    private var subtitle: String {
        let text = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "No additional text" : line
    }

    private var dateText: String {
        let date = note.updatedAt
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var accessibilityLabel: String {
        var parts = [displayTitle, dateText]
        if note.isPinned { parts.append("pinned") }
        if locked { parts.append("locked") }
        if !locked, !note.body.isEmpty { parts.append(note.body) }
        return parts.joined(separator: ", ")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = result.range(of: needle, options: .caseInsensitive) else { return result }
        result[range].backgroundColor = Theme.pinnedTint
        return result
    }
}
