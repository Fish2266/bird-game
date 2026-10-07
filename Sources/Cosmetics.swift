import AppKit
import simd

// MARK: - Catalog

/// Where a cosmetic goes on the bird. One of each can be worn at a time.
enum CosmeticSlot: String, CaseIterable, Codable {
    case hat, eyes, neck, trail, paint

    var title: String {
        switch self {
        case .hat: return "Hats"
        case .eyes: return "Glasses"
        case .neck: return "Neck"
        case .trail: return "Trails"
        case .paint: return "Paint"
        }
    }
    /// One-letter key used in the compact outfit code sent over the network.
    var key: String {
        switch self { case .hat: return "h"; case .eyes: return "e"; case .neck: return "n"; case .trail: return "t"; case .paint: return "p" }
    }
}

enum Rarity: Int, Comparable {
    case common, rare, epic, legendary, earned
    static func < (a: Rarity, b: Rarity) -> Bool { a.rawValue < b.rawValue }

    var name: String { ["Common", "Rare", "Epic", "Legendary", "Earned"][rawValue] }
    var color: NSColor {
        switch self {
        case .common: return NSColor(srgbRed: 0.45, green: 0.62, blue: 0.70, alpha: 1)
        case .rare: return NSColor(srgbRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
        case .epic: return NSColor(srgbRed: 0.62, green: 0.35, blue: 0.92, alpha: 1)
        case .legendary: return NSColor(srgbRed: 0.93, green: 0.62, blue: 0.10, alpha: 1)
        case .earned: return NSColor(srgbRed: 0.20, green: 0.68, blue: 0.40, alpha: 1)
        }
    }
}

struct Cosmetic {
    let id: String
    let slot: CosmeticSlot
    let name: String
    let blurb: String
    /// Price in coins (0 for earned items and the free "Classic" paint).
    let cost: Int
    let rarity: Rarity
    /// Goal that awards it (earned items can't be bought).
    var goal: String? = nil
    /// Not shown anywhere until it's yours (the end of The Finale).
    var secret = false

