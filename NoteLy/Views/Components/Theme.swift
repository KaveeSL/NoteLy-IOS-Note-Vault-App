import SwiftUI
import UIKit

/// Notes yellow. Folder icons, dates, links, and buttons use this tint, the same role yellow has in Notes.
enum Theme {
    static let accent = Color.accentColor
    static let pinnedTint = Color.accentColor.opacity(0.12)
    static let selection = Color.accentColor.opacity(0.16)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    /// Private area only. The notes list stays yellow.
    static let vault = Color(red: 1, green: 0.231, blue: 0.188)
    /// White in light mode. Raised gray in dark mode, so a field stays visible on a black page.
    static let fieldFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)
        }
        return .systemBackground
    })
    static let fieldStroke = Color.primary.opacity(0.18)

    /// Black on the brighter dark-mode yellow. White on the darker light-mode yellow.
    static func onAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }
}

/// List rows keep the colors on their labels. The default list button paints the whole row in the tint.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

enum VaultCopy {
    static let homeTitle = "Hidden Folders"
}

/// A solid white text box. Phrase and other typed fields use this instead of liquid glass.
struct PlainTextBox: View {
    var title: String
    @Binding var text: String
    var secure: Bool = true
    var identifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Color(.secondaryLabel))
            protectedField
                .tint(Theme.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.none)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(Theme.fieldFill, in: Capsule())
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    private var field: some View {
        if secure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }

    @ViewBuilder
    private var protectedField: some View {
        #if DEBUG
        if UITestHooks.showFilledPhrase || UITestHooks.showOnboardingPhrase {
            field
        } else {
            field.privacySensitive()
        }
        #else
        field.privacySensitive()
        #endif
    }
}

struct PhraseStrengthMeter: View {
    var phrase: String

    var body: some View {
        let strength = PhraseValidator.strength(phrase)
        let level = strength == .strong ? 3 : (strength == .ok ? 2 : 1)
        VStack(alignment: .leading, spacing: 6) {
            Text(phrase.isEmpty ? "8 or more characters" : "Strength: \(strength.rawValue)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { mark in
                    Capsule()
                        .fill(phrase.isEmpty ? Color.secondary.opacity(0.2) : (mark < level ? Theme.accent : Color.secondary.opacity(0.2)))
                        .frame(height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phrase.isEmpty ? "Use 8 or more characters" : "Strength \(strength.rawValue)")
    }
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
