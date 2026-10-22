import XCTest
@testable import NoteLy

final class FavoriteRankingTests: XCTestCase {
    func testManualKeepsStarOrder() {
        let items = [
            candidate("b", starred: true, order: 1, opens: 9),
            candidate("a", starred: true, order: 0, opens: 0),
            candidate("c", starred: false, order: nil, opens: 4)
        ]
        let ranked = FavoriteRanking.rank(items, mode: .manual)
        XCTAssertEqual(ranked.map(\.id), ["a", "b"])
    }

    func testRecentOpensOutrankOlderOnes() {
        let now = Date()
        let recent = candidate("recent", starred: false, order: nil, opens: 2, opened: now)
        let older = candidate("older", starred: false, order: nil, opens: 2, opened: now.addingTimeInterval(-14 * 24 * 60 * 60))
        XCTAssertGreaterThan(
            FavoriteRanking.weight(openCount: 2, lastOpened: recent.lastOpened, now: now),
            FavoriteRanking.weight(openCount: 2, lastOpened: older.lastOpened, now: now)
        )
        let ranked = FavoriteRanking.rank([older, recent], mode: .mostUsed, now: now)
        XCTAssertEqual(ranked.map(\.id), ["recent", "older"])
    }

    func testBothPutsStarsFirstWithoutDuplicates() {
        let now = Date()
        let star = candidate("star", starred: true, order: 0, opens: 1, opened: now)
        let used = candidate("used", starred: false, order: nil, opens: 5, opened: now)
        let ranked = FavoriteRanking.rank([used, star], mode: .both, now: now)
        XCTAssertEqual(ranked.map(\.id), ["star", "used"])
    }

    private func candidate(_ id: String, starred: Bool, order: Int?, opens: Int, opened: Date? = nil) -> FavoriteCandidate {
        FavoriteCandidate(id: id, title: id, starred: starred, order: order, openCount: opens, lastOpened: opened, systemImage: "star")
    }
}