    var earned: Bool { goal != nil }
}

enum CosmeticCatalog {
    static let all: [Cosmetic] = [
        // Hats
        Cosmetic(id: "party", slot: .hat, name: "Party Hat", blurb: "Every flight's a celebration.", cost: 60, rarity: .common),
        Cosmetic(id: "beanie", slot: .hat, name: "Beanie", blurb: "Knitted, cosy, pom-pom on top.", cost: 80, rarity: .common),
        Cosmetic(id: "cap", slot: .hat, name: "Backwards Cap", blurb: "Too cool to face forward.", cost: 90, rarity: .common),
        Cosmetic(id: "propeller", slot: .hat, name: "Propeller Cap", blurb: "The faster you fly, the faster it spins.", cost: 180, rarity: .rare),
        Cosmetic(id: "chef", slot: .hat, name: "Chef's Hat", blurb: "Cooking up a storm.", cost: 200, rarity: .rare),
        Cosmetic(id: "tophat", slot: .hat, name: "Top Hat", blurb: "Very distinguished. Very tall.", cost: 220, rarity: .rare),
        Cosmetic(id: "sombrero", slot: .hat, name: "Sombrero", blurb: "A wide brim for a big fiesta.", cost: 240, rarity: .rare),
        Cosmetic(id: "cowboy", slot: .hat, name: "Cowboy Hat", blurb: "Yee-haw.", cost: 250, rarity: .rare),
        Cosmetic(id: "pirate", slot: .hat, name: "Pirate Hat", blurb: "A captain's hat with gold trim.", cost: 400, rarity: .epic),
        Cosmetic(id: "wizard", slot: .hat, name: "Wizard Hat", blurb: "Tall, starry and slightly bent.", cost: 450, rarity: .epic),
        Cosmetic(id: "unicorn", slot: .hat, name: "Unicorn Horn", blurb: "A pearly, spiralled horn.", cost: 500, rarity: .epic),
        Cosmetic(id: "crown", slot: .hat, name: "Crown", blurb: "Solid gold with real gems. For royalty only.", cost: 1200, rarity: .legendary),
        Cosmetic(id: "grad", slot: .hat, name: "Graduation Cap", blurb: "Proof you finished flight school.", cost: 0, rarity: .earned, goal: "tutorial"),
        Cosmetic(id: "explorer", slot: .hat, name: "Explorer's Hat", blurb: "For flying in four different worlds.", cost: 0, rarity: .earned, goal: "worlds"),
        Cosmetic(id: "viking", slot: .hat, name: "Viking Helmet", blurb: "For beating the Hard bots.", cost: 0, rarity: .earned, goal: "fightHard"),
        Cosmetic(id: "halo", slot: .hat, name: "Halo", blurb: "Glows. For flying through 1,000 rings.", cost: 0, rarity: .earned, goal: "rings1000"),
        Cosmetic(id: "dinohood", slot: .hat, name: "Dino Hood", blurb: "Rawr. For finding every secret in Dino Valley.", cost: 0, rarity: .earned, goal: "paleo"),
        Cosmetic(id: "skycrown", slot: .hat, name: "Crown of the Sky", blurb: "Placed on your head by the King himself, at the end of everything.",
                 cost: 0, rarity: .earned, goal: "finale", secret: true),

        // Glasses
        Cosmetic(id: "shades", slot: .eyes, name: "Sunglasses", blurb: "Classic black shades.", cost: 60, rarity: .common),
        Cosmetic(id: "nerd", slot: .eyes, name: "Nerd Glasses", blurb: "Thick frames, taped in the middle.", cost: 70, rarity: .common),
        Cosmetic(id: "threed", slot: .eyes, name: "3D Glasses", blurb: "Red and blue. Everything pops.", cost: 80, rarity: .common),
        Cosmetic(id: "heartglasses", slot: .eyes, name: "Heart Glasses", blurb: "Seeing the world through pink lenses.", cost: 160, rarity: .rare),
        Cosmetic(id: "starshades", slot: .eyes, name: "Star Shades", blurb: "For the star of the show.", cost: 180, rarity: .rare),
        Cosmetic(id: "aviators", slot: .eyes, name: "Aviators", blurb: "Gold wire and gradient lenses. Every pilot's pick.", cost: 220, rarity: .rare),
        Cosmetic(id: "goggles", slot: .eyes, name: "Ski Goggles", blurb: "Big mirrored lens, strap all the way round.", cost: 250, rarity: .rare),
        Cosmetic(id: "monocle", slot: .eyes, name: "Monocle", blurb: "Positively splendid.", cost: 400, rarity: .epic),
        Cosmetic(id: "pixel", slot: .eyes, name: "Pixel Shades", blurb: "Deal with it.", cost: 450, rarity: .epic),
        Cosmetic(id: "visor", slot: .eyes, name: "Cyber Visor", blurb: "A glowing band from the future.", cost: 1000, rarity: .legendary),

        // Neck
        Cosmetic(id: "bowtie", slot: .neck, name: "Bow Tie", blurb: "Red with white polka dots.", cost: 70, rarity: .common),
        Cosmetic(id: "bandana", slot: .neck, name: "Bandana", blurb: "Ready for adventure.", cost: 80, rarity: .common),
        Cosmetic(id: "bell", slot: .neck, name: "Bell Collar", blurb: "A shiny golden bell.", cost: 90, rarity: .common),
        Cosmetic(id: "scarf", slot: .neck, name: "Aviator Scarf", blurb: "Flutters behind you in the wind.", cost: 250, rarity: .rare),
        Cosmetic(id: "rainbowscarf", slot: .neck, name: "Rainbow Scarf", blurb: "Every colour, flapping in the breeze.", cost: 500, rarity: .epic),
        Cosmetic(id: "medal", slot: .neck, name: "Gold Medal", blurb: "For winning your first gold medal.", cost: 0, rarity: .earned, goal: "gold"),
        Cosmetic(id: "lei", slot: .neck, name: "Flower Lei", blurb: "For flying with friends over LAN.", cost: 0, rarity: .earned, goal: "lan"),
        Cosmetic(id: "sheriff", slot: .neck, name: "Sheriff's Star", blurb: "For finding every secret in the Wild West.", cost: 0, rarity: .earned, goal: "sheriff"),

        // Trails
        Cosmetic(id: "contrails", slot: .trail, name: "Contrails", blurb: "White vapour streams off your wingtips.", cost: 100, rarity: .common),
        Cosmetic(id: "sparkles", slot: .trail, name: "Sparkles", blurb: "A glittering stream of gold.", cost: 120, rarity: .common),
        Cosmetic(id: "bubbles", slot: .trail, name: "Bubbles", blurb: "Floaty, shiny bubbles.", cost: 120, rarity: .common),
        Cosmetic(id: "hearts", slot: .trail, name: "Hearts", blurb: "Spread the love.", cost: 250, rarity: .rare),
        Cosmetic(id: "leaves", slot: .trail, name: "Autumn Leaves", blurb: "Red and gold leaves tumbling behind you.", cost: 250, rarity: .rare),
        Cosmetic(id: "snow", slot: .trail, name: "Snowflakes", blurb: "A flurry follows you everywhere.", cost: 250, rarity: .rare),
        Cosmetic(id: "notes", slot: .trail, name: "Music Notes", blurb: "Fly to your own tune.", cost: 280, rarity: .rare),
        Cosmetic(id: "confetti", slot: .trail, name: "Confetti", blurb: "Party wherever you go.", cost: 300, rarity: .rare),
        Cosmetic(id: "smoke", slot: .trail, name: "Airshow Smoke", blurb: "Red, white and blue, like an airshow team.", cost: 500, rarity: .epic),
        Cosmetic(id: "rainbow", slot: .trail, name: "Rainbow", blurb: "A rainbow ribbon from your tail.", cost: 600, rarity: .epic),
        Cosmetic(id: "fire", slot: .trail, name: "Fire", blurb: "Flames lick off your wingtips.", cost: 650, rarity: .epic),
        Cosmetic(id: "neon", slot: .trail, name: "Neon", blurb: "Glowing pink and blue light streaks.", cost: 1000, rarity: .legendary),
        Cosmetic(id: "stardust", slot: .trail, name: "Stardust", blurb: "A shimmering tail of stars.", cost: 1400, rarity: .legendary),

        // Paint
        Cosmetic(id: "classic", slot: .paint, name: "Classic", blurb: "Each bird's own natural colours.", cost: 0, rarity: .common),
        Cosmetic(id: "snowy", slot: .paint, name: "Snowy", blurb: "Clean white with frosty wingtips.", cost: 100, rarity: .common),
        Cosmetic(id: "robin", slot: .paint, name: "Robin", blurb: "Orange breast, brown back.", cost: 100, rarity: .common),
        Cosmetic(id: "bluejay", slot: .paint, name: "Blue Jay", blurb: "Bright blue with a white front.", cost: 120, rarity: .common),
        Cosmetic(id: "flamingo", slot: .paint, name: "Flamingo", blurb: "Pink all over, black wingtips.", cost: 200, rarity: .rare),
        Cosmetic(id: "sunset", slot: .paint, name: "Sunset", blurb: "Orange fading to pink and purple.", cost: 250, rarity: .rare),
        Cosmetic(id: "tropical", slot: .paint, name: "Tropical", blurb: "Parrot colours: green, blue, red and yellow.", cost: 250, rarity: .rare),
        Cosmetic(id: "candy", slot: .paint, name: "Cotton Candy", blurb: "Soft pastel pink, mint and lilac.", cost: 250, rarity: .rare),
        Cosmetic(id: "camo", slot: .paint, name: "Camo", blurb: "Now you see me…", cost: 400, rarity: .epic),
        Cosmetic(id: "tiger", slot: .paint, name: "Tiger", blurb: "Orange with bold black stripes.", cost: 450, rarity: .epic),
        Cosmetic(id: "midnight", slot: .paint, name: "Midnight", blurb: "Deep navy with glowing wingtips.", cost: 500, rarity: .epic),
        Cosmetic(id: "neonpaint", slot: .paint, name: "Neon", blurb: "Black with glowing pink and cyan.", cost: 900, rarity: .legendary),
        Cosmetic(id: "chrome", slot: .paint, name: "Chrome", blurb: "Polished mirror silver.", cost: 1000, rarity: .legendary),
        Cosmetic(id: "galaxy", slot: .paint, name: "Galaxy", blurb: "A night sky full of twinkling stars.", cost: 1500, rarity: .legendary),
        Cosmetic(id: "gold", slot: .paint, name: "Solid Gold", blurb: "For winning gold on four different courses.", cost: 0, rarity: .earned, goal: "gold4"),
    ]

