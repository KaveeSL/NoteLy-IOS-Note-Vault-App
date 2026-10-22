import Foundation

/// How the vault passcode is entered. This is never the iPhone passcode.
enum VaultPasscodeStyle: String, Codable, CaseIterable, Identifiable {
    case pin6
    case pin8
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin6: return "6-digit PIN"
        case .pin8: return "Longer PIN"
        case .mixed: return "Letters and numbers"
        }
    }

    var digitCount: Int? {
        switch self {
        case .pin6: return 6
        case .pin8: return 8
        case .mixed: return nil
        }
    }
}

/// Setup checks for the vault passcode. Unlock only checks the shape, so an older code still opens.
enum PasscodeRules {
    static func normalized(_ raw: String, style: VaultPasscodeStyle) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shape(text, style: style) else { throw VaultError.phraseTooShort }
        return style == .mixed ? text : text
    }

    /// Plain-language problem for setup. `nil` means Continue may enable.
    static func issue(for raw: String, style: VaultPasscodeStyle, phrase: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter a passcode." }
        switch style {
        case .pin6, .pin8:
            let count = style.digitCount ?? 6
            if text.count != count || !text.allSatisfy(\.isNumber) {
                return "Use \(count) digits."
            }
            if Set(text).count == 1 { return "Don't use the same digit repeated." }
            if isSequential(text) || blockedPins.contains(text) {
                return "Don't use a simple pattern like 123456."
            }
        case .mixed:
            if text.count < 8 { return "Use at least 8 characters." }
            if text.count > SecurityConstants.maxPhraseLength { return "Use \(SecurityConstants.maxPhraseLength) characters or fewer." }
            if !text.contains(where: \.isLetter) || !text.contains(where: \.isNumber) {
                return "Use both letters and numbers."
            }
            if Set(text).count <= 2 { return "Don't use a simple pattern." }
        }
        let phraseNorm = PhraseValidator.normalize(phrase)
        if !phraseNorm.isEmpty, PhraseValidator.normalize(text) == phraseNorm {
            return "Don't use your secret phrase as the passcode."
        }
        return nil
    }

    private static func shape(_ text: String, style: VaultPasscodeStyle) -> Bool {
        switch style {
        case .pin6:
            return text.count == 6 && text.allSatisfy(\.isNumber)
        case .pin8:
            return text.count == 8 && text.allSatisfy(\.isNumber)
        case .mixed:
            return text.count >= 8 && text.count <= SecurityConstants.maxPhraseLength
        }
    }

    private static let blockedPins: Set<String> = [
        "123456", "654321", "12345678", "87654321", "111111", "000000", "11111111", "00000000"
    ]

    private static func isSequential(_ text: String) -> Bool {
        let digits = Array(text)
        guard digits.count >= 4 else { return false }
        let values = digits.compactMap { $0.wholeNumberValue }
        guard values.count == digits.count else { return false }
        let forward = zip(values, values.dropFirst()).allSatisfy { $1 == $0 + 1 }
        let backward = zip(values, values.dropFirst()).allSatisfy { $1 == $0 - 1 }
        return forward || backward
    }
}
