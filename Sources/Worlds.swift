import AppKit
import SceneKit
import simd

// MARK: - Catalog (what the shop shows)

enum WorldID: String, CaseIterable {
    case meadow, volcano, caves, dogfight, city, dino, west
    /// The eighth world: opens when every goal is done.
    case finale
}

struct WorldInfo {
    let id: String
    let name: String
    let blurb: String
    let cost: Int
    /// Coins per ring are multiplied by this (and by the streak bonus in challenge worlds).
    let ringMultiplier: Float
    /// Extra speed (m/s) each ring gives you.
    let ringBoost: Float
    let hazards: String
    let comingSoon: Bool
    /// Colors for the little preview painting: sky top, sky bottom, ground, accent.
    let art: [SIMD3<Float>]
    var kind: WorldID? { WorldID(rawValue: id) }
    /// Challenge worlds have streaks, hazards and coin penalties. World 1 has none of that.
    var isChallenge: Bool { kind != nil && kind != .meadow }
    /// Ring multiplier as shown in the shop ("×1.5").
    var multiplierText: String { ringMultiplier == ringMultiplier.rounded() ? "×\(Int(ringMultiplier))" : String(format: "×%.1f", ringMultiplier) }
    /// Harder worlds pay a little more for finishing a race.
    var raceBonus: Float {
        switch kind {
        case .volcano?: return 1.15
        case .caves?: return 1.3
        case .dogfight?: return 1.2
        case .city?: return 1.3
        case .dino?: return 1.25
        case .west?: return 1.25
        case .finale?: return 1.5
        default: return 1
        }
    }
    var isFinale: Bool { kind == .finale }
}

enum WorldCatalog {
    static let all: [WorldInfo] = [
        WorldInfo(id: "meadow", name: "Home Isles", blurb: "The original islands. Calm skies, open ocean, mountains to soar over. No hazards, just flying.",
                  cost: 0, ringMultiplier: 1, ringBoost: 5, hazards: "None", comingSoon: false,
                  art: [SIMD3(0.38, 0.62, 0.92), SIMD3(0.80, 0.87, 0.95), SIMD3(0.36, 0.52, 0.22), SIMD3(0.10, 0.35, 0.50)]),
        WorldInfo(id: "volcano", name: "Volcano", blurb: "Lava lakes and smoking cones. Geysers blast lava into the sky, but the heat over the lava gives you free lift.",
                  cost: 250, ringMultiplier: 1.5, ringBoost: 10, hazards: "Lava geysers, lava lakes", comingSoon: false,
                  art: [SIMD3(0.30, 0.22, 0.30), SIMD3(0.90, 0.50, 0.32), SIMD3(0.20, 0.17, 0.17), SIMD3(1.00, 0.45, 0.10)]),
        WorldInfo(id: "caves", name: "Glow Caves", blurb: "Mossy tunnels lit by glowing mushrooms. Follow the passages up and down, from tight squeezes to huge caverns.",
                  cost: 400, ringMultiplier: 2, ringBoost: 6, hazards: "Walls, low ceilings", comingSoon: false,
                  art: [SIMD3(0.03, 0.08, 0.10), SIMD3(0.08, 0.20, 0.20), SIMD3(0.16, 0.30, 0.16), SIMD3(0.35, 0.95, 0.90)]),
        WorldInfo(id: "dogfight", name: "Dogfight", blurb: "Patchwork farmland under a big sky, patrolled by WWI biplanes. Stay out of their sights.",
                  cost: 600, ringMultiplier: 1.5, ringBoost: 12, hazards: "Biplanes that shoot", comingSoon: false,
                  art: [SIMD3(0.52, 0.66, 0.84), SIMD3(0.88, 0.86, 0.80), SIMD3(0.62, 0.64, 0.30), SIMD3(0.80, 0.15, 0.12)]),
        WorldInfo(id: "city", name: "Skyline City", blurb: "Thread the street canyons between glass towers. Traffic below, bird people on the sidewalks, trains overhead, bridges to dive under — and a subway to find below the streets.",
                  cost: 500, ringMultiplier: 1.5, ringBoost: 9, hazards: "Buildings, trains, cranes", comingSoon: false,
                  art: [SIMD3(0.36, 0.55, 0.85), SIMD3(0.98, 0.80, 0.62), SIMD3(0.30, 0.33, 0.38), SIMD3(1.00, 0.80, 0.25)]),
        WorldInfo(id: "dino", name: "Dino Valley", blurb: "A misty prehistoric valley where giant dinosaurs roam, graze and fight. Fly under the long necks, dodge the volcano's lava bombs, and don't get too close to a T. rex.",
                  cost: 700, ringMultiplier: 1.3, ringBoost: 10, hazards: "T. rex bites, tails, pterosaurs, lava bombs", comingSoon: false,
                  art: [SIMD3(0.55, 0.70, 0.78), SIMD3(0.92, 0.88, 0.72), SIMD3(0.26, 0.42, 0.18), SIMD3(0.55, 0.36, 0.20)]),
        WorldInfo(id: "west", name: "Wild West", blurb: "Frontier towns with saloons on the rim of a giant canyon. Dive between the cliffs, race the steam train, fly under the trestle and hunt for gold in the old mines.",
                  cost: 600, ringMultiplier: 1.2, ringBoost: 12, hazards: "Canyon walls, steam trains, dust devils", comingSoon: false,
                  art: [SIMD3(0.40, 0.62, 0.90), SIMD3(0.98, 0.78, 0.52), SIMD3(0.74, 0.40, 0.22), SIMD3(0.95, 0.85, 0.55)]),
        WorldInfo(id: "finale", name: "The Finale", blurb: "The castle where the champions of the sky are crowned. Its towers, its great hall and its gardens are yours to fly, and the whole kingdom is celebrating.",
                  cost: 0, ringMultiplier: 2, ringBoost: 14, hazards: "None. It's a party", comingSoon: false,
                  art: [SIMD3(0.18, 0.14, 0.32), SIMD3(0.98, 0.62, 0.42), SIMD3(0.22, 0.42, 0.24), SIMD3(1.00, 0.82, 0.30)]),
    ]

