import SwiftUI
import UniformTypeIdentifiers

struct VaultSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var autoLock: AutoLockService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showingPhraseChange = false
    @State private var showingDecoy = false
    @State private var showingExport = false
    @State private var showingImportPassword = false
    @State private var showingDelete = false
    @State private var importingFile = false
    @State private var exportingFile = false
    @State private var exportDocument: VaultBackupDocument?
    @State private var importBytes = Data()
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var currentPhrase = ""
    @State private var newPhrase = ""
    @State private var phraseConfirm = ""
    @State private var sheetMessage: String?
    @State private var showingPasscode = false
    @State private var currentPasscode = ""
    @State private var nextPasscode = ""
    @State private var confirmPasscode = ""
    @State private var redoingSetup = false
    @State private var showingWelcome = false
    @State private var confirmStartOver = false

    private var isDecoy: Bool { appState.isDecoySession }

    private func startOver() async {
        let problem = await appState.startFresh(notes: modelContext)
        if let problem {
            settings.statusMessage = problem
        }
    }

    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { appState.faceIDEnabled },
            set: { enabled in Task { await appState.setFaceIDEnabled(enabled) } }
        )
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showingWelcome = true
                } label: {
                    Label("Welcome", systemImage: "hand.wave")
                }
                .accessibilityIdentifier("vault.welcome")
                Button {
                    redoingSetup = true
                } label: {
                    Label("Redo setup", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Welcome shows the introduction. Redo setup replaces the phrase and the code.")
            }

            if JailbreakChecker.hasSuspiciousEnvironment {
                Section {
                    Text("This device looks modified. Private notes are less protected on a modified device. Consider moving them with an encrypted backup and reviewing the device.")
                        .font(.subheadline)
                } header: {
                    Text("Device warning")
                }
            }

            Section {
                Picker("Lock when idle", selection: $autoLock.timeout) {
                    ForEach(AutoLockService.Timeout.allCases) { timeout in
                        Text(timeout.title).tag(timeout)
                    }
                }
                .accessibilityLabel("Lock when idle")
                Text("Never keeps this area open while NoteLy is on screen. It still locks when you leave the app or tap Lock now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Lock")
            }

            Section {
                Picker("Ask again for risky actions", selection: Binding(
                    get: { appState.reauth.policy },
                    set: { appState.reauth.policy = $0 }
                )) {
                    ForEach(ReauthPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                Text("Export, emptying Recently Deleted, permanent delete, and deleting a folder can skip the next ask during that window. Changing the passcode, Face ID, backup, or deleting everything always asks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Favorites", selection: Binding(
                    get: { appState.favoriteMode },
                    set: { appState.setFavoriteMode($0) }
                )) {
                    ForEach(FavoriteMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Button("Clear usage history") {
                    appState.vaultViewModel.clearUsage()
                    appState.vaultFiles.clearUsage()
                }
            } header: {
                Text("Favorites")
            } footer: {
                Text("Manual shows starred items. Most Used ranks what you keep open. Both puts stars first.")
            }

            Section {
                Toggle("Face ID", isOn: Binding(
                    get: { appState.faceIDEnabled },
                    set: { enabled in Task { await appState.setFaceIDEnabled(enabled) } }
                ))
                Button("Change passcode") {
                    Task {
                        if await appState.reauth.authorize(.changePasscode) != nil {
                            showingPasscode = true
                        }
                    }
                }
            } footer: {
                Text("Face ID opens this space. You can change the 6-digit code here.")
            }

            Section {
                Button("Change phrase") { showingPhraseChange = true }
            } footer: {
                Text("Face ID or your device passcode confirms the change. The notes stay encrypted with the same key. If you forget the new phrase, there is no recovery.")
            }

            if !isDecoy {
                Section {
                    if settings.isDecoyConfigured() {
                        Button("Remove second phrase", role: .destructive) {
                            do {
                                try settings.disableDecoy()
                            } catch {
                                settings.statusMessage = "That couldn't be removed."
                            }
                        }
                    } else {
                        Button("Set a second phrase") { showingDecoy = true }
                    }
                } header: {
                    Text("Second phrase")
                } footer: {
                    Text("A second phrase opens a separate set of ordinary sample notes. It does not open these notes, and it does not ask for Face ID. Use a phrase you will not mix up with this one.")
                }

                Section {
                    Toggle("Include encrypted files in device backup", isOn: Binding(
                        get: { settings.includeVaultInBackup },
                        set: { included in Task { await appState.updateBackupIncluded(included) } }
                    ))
                    Text("Encrypted notes and files are included in an iPhone backup when this is on. The key stays on this iPhone, so the Files app and a backup alone cannot open them. Export is the way to move them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Device backup")
                }

                Section {
                    Toggle("Erase after repeated failures", isOn: $settings.panicWipeEnabled)
                    Stepper(value: $settings.panicThreshold, in: 3...10) {
                        Text("After \(settings.panicThreshold) failed confirmations")
                    }
                    Text("When this is on, that many failed Face ID or passcode attempts in a row permanently delete the private notes. Cancelled prompts do not count. Nothing extra is shown when it happens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Panic erase")
                }
            }

            Section {
                Button("Export encrypted backup") {
                    Task {
                        if await appState.reauth.authorize(.export) != nil { beginExport() }
                    }
                }
                Button("Import encrypted backup") { importingFile = true }
            } header: {
                Text("Move notes")
            } footer: {
                Text("The backup password is separate from your secret phrase. It is case-sensitive. You will need it to import. Changing Face ID can remove the biometric unlock; export a backup first. These notes do not transfer with a new phone unless you import that file.")
            }

            Section {
                Button("Delete private notes", role: .destructive) {
                    Task {
                        if await appState.reauth.authorize(.deleteVault) != nil {
                            showingDelete = true
                        }
                    }
                }
            } footer: {
                Text("Deletion asks you to confirm it's you and to type the phrase. This cannot be undone.")
            }

            Section {
                Button("Clear all data and start over", role: .destructive) {
                    confirmStartOver = true
                }
                .accessibilityIdentifier("vault.startOver")
            } footer: {
                Text("Deletes every note, photo, phrase, and code. A confirmation appears, then Face ID. The app opens like a new install.")
            }

            Section("Advanced") {
                NavigationLink("Face ID Diagnostics") {
                    BiometricDiagnosticsView()
                }
            }

            if let status = settings.statusMessage {
                Section {
                    Text(status)
                        .font(.subheadline)
                }
            }
        }
        .confirmationDialog("Use the app as new?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Clear all data", role: .destructive) {
                Task { await startOver() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every note and the hidden space. Face ID confirms it. This cannot be undone.")
        }
        .sheet(isPresented: $showingWelcome) {
            GuidedOnboardingView(mode: .replay)
                .environmentObject(appState)
        }
        .sheet(isPresented: $redoingSetup) {
            GuidedOnboardingView(mode: .redo)
                .environmentObject(appState)
        }
        .navigationTitle("Private Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPasscode) {
            NavigationStack {
                Form {
                    SecureField("Current passcode", text: $currentPasscode)
                        .keyboardType(.numberPad)
                    SecureField("New passcode", text: $nextPasscode)
                        .keyboardType(.numberPad)
                    SecureField("Confirm new passcode", text: $confirmPasscode)
                        .keyboardType(.numberPad)
                    if let sheetMessage {
                        Text(sheetMessage).foregroundStyle(.red)
                    }
                }
                .navigationTitle("Change passcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingPasscode = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let message = appState.changeVaultPasscode(current: currentPasscode, newCode: nextPasscode, confirm: confirmPasscode) {
                                sheetMessage = message
                            } else {
                                showingPasscode = false
                                currentPasscode = ""
                                nextPasscode = ""
                                confirmPasscode = ""
                                sheetMessage = nil
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingPhraseChange) { phraseSheet(decoy: isDecoy) }
        .sheet(isPresented: $showingDecoy) { decoySheet }
        .sheet(isPresented: $showingExport) { exportSheet }
        .sheet(isPresented: $showingImportPassword) { importSheet }
        .sheet(isPresented: $showingDelete) { deleteSheet }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    importBytes = try Data(contentsOf: url)
                    password = ""
                    sheetMessage = nil
                    showingImportPassword = true
                } catch {
                    settings.statusMessage = "Couldn't read that file."
                }
            case .failure:
                settings.statusMessage = "Couldn't read that file."
            }
        }
        .fileExporter(
            isPresented: $exportingFile,
            document: exportDocument,
            contentType: .data,
            defaultFilename: "NoteLy-Private-Backup.nlvault"
        ) { result in
            exportDocument = nil
            if case .failure = result {
                settings.statusMessage = "The backup file was not saved."
            } else {
                settings.statusMessage = "Encrypted backup saved."
            }
        }
    }

    private func beginExport() {
        password = ""
        passwordConfirm = ""
        sheetMessage = nil
        showingExport = true
    }

    private func phraseSheet(decoy: Bool) -> some View {
        NavigationStack {
            Form {
                SecureField("New phrase", text: $newPhrase)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                SecureField("Confirm new phrase", text: $phraseConfirm)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                Text("Saving asks for Face ID or your device passcode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let sheetMessage {
                    Text(sheetMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Change phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPhraseChange = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await savePhrase(decoy: decoy) }
                    }
                    .disabled(settings.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var decoySheet: some View {
        NavigationStack {
            Form {
                SecureField("Second phrase", text: $newPhrase)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Confirm phrase", text: $phraseConfirm)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("This phrase must be different from the one that opens these notes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let sheetMessage {
                    Text(sheetMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Second phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingDecoy = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveDecoy() } }
                        .disabled(settings.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var exportSheet: some View {
        NavigationStack {
            Form {
                SecureField("Backup password", text: $password)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Confirm password", text: $passwordConfirm)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("At least 8 characters. Case-sensitive. This is not your search phrase, and it is not saved in the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let sheetMessage {
                    Text(sheetMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Export backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingExport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await exportNow() } }
                        .disabled(settings.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                SecureField("Backup password", text: $password)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let sheetMessage {
                    Text(sheetMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Import backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importBytes = Data()
                        showingImportPassword = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await importNow() } }
                        .disabled(settings.isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var deleteSheet: some View {
        NavigationStack {
            Form {
                SecureField("Secret phrase", text: $currentPhrase)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("This permanently deletes the notes in this area.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let sheetMessage {
                    Text(sheetMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Delete notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingDelete = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) { Task { await deleteNow() } }
                        .disabled(settings.isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func savePhrase(decoy: Bool) async {
        sheetMessage = await settings.changePhrase(
            newPhrase: newPhrase,
            confirmation: phraseConfirm,
            decoy: decoy
        )
        if sheetMessage == nil {
            clearPhraseFields()
            showingPhraseChange = false
        }
    }

    private func saveDecoy() async {
        sheetMessage = await settings.enableDecoy(phrase: newPhrase, confirmation: phraseConfirm)
        if sheetMessage == nil {
            clearPhraseFields()
            showingDecoy = false
        }
    }

    private func exportNow() async {
        guard password == passwordConfirm else {
            sheetMessage = "Those passwords don't match."
            return
        }
        do {
            let data = try await settings.exportBackup(password: password, decoy: isDecoy)
            exportDocument = VaultBackupDocument(data: data)
            password = ""
            passwordConfirm = ""
            showingExport = false
            exportingFile = true
        } catch {
            sheetMessage = settings.message(for: error)
        }
    }

    private func importNow() async {
        do {
            let count = try await settings.importBackup(data: importBytes, password: password, decoy: isDecoy)
            importBytes = Data()
            password = ""
            showingImportPassword = false
            settings.statusMessage = count == 1 ? "Imported 1 note." : "Imported \(count) notes."
            await appState.vaultViewModel.load()
        } catch {
            sheetMessage = settings.message(for: error)
        }
    }

    private func deleteNow() async {
        let decoy = isDecoy
        sheetMessage = await settings.deleteArea(typedPhrase: currentPhrase, decoy: decoy)
        if sheetMessage == nil {
            clearPhraseFields()
            showingDelete = false
            appState.lock()
        }
    }

    private func clearPhraseFields() {
        currentPhrase = ""
        newPhrase = ""
        phraseConfirm = ""
        sheetMessage = nil
    }
}

struct VaultBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw VaultError.importFailed
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
