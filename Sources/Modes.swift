import AppKit
import simd

// Game modes, rules and the wire types live in Shared/LANProtocol.swift (Bird Server compiles them too).

struct MatchResult {
    var title: String
    var standings: [Standing]
    /// Coins this player earned for the match.
    var coins: Int = 0
    var personalBest = false
    var footer = ""
}

// MARK: - Nametag colors

extension NameColors {
    static func ns(_ i: Int, alpha: CGFloat = 1) -> NSColor {
        let c = color(i)
        return NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
    }
}

/// Race medals: beat the course's target times.
enum Medal: Int, Comparable {
    case bronze = 1, silver, gold
    var name: String { ["", "Bronze", "Silver", "Gold"][rawValue] }
    /// Coin bonus for finishing with this medal (doubled the first time you win it on a course).
    var coins: Int { [0, 15, 30, 50][rawValue] }
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
