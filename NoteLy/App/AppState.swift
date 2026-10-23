import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit

enum IdentityCheck {
    case allowed
    case cancelled
    case needCode
}

enum UnlockCodeAvailability {
    case ready
    case missing
    case coolingDown
}

/// Owns vault visibility, the in-memory key, and reactions to scene phase.
/// Public notes do not live here; SwiftData owns those.
@MainActor
final class AppState: ObservableObject {
    @Published var searchText = ""
    @Published var isVaultPresented = false
    @Published var isDecoySession = false
    @Published var isAuthenticating = false
    @Published var hasCompletedOnboarding: Bool
    @Published var isScreenCaptured = false
    @Published var showPasscode = false
    @Published var passcodeMessage = ""
    @Published var vaultRevealed = false
    @Published var isClosingVault = false
    @Published var faceIDEnabled: Bool
    @Published var systemUIActive = false
    @Published var reauthMessage = ""
    @Published var reauthPasscode = false
    @Published var favoriteMode: FavoriteMode
    @Published var hidingSecrets = false
    @Published var passcodeStyle: VaultPasscodeStyle = .pin6
    let onboardingStore: OnboardingStore
    /// Bumped when vault setup or erase changes what Settings should show.
    @Published private(set) var configurationRevision = 0

    let crypto: CryptoServicing
    let keychain: KeychainServicing
    let phrases: SecretPhraseServicing
    let biometric: BiometricAuthenticating
    let vaultStore: VaultStoring
    let decoyStore: VaultStoring
    let autoLock: AutoLockService
    let notesListViewModel: NotesListViewModel
    let vaultViewModel: VaultViewModel
    let vaultFiles: VaultFilesViewModel
    let settings: SettingsViewModel
    let session: VaultSession
    let reauth: ReauthService

    private let attemptLimiter: AttemptLimiter
    private let defaults: UserDefaults
    private let passcodes: VaultPasscodeService
    private var pendingKey: Data?
    enum PasscodeStep {
        case enter
        case create
        case change
    }
    @Published var passcodeStep: PasscodeStep = .enter
    private var scenePhase: ScenePhase = .active
    /// Bumped on lock so an in-flight Face ID success cannot open the vault afterward.
    private var unlockGeneration = 0
    private var reauthContinuation: CheckedContinuation<Bool, Never>?
    private var revealTask: Task<Void, Never>?

