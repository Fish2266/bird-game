import Foundation
import simd

// MARK: - Stats

enum BirdStat: Int, CaseIterable {
    case power, speed, agility, glide, luck

    var name: String {
        switch self {
        case .power: return "Flap Power"
        case .speed: return "Dive Speed"
        case .agility: return "Agility"
        case .glide: return "Glide"
        case .luck: return "Luck"
        }
    }

    var blurb: String {
        switch self {
        case .power: return "Thrust and climb from every flap"
        case .speed: return "Top speed and acceleration in a dive"
        case .agility: return "How fast you bank and turn"
        case .glide: return "How far you soar without flapping"
        case .luck: return "Coins earned per ring"
        }
    }
}

/// Stat points: species base (1…10) plus up to `maxLevel` upgrades.
enum StatRules {
    static let maxLevel = 5
    static let maxPoints = 15
    static let upgradeCosts = [10, 20, 35, 55, 80]
}

// MARK: - Species catalog

struct Species {
    let id: String
    let name: String
    let blurb: String
    let cost: Int
    /// Base points per `BirdStat`, 1…10.
    let base: [Int]
    let look: BirdLook
    var comingSoon = false
}

enum Catalog {
    static let all: [Species] = [
        Species(id: "gull", name: "Seagull", blurb: "A dependable all-rounder. Good at everything, great at nothing.",
                cost: 0, base: [5, 5, 5, 5, 5], look: BirdLook()),
        Species(id: "sparrow", name: "Sparrow", blurb: "Tiny and twitchy. Turns on a dime, but runs out of steam in a dive.",
                cost: 50, base: [6, 3, 9, 3, 5],
                look: BirdLook(body: SIMD3(0.80, 0.70, 0.56), back: SIMD3(0.45, 0.30, 0.18), head: SIMD3(0.42, 0.30, 0.22),
                               wingRoot: SIMD3(0.55, 0.38, 0.22), wingMid: SIMD3(0.45, 0.30, 0.18), wingTip: SIMD3(0.20, 0.13, 0.08),
                               tail: SIMD3(0.40, 0.28, 0.18), beak: SIMD3(0.25, 0.22, 0.2), span: 0.8, chord: 1.15, size: 0.8)),
        Species(id: "albatross", name: "Albatross", blurb: "Huge wings built for soaring. Glides forever, turns like a bus.",
                cost: 120, base: [4, 6, 3, 10, 5],
                look: BirdLook(body: SIMD3(0.92, 0.92, 0.90), back: SIMD3(0.30, 0.30, 0.33), head: SIMD3(0.93, 0.93, 0.91),
                               wingRoot: SIMD3(0.30, 0.30, 0.33), wingMid: SIMD3(0.22, 0.22, 0.25), wingTip: SIMD3(0.10, 0.10, 0.12),
                               tail: SIMD3(0.25, 0.25, 0.28), beak: SIMD3(0.95, 0.72, 0.62), span: 1.45, chord: 0.8, size: 1.1)),
        Species(id: "falcon", name: "Peregrine Falcon", blurb: "The fastest animal alive. Tuck in and hit ludicrous speed.",
                cost: 200, base: [5, 10, 7, 4, 4],
                look: BirdLook(body: SIMD3(0.88, 0.84, 0.76), back: SIMD3(0.30, 0.34, 0.40), head: SIMD3(0.16, 0.17, 0.20),
                               wingRoot: SIMD3(0.36, 0.40, 0.46), wingMid: SIMD3(0.28, 0.31, 0.37), wingTip: SIMD3(0.12, 0.13, 0.16),
                               tail: SIMD3(0.30, 0.33, 0.38), beak: SIMD3(0.95, 0.80, 0.25), span: 0.95, chord: 0.85, size: 0.95)),
        Species(id: "eagle", name: "Golden Eagle", blurb: "Powerful wingbeats and strong all round. A serious upgrade.",
                cost: 350, base: [8, 7, 5, 7, 6],
                look: BirdLook(body: SIMD3(0.36, 0.23, 0.12), back: SIMD3(0.30, 0.19, 0.10), head: SIMD3(0.72, 0.55, 0.26),
                               wingRoot: SIMD3(0.42, 0.28, 0.14), wingMid: SIMD3(0.32, 0.21, 0.11), wingTip: SIMD3(0.10, 0.07, 0.05),
                               tail: SIMD3(0.28, 0.18, 0.10), beak: SIMD3(0.95, 0.78, 0.20), span: 1.2, chord: 1.1, size: 1.2)),
        Species(id: "phoenix", name: "Phoenix", blurb: "Legendary. Burns bright, flies faster, and finds more gold.",
                cost: 700, base: [9, 9, 8, 8, 9],
                look: BirdLook(body: SIMD3(0.95, 0.45, 0.10), back: SIMD3(0.90, 0.25, 0.08), head: SIMD3(1.0, 0.75, 0.20),
                               wingRoot: SIMD3(1.0, 0.70, 0.15), wingMid: SIMD3(0.95, 0.35, 0.08), wingTip: SIMD3(0.85, 0.10, 0.05),
                               tail: SIMD3(1.0, 0.55, 0.10), beak: SIMD3(1.0, 0.9, 0.5), span: 1.15, chord: 1.1, size: 1.05, glow: 0.8)),
        Species(id: "owl", name: "Snowy Owl", blurb: "Silent wings. Coming soon.", cost: 0, base: [6, 4, 6, 8, 6],
                look: BirdLook(body: SIMD3(0.95, 0.95, 0.93), back: SIMD3(0.85, 0.85, 0.82), head: SIMD3(0.95, 0.95, 0.93),
                               wingRoot: SIMD3(0.92, 0.92, 0.90), wingMid: SIMD3(0.80, 0.80, 0.78), wingTip: SIMD3(0.50, 0.48, 0.45),
                               tail: SIMD3(0.90, 0.90, 0.88), beak: SIMD3(0.20, 0.20, 0.20)), comingSoon: true),
        Species(id: "hummingbird", name: "Hummingbird", blurb: "Tiny and blindingly quick. Coming soon.", cost: 0, base: [10, 5, 10, 2, 5],
                look: BirdLook(body: SIMD3(0.25, 0.65, 0.40), back: SIMD3(0.15, 0.55, 0.35), head: SIMD3(0.80, 0.15, 0.35),
                               wingRoot: SIMD3(0.20, 0.50, 0.35), wingMid: SIMD3(0.15, 0.40, 0.30), wingTip: SIMD3(0.10, 0.25, 0.20),
                               tail: SIMD3(0.15, 0.45, 0.30), beak: SIMD3(0.10, 0.10, 0.10)), comingSoon: true),
    ]

