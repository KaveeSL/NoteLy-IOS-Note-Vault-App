import SwiftData
import SwiftUI
import UIKit

/// Portrait for the whole app. A photo or video viewer asks for landscape while it is open.
enum AppOrientation {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func apply(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.windows.forEach { window in
            refreshOrientations(window.rootViewController)
        }
    }

    private static func refreshOrientations(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        refreshOrientations(controller.presentedViewController)
    }
}

final class NoteLyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

@main
struct NoteLyApp: App {
    @UIApplicationDelegateAdaptor(NoteLyAppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let container: ModelContainer?

    init() {
        VaultFileStore.purgeTemporaryFiles()
        _appState = StateObject(wrappedValue: AppState.live())
        container = Self.openContainer()
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootView()
                    .environmentObject(appState)
                    .modelContainer(container)
            } else {
                StorageErrorView()
            }
        }
    }
}

extension NoteLyApp {
    /// Opens the notes database. If an older schema is already on disk, it is removed once and created again.
    /// This app has not shipped a migration, so a schema change would otherwise leave the notes list closed.
    private static func openContainer() -> ModelContainer? {
        do {
            return try ModelContainer(for: Note.self, NoteFolder.self, NoteAttachment.self)
        } catch {
            VaultLog.security.error("Notes database could not be opened")
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let support, let urls = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) {
                for url in urls where url.lastPathComponent.contains("default.store") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            return try? ModelContainer(for: Note.self, NoteFolder.self, NoteAttachment.self)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if DEBUG
            if UITestHooks.openVault {
                VaultHomeView(model: appState.vaultViewModel, files: appState.vaultFiles)
                    .tint(Theme.vault)
            } else if appState.hasCompletedOnboarding {
                NotesListView(viewModel: appState.notesListViewModel)
            } else {
                OnboardingView()
            }
            #else
            if appState.hasCompletedOnboarding {
                NotesListView(viewModel: appState.notesListViewModel)
            } else {
                OnboardingView()
            }
            #endif
        }
        .fullScreenCover(isPresented: $appState.isVaultPresented, onDismiss: {
            appState.lock()
        }) {
            VaultHomeView(model: appState.vaultViewModel, files: appState.vaultFiles)
                .environmentObject(appState)
                .tint(Theme.vault)
        }
        .overlay {
            if appState.showPasscode {
                VaultPasscodePad()
                    .environmentObject(appState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if appState.reauthPasscode {
                ReauthPad()
                    .environmentObject(appState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: appState.showPasscode)
        .onChange(of: scenePhase) { _, phase in
            appState.sceneChanged(to: phase)
        }
        .tint(Theme.accent)
        .onAppear {
            appState.refreshCaptureState()
        }
        .task {
            await appState.adoptReplacementPhraseIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            appState.screenshotTaken()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            appState.refreshCaptureState()
        }
    }
}

struct ReauthPad: View {
    @EnvironmentObject private var appState: AppState
    @State private var digits = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Confirm it's you")
                    .font(.title3.weight(.semibold))
                Text("Enter your 6-digit code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if appState.passcodeStyle == .mixed {
                    SecureField("Vault passcode", text: $digits)
                        .privacySensitive()
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { appState.submitReauth(digits) }
                    Button("Continue") { appState.submitReauth(digits) }
                        .frame(minHeight: 44)
                } else {
                    HStack(spacing: 12) {
                        ForEach(0..<appState.passcodeLength, id: \.self) { index in
                            Circle()
                                .fill(index < digits.count ? Theme.vault : Color.secondary.opacity(0.25))
                                .frame(width: 12, height: 12)
                        }
                    }
                }
                if !appState.reauthMessage.isEmpty {
                    Text(appState.reauthMessage).font(.footnote).foregroundStyle(Theme.vault)
                }
                if appState.passcodeStyle != .mixed {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(1...9, id: \.self) { number in key("\(number)") }
                    Color.clear.frame(height: 64)
                    key("0")
                    Button {
                        if !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left").frame(width: 72, height: 64)
                    }
                    .accessibilityLabel("Delete")
                }
                .frame(maxWidth: 280)
                }
                Button("Cancel") { appState.cancelReauth() }
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .notesGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 24)
        }
        .tint(Theme.vault)
    }

    private func key(_ label: String) -> some View {
        Button {
            guard digits.count < appState.passcodeLength else { return }
            digits.append(label)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if digits.count == appState.passcodeLength {
                appState.submitReauth(digits)
                if appState.reauthPasscode { digits = "" }
            }
        } label: {
            Text(label).font(.title2).frame(width: 72, height: 64).notesGlass(in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct VaultPasscodePad: View {
    @EnvironmentObject private var appState: AppState
    @State private var digits = ""
    @State private var first = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 22) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if appState.passcodeStyle == .mixed {
                    SecureField("Vault passcode", text: $digits)
                        .textContentType(.password)
                        .privacySensitive()
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { commit() }
                    Button("Continue") { commit() }
                        .frame(minHeight: 44)
                } else {
                    HStack(spacing: 14) {
                        ForEach(0..<appState.passcodeLength, id: \.self) { index in
                            Circle()
                                .fill(index < digits.count ? Theme.vault : Color.secondary.opacity(0.25))
                                .frame(width: 12, height: 12)
                        }
                    }
                }
                if !appState.passcodeMessage.isEmpty {
                    Text(appState.passcodeMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if appState.passcodeStyle != .mixed {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                        ForEach(1...9, id: \.self) { number in
                            key("\(number)")
                        }
                        Color.clear.frame(height: 64)
                        key("0")
                        Button {
                            if !digits.isEmpty { digits.removeLast() }
                        } label: {
                            Image(systemName: "delete.left")
                                .frame(width: 72, height: 64)
                        }
                        .accessibilityLabel("Delete")
                    }
                    .frame(maxWidth: 280)
                }
                Button("Cancel") { appState.cancelPasscode() }
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .notesGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 24)
        }
        .tint(Theme.vault)
    }

    private var title: String {
        switch appState.passcodeStep {
        case .enter: return "Enter Passcode"
        case .create: return first.isEmpty ? "Create Passcode" : "Confirm Passcode"
        case .change: return "Change Passcode"
        }
    }

    private var subtitle: String {
        switch appState.passcodeStep {
        case .enter: return "Enter your 6-digit code."
        case .create: return "Choose 6 digits. You can change them later."
        case .change: return "Enter 6 digits."
        }
    }

    private func key(_ label: String) -> some View {
        Button {
            guard digits.count < appState.passcodeLength else { return }
            digits.append(label)
            if digits.count == appState.passcodeLength { commit() }
        } label: {
            Text(label)
                .font(.title2)
                .frame(width: 72, height: 64)
                .notesGlass(in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let entered = digits
        switch appState.passcodeStep {
        case .enter:
            appState.submitPasscode(entered)
            if appState.showPasscode { digits = "" }
        case .create:
            if first.isEmpty {
                first = entered
                digits = ""
            } else {
                appState.saveNewPasscode(first, confirm: entered)
                if appState.showPasscode {
                    first = ""
                    digits = ""
                }
            }
        case .change:
            break
        }
    }
}

struct StorageErrorView: View {
    var body: some View {
        ContentUnavailableView(
            "Notes couldn't be opened",
            systemImage: "exclamationmark.triangle",
            description: Text("NoteLy couldn't open its notes database. Restart the app and try again.")
        )
        .padding()
    }
}