    init(
        crypto: CryptoServicing,
        keychain: KeychainServicing,
        phrases: SecretPhraseServicing,
        biometric: BiometricAuthenticating,
        vaultStore: VaultStoring,
        decoyStore: VaultStoring,
        backup: VaultBackupServicing,
        autoLock: AutoLockService,
        attemptLimiter: AttemptLimiter,
        defaults: UserDefaults,
        notesListViewModel: NotesListViewModel? = nil
    ) {
        self.crypto = crypto
        self.keychain = keychain
        self.phrases = phrases
        self.biometric = biometric
        self.vaultStore = vaultStore
        self.decoyStore = decoyStore
        self.autoLock = autoLock
        self.attemptLimiter = attemptLimiter
        self.defaults = defaults
        let passcodeService = VaultPasscodeService(keychain: keychain, crypto: crypto)
        self.passcodes = passcodeService
        self.onboardingStore = OnboardingStore(keychain: keychain)
        self.passcodeStyle = passcodeService.currentStyle()
        if defaults.object(forKey: PreferenceKey.faceIDEnabled) == nil {
            defaults.set(true, forKey: PreferenceKey.faceIDEnabled)
        }
        self.faceIDEnabled = defaults.bool(forKey: PreferenceKey.faceIDEnabled)
        self.favoriteMode = FavoriteMode(rawValue: defaults.string(forKey: PreferenceKey.favoriteMode) ?? "") ?? .both
        let reauth = ReauthService(defaults: defaults)
        self.reauth = reauth
        self.notesListViewModel = notesListViewModel ?? NotesListViewModel()
        let session = VaultSession()
        self.session = session
        self.vaultViewModel = VaultViewModel(
            vaultStore: vaultStore,
            decoyStore: decoyStore,
            session: session
        )
        let fileStore = VaultFileStore(directory: VaultFileStore.defaultDirectory(), crypto: crypto)
        fileStore.risks = reauth.ledger
        let files = VaultFilesViewModel(store: fileStore, crypto: crypto, session: session)
        files.reauth = reauth
        files.risks = reauth.ledger
        self.vaultFiles = files
        vaultViewModel.reauth = reauth
        vaultViewModel.risks = reauth.ledger
        self.settings = SettingsViewModel(
            phrases: phrases,
            biometric: biometric,
            keychain: keychain,
            crypto: crypto,
            vaultStore: vaultStore,
            decoyStore: decoyStore,
            backup: backup,
            session: session,
            defaults: defaults
        )
        var record = self.onboardingStore.load()
        #if DEBUG
        if UITestHooks.resetOnboarding {
            record = .empty
            self.onboardingStore.save(record)
            defaults.set(false, forKey: PreferenceKey.onboardingComplete)
        } else if UITestHooks.skipOnboarding {
            record.completed = true
        }
        #endif
        self.hasCompletedOnboarding = record.completed || record.dismissedForever
        autoLock.onLock = { [weak self] in
            self?.lock()
        }
        reauth.prompter = { [weak self] action in
            await self?.promptReauth(action) ?? false
        }
        let optedIn = defaults.bool(forKey: PreferenceKey.backupOptIn)
        try? vaultStore.setExcludedFromBackup(!optedIn)
        try? decoyStore.setExcludedFromBackup(!optedIn)
        try? fileStore.applyBackupExclusion(!optedIn)
        #if DEBUG
        prepareUITests()
        #endif
    }

    static func live(defaults: UserDefaults = .standard) -> AppState {
        let crypto = CryptoService()
        let keychain = KeychainService()
        let phrases = SecretPhraseService(keychain: keychain, crypto: crypto)
        let vaultStore = VaultStore(directory: VaultStore.defaultDirectory(subfolder: "Vault"), crypto: crypto)
        let decoyStore = VaultStore(directory: VaultStore.defaultDirectory(subfolder: "Decoy"), crypto: crypto)
        let backup = VaultBackupService(crypto: crypto)
        return AppState(
            crypto: crypto,
            keychain: keychain,
            phrases: phrases,
            biometric: makeBiometric(),
            vaultStore: vaultStore,
            decoyStore: decoyStore,
            backup: backup,
            autoLock: AutoLockService(defaults: defaults),
            attemptLimiter: AttemptLimiter(recording: KeychainAttemptStore(keychain: keychain)),
            defaults: defaults
        )
    }

    func completeOnboarding() {
        var record = onboardingStore.load()
        record.completed = true
        record.step = OnboardingStep.summary.rawValue
        onboardingStore.save(record)
        hasCompletedOnboarding = true
        defaults.set(true, forKey: PreferenceKey.onboardingComplete)
        hidingSecrets = false
    }

    func saveOnboardingStep(_ step: Int) {
        var record = onboardingStore.load()
        guard record.showsSetupAgain else { return }
        record.step = step
        onboardingStore.save(record)
    }

    func deferOnboarding() {
        hidingSecrets = false
        hasCompletedOnboarding = true
    }

    func dismissOnboardingForever() {
        var record = onboardingStore.load()
        record.dismissedForever = true
        onboardingStore.save(record)
        hidingSecrets = false
        hasCompletedOnboarding = true
    }

    var passcodeLength: Int { passcodeStyle.digitCount ?? 6 }

    func vaultAlreadyConfigured() -> Bool {
        phrases.isVaultConfigured()
    }

    func biometricsAvailable() -> Bool {
        biometric.biometricsAvailable()
    }

    func testFaceID() async -> Bool {
        setSystemUI(true)
        let outcome = await biometric.authenticateBiometrics(reason: UnlockPrompt.reason)
        setSystemUI(false)
        if case .success = outcome { return true }
        return false
    }

