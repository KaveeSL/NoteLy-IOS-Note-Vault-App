import SwiftUI
import UIKit

enum OnboardingMode {
    case firstLaunch
    case replay
    case redo
}

/// A short first open. Four steps, yellow, and glass only on the controls.
struct GuidedOnboardingView: View {
    var mode: OnboardingMode = .firstLaunch

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index = 0
    @State private var phrase = ""
    @State private var phraseConfirm = ""
    @State private var showPhrase = false
    @State private var passcode = ""
    @State private var passcodeConfirm = ""
    @State private var editingConfirm = false
    @State private var faceID = false
    @State private var inlineError: String?
    @State private var working = false

    private var flow: [OnboardingStep] {
        if mode == .replay { return [.welcome] }
        if mode == .redo { return [.welcome, .phrase, .passcode, .faceID] }
        return [.welcome, .phrase, .passcode, .faceID]
    }

    private var current: OnboardingStep {
        flow[min(index, flow.count - 1)]
    }

    var body: some View {
        content
            .padding(.horizontal, current == .welcome ? 0 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
            }
            .background(Color(.systemBackground))
            .tint(Theme.accent)
        .onAppear(perform: restore)
        .onChange(of: index) { _, _ in
            inlineError = nil
            let secret = current == .phrase || current == .passcode
            appState.hidingSecrets = secret && mode != .replay
            if mode == .firstLaunch {
                appState.saveOnboardingStep(current.rawValue)
            }
            UIAccessibility.post(notification: .announcement, argument: "Step \(index + 1) of \(flow.count). \(current.title)")
        }
        .onDisappear { appState.hidingSecrets = false }
    }