    /// What the locked Finale says about itself.
    static let finaleTeaser = "Something is waiting at the end of the road. Finish every goal to find out what."

    static func info(_ id: String) -> WorldInfo { all.first { $0.id == id } ?? all[0] }

    /// The one-time discoveries hidden in each world (their reward ids), for the goals and the "secrets found" counts.
    static let secrets: [String: [String]] = [
        "city": ["city.subway", "city.bridge", "city.el", "city.heli", "city.blimp"],
        "dino": ["dino.fight", "dino.under", "dino.crater", "dino.eruption", "dino.skeleton", "dino.nest", "dino.waterfall"],
        "west": ["west.saloon", "west.mine", "west.gold", "west.trestle", "west.trestle.train", "west.train", "west.river", "west.stampede"],
    ]

    /// What each secret is once found, and a clue to it before (shown on the world's page in the menu).
    static let secretInfo: [String: (name: String, clue: String)] = [
        "city.subway": ("Found the subway", "Some street corners have stairs down to the subway. Fly down into it."),
        "city.bridge": ("Flew under a bridge", "A river winds through the city. Fly under one of its road bridges."),
        "city.el": ("Raced the elevated train", "A train runs on tracks above the streets. Fly alongside it."),
        "city.heli": ("Buzzed the helicopter", "A news helicopter circles over the city. Fly right up to it."),
        "city.blimp": ("Flew under the blimp", "A blimp drifts high above the city. Fly right underneath it."),
        "dino.fight": ("Saw a dinosaur fight", "Big dinosaurs sometimes fight each other. Find a fight and watch it."),
        "dino.under": ("Flew under a Brachiosaurus", "The long-necked dinosaurs are very tall. Fly under one, between its legs."),
        "dino.crater": ("Flew into the volcano", "The volcano has a crater at the top. Fly down inside it."),
        "dino.eruption": ("Braved the eruption", "Stay close to the volcano through an eruption without getting hit."),
        "dino.skeleton": ("Flew through a giant skeleton", "Giant fossil skeletons lie in the valley. Fly through one."),
        "dino.nest": ("Found a dinosaur nest", "Dinosaurs guard nests of eggs on the ground. Fly low over one."),
        "dino.waterfall": ("Flew through a waterfall", "Waterfalls pour off the cliffs. Fly straight through one."),
        "west.saloon": ("Flew through the saloon", "Every town has a saloon with doors front and back. Fly through it."),
        "west.mine": ("Flew through the old mine", "Old mine tunnels lead into the hills. Fly all the way through one."),
        "west.gold": ("Found gold in the mine", "Gold nuggets glint inside the old mines. Grab one."),
        "west.trestle": ("Flew under the trestle", "The railroad crosses the canyon on a tall wooden trestle. Fly under it."),
        "west.trestle.train": ("The train thundered over you", "Fly under a trestle while the train is crossing it."),
        "west.train": ("Raced the steam train", "A steam train runs between the towns. Fly alongside its engine."),
        "west.river": ("Skimmed the canyon river", "A river runs along the bottom of the canyon. Skim it."),
        "west.stampede": ("Started a stampede", "Longhorn cattle graze near the towns. Swoop low and fast over them."),
    ]
}

// MARK: - Terrain interface