    func needsPermissionExplanation(_ kind: PermissionKind) -> Bool {
        let record = onboardingStore.load()
        switch kind {
        case .photos: return !record.photosExplained
        case .camera: return !record.cameraExplained
        case .microphone: return !record.microphoneExplained
        case .faceID: return false
        }
    }

    func markPermissionExplained(_ kind: PermissionKind) {
        var record = onboardingStore.load()
        switch kind {
        case .photos: record.photosExplained = true
        case .camera: record.cameraExplained = true
        case .microphone: record.microphoneExplained = true
        case .faceID: break
        }
        onboardingStore.save(record)
    }

    func commitGuidedVault(
        phrase: String,
        confirmation: String,
        passcode: String,
        style: VaultPasscodeStyle,
        faceID: Bool,
        backup: Bool,
        recoveryWords: [String]?,
        replacingExisting: Bool
    ) async -> String? {
        if case .invalid(let reason) = PhraseValidator.validate(phrase) { return reason }
        if PhraseValidator.normalize(phrase) != PhraseValidator.normalize(confirmation) {
            return "Those phrases don't match."
        }
        if let issue = PasscodeRules.issue(for: passcode, style: style, phrase: phrase) { return issue }
        let keepExistingKey = replacingExisting || phrases.isVaultConfigured()
        let keyData: Data
        if let existing = session.key {
            keyData = crypto.keyData(existing)
        } else if keepExistingKey {
            let stored = try? keychain.data(for: KeychainAccount.vaultKey)
            guard let stored else {
                return "Your hidden notes are already on this iPhone. The phrase and code were left as they are."
            }
            keyData = stored
        } else {
            keyData = crypto.keyData(crypto.generateKey())
        }
        do {
            try passcodes.save(passcode: passcode, keyData: keyData, style: style)
            passcodeStyle = style
            if let recoveryWords {
                try passcodes.saveRecovery(words: recoveryWords, keyData: keyData)
            }
            try await phrases.setVaultPhrase(phrase)
        } catch {
            VaultLog.security.error("Guided vault setup could not be saved")
            return "The private vault couldn't be saved. Try again."
        }
        if faceID, biometric.biometricsAvailable() {
            setSystemUI(true)
            let outcome = await biometric.authenticateBiometrics(reason: UnlockPrompt.reason)
            setSystemUI(false)
            if case .success(let context) = outcome {
                try? keychain.set(
                    keyData,
                    account: KeychainAccount.vaultKey,
                    protection: .biometryCurrentSetOrPasscode,
                    context: context
                )
                faceIDEnabled = true
            } else {
                faceIDEnabled = false
            }
        } else {
            faceIDEnabled = false
        }
        defaults.set(faceIDEnabled, forKey: PreferenceKey.faceIDEnabled)
        settings.includeVaultInBackup = backup
        configurationRevision += 1
        return nil
    }

    /// Replaces the saved phrase once. `unlock778` is a valid phrase, but it was never opening
    /// the private area, so this install switches to a phrase the owner can type and test.
    func adoptReplacementPhraseIfNeeded() async {
        #if DEBUG
        if UITestHooks.isEnabled { return }
        #endif
        let key = "notely.adoptedPhrase.paper-harbor"
        guard !defaults.bool(forKey: key) else { return }
        do {
            try await phrases.setVaultPhrase("paper-harbor")
            defaults.set(true, forKey: key)
        } catch {
            VaultLog.security.error("Phrase could not be updated")
        }
    }

    func registerActivity() {
        guard isVaultPresented else { return }
        autoLock.recordInteraction()
    }

    /// Runs only after the user submits the search field. A miss leaves the query in place
    /// and the list filters as usual. A hit clears the field before the system prompt.
    ///
    /// A search that is not the phrase is not an unlock attempt. Panic erase counts a wrong
    /// 6-digit code only. Typing ordinary words must not move that count.
    func handleSearchSubmit(_ typed: String? = nil) async {
        let direct = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let submitted = direct.isEmpty ? searchText : direct
        guard !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isAuthenticating, !attemptLimiter.isCoolingDown() else { return }
        searchText = submitted
        let match = await phrases.verify(submitted)
        switch match {
        case .none:
            return
        case .vault:
            await unlockVault()
        case .decoy:
            await unlockDecoy()
        }
    }