    @ViewBuilder
    private var content: some View {
        if current == .welcome {
            welcome
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                Group {
                    switch current {
                    case .phrase: phraseStep
                    case .passcode: passcodeStep
                    case .faceID: faceStep
                    default: phraseStep
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                continueForward()
            } label: {
                Text(continueTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: current == .welcome ? 52 : nil)
            }
            .modifier(WelcomeGlass(yellow: current == .welcome))
            .buttonBorderShape(.capsule)
            .controlSize(current == .welcome ? .extraLarge : .large)
            .frame(maxWidth: .infinity)
            .opacity((!canContinue || working) ? 0.4 : 1)
            .disabled(!canContinue || working)
            .accessibilityHint(index == flow.count - 1 ? "Finishes setup" : "Goes to the next step")
            .accessibilityIdentifier("onboarding.continue")
            if index > 0 {
                Button("Back", action: goBack)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityHint("Returns to the previous step")
                    .accessibilityIdentifier("onboarding.back")
            }
            if let inlineError {
                Text(inlineError)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 8)
    }

    private var continueTitle: String {
        if mode == .replay { return "Done" }
        if index == flow.count - 1 {
            return mode == .redo ? "Save" : "Start using the app"
        }
        if index == 0 { return "Get Started" }
        return "Continue"
    }

    private var canContinue: Bool {
        if mode == .replay { return true }
        switch current {
        case .welcome, .faceID: return true
        case .phrase: return phraseReady
        case .passcode: return passcodeReady
        default: return true
        }
    }

    private var phraseReady: Bool {
        if case .invalid = PhraseValidator.validate(phrase) { return false }
        return PhraseValidator.normalize(phrase) == PhraseValidator.normalize(phraseConfirm) && !phraseConfirm.isEmpty
    }

    private var passcodeReady: Bool {
        PasscodeRules.issue(for: passcode, style: .pin6, phrase: phrase) == nil
            && passcode == passcodeConfirm
            && passcodeConfirm.count == 6
    }

    private func restore() {
        faceID = appState.biometricsAvailable()
        let saved = appState.onboardingStore.load().step
        if mode == .firstLaunch, let match = flow.firstIndex(where: { $0.rawValue == saved }) {
            index = match
        } else {
            index = 0
        }
    }

    private func continueForward() {
        if mode == .replay {
            dismiss()
            return
        }
        if index >= flow.count - 1 {
            Task { await finish() }
            return
        }
        advance()
    }

    private func advance() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)) {
            index = min(index + 1, flow.count - 1)
        }
    }

    private func goBack() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)) {
            if current == .passcode { editingConfirm = false }
            index = max(index - 1, 0)
        }
    }

    private func finish() async {
        working = true
        defer { working = false }
        let problem = await appState.commitGuidedVault(
            phrase: phrase,
            confirmation: phraseConfirm,
            passcode: passcode,
            style: .pin6,
            faceID: faceID,
            backup: false,
            recoveryWords: nil,
            replacingExisting: mode == .redo
        )
        if let problem {
            inlineError = problem
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        phrase = ""
        phraseConfirm = ""
        passcode = ""
        passcodeConfirm = ""
        if mode == .firstLaunch {
            appState.completeOnboarding()
        } else {
            dismiss()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            welcomeHero
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome to NoteLy")
                    .font(.system(size: 34, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Image(systemName: "folder.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 20)
                    .accessibilityHidden(true)
                Text("Notes stay on this iPhone. Search a secret phrase to open a hidden space, then set a code. Face ID is optional.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    private var welcomeHero: some View {
        Color.clear
            .overlay {
                Image("WelcomeHero")
                    .resizable()
                    .scaledToFill()
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.74),
                        .init(color: .black.opacity(0.82), location: 0.84),
                        .init(color: .black.opacity(0.4), location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .accessibilityHidden(true)
    }

    private var phraseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupMark("magnifyingglass")
            Text("Your phrase")
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("You'll type this in Search later. Pick something you would never search for a note.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            phraseField("Phrase", text: $phrase, identifier: "onboarding.phrase")
            phraseField("Type it again", text: $phraseConfirm, identifier: "onboarding.phraseConfirm")
            Toggle("Show phrase", isOn: $showPhrase)
                .font(.body)
                .padding(.trailing, 4)
                .frame(minHeight: 44)
            strengthMeter
            if let problem = phraseProblem {
                Text(problem)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .privacySensitive()
    }

    private func setupMark(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    private var phraseProblem: String? {
        if phrase.isEmpty { return nil }
        if case .invalid(let reason) = PhraseValidator.validate(phrase) { return reason }
        if !phraseConfirm.isEmpty, PhraseValidator.normalize(phrase) != PhraseValidator.normalize(phraseConfirm) {
            return "Those phrases don't match."
        }
        return nil
    }

    private var strengthMeter: some View {
        let strength = PhraseValidator.strength(phrase)
        let level = strength == .strong ? 3 : (strength == .ok ? 2 : 1)
        return VStack(alignment: .leading, spacing: 6) {
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

    private var passcodeStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 28)
                .accessibilityHidden(true)
            Text(editingConfirm ? "Type it again" : "Choose a 6-digit code")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .accessibilityAddTraits(.isHeader)
            Text(editingConfirm
                 ? "Enter the same six digits to confirm."
                 : "Type six digits for the hidden space. You'll enter them once more to confirm.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 8)
            HStack(spacing: 18) {
                ForEach(0..<6, id: \.self) { mark in
                    Circle()
                        .fill(mark < activePasscode.count ? Color.primary : Color.clear)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: mark < activePasscode.count ? 0 : 1.5))
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.top, 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(activePasscode.count) of 6 digits")
            digitPad
                .padding(.top, 36)
            if let problem = passcodeProblem {
                Text(problem)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var passcodeProblem: String? {
        let value = activePasscode
        guard value.count == 6 else { return nil }
        if let issue = PasscodeRules.issue(for: value, style: .pin6, phrase: phrase) { return issue }
        if editingConfirm, passcode != passcodeConfirm { return "Those codes don't match." }
        return nil
    }

    private var activePasscode: String { editingConfirm ? passcodeConfirm : passcode }

    private var digitPad: some View {
        glassGroup {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(1...9, id: \.self) { number in
                    digit("\(number)")
                }
                Button(action: clearDigits) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 72, height: 72)
                        .notesGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                digit("0")
                Button(action: deleteDigit) {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .frame(width: 72, height: 72)
                        .notesGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
    }

    private func digit(_ label: String) -> some View {
        Button {
            guard activePasscode.count < 6 else { return }
            let next = activePasscode + label
            setActive(next)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if !editingConfirm, next.count == 6, PasscodeRules.issue(for: next, style: .pin6, phrase: phrase) == nil {
                editingConfirm = true
            }
        } label: {
            Text(label)
                .font(.title2.weight(.medium))
                .frame(width: 72, height: 72)
                .notesGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func clearDigits() {
        if editingConfirm {
            passcodeConfirm = ""
        } else {
            passcode = ""
        }
    }

    private func deleteDigit() {
        if editingConfirm {
            if passcodeConfirm.isEmpty {
                editingConfirm = false
            } else {
                passcodeConfirm.removeLast()
            }
        } else if !passcode.isEmpty {
            passcode.removeLast()
        }
    }

    private func setActive(_ value: String) {
        if editingConfirm {
            passcodeConfirm = value
        } else {
            passcode = value
        }
    }

    private var faceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupMark("faceid")
            Text("Face ID")
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(appState.biometricsAvailable()
                 ? "Optional. Your code still opens the hidden space."
                 : "Face ID isn't available here. Your code is enough.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appState.biometricsAvailable() {
                Toggle("Use Face ID", isOn: $faceID)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.trailing, 8)
                    .frame(minHeight: 50)
                    .notesGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func phraseField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        Group {
            if showPhrase {
                TextField(title, text: text)
            } else {
                SecureField(title, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.none)
        .privacySensitive()
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .notesGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier(identifier)
    }
}

/// Yellow liquid glass on the welcome button. Later setup buttons stay clear glass.
private struct WelcomeGlass: ViewModifier {
    var yellow: Bool

    func body(content: Content) -> some View {
        if yellow {
            content.prominentGlassButton()
        } else {
            content.secondaryGlassButton()
        }
    }
}

struct PermissionPrimer: View {
    var symbol: String
    var title: String
    var message: String
    var confirmTitle: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(Theme.vault)
                .accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(confirmTitle, action: onConfirm)
                .prominentGlassButton()
                .tint(Theme.vault)
                .frame(maxWidth: .infinity, minHeight: 44)
            Button("Not now", action: onCancel)
                .secondaryGlassButton()
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

extension OnboardingStep: Identifiable {
    var id: Int { rawValue }
}