    static func item(_ id: String?, _ slot: CosmeticSlot) -> Cosmetic? {
        guard let id else { return nil }
        return all.first { $0.id == id && $0.slot == slot }
    }
    static func items(_ slot: CosmeticSlot) -> [Cosmetic] { all.filter { $0.slot == slot } }
    /// Free items everyone owns from the start.
    static func isFree(_ c: Cosmetic) -> Bool { c.cost == 0 && !c.earned }
}

// MARK: - Outfit

/// What a bird is wearing: at most one item per slot (nil = nothing; paint nil = Classic).
struct Outfit: Codable, Equatable {
    var hat: String?
    var eyes: String?
    var neck: String?
    var trail: String?
    var paint: String?

    subscript(_ s: CosmeticSlot) -> String? {
        get {
            switch s { case .hat: return hat; case .eyes: return eyes; case .neck: return neck; case .trail: return trail; case .paint: return paint }
        }
        set {
            switch s {
            case .hat: hat = newValue
            case .eyes: eyes = newValue
            case .neck: neck = newValue
            case .trail: trail = newValue
            case .paint: paint = newValue == "classic" ? nil : newValue
            }
        }
    }

    var isEmpty: Bool { CosmeticSlot.allCases.allSatisfy { self[$0] == nil } }

    /// Compact form for the network, e.g. "h=crown,e=shades,t=rainbow".
    var code: String {
        CosmeticSlot.allCases.compactMap { s in self[s].map { "\(s.key)=\($0)" } }.joined(separator: ",")
    }

