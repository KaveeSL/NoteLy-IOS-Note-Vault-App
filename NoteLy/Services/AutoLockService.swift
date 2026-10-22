import Combine
import Foundation

/// Locks the private area after the user goes idle. Background locking is handled by `AppState`
/// and always happens, regardless of this timer. "Immediately" has no timer; leaving the app locks it.
@MainActor
final class AutoLockService: ObservableObject {
    enum Timeout: String, CaseIterable, Identifiable, Sendable {
        case never
        case oneMinute
        case fiveMinutes
        case fifteenMinutes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .never: return "Never"
            case .oneMinute: return "1 minute"
            case .fiveMinutes: return "5 minutes"
            case .fifteenMinutes: return "15 minutes"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .never: return nil
            case .oneMinute: return 60
            case .fiveMinutes: return 300
            case .fifteenMinutes: return 900
            }
        }
    }

    @Published var timeout: Timeout {
        didSet {
            defaults.set(timeout.rawValue, forKey: PreferenceKey.autoLock)
            if isArmed {
                arm()
            }
        }
    }

    var onLock: (() -> Void)?
    private var task: Task<Void, Never>?
    private var isArmed = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: PreferenceKey.autoLock)
        let migrated = defaults.bool(forKey: Self.migratedKey)
        if migrated {
            switch stored {
            case Timeout.fiveMinutes.rawValue: timeout = .fiveMinutes
            case Timeout.fifteenMinutes.rawValue: timeout = .fifteenMinutes
            case Timeout.oneMinute.rawValue: timeout = .oneMinute
            default:
                timeout = .never
                defaults.set(Timeout.never.rawValue, forKey: PreferenceKey.autoLock)
            }
        } else {
            switch stored {
            case Timeout.fiveMinutes.rawValue: timeout = .fiveMinutes
            case Timeout.fifteenMinutes.rawValue: timeout = .fifteenMinutes
            default:
                timeout = .never
                defaults.set(Timeout.never.rawValue, forKey: PreferenceKey.autoLock)
            }
            defaults.set(true, forKey: Self.migratedKey)
        }
    }

    private static let migratedKey = "notely.vault.autolock.v2"

    func recordInteraction() {
        guard isArmed, timeout.interval != nil else { return }
        arm()
    }

    func arm() {
        isArmed = true
        task?.cancel()
        guard let interval = timeout.interval else { return }
        let nanoseconds = UInt64(interval * 1_000_000_000)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.onLock?()
        }
    }

    func disarm() {
        isArmed = false
        task?.cancel()
        task = nil
    }
}
