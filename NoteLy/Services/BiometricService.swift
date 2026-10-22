import Foundation
import LocalAuthentication

/// Generic system-prompt copy. Do not mention a vault, a secret phrase, or private notes by a special name.
enum UnlockPrompt {
    static var reason: String {
        String(localized: "Unlock your notes")
    }
}

enum BiometricAvailability: Equatable {
    case ready(LABiometryType)
    case passcodeNotSet
    case unavailable
}

enum BiometricAuthOutcome {
    case success(LAContext)
    case cancelled
    case lockout
    case failed
    case passcodeNotSet
    case notAvailable
    case notEnrolled
}

/// Main-actor protocol: `LAContext.evaluatePolicy` is documented to run on the main thread,
/// and the returned context is reused immediately for the keychain read.
@MainActor
protocol BiometricAuthenticating: AnyObject {
    func availability() -> BiometricAvailability
    /// Shows the system prompt. The reason string must stay generic so the prompt does not name a hidden area.
    func authenticate(reason: String) async -> BiometricAuthOutcome
    /// Face ID or Touch ID only. A failure does not accept the device passcode.
    func authenticateBiometrics(reason: String) async -> BiometricAuthOutcome
    func biometricsAvailable() -> Bool
}

/// LocalAuthentication wrapper.
///
/// Policy is `.deviceOwnerAuthentication` so the device passcode works when Face ID fails,
/// is not enrolled, or is locked out. The same `LAContext` is returned on success and reused
/// for the keychain read (`touchIDAuthenticationAllowableReuseDuration`) so the user is not
/// prompted twice. The reuse window is intentionally short.
@MainActor
final class BiometricService: BiometricAuthenticating {
    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .ready(context.biometryType)
        }
        guard let error, error.domain == LAError.errorDomain else {
            return .unavailable
        }
        guard let code = LAError.Code(rawValue: error.code) else {
            return .unavailable
        }
        switch code {
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return .unavailable
        }
    }

    func authenticate(reason: String) async -> BiometricAuthOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.touchIDAuthenticationAllowableReuseDuration = 10
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canError) else {
            if let canError { return Self.map(canError) }
            return .notAvailable
        }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return accepted ? .success(context) : .failed
        } catch {
            return Self.map(error)
        }
    }

    func biometricsAvailable() -> Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func authenticateBiometrics(reason: String) async -> BiometricAuthOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canError) else {
            if let canError { return Self.map(canError) }
            return .notAvailable
        }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return accepted ? .success(context) : .failed
        } catch {
            return Self.map(error)
        }
    }

    /// Maps system errors. Callers on the notes screen must not turn these into vault-specific alerts.
    static func map(_ error: Error) -> BiometricAuthOutcome {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain, let code = LAError.Code(rawValue: nsError.code) else {
            return .failed
        }
        switch code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled
        case .biometryLockout:
            return .lockout
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return .failed
        }
    }
}

#if DEBUG
/// Used only by UI tests. Release builds do not compile this type.
@MainActor
final class SuccessfulBiometricService: BiometricAuthenticating {
    func availability() -> BiometricAvailability {
        .ready(.none)
    }

    func authenticate(reason: String) async -> BiometricAuthOutcome {
        .success(LAContext())
    }

    func biometricsAvailable() -> Bool { true }

    func authenticateBiometrics(reason: String) async -> BiometricAuthOutcome {
        .success(LAContext())
    }
}

/// UI tests for the path where Face ID cannot be used.
@MainActor
final class UnavailableBiometricService: BiometricAuthenticating {
    func availability() -> BiometricAvailability { .unavailable }
    func authenticate(reason: String) async -> BiometricAuthOutcome { .notAvailable }
    func authenticateBiometrics(reason: String) async -> BiometricAuthOutcome { .notAvailable }
    func biometricsAvailable() -> Bool { false }
}
#endif
