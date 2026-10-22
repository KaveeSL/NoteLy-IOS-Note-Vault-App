import SwiftUI

/// Notes yellow. Folder icons, dates, links, and buttons use this tint, the same role yellow has in Notes.
enum Theme {
    static let accent = Color.accentColor
    static let pinnedTint = Color.accentColor.opacity(0.12)
    static let selection = Color.accentColor.opacity(0.16)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    /// Private area only. The notes list stays yellow.
    static let vault = Color(red: 1, green: 0.231, blue: 0.188)
}

enum VaultCopy {
    static let homeTitle = "Hidden Folders"
}

extension View {
    /// Liquid Glass on iOS 26 and later. Earlier systems use the system material.
    /// Use this on floating controls only, never stacked, and never behind long text.
    @ViewBuilder
    func notesGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Main action. Red tint comes from the caller. Glass on iOS 26, bordered before that.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary floating action.
    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Groups floating glass controls on iOS 26. Older systems keep the same layout.
    @ViewBuilder
    func glassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content()
            }
        } else {
            content()
        }
    }
}