    func sceneChanged(to phase: ScenePhase) {
        scenePhase = phase
        if phase == .background {
            if reauthPasscode || reauthContinuation != nil {
                cancelReauth()
                lock()
            } else if !systemUIActive {
                lock()
            }
        }
        updateShield()
    }

    func setSystemUI(_ active: Bool) {
        systemUIActive = active
        if active {
            autoLock.disarm()
        } else if isVaultPresented {
            autoLock.arm()
        }
    }

    func refreshCaptureState() {
        isScreenCaptured = CaptureDetector.isCaptured
        updateShield()
    }

    /// iOS delivers this after the image is already captured. Locking still clears the private
    /// screen so a following capture does not keep showing it. Recording is covered by `isCaptured`.
    func screenshotTaken() {
        #if DEBUG
        if UITestHooks.isEnabled { return }
        #endif
        guard isVaultPresented || session.isOpen else { return }
        lock()
    }

    func lock() {
        unlockGeneration += 1
        showPasscode = false
        passcodeMessage = ""
        if reauthPasscode || reauthContinuation != nil {
            cancelReauth()
        }
        let shouldClose = isVaultPresented || session.isOpen || isAuthenticating
        guard shouldClose else {
            updateShield()
            return
        }
        revealTask?.cancel()
        vaultViewModel.flush()
        vaultFiles.wipe()
        autoLock.disarm()
        reauth.clear()
        session.wipe()
        vaultViewModel.wipeMemory()
        isDecoySession = false
        isVaultPresented = false
        isAuthenticating = false
        showPasscode = false
        vaultRevealed = false
        isClosingVault = false
        systemUIActive = false
        pendingKey = nil
        searchText = ""
        updateShield()
    }