/// Everything the renderer and physics need to know about a world's ground (and, in caves, its ceiling).
protocol WorldTerrain: AnyObject {
    /// Water (or lava) surface height; `-1e9` when a world has none.
    var waterLevel: Float { get }
    var chunkSize: Float { get }
    var cells: Int { get }
    /// Cells for the far level of detail, or nil for no LOD.
    var lowCells: Int? { get }
    var lodDistance: Float { get }
    var radius: Int { get }
    func height(_ x: Float, _ z: Float) -> Float
    /// Cave worlds have a ceiling; open worlds return nil.
    func ceiling(_ x: Float, _ z: Float) -> Float?
    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float>
    func ceilingColor(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float>
    /// Adds trees, rocks, mushrooms…; `glow` holds self-lit pieces.
    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float)
    /// Restyle the shared ground and glow materials once (street paint, rock layers…).
    func configure(ground: SCNMaterial, glow: SCNMaterial)
    /// More pieces of a chunk with materials of their own (buildings, props), in chunk-local coordinates.
    /// Built on the terrain threads like the rest of the chunk.
    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode]
    /// Ground cells (by centre) left out of the mesh: openings down into something underground.
    func isHole(_ x: Float, _ z: Float) -> Bool
    /// The floor under a point that's underground (a tunnel), or nil to use the ground. Collisions only.
    func tunnelFloor(_ x: Float, _ z: Float, _ y: Float) -> Float?
    /// How close (m) a chunk has to be for its close-up detail to be built (0: no detail layer).
    var detailDistance: Float { get }
    /// Close-up detail for a chunk (street furniture, plants, the subway…), in chunk-local coordinates. Built only
    /// near the player and dropped again further out, so it costs no memory far away. Parts of the main chunk named
    /// "swap:…" are hidden while the detail is loaded (they're its stand-ins).
    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode]
}

extension WorldTerrain {
    func ceiling(_ x: Float, _ z: Float) -> Float? { nil }
    func ceilingColor(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> { SIMD3(0.2, 0.2, 0.22) }
    func configure(ground: SCNMaterial, glow: SCNMaterial) {}
    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] { [] }
    func isHole(_ x: Float, _ z: Float) -> Bool { false }
    func tunnelFloor(_ x: Float, _ z: Float, _ y: Float) -> Float? { nil }
    var detailDistance: Float { 0 }
    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] { [] }
}

// MARK: - Look & feel per world

enum SurfaceKind { case ocean, river, lava, none }
enum MoteKind { case dust, embers, fireflies, pollen, sand }

