import SwiftUI

struct RowSlide: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var tint: Color
    var run: () -> Void
}

/// Folder swipe that stays inside the row. The system swipe squares the grouped corners, then rounds them again a moment later.
struct SlideRow<Content: View>: View {
    var rowID: UUID
    @Binding var openID: UUID?
    var leading: [RowSlide] = []
    var trailing: [RowSlide] = []
    var onTap: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var shift: CGFloat = 0
    @State private var origin: CGFloat = 0
    @State private var dragging = false

    private let buttonWidth: CGFloat = 72

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if shift > 8 {
                    ForEach(leading) { action in
                        actionButton(action)
                    }
                    Spacer(minLength: 0)
                }
                if shift < -8 {
                    Spacer(minLength: 0)
                    ForEach(trailing) { action in
                        actionButton(action)
                    }
                }
            }
            .padding(.horizontal, 10)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .contentShape(Rectangle())
                .onTapGesture {
                    if shift != 0 {
                        close()
                    } else {
                        onTap()
                    }
                }
                .simultaneousGesture(drag)
                .offset(x: shift)
        }
        .clipped()
        .onChange(of: openID) { _, id in
            if id != rowID, shift != 0 {
                withAnimation(.smooth(duration: 0.22)) {
                    shift = 0
                    origin = 0
                }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let width = value.translation.width
                let height = value.translation.height
                if !dragging {
                    guard abs(width) > abs(height) else { return }
                    dragging = true
                    origin = shift
                }
                let lead = CGFloat(leading.count) * buttonWidth
                let trail = CGFloat(trailing.count) * buttonWidth
                shift = min(max(origin + width, -trail), lead)
            }
            .onEnded { value in
                defer { dragging = false }
                guard dragging || abs(value.translation.width) > 16 else { return }
                let predicted = value.predictedEndTranslation.width
                withAnimation(.smooth(duration: 0.22)) {
                    if predicted < -36, !trailing.isEmpty {
                        shift = -CGFloat(trailing.count) * buttonWidth
                        origin = shift
                        openID = rowID
                    } else if predicted > 36, !leading.isEmpty {
                        shift = CGFloat(leading.count) * buttonWidth
                        origin = shift
                        openID = rowID
                    } else {
                        shift = 0
                        origin = 0
                        if openID == rowID { openID = nil }
                    }
                }
            }
    }

    private func close() {
        withAnimation(.smooth(duration: 0.22)) {
            shift = 0
            origin = 0
            if openID == rowID { openID = nil }
        }
    }

    private func actionButton(_ action: RowSlide) -> some View {
        Button {
            close()
            action.run()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 52)
            .background(action.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }
}
