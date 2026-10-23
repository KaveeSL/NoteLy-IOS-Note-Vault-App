import SwiftUI

/// Honest setup for the private vault. Shown during onboarding and again from Settings.
/// The system prompt still says "Unlock your notes" and does not add a second, more specific reason.
struct VaultSetupView: View {
    var allowsSkip: Bool
    var onSkip: () -> Void
    var onCompleted: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var phrase = ""
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Private Vault")
                        .font(.largeTitle.bold())
                    Text("A second set of notes, encrypted on this device. It does not show up in your notes list. You open it by typing a secret phrase into Search and pressing Return, then confirming with Face ID or your device passcode.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    labeledField(title: "Secret phrase", text: $phrase, identifier: "vault.phrase")
                    labeledField(title: "Confirm phrase", text: $confirmation, identifier: "vault.phraseConfirm")
                    Text("At least \(SecurityConstants.minPhraseLength) characters. Spaces at the ends are ignored, and capital letters don't matter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Strength: \(PhraseValidator.strength(phrase).rawValue)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Strength \(PhraseValidator.strength(phrase).rawValue)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    warning("If you forget this phrase, private notes cannot be recovered. There is no reset and no Apple ID recovery.")
                    warning("Changing Face ID later can turn off the biometric path. Your device passcode is the fallback. Export an encrypted backup from the private area before you change Face ID or move phones. The vault does not copy to a new device by itself.")
                    if let footnote = appState.settings.biometryFootnote() {
                        Text(footnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }

                Button {
                    Task { await enable() }
                } label: {
                    Group {
                        if appState.settings.isWorking {
                            ProgressView()
                        } else {
                            Text("Enable Private Vault")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!appState.settings.canOfferVaultSetup() || appState.settings.isWorking)
                .accessibilityIdentifier("vault.enable")

                if allowsSkip {
                    Button("Skip for now", action: onSkip)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.skipVault")
                }
            }
            .padding(24)
        }
        .navigationTitle("Private Vault")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private func labeledField(title: String, text: Binding<String>, identifier: String) -> some View {
        PlainTextBox(title: title, text: text, identifier: identifier)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func enable() async {
        message = nil
        let result = await appState.settings.setupVault(phrase: phrase, confirmation: confirmation)
        if let result {
            message = result
            return
        }
        if appState.phrases.isVaultConfigured() {
            phrase = ""
            confirmation = ""
            onCompleted()
        }
    }
}
