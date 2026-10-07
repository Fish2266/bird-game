import Foundation
import simd

// Where things are in the Wild West: the canyon network, the railroad lines across the plateau, the towns at their
// stations, and the trestles where a line crosses a canyon. Pure functions (cached where they're costly), so the
// terrain threads and the game agree without talking to each other.

enum WestLayout {
    /// Plateau height near the canyon rim.
    static let rim: Float = 182
    /// Railroad lines run along x, every `lineSpacing` metres in z.
    static let lineSpacing: Float = 2600
    static let lineOffset: Float = 700
    /// Towns along each line, roughly this far apart.
    static let townSpacing: Float = 1900
    /// Main street half-length and half-width; the street sits north of the tracks.
    static let streetHalfLength: Float = 105
    static let streetHalfWidth: Float = 12
    static let streetOffset: Float = 62

    // MARK: Canyons

    /// The two canyon fields (zero along the middle of each canyon network).
    @inline(__always) static func fields(_ x: Float, _ z: Float) -> (Float, Float) {
        let wx = x + 300 * Noise.perlin(x * 0.00035 + 5.3, z * 0.00035 - 8.1)
        let wz = z + 300 * Noise.perlin(x * 0.00035 - 2.9, z * 0.00035 + 4.7)
        return (Noise.perlin(wx * 0.00042 + 0.61, wz * 0.00042 + 0.17), Noise.perlin(wx * 0.0009 + 13.7, wz * 0.0009 - 27.3))
    }

    /// Roughly how far (m) from the middle of the main canyon and of the side canyons. `steady` floors the fields'
    /// slopes: where a field flattens out near its zero line (a saddle), value ÷ slope blows up and the ground would
    /// shoot up to the plateau in a single spike; the terrain uses it, placement keeps the plain estimate.
    static func canyonDistances(_ x: Float, _ z: Float, steady: Bool = false) -> (Float, Float) {
        let e: Float = 3
        let (a, b) = fields(x, z)
        let (ax, bx) = fields(x + e, z)
        let (az, bz) = fields(x, z + e)
        let ga = simd_length(SIMD2(ax - a, az - a)) / e
        let gb = simd_length(SIMD2(bx - b, bz - b)) / e
        return (abs(a) / max(ga, steady ? 1.6e-4 : 1e-6), abs(b) / max(gb, steady ? 3.5e-4 : 1e-6))
    }

    /// Rim half-widths: the great canyon, and the narrower side canyons.
    @inline(__always) static func canyonWidths(_ x: Float, _ z: Float) -> (Float, Float) {
        (360 + 110 * Noise.perlin(x * 0.0004 + 3.1, z * 0.0004 + 9.9), 135 + 45 * Noise.perlin(x * 0.0008 - 4.4, z * 0.0008 + 1.3))
    }

    /// The plateau before any canyon cuts it (gentle swells): the railroad and towns sit on this.
    @inline(__always) static func plateau(_ x: Float, _ z: Float) -> Float {
        rim + 14 * Noise.fbm(x * 0.0011 + 7.7, z * 0.0011 - 3.3, octaves: 3)
    }

    // MARK: Railroad

    static func lineZ(_ k: Int) -> Float { Float(k) * lineSpacing + lineOffset }

    /// The line nearest a point (index) and how far it is.
    @inline(__always) static func nearestLine(_ z: Float) -> (Int, Float) {
        let k = Int(((z - lineOffset) / lineSpacing).rounded())
        return (k, abs(z - lineZ(k)))
    }

    /// Height of the rails: the plateau smoothed along the line (it never dips into a canyon — trestles carry it).
    static func trackY(_ x: Float, line k: Int) -> Float {
        let z = lineZ(k)
        var s: Float = 0
        for o: Float in [-60, -30, 0, 30, 60] { s += plateau(x + o, z) }
        return s / 5 + 1.2
    }

    // MARK: Towns

    struct Town {
        let line: Int
        let index: Int
        /// Middle of the main street; the street runs along x.
        let center: SIMD2<Float>
        let ground: Float
        let name: Int
        var station: SIMD2<Float> { SIMD2(center.x, lineZ(line)) }
    }

    private static let lock = NSLock()
    private static var townCache: [Int64: Town?] = [:]

    /// The town in slot `i` along line `k`, if the plateau there is clear of canyons.
    static func town(line k: Int, _ i: Int) -> Town? {
        let key = (Int64(k) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: i)))
        lock.lock()
        if let t = townCache[key] { lock.unlock(); return t }
        lock.unlock()
        let t = makeTown(k, i)
        lock.lock()
        if townCache.count > 2000 { townCache.removeAll(keepingCapacity: true) }
        townCache[key] = t
        lock.unlock()
        return t
    }

    private static func makeTown(_ k: Int, _ i: Int) -> Town? {
        var rng = cellRNG(k, i, 0x70_77)
        let x = (Float(i) + rng.float(-0.18, 0.18)) * townSpacing
        let z = lineZ(k) + streetOffset
        // Clear of every canyon (with room around), not on a mesa.
        for dx: Float in [-180, -90, 0, 90, 180] {
            for dz: Float in [-80, 0, 70, 140] {
                let (d1, d2) = canyonDistances(x + dx, z + dz)
                let (w1, w2) = canyonWidths(x + dx, z + dz)
                if d1 < w1 + 130 || d2 * 1.1 < w2 + 110 { return nil }
            }
        }
        return Town(line: k, index: i, center: SIMD2(x, z), ground: trackY(x, line: k) - 1.2 + 0.3, name: Int(rng.float(0, 9.99)))
    }

    /// Towns near a point.
    static func towns(near p: SIMD2<Float>, radius r: Float) -> [Town] {
        var out: [Town] = []
        let k0 = Int(floor((p.y - r - lineOffset) / lineSpacing)), k1 = Int(ceil((p.y + r - lineOffset) / lineSpacing))
        for k in k0...k1 {
            let i0 = Int(floor((p.x - r) / townSpacing)) - 1, i1 = Int(ceil((p.x + r) / townSpacing)) + 1
            for i in i0...i1 {
                guard let t = town(line: k, i) else { continue }
                if simd_distance(t.center, p) < r + streetHalfLength { out.append(t) }
            }
        }
        return out
    }

    /// The town whose flattened ground covers a point, and how much (1 inside the town, fading to 0 around it).
    @inline(__always) static func townBlend(_ x: Float, _ z: Float) -> (Town, Float)? {
        let (k, dz) = nearestLine(z - streetOffset)
        guard dz < 260 else { return nil }
        let i = Int((x / townSpacing).rounded())
        for ii in [i - 1, i, i + 1] {
            guard let t = town(line: k, ii) else { continue }
            let dx = max(abs(x - t.center.x) - (streetHalfLength + 40), 0)
            let dzz = max(abs(z - (t.center.y - 10)) - 95, 0)
            let d = sqrt(dx * dx + dzz * dzz)
            if d < 90 { return (t, smoothstep(90, 0, d)) }
        }
        return nil
    }

    static let townNames = ["Dusty Gulch", "Tumbleweed", "Coyote Springs", "Vulture Rock", "Red Mesa", "Sagebrush Flats",
                            "Feather Creek", "Buzzard Bend", "Cactus Hollow", "Gold Feather"]
}
