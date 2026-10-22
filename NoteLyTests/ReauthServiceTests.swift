import XCTest
@testable import NoteLy

@MainActor
final class ReauthServiceTests: XCTestCase {
    func testAlwaysAsksAndIssuesProof() async {
        let service = ReauthService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        service.policy = .always
        service.prompter = { _ in true }
        let proof = await service.authorize(.export)
        XCTAssertEqual(proof?.action, .export)
        XCTAssertNoThrow(try service.ledger.require(proof!, action: .export))
        XCTAssertThrowsError(try service.ledger.require(RiskProof(action: .export, id: UUID()), action: .export))
    }

    func testGraceSkipsTheSecondPrompt() async {
        let service = ReauthService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        service.policy = .thirtySeconds
        var prompts = 0
        service.prompter = { _ in
            prompts += 1
            return true
        }
        let now = Date()
        _ = await service.authorize(.permanentDelete, now: now)
        _ = await service.authorize(.permanentDelete, now: now.addingTimeInterval(10))
        XCTAssertEqual(prompts, 1)
        _ = await service.authorize(.changePasscode, now: now)
        XCTAssertEqual(prompts, 2)
    }

    func testDeniedPromptDoesNotGrant() async {
        let service = ReauthService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        service.prompter = { _ in false }
        let proof = await service.authorize(.deleteVault)
        XCTAssertNil(proof)
    }

    func testLockClearsGrace() async {
        let service = ReauthService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        service.policy = .oneMinute
        var prompts = 0
        service.prompter = { _ in
            prompts += 1
            return true
        }
        _ = await service.authorize(.export)
        service.clear()
        _ = await service.authorize(.export)
        XCTAssertEqual(prompts, 2)
    }
}
