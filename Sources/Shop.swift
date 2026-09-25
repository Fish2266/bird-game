import Foundation
import simd

// MARK: - Stats

enum BirdStat: Int, CaseIterable {
    case power, speed, agility, glide, luck, weight, ram, attack

    var name: String {
        switch self {
        case .power: return "Flap Power"
        case .speed: return "Dive Speed"
        case .agility: return "Agility"
        case .glide: return "Glide"
        case .luck: return "Luck"
        case .weight: return "Weight"
        case .ram: return "Ram"
        case .attack: return "Attack"
        }
    }

    var blurb: String {
        switch self {
        case .power: return "Thrust and climb from every flap"
        case .speed: return "Top speed and acceleration in a dive"
        case .agility: return "How fast you bank and turn"
        case .glide: return "How far you soar without flapping"
        case .luck: return "Coins earned per ring, race and fight"
        case .weight: return "Shrugs off knockback from hits and crashes"
        case .ram: return "Knockback you deal when you crash into another bird"
        case .attack: return "Damage and reload speed of your attack"
        }
    }
}

/// Stat points: species base (1…10) plus upgrades, up to each bird's own upgrade cap.
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
    /// How many times each stat can be upgraded (cheaper birds top out sooner).
    let maxLevel: Int
    let weapon: WeaponKind
    let look: BirdLook
    var comingSoon = false

    /// Sum of base points: the catalog is ordered so this climbs with the price.
    var rating: Int { base.reduce(0, +) }
}