    func lockFromButton() {
        guard isVaultPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lock()
        }
    }

    func eraseAllPrivateData() {
        lock()
        try? vaultStore.deleteAll()
        try? decoyStore.deleteAll()
        try? keychain.removeAllVaultItems()
        attemptLimiter.reset()
        configurationRevision += 1
    }

    /// Deletes notes, photos, the phrase, and the code, then shows the welcome screen.
    /// Call this only after the confirmation popup. Face ID is required and does not fall back to the iPhone passcode.
    func startFresh(notes context: ModelContext) async -> String? {
        guard biometric.biometricsAvailable() else {
            return "Face ID isn't available, so nothing was deleted."
        }
        setSystemUI(true)
        let outcome = await biometric.authenticateBiometrics(reason: "Confirm it's you before deleting everything")
        setSystemUI(false)
        switch outcome {
        case .success:
            break
        case .cancelled:
            return nil
        default:
            return "Face ID didn't confirm, so nothing was deleted."
        }
        do {
            for note in try context.fetch(FetchDescriptor<Note>()) { context.delete(note) }
            for attachment in try context.fetch(FetchDescriptor<NoteAttachment>()) { context.delete(attachment) }
            for folder in try context.fetch(FetchDescriptor<NoteFolder>()) { context.delete(folder) }
            try context.save()
        } catch {
            return "Notes couldn't be cleared. Nothing else was deleted."
        }
        vaultFiles.deleteStoredFiles()
        try? vaultStore.deleteAll()
        try? decoyStore.deleteAll()
        try? keychain.removeAllVaultItems()
        onboardingStore.save(.empty)
        hasCompletedOnboarding = false
        hidingSecrets = false
        defaults.set(false, forKey: PreferenceKey.onboardingComplete)
        faceIDEnabled = true
        defaults.set(true, forKey: PreferenceKey.faceIDEnabled)
        setFavoriteMode(.both)
        reauth.policy = .always
        reauth.clear()
        autoLock.timeout = .never
        settings.panicWipeEnabled = false
        settings.includeVaultInBackup = false
        settings.statusMessage = nil
        passcodeStyle = .pin6
        NotesPreferences.shared.paper = .plain
        NotesPreferences.shared.smartFolders = []
        attemptLimiter.reset()
        configurationRevision += 1
        lock()
        return nil
    }

    func panicThreshold() -> Int {
        let stored = defaults.integer(forKey: PreferenceKey.panicThreshold)
        return stored == 0 ? SecurityConstants.defaultPanicThreshold : stored
    }

    // MARK: - Unlock

    private func unlockVault() async {
        let generation = unlockGeneration
        searchText = ""
        guard !attemptLimiter.isCoolingDown() else { return }
        isAuthenticating = true
        updateShield()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let ready = await waitUntilSceneActive(generation: generation)
        guard ready else {
            isAuthenticating = false
            updateShield()
            return
        }
        if faceIDEnabled, biometric.biometricsAvailable() {
            let outcome = await biometric.authenticateBiometrics(reason: UnlockPrompt.reason)
            guard generation == unlockGeneration else { return }
            if case .success(let context) = outcome {
                isAuthenticating = false
                await openVault(with: context, generation: generation)
                return
            }
            isAuthenticating = false
            updateShield()
            return
        }
        isAuthenticating = false
        updateShield()
        if passcodes.isConfigured() {
            passcodeStep = .enter
            passcodeMessage = ""
            showPasscode = true
            return
        }
        guard generation == unlockGeneration else { return }
        let legacy = await biometric.authenticate(reason: UnlockPrompt.reason)
        guard generation == unlockGeneration else { return }
        if case .success(let context) = legacy {
            await openVault(with: context, generation: generation, requireNewPasscode: true)
        } else if case .cancelled = legacy {
            return
        } else {
            attemptLimiter.recordFailure()
            considerPanicWipe()
        }
        updateShield()
    }

    private func openVault(with context: LAContext, generation: Int, requireNewPasscode: Bool = false) async {
        do {
            let storedKey: Data?
            #if DEBUG
            if UITestHooks.biometricAlwaysSucceeds {
                storedKey = try keychain.data(for: KeychainAccount.vaultKey, context: nil)
            } else {
                storedKey = try keychain.data(for: KeychainAccount.vaultKey, context: context)
            }
            #else
            storedKey = try keychain.data(for: KeychainAccount.vaultKey, context: context)
            #endif
            let keyData: Data
            if let storedKey {
                keyData = storedKey
            } else if passcodes.isConfigured() {
                isAuthenticating = false
                passcodeStep = .enter
                passcodeMessage = ""
                showPasscode = true
                updateShield()
                return
            } else {
                let created = crypto.generateKey()
                try keychain.set(
                    crypto.keyData(created),
                    account: KeychainAccount.vaultKey,
                    protection: .biometryCurrentSetOrPasscode,
                    context: context
                )
                keyData = crypto.keyData(created)
            }
            guard generation == unlockGeneration else { return }
            #if DEBUG
            if UITestHooks.isEnabled {
                let key = try crypto.key(from: keyData)
                present(key: key, decoy: false)
                attemptLimiter.reset()
                return
            }
            #endif
            if requireNewPasscode || !passcodes.isConfigured() {
                pendingKey = keyData
                passcodeStep = .create
                passcodeMessage = ""
                showPasscode = true
                return
            }
            let key = try crypto.key(from: keyData)
            present(key: key, decoy: false)
            attemptLimiter.reset()
        } catch {
            VaultLog.security.error("Vault key unreadable after authentication")
            attemptLimiter.recordFailure()
            considerPanicWipe()
        }
        updateShield()
    }

    func submitPasscode(_ code: String) {
        passcodeMessage = ""
        switch passcodeStep {
        case .enter:
            do {
                let data = try passcodes.unlock(passcode: code)
                let key = try crypto.key(from: data)
                showPasscode = false
                present(key: key, decoy: false)
                attemptLimiter.reset()
            } catch {
                attemptLimiter.recordFailure()
                considerPanicWipe()
                passcodeMessage = "Wrong passcode."
            }
        case .create:
            break
        case .change:
            break
        }
    }

    func saveNewPasscode(_ code: String, confirm: String) {
        guard code == confirm else {
            passcodeMessage = "Those passcodes don't match."
            return
        }
        guard let pendingKey else {
            passcodeMessage = "Use Face ID once, then choose a passcode."
            return
        }
        do {
            try passcodes.save(passcode: code, keyData: pendingKey)
            let key = try crypto.key(from: pendingKey)
            self.pendingKey = nil
            showPasscode = false
            present(key: key, decoy: false)
            attemptLimiter.reset()
        } catch {
            passcodeMessage = "Use 6 digits."
        }
    }

    func changeVaultPasscode(current: String, newCode: String, confirm: String) -> String? {
        guard newCode == confirm else { return "Those passcodes don't match." }
        guard let key = session.key else { return "Open this area first." }
        do {
            try passcodes.change(from: current, to: newCode, keyData: crypto.keyData(key))
            return nil
        } catch {
            return "Check the current passcode. The new one must be 6 digits."
        }
    }

    func cancelPasscode() {
        showPasscode = false
        pendingKey = nil
        passcodeMessage = ""
    }

    /// Face ID when this iPhone has it. The 6-digit code is only for a phone without Face ID.
    /// A miss or a cancel does not open the digit pad.
    func confirmWithFaceID() async -> IdentityCheck {
        guard biometric.biometricsAvailable() else { return .needCode }
        isAuthenticating = true
        updateShield()
        let outcome = await biometric.authenticateBiometrics(reason: UnlockPrompt.reason)
        isAuthenticating = false
        updateShield()
        if case .success = outcome { return .allowed }
        return .cancelled
    }

    func unlockCodeAvailability() -> UnlockCodeAvailability {
        if !passcodes.isConfigured() { return .missing }
        if attemptLimiter.isCoolingDown() { return .coolingDown }
        return .ready
    }

    /// Checks the 6-digit code without opening the hidden space.
    func unlockCodeMatches(_ code: String) -> Bool {
        guard passcodes.isConfigured(), !attemptLimiter.isCoolingDown() else { return false }
        do {
            _ = try passcodes.unlock(passcode: code)
            attemptLimiter.reset()
            return true
        } catch {
            attemptLimiter.recordFailure()
            considerPanicWipe()
            return false
        }
    }

    func setFaceIDEnabled(_ enabled: Bool) async {
        if enabled, !biometric.biometricsAvailable() {
            settings.statusMessage = "Face ID isn't set up on this iPhone."
            objectWillChange.send()
            return
        }
        guard await reauth.authorize(.faceID) != nil else {
            objectWillChange.send()
            return
        }
        if !enabled, !passcodes.isConfigured() {
            settings.statusMessage = "Choose a 6-digit passcode before turning Face ID off."
            objectWillChange.send()
            return
        }
        faceIDEnabled = enabled
        defaults.set(enabled, forKey: PreferenceKey.faceIDEnabled)
    }

    func updateBackupIncluded(_ included: Bool) async {
        guard await reauth.authorize(.backup) != nil else { return }
        settings.includeVaultInBackup = included
    }

    func emptyRecentlyDeleted() async {
        guard let proof = await reauth.authorize(.emptyBin) else { return }
        vaultViewModel.eraseDeleted(proof: proof)
        vaultFiles.eraseDeleted(proof: proof)
    }

    func setFavoriteMode(_ mode: FavoriteMode) {
        favoriteMode = mode
        defaults.set(mode.rawValue, forKey: PreferenceKey.favoriteMode)
    }

    private func promptReauth(_ action: RiskyAction) async -> Bool {
        if biometric.biometricsAvailable() {
            setSystemUI(true)
            let outcome = await biometric.authenticateBiometrics(reason: action.title)
            setSystemUI(false)
            if case .success = outcome { return true }
            return false
        }
        guard passcodes.isConfigured() else { return false }
        reauthMessage = ""
        reauthPasscode = true
        return await withCheckedContinuation { continuation in
            reauthContinuation = continuation
        }
    }

    func submitReauth(_ code: String) {
        do {
            _ = try passcodes.unlock(passcode: code)
            attemptLimiter.reset()
            reauthPasscode = false
            reauthMessage = ""
            reauthContinuation?.resume(returning: true)
            reauthContinuation = nil
        } catch {
            attemptLimiter.recordFailure()
            considerPanicWipe()
            reauthMessage = "Wrong passcode."
        }
    }

    func cancelReauth() {
        reauthPasscode = false
        reauthMessage = ""
        reauthContinuation?.resume(returning: false)
        reauthContinuation = nil
    }

    private func unlockDecoy() async {
        let generation = unlockGeneration
        searchText = ""
        do {
            guard let keyData = try keychain.data(for: KeychainAccount.decoyKey) else {
                VaultLog.security.error("Decoy key missing")
                return
            }
            let key = try crypto.key(from: keyData)
            guard generation == unlockGeneration else { return }
            present(key: key, decoy: true)
        } catch {
            VaultLog.security.error("Decoy key unreadable")
        }
    }

    private func present(key: SymmetricKey, decoy: Bool) {
        session.install(key)
        isDecoySession = decoy
        vaultViewModel.useDecoyStore = decoy
        vaultRevealed = true
        isClosingVault = false
        PrivacyShieldWindow.shared.hide()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isVaultPresented = true
        }
        autoLock.arm()
        updateShield()
        revealAfterLoad()
    }

    private func revealAfterLoad() {
        revealTask?.cancel()
        let generation = unlockGeneration
        revealTask = Task {
            async let notes: Void = vaultViewModel.load()
            async let files: Void = vaultFiles.load()
            _ = await (notes, files)
            guard generation == unlockGeneration, !Task.isCancelled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func considerPanicWipe() {
        guard defaults.bool(forKey: PreferenceKey.panicEnabled) else { return }
        guard attemptLimiter.consecutiveFailures() >= panicThreshold() else { return }
        VaultLog.security.error("Protected items removed after repeated authentication failures")
        eraseAllPrivateData()
    }

    /// Keyboard dismissal and the Face ID sheet both mark the scene inactive. Covering the
    /// screen then hides the prompt and makes unlock look like it did nothing.
    private func waitUntilSceneActive(generation: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        var sawActive = false
        while ContinuousClock.now < deadline {
            if generation != unlockGeneration { return false }
            if scenePhase == .active {
                if sawActive { return true }
                sawActive = true
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            sawActive = false
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return generation == unlockGeneration && scenePhase == .active
    }

    private func updateShield() {
        let vaultVisible = isVaultPresented || session.isOpen
        let sensitive = vaultVisible || isAuthenticating || hidingSecrets
        // Face ID and the keyboard mark the scene inactive. That is not a loading cover.
        let inSwitcher = scenePhase == .background
        let shouldCover = sensitive && (inSwitcher || isScreenCaptured)
        if shouldCover {
            PrivacyShieldWindow.shared.show()
        } else {
            PrivacyShieldWindow.shared.hide()
        }
    }

    private static func makeBiometric() -> BiometricAuthenticating {
        #if DEBUG
        if UITestHooks.biometricsUnavailable {
            return UnavailableBiometricService()
        }
        if UITestHooks.biometricAlwaysSucceeds {
            return SuccessfulBiometricService()
        }
        #endif
        return BiometricService()
    }

    #if DEBUG
    /// Debug-only. Release builds omit this. The phrase comes from the UI test environment,
    /// not from a string in this function. The key is stored without biometrics so XCUITest
    /// can open the private area after typing that phrase.
    private func prepareUITests() {
        if UITestHooks.openVault {
            let key = crypto.generateKey()
            try? seedGuideVaultNotes(using: key)
        }
        guard let phrase = UITestHooks.phrase else { return }
        guard let phrases = phrases as? SecretPhraseService else { return }
        if !UITestHooks.openVault {
            try? vaultStore.deleteAll()
        }
        try? decoyStore.deleteAll()
        do {
            try phrases.configureForUITest(phrase: phrase)
            let key = crypto.generateKey()
            try keychain.set(
                crypto.keyData(key),
                account: KeychainAccount.vaultKey,
                protection: .afterFirstUnlockThisDeviceOnly
            )
            if UITestHooks.openVault {
                try seedGuideVaultNotes(using: key)
            }
        } catch {
            VaultLog.security.error("UI test vault setup failed")
        }
        if UITestHooks.openVault, session.key != nil {
            vaultFiles.deleteStoredFiles()
            vaultFiles.seedGuideSamples()
        }
    }

    private static var didSeedNotes = false

    func seedGuideVaultNotes(using key: SymmetricKey) throws {
        try vaultStore.deleteAll()
        let samples = [
            ("Travel plans", "Pack a jacket for the ridge."),
            ("Cabin stay", "The window looks over the snow."),
            ("Train times", "Leave after breakfast."),
            ("Restaurant", "Ask for a table by the water."),
            ("Packing list", "Boots, a map, and a light."),
            ("Addresses", "Keep these off the other notes."),
            ("Flight note", "A window seat if one is open.")
        ]
        for (index, sample) in samples.enumerated() {
            let note = VaultNote(
                title: sample.0,
                body: sample.1,
                updatedAt: Date().addingTimeInterval(TimeInterval(-index * 3600))
            )
            try vaultStore.save(note, using: key)
        }
        session.install(key)
    }

    func seedUITestNotesIfNeeded(context: ModelContext, existingCount: Int) {
        guard UITestHooks.seedNotes, !Self.didSeedNotes else { return }
        Self.didSeedNotes = true
        if let existing = try? context.fetch(FetchDescriptor<Note>()) {
            existing.forEach { context.delete($0) }
        }
        if let folders = try? context.fetch(FetchDescriptor<NoteFolder>()) {
            folders.filter { $0.kind == .custom }.forEach { context.delete($0) }
        }
        let personal = NoteFolder(name: "Personal", sortOrder: 2, kind: .custom)
        let work = NoteFolder(name: "Work", sortOrder: 3, kind: .custom)
        context.insert(personal)
        context.insert(work)
        let rows: [(String, String, String?, NoteFolder?)] = [
            ("Grocery list", "Milk, bread, and apples.", "green", nil),
            ("Weekend hike", "The trail starts at the ridge.", nil, nil),
            ("Dinner idea", "Tomato pasta and a green salad.", "orange", nil),
            ("Reading list", "Finish the chapter on the train.", nil, personal),
            ("Gift idea", "A small framed photo from the trip.", nil, personal),
            ("Meeting notes", "Review the draft on Monday morning.", "blue", work),
            ("Call list", "Ask about the Thursday time.", nil, work)
        ]
        for (offset, row) in rows.enumerated() {
            let note = Note(
                title: row.0,
                body: row.1,
                updatedAt: Date().addingTimeInterval(TimeInterval(-offset * 1800)),
                colorTag: row.2
            )
            note.folder = row.3
            note.plainText = "\(row.0)\n\(row.1)"
            context.insert(note)
        }
        try? context.save()
    }
    #endif
}

#if DEBUG
enum UITestHooks {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    static var skipOnboarding: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-skip-onboarding")
    }

    static var resetOnboarding: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-reset-onboarding")
    }

    static var biometricsUnavailable: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-biometrics-off")
    }

    static var seedNotes: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-notes")
    }

    static var biometricAlwaysSucceeds: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-biometric-success")
    }

    /// Opens the private area on launch so a UI test can photograph it.
    static var openVault: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-open-vault")
    }

    /// Opens Settings on the phrase form with an example phrase already typed.
    static var showFilledPhrase: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-show-phrase")
    }

    /// Opens the first-launch phrase step with an example already typed.
    static var showOnboardingPhrase: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-ui-testing-show-onboarding-phrase")
    }

    /// Supplied by the UI test process. Empty unless `-ui-testing` is also set.
    static var phrase: String? {
        guard isEnabled else { return nil }
        let value = ProcessInfo.processInfo.environment["NOTELY_UITEST_PHRASE"] ?? ""
        return value.isEmpty ? nil : value
    }
}
#endif