    static func species(_ id: String) -> Species { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Flight tuning derived from stats

struct FlightTuning {
    var thrust: Float = 1
    var flapLift: Float = 1
    var diveDrag: Float = 1
    var maxSpeed: Float = 120
    var rollRate: Float = 1
    var turn: Float = 1
    var maxBank: Float = 1.1
    var glideDrag: Float = 1
    var stallDrop: Float = 0
    var bankPenalty: Float = 1
    /// Extra forward acceleration (m/s²) while tucked.
    var diveAccel: Float = 0

    /// `points` are effective stat points (1…15); 5 is the Seagull baseline.
    init(points p: [Int] = [5, 5, 5, 5, 5]) {
        func f(_ s: BirdStat) -> Float { (Float(p[s.rawValue]) - 5) / 5 }
        thrust = 1 + 0.25 * f(.power)
        flapLift = 1 + 0.15 * f(.power)
        diveDrag = 1 / (1 + 0.35 * f(.speed))
        maxSpeed = 120 + 15 * f(.speed)
        diveAccel = 3 * f(.speed)
        rollRate = 1 + 0.35 * f(.agility)
        turn = 1 + 0.2 * f(.agility)
        maxBank = 1.1 + 0.08 * f(.agility)
        glideDrag = 1 / (1 + 0.25 * f(.glide))
        stallDrop = 1.2 * f(.glide)
        bankPenalty = 1 / (1 + 0.3 * f(.glide))
    }
}

// MARK: - Saved progress (main thread only)

final class Progress {
    struct WorldStats: Codable {
        var rings = 0
        var coins = 0
        var bestStreak = 0
    }

    private struct Saved: Codable {
        var coins = 0
        var owned: [String] = ["gull"]
        var selected = "gull"
        var levels: [String: [Int]] = [:]
        var totalRings = 0
        var coinsEarned = 0
        var worldsOwned: [String] = ["meadow"]
        var world = "meadow"
        var worldStats: [String: WorldStats] = [:]

        init() {}
        // Older saves don't have the world fields; fill in defaults instead of failing.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            coins = try c.decodeIfPresent(Int.self, forKey: .coins) ?? 0
            owned = try c.decodeIfPresent([String].self, forKey: .owned) ?? ["gull"]
            selected = try c.decodeIfPresent(String.self, forKey: .selected) ?? "gull"
            levels = try c.decodeIfPresent([String: [Int]].self, forKey: .levels) ?? [:]
            totalRings = try c.decodeIfPresent(Int.self, forKey: .totalRings) ?? 0
            coinsEarned = try c.decodeIfPresent(Int.self, forKey: .coinsEarned) ?? 0
            worldsOwned = try c.decodeIfPresent([String].self, forKey: .worldsOwned) ?? ["meadow"]
            world = try c.decodeIfPresent(String.self, forKey: .world) ?? "meadow"
            worldStats = try c.decodeIfPresent([String: WorldStats].self, forKey: .worldStats) ?? [:]
        }
    }

    private var s: Saved
    private let key: String
    var onChange: (() -> Void)?

    init(key: String = "progress.v1") {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            s = saved
        } else {
            s = Saved()
        }
    }