enum Catalog {
    //                                  Pow Dive Agi Glide Luck Wgt Ram Atk
    static let all: [Species] = [
        Species(id: "gull", name: "Seagull", blurb: "A dependable all-rounder: good at everything, great at nothing.",
                cost: 0, base: [5, 5, 5, 5, 5, 4, 4, 3], maxLevel: 2, weapon: .pebble, look: BirdLook()),
        Species(id: "sparrow", name: "Sparrow", blurb: "Tiny and twitchy. Turns on a dime, but easy to knock around.",
                cost: 50, base: [7, 3, 10, 4, 6, 2, 3, 5], maxLevel: 3, weapon: .seeds,
                look: BirdLook(body: SIMD3(0.80, 0.70, 0.56), back: SIMD3(0.45, 0.30, 0.18), head: SIMD3(0.42, 0.30, 0.22),
                               wingRoot: SIMD3(0.55, 0.38, 0.22), wingMid: SIMD3(0.45, 0.30, 0.18), wingTip: SIMD3(0.20, 0.13, 0.08),
                               tail: SIMD3(0.40, 0.28, 0.18), beak: SIMD3(0.25, 0.22, 0.2), span: 0.8, chord: 1.15, size: 0.8)),
        Species(id: "albatross", name: "Albatross", blurb: "Glides forever and shrugs off hits, but turns like a bus.",
                cost: 120, base: [4, 6, 3, 10, 6, 9, 4, 3], maxLevel: 3, weapon: .gust,
                look: BirdLook(body: SIMD3(0.92, 0.92, 0.90), back: SIMD3(0.30, 0.30, 0.33), head: SIMD3(0.93, 0.93, 0.91),
                               wingRoot: SIMD3(0.30, 0.30, 0.33), wingMid: SIMD3(0.22, 0.22, 0.25), wingTip: SIMD3(0.10, 0.10, 0.12),
                               tail: SIMD3(0.25, 0.25, 0.28), beak: SIMD3(0.95, 0.72, 0.62), span: 1.45, chord: 0.8, size: 1.1)),
        Species(id: "falcon", name: "Peregrine Falcon", blurb: "The fastest bird alive. Dive to ludicrous speed and bowl birds over.",
                cost: 200, base: [6, 10, 8, 4, 5, 5, 9, 5], maxLevel: 4, weapon: .feathers,
                look: BirdLook(body: SIMD3(0.88, 0.84, 0.76), back: SIMD3(0.30, 0.34, 0.40), head: SIMD3(0.16, 0.17, 0.20),
                               wingRoot: SIMD3(0.36, 0.40, 0.46), wingMid: SIMD3(0.28, 0.31, 0.37), wingTip: SIMD3(0.12, 0.13, 0.16),
                               tail: SIMD3(0.30, 0.33, 0.38), beak: SIMD3(0.95, 0.80, 0.25), span: 0.95, chord: 0.85, size: 0.95)),
        Species(id: "eagle", name: "Golden Eagle", blurb: "Heavy, powerful and strong all round. Fires homing missiles.",
                cost: 350, base: [9, 7, 6, 7, 6, 8, 7, 7], maxLevel: 4, weapon: .missiles,
                look: BirdLook(body: SIMD3(0.36, 0.23, 0.12), back: SIMD3(0.30, 0.19, 0.10), head: SIMD3(0.72, 0.55, 0.26),
                               wingRoot: SIMD3(0.42, 0.28, 0.14), wingMid: SIMD3(0.32, 0.21, 0.11), wingTip: SIMD3(0.10, 0.07, 0.05),
                               tail: SIMD3(0.28, 0.18, 0.10), beak: SIMD3(0.95, 0.78, 0.20), span: 1.2, chord: 1.1, size: 1.2)),
        Species(id: "phoenix", name: "Phoenix", blurb: "Legendary: faster, luckier, and sets other birds on fire.",
                cost: 700, base: [9, 9, 8, 8, 9, 7, 7, 10], maxLevel: 5, weapon: .fire,
                look: BirdLook(body: SIMD3(0.95, 0.45, 0.10), back: SIMD3(0.90, 0.25, 0.08), head: SIMD3(1.0, 0.75, 0.20),
                               wingRoot: SIMD3(1.0, 0.70, 0.15), wingMid: SIMD3(0.95, 0.35, 0.08), wingTip: SIMD3(0.85, 0.10, 0.05),
                               tail: SIMD3(1.0, 0.55, 0.10), beak: SIMD3(1.0, 0.9, 0.5), span: 1.15, chord: 1.1, size: 1.05, glow: 0.8)),
        Species(id: "owl", name: "Snowy Owl", blurb: "Silent wings and sharp eyes. Coming soon.", cost: 0, base: [6, 4, 6, 8, 6, 6, 5, 6],
                maxLevel: 4, weapon: .pebble,
                look: BirdLook(body: SIMD3(0.95, 0.95, 0.93), back: SIMD3(0.85, 0.85, 0.82), head: SIMD3(0.95, 0.95, 0.93),
                               wingRoot: SIMD3(0.92, 0.92, 0.90), wingMid: SIMD3(0.80, 0.80, 0.78), wingTip: SIMD3(0.50, 0.48, 0.45),
                               tail: SIMD3(0.90, 0.90, 0.88), beak: SIMD3(0.20, 0.20, 0.20)), comingSoon: true),
        Species(id: "hummingbird", name: "Hummingbird", blurb: "Tiny and blindingly quick. Coming soon.", cost: 0, base: [10, 5, 10, 2, 5, 1, 2, 6],
                maxLevel: 4, weapon: .seeds,
                look: BirdLook(body: SIMD3(0.25, 0.65, 0.40), back: SIMD3(0.15, 0.55, 0.35), head: SIMD3(0.80, 0.15, 0.35),
                               wingRoot: SIMD3(0.20, 0.50, 0.35), wingMid: SIMD3(0.15, 0.40, 0.30), wingTip: SIMD3(0.10, 0.25, 0.20),
                               tail: SIMD3(0.15, 0.45, 0.30), beak: SIMD3(0.10, 0.10, 0.10)), comingSoon: true),
    ]

