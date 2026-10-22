import Foundation

struct AttemptSnapshot: Equatable, Codable, Sendable {
    var stamps: [Double]
    var cooldownUntil: Double
    var consecutive: Int

    static let empty = AttemptSnapshot(stamps: [], cooldownUntil: 0, consecutive: 0)
}

protocol AttemptRecording: AnyObject {
    func load() -> AttemptSnapshot
    func save(_ snapshot: AttemptSnapshot)
}

/// Silent brake for repeated biometric failures.
///
/// After 5 failures inside 10 minutes, further secret-phrase submits are treated as ordinary
/// searches for 5 minutes. Nothing in the UI says why. Cancelled prompts are not failures.
/// `consecutiveFailures` is separate and feeds the optional panic wipe.
/// The live app stores the counters in the Keychain. Tests can pass an in-memory or UserDefaults store.
final class AttemptLimiter: @unchecked Sendable {
    private let recording: AttemptRecording
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.recording = UserDefaultsAttemptStore(defaults: defaults)
    }

    init(recording: AttemptRecording) {
        self.recording = recording
    }

    func isCoolingDown(now: Date = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording.load().cooldownUntil > now.timeIntervalSince1970
    }

    func recordFailure(now: Date = .now) {
        lock.lock()
        defer { lock.unlock() }
        let nowInterval = now.timeIntervalSince1970
        var snapshot = recording.load()
        snapshot.stamps = snapshot.stamps.filter { nowInterval - $0 < SecurityConstants.failureWindow }
        snapshot.stamps.append(nowInterval)
        if snapshot.stamps.count >= SecurityConstants.maxFailedAttempts {
            snapshot.cooldownUntil = nowInterval + SecurityConstants.cooldownDuration
        }
        snapshot.consecutive += 1
        recording.save(snapshot)
    }

    func consecutiveFailures() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recording.load().consecutive
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recording.save(.empty)
    }
}

final class UserDefaultsAttemptStore: AttemptRecording, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "notely.auth.attemptSnapshot"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> AttemptSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(AttemptSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: AttemptSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Counters for biometric failures. Stored as one keychain blob so they are not in UserDefaults.
final class KeychainAttemptStore: AttemptRecording, @unchecked Sendable {
    private let keychain: KeychainServicing
    private let account = "auth.attempts"

    init(keychain: KeychainServicing) {
        self.keychain = keychain
    }

    func load() -> AttemptSnapshot {
        guard let data = try? keychain.data(for: account),
              let snapshot = try? JSONDecoder().decode(AttemptSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: AttemptSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? keychain.set(data, account: account, protection: .afterFirstUnlockThisDeviceOnly)
    }
}