    init() {}

    /// Parses `code`, ignoring anything unknown (an item from a newer version just isn't shown).
    init(code: String) {
        for part in code.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let slot = CosmeticSlot.allCases.first(where: { $0.key == kv[0] }),
                  CosmeticCatalog.item(kv[1], slot) != nil else { continue }
            self[slot] = kv[1]
        }
    }

    /// A random outfit for a bot (so players see what's in the shop).
    static func random(_ rng: inout SplitMix64) -> Outfit {
        var o = Outfit()
        let odds: [(CosmeticSlot, Float)] = [(.hat, 0.7), (.eyes, 0.4), (.neck, 0.3), (.trail, 0.35), (.paint, 0.45)]
        for (slot, p) in odds where rng.float() < p {
            let pool = CosmeticCatalog.items(slot).filter { $0.id != "classic" }
            o[slot] = pool[min(Int(rng.float() * Float(pool.count)), pool.count - 1)].id
        }
        return o
    }
}

// MARK: - Paint jobs

struct PaintJob {
    var body: SIMD3<Float>
    var back: SIMD3<Float>
    var head: SIMD3<Float>
    var wingRoot: SIMD3<Float>
    var wingMid: SIMD3<Float>
    var wingTip: SIMD3<Float>
    var tail: SIMD3<Float>
    var beak: SIMD3<Float>
    /// Wing-tip glow (0 = none). Paints replace the species' own glow.
    var glow: Float = 0
    var metal: Float = 0
    var pattern: BirdPattern? = nil
}

enum BirdPattern { case camo, tiger, galaxy, speckle }