    var coins: Int { s.coins }
    var totalRings: Int { s.totalRings }
    var coinsEarned: Int { s.coinsEarned }
    var selected: Species { Catalog.species(s.selected) }
    func owns(_ sp: Species) -> Bool { s.owned.contains(sp.id) }

    // MARK: Worlds

    var world: WorldInfo { WorldCatalog.info(s.world) }
    func ownsWorld(_ w: WorldInfo) -> Bool { s.worldsOwned.contains(w.id) }
    func stats(_ w: WorldInfo) -> WorldStats { s.worldStats[w.id] ?? WorldStats() }

    @discardableResult
    func buyWorld(_ w: WorldInfo) -> Bool {
        guard !w.comingSoon, !ownsWorld(w), s.coins >= w.cost else { return false }
        s.coins -= w.cost
        s.worldsOwned.append(w.id)
        s.world = w.id
        save()
        return true
    }

    func selectWorld(_ w: WorldInfo) {
        guard ownsWorld(w) else { return }
        s.world = w.id
        save()
    }

    /// Coins for one ring: bird luck × world multiplier × streak bonus (challenge worlds only).
    func ringValue(streak: Int) -> Int {
        let base = Float(coinsPerRing(selected))
        let w = world
        guard w.isChallenge else { return Int(base) }
        let streakBonus = 1 + 0.25 * Float(min(max(streak - 1, 0), 8))
        return Int((base * w.ringMultiplier * streakBonus).rounded())
    }

    /// Hazard penalty. Returns the coins actually lost.
    func lose(_ amount: Int) -> Int {
        let lost = min(amount, s.coins)
        s.coins -= lost
        save()
        return lost
    }

    func level(_ sp: Species, _ stat: BirdStat) -> Int { s.levels[sp.id]?[stat.rawValue] ?? 0 }
    func points(_ sp: Species) -> [Int] {
        BirdStat.allCases.map { min(sp.base[$0.rawValue] + level(sp, $0), StatRules.maxPoints) }
    }

    /// Cost of the next upgrade, or nil when maxed.
    func upgradeCost(_ sp: Species, _ stat: BirdStat) -> Int? {
        let l = level(sp, stat)
        return l < StatRules.maxLevel ? StatRules.upgradeCosts[l] : nil
    }

    func coinsPerRing(_ sp: Species) -> Int {
        let luck = Float(points(sp)[BirdStat.luck.rawValue])
        return Int((5 * (0.6 + 0.08 * luck)).rounded())
    }

    @discardableResult
    func buy(_ sp: Species) -> Bool {
        guard !sp.comingSoon, !owns(sp), s.coins >= sp.cost else { return false }
        s.coins -= sp.cost
        s.owned.append(sp.id)
        s.selected = sp.id
        save()
        return true
    }

    @discardableResult
    func upgrade(_ sp: Species, _ stat: BirdStat) -> Bool {
        guard owns(sp), let cost = upgradeCost(sp, stat), s.coins >= cost else { return false }
        s.coins -= cost
        var lv = s.levels[sp.id] ?? Array(repeating: 0, count: BirdStat.allCases.count)
        lv[stat.rawValue] += 1
        s.levels[sp.id] = lv
        save()
        return true
    }

    func select(_ sp: Species) {
        guard owns(sp) else { return }
        s.selected = sp.id
        save()
    }

    /// Returns coins awarded.
    func ringPassed(streak: Int = 0) -> Int {
        let c = ringValue(streak: streak)
        s.coins += c
        s.coinsEarned += c
        s.totalRings += 1
        var st = s.worldStats[s.world] ?? WorldStats()
        st.rings += 1
        st.coins += c
        st.bestStreak = max(st.bestStreak, streak)
        s.worldStats[s.world] = st
        save()
        return c
    }

    func grant(_ c: Int) { s.coins += c; save() }

    /// Wipe everything saved (coins, birds, upgrades, worlds, stats, settings).
    func resetAll() {
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.removeObject(forKey: key)
        s = Saved()
        onChange?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
}
