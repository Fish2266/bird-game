import AppKit
import simd

// MARK: - Catalog (what the shop shows)

enum WorldID: String {
    case meadow, volcano, caves, dogfight
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
}

enum WorldCatalog {
    static let all: [WorldInfo] = [
        WorldInfo(id: "meadow", name: "Home Isles", blurb: "The original islands. Calm skies, open ocean, mountains to soar over. No hazards, just flying.",
                  cost: 0, ringMultiplier: 1, ringBoost: 5, hazards: "None", comingSoon: false,
                  art: [SIMD3(0.38, 0.62, 0.92), SIMD3(0.80, 0.87, 0.95), SIMD3(0.36, 0.52, 0.22), SIMD3(0.10, 0.35, 0.50)]),
        WorldInfo(id: "volcano", name: "Volcano", blurb: "Lava lakes and smoking cones. Geysers blast lava into the sky, but the heat over the lava gives you free lift.",
                  cost: 250, ringMultiplier: 2, ringBoost: 10, hazards: "Lava geysers, lava lakes", comingSoon: false,
                  art: [SIMD3(0.30, 0.22, 0.30), SIMD3(0.90, 0.50, 0.32), SIMD3(0.20, 0.17, 0.17), SIMD3(1.00, 0.45, 0.10)]),
        WorldInfo(id: "caves", name: "Glow Caves", blurb: "Mossy tunnels lit by glowing mushrooms. Follow the passages up and down, from tight squeezes to huge caverns.",
                  cost: 400, ringMultiplier: 3, ringBoost: 6, hazards: "Walls, low ceilings", comingSoon: false,
                  art: [SIMD3(0.03, 0.08, 0.10), SIMD3(0.08, 0.20, 0.20), SIMD3(0.16, 0.30, 0.16), SIMD3(0.35, 0.95, 0.90)]),
        WorldInfo(id: "dogfight", name: "Dogfight", blurb: "Patchwork farmland under a big sky, patrolled by WWI biplanes. Stay out of their sights.",
                  cost: 600, ringMultiplier: 3, ringBoost: 12, hazards: "Biplanes that shoot", comingSoon: false,
                  art: [SIMD3(0.52, 0.66, 0.84), SIMD3(0.88, 0.86, 0.80), SIMD3(0.62, 0.64, 0.30), SIMD3(0.80, 0.15, 0.12)]),
        WorldInfo(id: "storm", name: "Storm Coast", blurb: "Lightning, gusts and huge updrafts inside the thunderheads.",
                  cost: 0, ringMultiplier: 3, ringBoost: 10, hazards: "Lightning, wind", comingSoon: true,
                  art: [SIMD3(0.20, 0.24, 0.32), SIMD3(0.45, 0.50, 0.58), SIMD3(0.22, 0.30, 0.28), SIMD3(0.90, 0.92, 1.00)]),
        WorldInfo(id: "canyon", name: "Slot Canyon", blurb: "A narrow desert canyon built for speed.",
                  cost: 0, ringMultiplier: 3, ringBoost: 14, hazards: "Canyon walls", comingSoon: true,
                  art: [SIMD3(0.45, 0.65, 0.90), SIMD3(0.95, 0.85, 0.70), SIMD3(0.80, 0.45, 0.25), SIMD3(0.95, 0.70, 0.40)]),
        WorldInfo(id: "peaks", name: "Frozen Peaks", blurb: "Ride the wind up icy ridges. Watch for avalanches.",
                  cost: 0, ringMultiplier: 3, ringBoost: 8, hazards: "Avalanches, thin air", comingSoon: true,
                  art: [SIMD3(0.55, 0.70, 0.90), SIMD3(0.90, 0.94, 0.98), SIMD3(0.92, 0.95, 0.98), SIMD3(0.55, 0.75, 0.95)]),
        WorldInfo(id: "skyisles", name: "Sky Islands", blurb: "Floating islands, waterfalls into the clouds and wind tunnels.",
                  cost: 0, ringMultiplier: 2, ringBoost: 8, hazards: "Wind tunnels", comingSoon: true,
                  art: [SIMD3(0.60, 0.75, 0.98), SIMD3(0.98, 0.88, 0.92), SIMD3(0.45, 0.70, 0.35), SIMD3(0.95, 0.95, 1.00)]),
    ]

    static func info(_ id: String) -> WorldInfo { all.first { $0.id == id } ?? all[0] }
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
}

extension WorldTerrain {
    func ceiling(_ x: Float, _ z: Float) -> Float? { nil }
    func ceilingColor(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> { SIMD3(0.2, 0.2, 0.22) }
}

// MARK: - Look & feel per world

enum SurfaceKind { case ocean, lava, none }
enum MoteKind { case dust, embers, fireflies }

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
}
