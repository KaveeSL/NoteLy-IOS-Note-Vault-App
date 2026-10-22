import Foundation

enum ValidationResult<Value>: Equatable where Value: Equatable {
    case valid(Value)
    case invalid(String)
}

enum PhraseStrength: String {
    case weak = "Weak"
    case ok = "OK"
    case strong = "Strong"
}

/// Rules for the secret phrase. Messages from here are shown only in setup and settings.
/// A failed check in the notes search stays silent.
enum PhraseValidator {
    private static let denylist: Set<String> = [
        "password", "password1", "unlock", "12345678", "qwerty", "qwertyui",
        "letmein", "welcome", "iloveyou", "admin", "secret", "trustno1",
        "work", "todo", "shopping", "notes", "meeting", "ideas", "grocery"
    ]

    static func normalize(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func validate(_ phrase: String) -> ValidationResult<String> {
        let normalized = normalize(phrase)
        if normalized.isEmpty {
            return .invalid("Enter a phrase.")
        }
        if normalized.count < SecurityConstants.minPhraseLength {
            return .invalid("Use at least \(SecurityConstants.minPhraseLength) characters.")
        }
        if normalized.count > SecurityConstants.maxPhraseLength {
            return .invalid("Use \(SecurityConstants.maxPhraseLength) characters or fewer.")
        }
        if Set(normalized).count <= 1 {
            return .invalid("Don't use the same character repeated.")
        }
        if isSequential(normalized) {
            return .invalid("Don't use a sequence like 12345678 or abcdefgh.")
        }
        if denylist.contains(normalized) {
            return .invalid("Choose a phrase that isn't a common word or a typical note search.")
        }
        return .valid(normalized)
    }

    /// Maps a phrase to the error stored by the phrase service. `nil` means it can be saved.
    static func storageError(for phrase: String) -> VaultError? {
        let normalized = normalize(phrase)
        if normalized.isEmpty || normalized.count < SecurityConstants.minPhraseLength {
            return .phraseTooShort
        }
        if normalized.count > SecurityConstants.maxPhraseLength {
            return .phraseTooLong
        }
        if case .invalid = validate(phrase) {
            return .phraseTooWeak
        }
        return nil
    }

    static func strength(_ phrase: String) -> PhraseStrength {
        let normalized = normalize(phrase)
        guard normalized.count >= SecurityConstants.minPhraseLength else { return .weak }
        if case .invalid = validate(phrase) { return .weak }
        let hasLetter = normalized.contains { $0.isLetter }
        let hasDigit = normalized.contains { $0.isNumber }
        let hasOther = normalized.contains { !$0.isLetter && !$0.isNumber }
        let varieties = [hasLetter, hasDigit, hasOther].filter { $0 }.count
        if normalized.count >= 16 && varieties >= 2 { return .strong }
        if normalized.count >= 12 { return .ok }
        return .weak
    }

    private static func isSequential(_ text: String) -> Bool {
        guard text.count >= 4 else { return false }
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let reversed = String(alphabet.reversed())
        return alphabet.contains(text) || reversed.contains(text)
    }
}