struct WorldVisuals {
    var horizon = Sky.horizon
    var zenith = Sky.zenith
    var below = SIMD3<Float>(0.62, 0.70, 0.78)
    var sunDir = Sky.sunDir
    var sunGlow = SIMD3<Float>(1.0, 0.92, 0.75)
    var sunColor = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1)
    var sunIntensity: CGFloat = 2300
    var shadows = true
    var envIntensity: CGFloat = 1.25
    var fogStart: CGFloat = 350
    var fogEnd: CGFloat = 2100
    var fogColor: SIMD3<Float>? = nil     // defaults to the horizon color
    var cloudCount = 34
    var cloudHeight: ClosedRange<Float> = 240...460
    var cloudTint: SIMD3<Float>? = nil
    var surface = SurfaceKind.ocean
    /// Water colour (nil = the Home Isles ocean).
    var waterColor: SIMD3<Float>? = nil
    var motes = MoteKind.dust
    var flockCount = 5
    var zFar: CGFloat = 5000
    var exposure: CGFloat = 0.15

    static let meadow = WorldVisuals()

    static let volcano: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.86, 0.50, 0.36)
        v.zenith = SIMD3(0.28, 0.22, 0.32)
        v.below = SIMD3(0.45, 0.28, 0.24)
        v.sunDir = simd_normalize(SIMD3(-0.6, 0.42, 0.7))
        v.sunGlow = SIMD3(1.0, 0.62, 0.35)
        v.sunColor = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.52, alpha: 1)
        v.sunIntensity = 1700
        v.envIntensity = 1.0
        v.fogStart = 150
        v.fogEnd = 1500
        v.fogColor = SIMD3(0.62, 0.36, 0.30)
        v.cloudCount = 26
        v.cloudHeight = 180...360
        v.cloudTint = SIMD3(0.42, 0.38, 0.38)
        v.surface = .lava
        v.motes = .embers
        v.flockCount = 3
        return v
    }()

    static let caves: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.04, 0.10, 0.11)
        v.zenith = SIMD3(0.02, 0.05, 0.06)
        v.below = SIMD3(0.03, 0.07, 0.08)
        v.sunGlow = .zero
        v.sunIntensity = 0
        v.shadows = false
        v.envIntensity = 0.6
        v.fogStart = 25
        v.fogEnd = 190
        v.cloudCount = 0
        v.surface = .none
        v.motes = .fireflies
        v.flockCount = 0
        v.zFar = 400
        v.exposure = 0.05
        return v
    }()

    static let dogfight: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.86, 0.87, 0.86)
        v.zenith = SIMD3(0.40, 0.56, 0.80)
        v.below = SIMD3(0.66, 0.70, 0.72)
        v.sunDir = simd_normalize(SIMD3(0.4, 0.55, 0.7))
        v.sunIntensity = 2100
        v.fogStart = 300
        v.fogEnd = 2000
        v.cloudCount = 46
        v.cloudHeight = 170...420
        v.flockCount = 3
        return v
    }()

    /// Late afternoon over the city: warm low sun, long shadows down the avenues, a golden haze on the skyline.
    static let city: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.94, 0.81, 0.69)
        v.zenith = SIMD3(0.30, 0.50, 0.82)
        v.below = SIMD3(0.56, 0.56, 0.60)
        v.sunDir = simd_normalize(SIMD3(-0.55, 0.42, 0.62))
        v.sunGlow = SIMD3(1.0, 0.76, 0.52)
        v.sunColor = NSColor(srgbRed: 1.0, green: 0.88, blue: 0.75, alpha: 1)
        v.sunIntensity = 2150
        v.envIntensity = 1.35
        v.fogStart = 300
        v.fogEnd = 2550
        v.fogColor = SIMD3(0.86, 0.78, 0.72)
        v.cloudCount = 20
        v.cloudHeight = 430...700
        v.cloudTint = SIMD3(1.0, 0.95, 0.9)
        v.surface = .river
        v.waterColor = SIMD3(0.10, 0.22, 0.26)
        v.flockCount = 3
        v.zFar = 7000
        v.exposure = 0.1
        return v
    }()

    /// Humid and hazy: mist in the valleys, a warm sun through the haze.
    static let dino: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.82, 0.86, 0.80)
        v.zenith = SIMD3(0.36, 0.56, 0.80)
        v.below = SIMD3(0.50, 0.58, 0.50)
        v.sunDir = simd_normalize(SIMD3(0.5, 0.62, -0.6))
        v.sunGlow = SIMD3(1.0, 0.9, 0.7)
        v.sunColor = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.84, alpha: 1)
        v.sunIntensity = 2050
        v.envIntensity = 1.2
        v.fogStart = 200
        v.fogEnd = 2150
        v.fogColor = SIMD3(0.76, 0.82, 0.76)
        v.cloudCount = 30
        v.cloudHeight = 320...560
        v.surface = .river
        v.waterColor = SIMD3(0.10, 0.25, 0.20)
        v.motes = .pollen
        v.flockCount = 0
        v.zFar = 5500
        return v
    }()

    /// A clear desert afternoon: deep blue sky, warm light raking across the canyon's layers.
    static let west: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.98, 0.85, 0.68)
        v.zenith = SIMD3(0.26, 0.48, 0.86)
        v.below = SIMD3(0.70, 0.56, 0.44)
        v.sunDir = simd_normalize(SIMD3(0.62, 0.46, 0.52))
        v.sunGlow = SIMD3(1.0, 0.8, 0.52)
        v.sunColor = NSColor(srgbRed: 1.0, green: 0.88, blue: 0.70, alpha: 1)
        v.sunIntensity = 2300
        v.envIntensity = 1.25
        v.fogStart = 900
        v.fogEnd = 5200
        v.fogColor = SIMD3(0.95, 0.83, 0.70)
        v.cloudCount = 14
        v.cloudHeight = 520...820
        v.cloudTint = SIMD3(1.0, 0.96, 0.92)
        v.surface = .river
        v.waterColor = SIMD3(0.16, 0.30, 0.26)
        v.motes = .sand
        v.flockCount = 0
        v.zFar = 7500
        return v
    }()

    /// The Finale: a golden evening over the castle, the sun low behind the towers.
    static let finale: WorldVisuals = {
        var v = WorldVisuals()
        v.horizon = SIMD3(0.99, 0.72, 0.52)
        v.zenith = SIMD3(0.24, 0.30, 0.62)
        v.below = SIMD3(0.52, 0.48, 0.52)
        v.sunDir = simd_normalize(SIMD3(-0.55, 0.26, -0.79))
        v.sunGlow = SIMD3(1.0, 0.68, 0.40)
        v.sunColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.62, alpha: 1)
        v.sunIntensity = 2100
        v.envIntensity = 1.3
        v.fogStart = 700
        v.fogEnd = 4200
        v.fogColor = SIMD3(0.92, 0.70, 0.62)
        v.cloudCount = 22
        v.cloudHeight = 380...640
        v.cloudTint = SIMD3(1.0, 0.84, 0.76)
        v.surface = .ocean
        v.waterColor = SIMD3(0.14, 0.32, 0.42)
        v.motes = .fireflies
        v.flockCount = 4
        v.zFar = 7000
        return v
    }()
}