    static func species(_ id: String) -> Species { all.first { $0.id == id } ?? all[0] }
    static var playable: [Species] { all.filter { !$0.comingSoon } }
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
    init(points p: [Int] = [5, 5, 5, 5, 5, 5, 5, 5]) {
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

/// Weight, ram and attack: how a bird fares when birds collide or shoot at each other.
struct CombatTuning: Codable, Equatable {
    /// Multiplies knockback you receive (heavier = less).
    var knockTaken: Float = 1
    /// Multiplies knockback you deal by ramming.
    var ramPower: Float = 1
    /// Attack stat points (1…15).
    var attack: Int = 5

    init(points p: [Int] = [5, 5, 5, 5, 5, 5, 5, 5]) {
        let w = Float(p[BirdStat.weight.rawValue]), r = Float(p[BirdStat.ram.rawValue])
        knockTaken = 1.45 - 0.07 * w          // weight 1: 1.38×, 5: 1.1×, 10: 0.75×, 15: 0.4×
        ramPower = 0.55 + 0.1 * r             // ram 1: 0.65×, 5: 1.05×, 10: 1.55×, 15: 2.05×
        attack = p[BirdStat.attack.rawValue]
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
        /// Purchased upgrade levels per bird.
        var levels: [String: [Int]] = [:]
        /// Levels actually in use (≤ purchased). Lowering one keeps the purchase so it can be turned back up for free.
        var active: [String: [Int]] = [:]
        var totalRings = 0
        var coinsEarned = 0
        var worldsOwned: [String] = ["meadow"]
        var world = "meadow"
        var worldStats: [String: WorldStats] = [:]
        /// Best race times in seconds, keyed "mode-world".
        var bestTimes: [String: Double] = [:]
        /// Gold / silver / bronze times per course, remembered from the last race on it.
        var medalTimes: [String: [Double]] = [:]
        var racesFinished = 0
        var wins = 0
        var knockouts = 0

        init() {}
        // Older saves don't have the newer fields; fill in defaults instead of failing.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            coins = try c.decodeIfPresent(Int.self, forKey: .coins) ?? 0
            owned = try c.decodeIfPresent([String].self, forKey: .owned) ?? ["gull"]
            selected = try c.decodeIfPresent(String.self, forKey: .selected) ?? "gull"
            levels = try c.decodeIfPresent([String: [Int]].self, forKey: .levels) ?? [:]
            active = try c.decodeIfPresent([String: [Int]].self, forKey: .active) ?? [:]
            totalRings = try c.decodeIfPresent(Int.self, forKey: .totalRings) ?? 0
            coinsEarned = try c.decodeIfPresent(Int.self, forKey: .coinsEarned) ?? 0
            worldsOwned = try c.decodeIfPresent([String].self, forKey: .worldsOwned) ?? ["meadow"]
            world = try c.decodeIfPresent(String.self, forKey: .world) ?? "meadow"
            worldStats = try c.decodeIfPresent([String: WorldStats].self, forKey: .worldStats) ?? [:]
            bestTimes = try c.decodeIfPresent([String: Double].self, forKey: .bestTimes) ?? [:]
            medalTimes = try c.decodeIfPresent([String: [Double]].self, forKey: .medalTimes) ?? [:]
            racesFinished = try c.decodeIfPresent(Int.self, forKey: .racesFinished) ?? 0
            wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
            knockouts = try c.decodeIfPresent(Int.self, forKey: .knockouts) ?? 0
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
        if migrate() { save() }
    }

    /// 0.1 saves have 5 stats and uncapped upgrades: pad to the new stat list and refund levels above each bird's cap.
    private func migrate() -> Bool {
        var changed = false
        let n = BirdStat.allCases.count
        for (id, lv) in s.levels {
            var l = lv
            if l.count < n { l += Array(repeating: 0, count: n - l.count); changed = true }
            let cap = Catalog.species(id).maxLevel
            for i in l.indices where l[i] > cap {
                for k in cap..<min(l[i], StatRules.upgradeCosts.count) { s.coins += StatRules.upgradeCosts[k] }
                l[i] = cap
                changed = true
            }
            s.levels[id] = l
        }
        for (id, a) in s.active where a.count < n {
            s.active[id] = a + Array(repeating: 0, count: n - a.count)
            changed = true
        }
        return changed
    }

    var coins: Int { s.coins }
    var totalRings: Int { s.totalRings }
    var coinsEarned: Int { s.coinsEarned }
    var racesFinished: Int { s.racesFinished }
    var wins: Int { s.wins }
    var knockouts: Int { s.knockouts }
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

    // MARK: Upgrades

    private func levels(_ sp: Species) -> [Int] { s.levels[sp.id] ?? Array(repeating: 0, count: BirdStat.allCases.count) }

    /// Upgrades bought for a stat.
    func level(_ sp: Species, _ stat: BirdStat) -> Int { levels(sp)[stat.rawValue] }
    /// Upgrades currently switched on for a stat (≤ `level`).
    func activeLevel(_ sp: Species, _ stat: BirdStat) -> Int {
        let bought = level(sp, stat)
        guard let a = s.active[sp.id] else { return bought }
        return min(a[stat.rawValue], bought)
    }

    /// Effective stat points (base + active upgrades).
    func points(_ sp: Species) -> [Int] {
        BirdStat.allCases.map { min(sp.base[$0.rawValue] + activeLevel(sp, $0), StatRules.maxPoints) }
    }

    /// Cost of the next upgrade, or nil when this bird's cap is reached.
    func upgradeCost(_ sp: Species, _ stat: BirdStat) -> Int? {
        let l = level(sp, stat)
        return l < min(sp.maxLevel, StatRules.maxLevel) ? StatRules.upgradeCosts[l] : nil
    }

    func coinsPerRing(_ sp: Species) -> Int {
        let luck = Float(points(sp)[BirdStat.luck.rawValue])
        return Int((5 * (0.6 + 0.08 * luck)).rounded())
    }

    /// Luck multiplier for race and fight rewards.
    func luckBonus(_ sp: Species) -> Float { 0.6 + 0.08 * Float(points(sp)[BirdStat.luck.rawValue]) }

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
        var lv = levels(sp)
        lv[stat.rawValue] += 1
        s.levels[sp.id] = lv
        var a = s.active[sp.id] ?? lv
        a[stat.rawValue] = lv[stat.rawValue]
        s.active[sp.id] = a
        save()
        return true
    }

    /// Turn one bought upgrade off (no refund; it can be turned back on). Returns false at level 0.
    @discardableResult
    func lowerLevel(_ sp: Species, _ stat: BirdStat) -> Bool {
        let cur = activeLevel(sp, stat)
        guard owns(sp), cur > 0 else { return false }
        var a = s.active[sp.id] ?? levels(sp)
        a[stat.rawValue] = cur - 1
        s.active[sp.id] = a
        save()
        return true
    }

    /// Turn a previously lowered upgrade back on (free). Returns false when all bought levels are on.
    @discardableResult
    func raiseLevel(_ sp: Species, _ stat: BirdStat) -> Bool {
        let cur = activeLevel(sp, stat)
        guard owns(sp), cur < level(sp, stat) else { return false }
        var a = s.active[sp.id] ?? levels(sp)
        a[stat.rawValue] = cur + 1
        s.active[sp.id] = a
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

    // MARK: Modes

    /// Race / fight reward, scaled by the flown bird's luck. Returns coins awarded.
    @discardableResult
    func award(_ base: Int, world: String? = nil) -> Int {
        guard base > 0 else { return 0 }
        let c = max(1, Int((Float(base) * luckBonus(selected)).rounded()))
        s.coins += c
        s.coinsEarned += c
        if let world {
            var st = s.worldStats[world] ?? WorldStats()
            st.coins += c
            s.worldStats[world] = st
        }
        save()
        return c
    }

    func bestTime(_ mode: GameMode, _ world: String) -> Double? { s.bestTimes["\(mode.rawValue)-\(world)"] }

    /// Best medal won on a course (nil = none yet).
    func bestMedal(_ mode: GameMode, _ world: String) -> Medal? {
        let k = "\(mode.rawValue)-\(world)"
        guard let t = s.bestTimes[k], let m = s.medalTimes[k] else { return nil }
        return Medal.of(t, m)
    }

    /// Records a finished race; returns true for a new personal best.
    @discardableResult
    func recordRace(_ mode: GameMode, _ world: String, time: Double, won: Bool, medals: [Double] = []) -> Bool {
        s.racesFinished += 1
        if won { s.wins += 1 }
        let k = "\(mode.rawValue)-\(world)"
        if medals.count == 3 { s.medalTimes[k] = medals }
        let best = s.bestTimes[k].map { time < $0 } ?? true
        if best { s.bestTimes[k] = time }
        save()
        return best
    }

    func recordFight(won: Bool, knockouts: Int) {
        if won { s.wins += 1 }
        s.knockouts += knockouts
        save()
    }

    func grant(_ c: Int) { s.coins += c; save() }

    /// Wipe everything saved (coins, birds, upgrades, worlds, stats, settings).
    func resetAll() {
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.removeObject(forKey: key)
        s = Saved()
        Ghosts.deleteAll()
        onChange?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
}
