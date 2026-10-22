import XCTest
@testable import NoteLy

final class OnboardingRulesTests: XCTestCase {
    func testPhraseRulesRejectCommonAndSequentialValues() {
        XCTAssertEqual(PhraseValidator.validate("password").invalidMessage, "Choose a phrase that isn't a common word or a typical note search.")
        XCTAssertEqual(PhraseValidator.validate("12345678").invalidMessage, "Don't use a sequence like 12345678 or abcdefgh.")
        XCTAssertEqual(PhraseValidator.validate("notes").invalidMessage, "Use at least 8 characters.")
        if case .valid = PhraseValidator.validate("paper-harbor") {
        } else {
            XCTFail("Expected a valid phrase")
        }
    }

    func testPasscodeRules() {
        XCTAssertEqual(PasscodeRules.issue(for: "111111", style: .pin6, phrase: ""), "Don't use the same digit repeated.")
        XCTAssertEqual(PasscodeRules.issue(for: "123456", style: .pin6, phrase: ""), "Don't use a simple pattern like 123456.")
        XCTAssertEqual(PasscodeRules.issue(for: "246810", style: .pin6, phrase: "246810"), "Don't use your secret phrase as the passcode.")
        XCTAssertNil(PasscodeRules.issue(for: "246810", style: .pin6, phrase: "paper-harbor"))
        XCTAssertEqual(PasscodeRules.issue(for: "12345678", style: .pin8, phrase: ""), "Don't use a simple pattern like 123456.")
        XCTAssertNil(PasscodeRules.issue(for: "24681357", style: .pin8, phrase: ""))
        XCTAssertEqual(PasscodeRules.issue(for: "letters", style: .mixed, phrase: ""), "Use at least 8 characters.")
        XCTAssertEqual(PasscodeRules.issue(for: "lettersonly", style: .mixed, phrase: ""), "Use both letters and numbers.")
        XCTAssertNil(PasscodeRules.issue(for: "harbor24", style: .mixed, phrase: "paper-harbor"))
    }

    func testRecoveryConfirmation() {
        XCTAssertEqual(Set(RecoveryKey.lexicon).count, RecoveryKey.lexicon.count)
        XCTAssertGreaterThanOrEqual(RecoveryKey.lexicon.count, 256)
        let words = ["amber", "cedar", "harbor", "lantern"] + Array(repeating: "willow", count: 20)
        let indexes = [0, 2, 3]
        XCTAssertTrue(RecoveryKey.matches(words: words, indexes: indexes, answers: ["Amber", " harbor ", "Lantern"]))
        XCTAssertFalse(RecoveryKey.matches(words: words, indexes: indexes, answers: ["amber", "cedar", "lantern"]))
        let generated = RecoveryKey.generate()
        XCTAssertEqual(generated.count, 24)
        XCTAssertEqual(Set(generated).count, 24)
    }

    func testOnboardingResumeAfterQuit() {
        let keychain = InMemoryKeychain()
        let store = OnboardingStore(keychain: keychain)
        XCTAssertEqual(store.load(), .empty)
        var record = OnboardingRecord.empty
        record.step = OnboardingStep.phrase.rawValue
        store.save(record)
        let reloaded = OnboardingStore(keychain: keychain).load()
        XCTAssertEqual(reloaded.step, OnboardingStep.phrase.rawValue)
        XCTAssertTrue(reloaded.showsSetupAgain)
        record.completed = true
        store.save(record)
        XCTAssertFalse(store.load().showsSetupAgain)
        record.completed = false
        record.dismissedForever = true
        store.save(record)
        XCTAssertFalse(store.load().showsSetupAgain)
    }
}

private extension ValidationResult where Value == String {
    var invalidMessage: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
