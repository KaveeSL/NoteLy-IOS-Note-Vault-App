import Foundation

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome
    case benefits
    case howItWorks
    case stayingSafe
    case permissions
    case phrase
    case passcode
    case faceID
    case recovery
    case backup
    case practice
    case summary

    var isLearn: Bool { rawValue <= OnboardingStep.stayingSafe.rawValue }

    var title: String {
        switch self {
        case .welcome: return "Notes"
        case .benefits: return "What you get"
        case .howItWorks: return "How it works"
        case .stayingSafe: return "Staying safe"
        case .permissions: return "Permissions"
        case .phrase: return "Your phrase"
        case .passcode: return "A 6-digit code"
        case .faceID: return "Face ID"
        case .recovery: return "Recovery Key"
        case .backup: return "Backup"
        case .practice: return "Try it"
        case .summary: return "All set"
        }
    }
}

enum PermissionKind: String, Codable {
    case photos
    case camera
    case microphone
    case faceID
}

/// Progress only. The phrase, passcode, and recovery words are never stored here.
struct OnboardingRecord: Codable, Equatable {
    var step: Int
    var completed: Bool
    var dismissedForever: Bool
    var faceIDEnabled: Bool
    var backupIncluded: Bool
    var recoverySaved: Bool
    var photosExplained: Bool
    var cameraExplained: Bool
    var microphoneExplained: Bool

    static let empty = OnboardingRecord(
        step: 0,
        completed: false,
        dismissedForever: false,
        faceIDEnabled: false,
        backupIncluded: false,
        recoverySaved: false,
        photosExplained: false,
        cameraExplained: false,
        microphoneExplained: false
    )

    var showsSetupAgain: Bool { !completed && !dismissedForever }
}

/// Keychain record for first-launch progress. Not UserDefaults.
struct OnboardingStore {
    static let account = "onboarding.progress"
    private let keychain: KeychainServicing

    init(keychain: KeychainServicing) {
        self.keychain = keychain
    }

    func load() -> OnboardingRecord {
        guard let data = try? keychain.data(for: Self.account),
              let record = try? JSONDecoder().decode(OnboardingRecord.self, from: data) else {
            return .empty
        }
        return record
    }

    func save(_ record: OnboardingRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? keychain.set(data, account: Self.account, protection: .afterFirstUnlockThisDeviceOnly)
    }
}
