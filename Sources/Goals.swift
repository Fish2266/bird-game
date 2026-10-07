import Foundation

/// Something to aim for: finishing one pays coins and / or unlocks a cosmetic you can't buy.
struct Goal {
    enum Metric {
        case tutorial, rings, topSpeed, medals, golds, fightWins, hardWins, knockouts, worldsFlown, lanGames, birdsOwned
        case cosmeticsOwned, distanceKm
        /// Secrets found: anywhere, or in one world.
        case secrets, citySecrets, dinoSecrets, westSecrets
        // 1.0
        case bestStreak, maxedBirds, coinsEarned, perfectRaces, racesFinished
    }
    let id: String
    let title: String
    let detail: String
    let metric: Metric
    let target: Double
    let coins: Int
    /// Cosmetic awarded (looked up in the catalog by id).
    var cosmetic: String? = nil
    /// A bonus goal: nice to have, but not needed to open The Finale (it needs someone else to play with).
    var bonus = false

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
        Goal(id: "worlds", title: "Globetrotter", detail: "Fly in 4 different worlds", metric: .worldsFlown, target: 4, coins: 0, cosmetic: "explorer"),
        Goal(id: "worlds7", title: "World tour", detail: "Fly in all 7 worlds", metric: .worldsFlown, target: 7, coins: 300),
        Goal(id: "secrets10", title: "Sightseer", detail: "Find 10 secrets in the worlds", metric: .secrets, target: 10, coins: 150),
        Goal(id: "metro", title: "Urban explorer", detail: "Find every secret in Skyline City",
             metric: .citySecrets, target: Double(WorldCatalog.secrets["city"]?.count ?? 1), coins: 200),
        Goal(id: "paleo", title: "Paleontologist", detail: "Find every secret in Dino Valley",
             metric: .dinoSecrets, target: Double(WorldCatalog.secrets["dino"]?.count ?? 1), coins: 100, cosmetic: "dinohood"),
        Goal(id: "sheriff", title: "Sheriff", detail: "Find every secret in the Wild West",
             metric: .westSecrets, target: Double(WorldCatalog.secrets["west"]?.count ?? 1), coins: 100, cosmetic: "sheriff"),
        Goal(id: "lan", title: "Flock together", detail: "Play a LAN game with a friend", metric: .lanGames, target: 1, coins: 0, cosmetic: "lei",
             bonus: true),
        Goal(id: "birds", title: "Aviary", detail: "Own every bird", metric: .birdsOwned, target: Double(Catalog.playable.count), coins: 300),
        Goal(id: "style5", title: "Dressed to impress", detail: "Own 5 cosmetics", metric: .cosmeticsOwned, target: 5, coins: 100),
        Goal(id: "distance", title: "Long haul", detail: "Fly 100 km in total", metric: .distanceKm, target: 100, coins: 200),
        // 1.0: the long road. Finish every goal (bonus goals aside) and something opens.
        Goal(id: "medalall", title: "Podium everywhere", detail: "Win a medal in every race in every world",
             metric: .medals, target: Double(GoalCatalog.raceCourses), coins: 400),
        Goal(id: "goldall", title: "Gold rush", detail: "Win gold in every race in every world",
             metric: .golds, target: Double(GoalCatalog.raceCourses), coins: 1000),
        Goal(id: "rings5000", title: "Ring legend", detail: "Fly through 5,000 rings", metric: .rings, target: 5000, coins: 600),
        Goal(id: "streak20", title: "On fire", detail: "Fly a 20-ring streak in a challenge world", metric: .bestStreak, target: 20, coins: 300),
        Goal(id: "speed300", title: "Terminal velocity", detail: "Dive faster than 300 km/h", metric: .topSpeed, target: 300, coins: 250),
        Goal(id: "races50", title: "Racer", detail: "Finish 50 races", metric: .racesFinished, target: 50, coins: 400),
        Goal(id: "flawless", title: "Flawless", detail: "Finish 5 Ring Races without missing a ring", metric: .perfectRaces, target: 5, coins: 400),
        Goal(id: "fight25", title: "Champion", detail: "Win 25 PvP fights", metric: .fightWins, target: 25, coins: 500),
        Goal(id: "hard10", title: "Hard as nails", detail: "Win 10 fights against Hard bots", metric: .hardWins, target: 10, coins: 600),
        Goal(id: "ko100", title: "Knockout king", detail: "Knock out 100 birds", metric: .knockouts, target: 100, coins: 500),
        Goal(id: "secretsall", title: "Secret keeper", detail: "Find every secret in the new worlds",
             metric: .secrets, target: Double(WorldCatalog.secrets.values.reduce(0) { $0 + $1.count }), coins: 600),
        Goal(id: "maxed", title: "Fully loaded", detail: "Max out every stat on one bird", metric: .maxedBirds, target: 1, coins: 400),
        Goal(id: "style25", title: "Fashion icon", detail: "Own 25 cosmetics", metric: .cosmeticsOwned, target: 25, coins: 400),
        Goal(id: "earn10k", title: "Tycoon", detail: "Earn 10,000 coins in total", metric: .coinsEarned, target: 10_000, coins: 500),
        Goal(id: "distance500", title: "Around the world", detail: "Fly 500 km in total", metric: .distanceKm, target: 500, coins: 600),
    ]

    /// Race courses that count for the "every course" goals: both races in every world before The Finale.
    static let raceCourses = WorldID.allCases.filter { $0 != .finale }.count * 2
    /// The goals that open The Finale (bonus goals don't count).
    static var required: [Goal] { all.filter { !$0.bonus } }

    static func goal(_ id: String) -> Goal? { all.first { $0.id == id } }
    /// The goal that awards a cosmetic, if any.
    static func goal(awarding cosmetic: String) -> Goal? { all.first { $0.cosmetic == cosmetic } }
}
