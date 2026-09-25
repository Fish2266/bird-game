import AppKit
import simd

// MARK: - Game modes

enum GameMode: String, Codable, CaseIterable {
    case freeRoam, ringRace, speedRace, pvp

    var title: String {
        switch self {
        case .freeRoam: return "Free Roam"
        case .ringRace: return "Ring Race"
        case .speedRace: return "Speed Race"
        case .pvp: return "PvP Fight"
        }
    }

    var blurb: String {
        switch self {
        case .freeRoam: return "Fly anywhere and chase the endless rings. The original game."
        case .ringRace: return "Fly a fixed course of rings as fast as you can. Every ring you miss adds 5 seconds."
        case .speedRace: return "Follow the glowing sky road through checkpoints, past spinning blades and other obstacles."
        case .pvp: return "Three lives each; the last bird flying wins. Lock on and open your mouth wide to attack."
        }
    }

    var isRace: Bool { self == .ringRace || self == .speedRace }
}

/// Host settings for a LAN game (single player uses the defaults, with PvP only in the fight mode).
struct MatchRules: Codable, Equatable {
    var collisions = true
    var pvp = true
    var showLocation = true
}

/// One line of a race / fight result.
struct Standing: Codable, Equatable {
    var id: Int
    var name: String
    var color: Int
    var place: Int
    /// Race time in seconds (nil = did not finish).
    var time: Double?
    var knockouts = 0
    var note = ""
}

struct MatchResult {
    var title: String
    var standings: [Standing]
    /// Coins this player earned for the match.
    var coins: Int = 0
    var personalBest = false
    var footer = ""
}

// MARK: - Nametag colors

enum NameColors {
    static let all: [SIMD3<Float>] = [
        SIMD3(0.93, 0.26, 0.24),  // red
        SIMD3(0.98, 0.58, 0.15),  // orange
        SIMD3(0.97, 0.83, 0.20),  // yellow
        SIMD3(0.35, 0.80, 0.30),  // green
        SIMD3(0.20, 0.80, 0.78),  // teal
        SIMD3(0.25, 0.55, 0.98),  // blue
        SIMD3(0.62, 0.40, 0.95),  // purple
        SIMD3(0.97, 0.45, 0.75),  // pink
    ]
    static let names = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
    static func color(_ i: Int) -> SIMD3<Float> { all[((i % all.count) + all.count) % all.count] }
    static func ns(_ i: Int, alpha: CGFloat = 1) -> NSColor {
        let c = color(i)
        return NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
    }
}

// MARK: - Wire types shared by the game and the network

/// A bird's flight state as sent ~30 times a second.
struct NetState: Codable {
    var id: Int
    var p: SIMD3<Float>
    /// Orientation quaternion (ix, iy, iz, r).
    var q: SIMD4<Float>
    var v: SIMD3<Float>
    /// Wing elevation L/R, wing bend, fold.
    var w: SIMD4<Float>
    var hp: Float
    var flags: Int
    var bird: String
    /// Race progress (gates passed + fraction) for live standings.
    var progress: Float = 0
    var lives = Fighter.startLives

    static let alive = 1, paused = 2, finished = 4, spectator = 8, burning = 16
}

enum WeaponKind: String, Codable, CaseIterable {
    case pebble, seeds, gust, feathers, missiles, fire

    var name: String {
        switch self {
        case .pebble: return "Pebble Shot"
        case .seeds: return "Seed Spray"
        case .gust: return "Gale Gust"
        case .feathers: return "Razor Feathers"
        case .missiles: return "Homing Missiles"
        case .fire: return "Phoenix Fire"
        }
    }

    var blurb: String {
        switch self {
        case .pebble: return "One pebble that curves toward its target."
        case .seeds: return "A shotgun burst of seeds. Deadly up close."
        case .gust: return "A huge blast of wind: little damage, massive knockback."
        case .feathers: return "A fast burst of three razor feathers."
        case .missiles: return "Two heat-seeking missiles that explode on impact."
        case .fire: return "Homing fireballs that explode and set birds alight."
        }
    }
}

/// One attack as broadcast to other players (they replay it for looks; the shooter decides hits).
struct Shot: Codable {
    var owner: Int
    var weapon: WeaponKind
    var attack: Int
    var origin: SIMD3<Float>
    var dir: SIMD3<Float>
    var ownerVel: SIMD3<Float>
    var target: Int?
    /// Fired by a person (stronger homing, bigger hit radius) rather than a bot.
    var assist = false
}

enum HitSource: String, Codable { case shot, ram, border, hazard }

struct HitReport: Codable {
    var from: Int
    var to: Int
    var damage: Float
    var impulse: SIMD3<Float>
    var burn: Float = 0
    var source: HitSource
    var weapon: WeaponKind?
}

enum GameEvent: Codable {
    case fire(Shot)
    case hit(HitReport)
    /// `killer` 0 = nobody (border, crash).
    case died(victim: Int, killer: Int)
    case finished(id: Int, time: Double)
    case respawned(id: Int)
    /// Out of lives (fights).
    case eliminated(id: Int)
    /// Someone took a health orb; everyone hides it.
    case pickup(orb: Int, by: Int)
}

/// Host → everyone: match flow.
enum MatchCommand: Codable {
    /// Put everyone on the start grid and count down.
    case start(matchId: Int, countdown: Double, slots: [Int: Int])
    case results(matchId: Int, standings: [Standing])
    case warmup
}

/// Race medals: beat the course's target times.
enum Medal: Int, Comparable {
    case bronze = 1, silver, gold
    var name: String { ["", "Bronze", "Silver", "Gold"][rawValue] }
    /// Coin bonus for finishing with this medal.
    var coins: Int { [0, 8, 18, 30][rawValue] }
    /// Row color in the results (negative = medal colors).
    var color: Int { -1 - rawValue }
    static func < (a: Medal, b: Medal) -> Bool { a.rawValue < b.rawValue }

    /// `targets` are the gold, silver and bronze times.
    static func of(_ time: Double, _ targets: [Double]) -> Medal? {
        guard targets.count == 3 else { return nil }
        if time <= targets[0] { return .gold }
        if time <= targets[1] { return .silver }
        if time <= targets[2] { return .bronze }
        return nil
    }

    static func ns(_ color: Int) -> NSColor? {
        switch color {
        case -4: return NSColor(srgbRed: 0.95, green: 0.75, blue: 0.15, alpha: 1)
        case -3: return NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1)
        case -2: return NSColor(srgbRed: 0.80, green: 0.50, blue: 0.28, alpha: 1)
        default: return nil
        }
    }
}

func ordinal(_ n: Int) -> String {
    let s: String
    switch (n % 10, n % 100) {
    case (1, let t) where t != 11: s = "st"
    case (2, let t) where t != 12: s = "nd"
    case (3, let t) where t != 13: s = "rd"
    default: s = "th"
    }
    return "\(n)\(s)"
}

func raceClock(_ t: Double) -> String {
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}
