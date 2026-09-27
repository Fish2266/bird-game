import Foundation

/// Something to aim for: finishing one pays coins and / or unlocks a cosmetic you can't buy.
struct Goal {
    enum Metric {
        case tutorial, rings, topSpeed, medals, golds, fightWins, hardWins, knockouts, worldsFlown, lanGames, birdsOwned
        case cosmeticsOwned, distanceKm
    }
    let id: String
    let title: String
    let detail: String
    let metric: Metric
    let target: Double
    let coins: Int
    /// Cosmetic awarded (looked up in the catalog by id).
    var cosmetic: String? = nil

    var rewardText: String {
        var parts: [String] = []
        if coins > 0 { parts.append("+\(coins) ●") }
        if let c = cosmetic, let item = CosmeticCatalog.all.first(where: { $0.id == c }) { parts.append(item.name) }
        return parts.joined(separator: " + ")
    }
}

enum GoalCatalog {
    static let all: [Goal] = [
        Goal(id: "tutorial", title: "Flight school", detail: "Finish the tutorial", metric: .tutorial, target: 1, coins: 100, cosmetic: "grad"),
        Goal(id: "rings25", title: "First rings", detail: "Fly through 25 rings", metric: .rings, target: 25, coins: 40),
        Goal(id: "rings250", title: "Ring collector", detail: "Fly through 250 rings", metric: .rings, target: 250, coins: 150),
        Goal(id: "rings1000", title: "Lord of the rings", detail: "Fly through 1,000 rings", metric: .rings, target: 1000, coins: 0, cosmetic: "halo"),
        Goal(id: "speed", title: "Speed demon", detail: "Dive faster than 200 km/h", metric: .topSpeed, target: 200, coins: 100),
        Goal(id: "medal", title: "On the podium", detail: "Win a medal in any race", metric: .medals, target: 1, coins: 60),
        Goal(id: "gold", title: "Gold!", detail: "Win a gold medal", metric: .golds, target: 1, coins: 0, cosmetic: "medal"),
        Goal(id: "gold4", title: "Golden touch", detail: "Win gold on 4 different courses", metric: .golds, target: 4, coins: 0, cosmetic: "gold"),
        Goal(id: "fightWin", title: "Top bird", detail: "Win a PvP fight", metric: .fightWins, target: 1, coins: 80),
        Goal(id: "fightHard", title: "Unbeatable", detail: "Win a fight against Hard bots", metric: .hardWins, target: 1, coins: 0, cosmetic: "viking"),
        Goal(id: "ko25", title: "Knockout artist", detail: "Knock out 25 birds", metric: .knockouts, target: 25, coins: 150),
        Goal(id: "worlds", title: "Globetrotter", detail: "Fly in every world", metric: .worldsFlown, target: 4, coins: 0, cosmetic: "explorer"),
        Goal(id: "lan", title: "Flock together", detail: "Play a LAN game with a friend", metric: .lanGames, target: 1, coins: 0, cosmetic: "lei"),
        Goal(id: "birds", title: "Aviary", detail: "Own every bird", metric: .birdsOwned, target: Double(Catalog.playable.count), coins: 300),
        Goal(id: "style5", title: "Dressed to impress", detail: "Own 5 cosmetics", metric: .cosmeticsOwned, target: 5, coins: 100),
        Goal(id: "distance", title: "Long haul", detail: "Fly 100 km in total", metric: .distanceKm, target: 100, coins: 200),
    ]

    static func goal(_ id: String) -> Goal? { all.first { $0.id == id } }
    /// The goal that awards a cosmetic, if any.
    static func goal(awarding cosmetic: String) -> Goal? { all.first { $0.cosmetic == cosmetic } }
}
