import Foundation

enum FavoriteMode: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case mostUsed = "Most Used"
    case both = "Both"
    var id: String { rawValue }
}

struct FavoriteCandidate: Equatable, Identifiable {
    var id: String
    var title: String
    var starred: Bool
    var order: Int?
    var openCount: Int
    var lastOpened: Date?
    var systemImage: String
}

enum FavoriteRanking {
    static func rank(_ items: [FavoriteCandidate], mode: FavoriteMode, now: Date = .now, limit: Int = 12) -> [FavoriteCandidate] {
        switch mode {
        case .manual:
            return Array(starred(items).prefix(limit))
        case .mostUsed:
            return Array(byUse(items, now: now).prefix(limit))
        case .both:
            let first = starred(items)
            let rest = byUse(items, now: now).filter { item in !first.contains(where: { $0.id == item.id }) }
            return Array((first + rest).prefix(limit))
        }
    }

    static func weight(openCount: Int, lastOpened: Date?, now: Date) -> Double {
        guard openCount > 0 else { return 0 }
        let age = lastOpened.map { now.timeIntervalSince($0) } ?? (30 * 24 * 60 * 60)
        let week: Double = 7 * 24 * 60 * 60
        return Double(openCount) * exp(-max(age, 0) / week)
    }

    private static func starred(_ items: [FavoriteCandidate]) -> [FavoriteCandidate] {
        items.filter(\.starred).sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
    }

    private static func byUse(_ items: [FavoriteCandidate], now: Date) -> [FavoriteCandidate] {
        items.filter { $0.openCount > 0 }.sorted {
            weight(openCount: $0.openCount, lastOpened: $0.lastOpened, now: now)
                > weight(openCount: $1.openCount, lastOpened: $1.lastOpened, now: now)
        }
    }
}
