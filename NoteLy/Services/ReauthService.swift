import Foundation

enum RiskyAction: String, Equatable, Sendable {
    case export
    case emptyBin
    case permanentDelete
    case deleteFolder
    case deleteVault
    case changePasscode
    case faceID
    case backup

    var allowsGrace: Bool {
        switch self {
        case .export, .emptyBin, .permanentDelete, .deleteFolder: return true
        case .deleteVault, .changePasscode, .faceID, .backup: return false
        }
    }

    var title: String {
        switch self {
        case .export: return "Confirm export"
        case .emptyBin: return "Empty Recently Deleted"
        case .permanentDelete: return "Delete permanently"
        case .deleteFolder: return "Delete folder"
        case .deleteVault: return "Delete private notes"
        case .changePasscode: return "Change passcode"
        case .faceID: return "Change Face ID"
        case .backup: return "Change backup"
        }
    }
}

enum ReauthPolicy: String, CaseIterable, Identifiable {
    case always = "Always ask"
    case thirtySeconds = "Within 30 seconds"
    case oneMinute = "Within 1 minute"
    var id: String { rawValue }

    var grace: TimeInterval? {
        switch self {
        case .always: return nil
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        }
    }
}

struct RiskProof: Equatable, Sendable {
    var action: RiskyAction
    var id: UUID
}

/// Grants created only after a successful ask-again check. Store methods reject work without one.
final class RiskLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [UUID: RiskyAction] = [:]

    func issue(_ action: RiskyAction) -> RiskProof {
        let proof = RiskProof(action: action, id: UUID())
        lock.lock()
        open[proof.id] = action
        lock.unlock()
        return proof
    }

    func require(_ proof: RiskProof, action: RiskyAction) throws {
        lock.lock()
        defer { lock.unlock() }
        guard open[proof.id] == action else { throw VaultError.authorizationRequired }
    }

    func clear() {
        lock.lock()
        open.removeAll()
        lock.unlock()
    }
}

/// Decides whether a risky action may proceed. The prompt is injected so tests do not show UI.
@MainActor
final class ReauthService: ObservableObject {
    @Published var policy: ReauthPolicy {
        didSet { defaults.set(policy.rawValue, forKey: PreferenceKey.reauthPolicy) }
    }

    let ledger = RiskLedger()
    var prompter: ((RiskyAction) async -> Bool)?
    private var graceUntil: [RiskyAction: Date] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: PreferenceKey.reauthPolicy)
        policy = stored.flatMap(ReauthPolicy.init(rawValue:)) ?? .always
    }

    func authorize(_ action: RiskyAction, now: Date = .now) async -> RiskProof? {
        if action.allowsGrace, let until = graceUntil[action], now < until {
            return ledger.issue(action)
        }
        let allowed = await prompter?(action) ?? false
        guard allowed else { return nil }
        if action.allowsGrace, let window = policy.grace {
            graceUntil[action] = now.addingTimeInterval(window)
        }
        return ledger.issue(action)
    }

    func clear() {
        graceUntil.removeAll()
        ledger.clear()
    }
}