enum Paints {
    static func job(_ id: String?) -> PaintJob? {
        switch id {
        case "snowy":
            return PaintJob(body: SIMD3(0.96, 0.97, 0.98), back: SIMD3(0.86, 0.89, 0.93), head: SIMD3(0.97, 0.97, 0.98),
                            wingRoot: SIMD3(0.93, 0.94, 0.96), wingMid: SIMD3(0.84, 0.88, 0.93), wingTip: SIMD3(0.62, 0.72, 0.86),
                            tail: SIMD3(0.90, 0.92, 0.95), beak: SIMD3(1.0, 0.72, 0.25))
        case "robin":
            return PaintJob(body: SIMD3(0.95, 0.52, 0.22), back: SIMD3(0.40, 0.33, 0.27), head: SIMD3(0.28, 0.24, 0.21),
                            wingRoot: SIMD3(0.45, 0.38, 0.30), wingMid: SIMD3(0.36, 0.30, 0.24), wingTip: SIMD3(0.18, 0.15, 0.13),
                            tail: SIMD3(0.26, 0.22, 0.19), beak: SIMD3(0.95, 0.78, 0.25))
        case "bluejay":
            return PaintJob(body: SIMD3(0.93, 0.95, 0.98), back: SIMD3(0.22, 0.42, 0.85), head: SIMD3(0.28, 0.50, 0.92),
                            wingRoot: SIMD3(0.28, 0.52, 0.95), wingMid: SIMD3(0.16, 0.36, 0.82), wingTip: SIMD3(0.06, 0.09, 0.18),
                            tail: SIMD3(0.20, 0.40, 0.86), beak: SIMD3(0.14, 0.14, 0.16))
        case "flamingo":
            return PaintJob(body: SIMD3(1.0, 0.62, 0.72), back: SIMD3(0.95, 0.47, 0.60), head: SIMD3(1.0, 0.68, 0.77),
                            wingRoot: SIMD3(1.0, 0.60, 0.71), wingMid: SIMD3(0.95, 0.42, 0.58), wingTip: SIMD3(0.16, 0.10, 0.12),
                            tail: SIMD3(0.95, 0.50, 0.64), beak: SIMD3(0.98, 0.88, 0.80))
        case "sunset":
            return PaintJob(body: SIMD3(1.0, 0.80, 0.55), back: SIMD3(0.95, 0.48, 0.36), head: SIMD3(1.0, 0.62, 0.40),
                            wingRoot: SIMD3(1.0, 0.66, 0.28), wingMid: SIMD3(0.96, 0.36, 0.45), wingTip: SIMD3(0.46, 0.24, 0.62),
                            tail: SIMD3(0.85, 0.35, 0.52), beak: SIMD3(0.38, 0.22, 0.32))
        case "tropical":
            return PaintJob(body: SIMD3(0.30, 0.78, 0.36), back: SIMD3(0.14, 0.55, 0.30), head: SIMD3(0.95, 0.22, 0.20),
                            wingRoot: SIMD3(0.20, 0.56, 0.96), wingMid: SIMD3(0.14, 0.40, 0.86), wingTip: SIMD3(0.99, 0.84, 0.16),
                            tail: SIMD3(0.97, 0.56, 0.12), beak: SIMD3(0.22, 0.22, 0.24))
        case "candy":
            return PaintJob(body: SIMD3(1.0, 0.70, 0.84), back: SIMD3(0.56, 0.80, 1.0), head: SIMD3(0.76, 0.64, 1.0),
                            wingRoot: SIMD3(1.0, 0.64, 0.82), wingMid: SIMD3(0.50, 0.86, 0.84), wingTip: SIMD3(0.66, 0.56, 1.0),
                            tail: SIMD3(1.0, 0.84, 0.50), beak: SIMD3(1.0, 0.55, 0.70))
        case "camo":
            return PaintJob(body: SIMD3(0.62, 0.62, 0.42), back: SIMD3(0.46, 0.50, 0.30), head: SIMD3(0.50, 0.54, 0.32),
                            wingRoot: SIMD3(0.54, 0.56, 0.34), wingMid: SIMD3(0.44, 0.46, 0.28), wingTip: SIMD3(0.36, 0.34, 0.24),
                            tail: SIMD3(0.42, 0.44, 0.28), beak: SIMD3(0.30, 0.27, 0.22), pattern: .camo)
        case "tiger":
            return PaintJob(body: SIMD3(1.0, 0.86, 0.66), back: SIMD3(0.98, 0.52, 0.12), head: SIMD3(0.98, 0.56, 0.14),
                            wingRoot: SIMD3(1.0, 0.60, 0.16), wingMid: SIMD3(0.96, 0.50, 0.10), wingTip: SIMD3(0.90, 0.42, 0.08),
                            tail: SIMD3(0.95, 0.50, 0.12), beak: SIMD3(0.20, 0.18, 0.16), pattern: .tiger)
        case "midnight":
            return PaintJob(body: SIMD3(0.16, 0.18, 0.30), back: SIMD3(0.09, 0.10, 0.18), head: SIMD3(0.12, 0.13, 0.24),
                            wingRoot: SIMD3(0.14, 0.17, 0.34), wingMid: SIMD3(0.10, 0.16, 0.36), wingTip: SIMD3(0.25, 0.85, 1.0),
                            tail: SIMD3(0.10, 0.12, 0.26), beak: SIMD3(0.95, 0.80, 0.32), glow: 0.9)
        case "neonpaint":
            return PaintJob(body: SIMD3(0.12, 0.12, 0.15), back: SIMD3(0.07, 0.07, 0.09), head: SIMD3(0.09, 0.09, 0.12),
                            wingRoot: SIMD3(0.14, 0.12, 0.18), wingMid: SIMD3(0.92, 0.12, 0.74), wingTip: SIMD3(0.12, 1.0, 0.88),
                            tail: SIMD3(0.92, 0.12, 0.74), beak: SIMD3(0.12, 1.0, 0.88), glow: 1.2)
        case "chrome":
            return PaintJob(body: SIMD3(0.90, 0.92, 0.95), back: SIMD3(0.78, 0.80, 0.84), head: SIMD3(0.92, 0.93, 0.96),
                            wingRoot: SIMD3(0.88, 0.90, 0.94), wingMid: SIMD3(0.76, 0.79, 0.84), wingTip: SIMD3(0.55, 0.58, 0.64),
                            tail: SIMD3(0.82, 0.84, 0.88), beak: SIMD3(0.95, 0.80, 0.35), metal: 0.92)
        case "galaxy":
            return PaintJob(body: SIMD3(0.26, 0.18, 0.46), back: SIMD3(0.14, 0.10, 0.30), head: SIMD3(0.20, 0.14, 0.40),
                            wingRoot: SIMD3(0.30, 0.20, 0.56), wingMid: SIMD3(0.16, 0.14, 0.44), wingTip: SIMD3(0.08, 0.10, 0.28),
                            tail: SIMD3(0.18, 0.12, 0.40), beak: SIMD3(0.95, 0.85, 0.50), pattern: .galaxy)
        case "gold":
            return PaintJob(body: SIMD3(1.0, 0.76, 0.30), back: SIMD3(0.95, 0.66, 0.20), head: SIMD3(1.0, 0.78, 0.33),
                            wingRoot: SIMD3(1.0, 0.79, 0.36), wingMid: SIMD3(0.95, 0.68, 0.22), wingTip: SIMD3(0.80, 0.50, 0.12),
                            tail: SIMD3(0.95, 0.70, 0.24), beak: SIMD3(1.0, 0.95, 0.80), metal: 0.9)
        default:
            return nil
        }
    }
}

extension BirdLook {
    /// This species' shape in a paint job's colors (nil or "classic" = unchanged).
    func painted(_ id: String?) -> BirdLook {
        guard let p = Paints.job(id) else { return self }
        var l = self
        l.body = p.body; l.back = p.back; l.head = p.head
        l.wingRoot = p.wingRoot; l.wingMid = p.wingMid; l.wingTip = p.wingTip
        l.tail = p.tail; l.beak = p.beak
        l.glow = p.glow
        // A painted glow lights up only the wing tips (a species glow warms the whole bird).
        l.tipGlow = p.glow > 0
        l.metal = p.metal
        l.pattern = p.pattern
        // A throat patch takes the paint's head color.
        if l.throat != nil { l.throat = p.head }
        return l
    }
}
