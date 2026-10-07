import Foundation
import simd

// Skyline City is laid out by pure functions of position, so the chunk meshes (built on background threads), the
// collisions, traffic, rings and race courses all agree without sharing state.
//
// A street grid: lines at x = i·pitch ("x-lines", the streets run along z) and z = j·pitch ("z-lines", along x).
// Every third x-line and every fourth z-line is an avenue; every twelfth x-line (an avenue) carries the elevated
// train. A river winds through (the zero line of a noise field) inside stone quay walls, under bridges. Districts
// (low-frequency noise) go from downtowns of glass towers through mid-rise blocks to brick and townhouse streets.

/// One street line of the grid.
struct CityLine {
    let index: Int
    let avenue: Bool
    /// The elevated train runs above the median.
    let el: Bool
    /// Centre line to the curb.
    var halfRoad: Float { el ? 9 : (avenue ? 7.5 : 6) }
    /// Centre line to the property line (the outer edge of the sidewalk).
    var halfWidth: Float { halfRoad + (avenue ? 5 : 4) }
    var median: Float { el ? 2 : (avenue ? 0.5 : 0) }
    /// Lane centres for one direction of travel (distance right of the centre line).
    var lanes: [Float] { avenue ? [median + 1.75, median + 5.25] : [1.75] }
    /// Parking lane centre (streets only).
    var parking: Float? { avenue ? nil : 4.75 }
}

struct CityPart {
    enum Shape { case box, cylinder, octagon }
    var shape: Shape
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    /// Facade style (see CityShaders): 0 glass, 1 office grid, 2 ribbon windows, 3 brick, 4 deco piers,
    /// 5 balconies, 6 garage, 7 plain.
    var style: Int
    var color: SIMD3<Float>
    /// Rotation about the part's centre (twisted towers).
    var yaw: Float = 0
    var roof = true

    var center: SIMD3<Float> { (lo + hi) * 0.5 }
    var half: SIMD3<Float> { (hi - lo) * 0.5 }
    var radius: Float { min(hi.x - lo.x, hi.z - lo.z) * 0.5 }
}

enum RoofItem {
    case unit(SIMD3<Float>, SIMD3<Float>)          // HVAC box: centre (on the roof), half size
    case waterTower(SIMD3<Float>, Float)           // base, radius
    case antenna(SIMD3<Float>, Float)              // base, height
    case helipad(SIMD3<Float>, Float)              // centre, radius
    case garden(SIMD3<Float>, SIMD2<Float>)        // centre, half size
    case pool(SIMD3<Float>, SIMD2<Float>)
    case billboard(SIMD3<Float>, Float, Float, Int) // centre, width, yaw, ad
}

struct CityBuilding {
    enum Kind { case glass, round, office, deco, brick, modern, shops, townhouses, garage, landmark, frame, twisted }
    var kind: Kind
    var parts: [CityPart] = []
    var base: Float
    /// Top of the highest roof.
    var top: Float = 0
    var spire: (base: SIMD3<Float>, height: Float)?
    /// A sloped glass top on the highest tier.
    var crown: Crown?
    enum Crown { case wedge(alongX: Bool, height: Float), pyramid(height: Float) }
    var seed: Int
    var storefront: Bool
    var roof: [RoofItem] = []
    var lot: (lo: SIMD2<Float>, hi: SIMD2<Float>)
}

struct CitySkybridge {
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    var color: SIMD3<Float>
}

struct CityCrane {
    var mast: SIMD3<Float>      // base
    var height: Float
    var jib: Float
    var phase: Float
}

struct CityBlock {
    enum Kind { case towers, midrise, residential, park, plaza, construction, parking, waterfront }
    var kind: Kind
    var bi: Int, bj: Int
    var lo: SIMD2<Float>
    var hi: SIMD2<Float>
    var district: Float
    var buildings: [CityBuilding] = []
    var skybridges: [CitySkybridge] = []
    var crane: CityCrane?
    var fountain: SIMD3<Float>?
    var pond: (c: SIMD2<Float>, r: Float)?
    var center: SIMD2<Float> { (lo + hi) * 0.5 }
}

/// A street segment between two intersections, and the bridge over the river if it crosses one.
struct CityEdge {
    /// Along x (on z-line j, from node i to i+1) or along z (on x-line i, from node j to j+1).
    let alongX: Bool
    let i: Int, j: Int
    /// Water span (distance from the first node) and the deck height, if this is a bridge.
    var bridge: (s0: Float, s1: Float, deck: Float)?
    var line: CityLine { alongX ? CityLayout.lineZ(j) : CityLayout.lineX(i) }
    var start: SIMD2<Float> { SIMD2(Float(i) * CityLayout.pitch, Float(j) * CityLayout.pitch) }
    var dir: SIMD2<Float> { alongX ? SIMD2(1, 0) : SIMD2(0, 1) }
}

enum CityLayout {
    static let pitch: Float = 120
    static let riverHalf: Float = 38
    /// Ground near the river (the quay top); bridges sit at about this height.
    static let quayTop: Float = 12

    // MARK: Lines

    static func lineX(_ i: Int) -> CityLine {
        CityLine(index: i, avenue: fmodi(i, 3) == 0, el: fmodi(i, 12) == 6)
    }
    static func lineZ(_ j: Int) -> CityLine {
        CityLine(index: j, avenue: fmodi(j, 4) == 0, el: false)
    }

    // MARK: Fields

    /// 0 = quiet townhouse streets, 1 = the heart of a downtown.
    static func district(_ x: Float, _ z: Float) -> Float {
        let n = Noise.fbm(x * 0.00042 + 7.1, z * 0.00042 - 3.3, octaves: 3) + 0.08 * Noise.perlin(x * 0.002, z * 0.002 + 4)
        return smoothstep(-0.18, 0.42, n)
    }

    /// River: the zero line of this field.
    @inline(__always) static func riverField(_ x: Float, _ z: Float) -> Float {
        let wx = x + 260 * Noise.perlin(x * 0.0004 + 1.7, z * 0.0004 - 2.2)
        let wz = z + 260 * Noise.perlin(x * 0.0004 - 4.6, z * 0.0004 + 3.3)
        return Noise.perlin(wx * 0.0003 + 11.3, wz * 0.0003 + 5.9)
    }

    /// Approximate distance (m) to the middle of the river.
    static func riverDistance(_ x: Float, _ z: Float) -> Float {
        let f = riverField(x, z)
        let e: Float = 3
        let gx = (riverField(x + e, z) - riverField(x - e, z)) / (2 * e)
        let gz = (riverField(x, z + e) - riverField(x, z - e)) / (2 * e)
        let g = max(sqrt(gx * gx + gz * gz), 1e-6)
        return abs(f) / g
    }

    /// Big parks spanning several blocks.
    static func parkiness(_ x: Float, _ z: Float) -> Float {
        Noise.perlin(x * 0.0011 - 9.4, z * 0.0011 + 2.8)
    }

    /// The ground (streets, parks, the river bed).
    static func ground(_ x: Float, _ z: Float) -> Float {
        let hills = 13 + 6 * Noise.fbm(x * 0.0005 + 3.7, z * 0.0005 - 8.1, octaves: 3)
        let d = riverDistance(x, z)
        if d < riverHalf { return -4.5 - 2 * (1 - d / riverHalf) }
        let land = hills + max(0, quayTop - hills) * smoothstep(riverHalf + 170, riverHalf + 50, d)
        return lerp(-3.5, land, smoothstep(riverHalf, riverHalf + 2.5, d))
    }

    static func isWater(_ x: Float, _ z: Float) -> Bool { riverDistance(x, z) < riverHalf + 1 }

    // MARK: Network

    static func nodePosition(_ i: Int, _ j: Int) -> SIMD2<Float> { SIMD2(Float(i) * pitch, Float(j) * pitch) }

    static func nodeExists(_ i: Int, _ j: Int) -> Bool {
        let p = nodePosition(i, j)
        return riverDistance(p.x, p.y) > riverHalf + 9   // close enough to the bank that streets can bridge the river
    }

    /// The street segment from node (i, j) along x (to i+1) or along z (to j+1); nil where the river swallows it.
    static func edge(alongX: Bool, _ i: Int, _ j: Int) -> CityEdge? {
        let a = nodePosition(i, j)
        guard nodeExists(i, j), nodeExists(alongX ? i + 1 : i, alongX ? j : j + 1) else { return nil }
        let d = alongX ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
        var s0: Float = .infinity, s1: Float = -.infinity
        var s: Float = 0
        while s <= pitch {
            let p = a + d * s
            if riverDistance(p.x, p.y) < riverHalf + 4 { s0 = min(s0, s); s1 = max(s1, s) }
            s += 4
        }
        var e = CityEdge(alongX: alongX, i: i, j: j)
        if s0 <= s1 {
            guard s1 - s0 < pitch - 6 else { return nil }   // (angled crossings span most of a block)
            let lo = max(0, s0 - 8), hi = min(pitch, s1 + 8)
            let pa = a + d * lo, pb = a + d * hi
            let deck = max(max(ground(pa.x, pa.y), ground(pb.x, pb.y)), quayTop) + 0.4
            e.bridge = (lo, hi, deck)
        }
        return e
    }

    /// Height of the road surface at a point on an edge (the bridge deck over water).
    static func roadY(_ e: CityEdge, s: Float, at p: SIMD2<Float>) -> Float {
        if let b = e.bridge, s > b.s0 - 2, s < b.s1 + 2 {
            // Ease onto the deck over the last few metres so cars don't step up.
            let g = ground(p.x, p.y)
            let k = min(smoothstep(b.s0 - 2, b.s0 + 4, s), smoothstep(b.s1 + 2, b.s1 - 4, s))
            return lerp(max(g, b.deck - 1.5), b.deck, k)
        }
        return ground(p.x, p.y)
    }

    // MARK: Traffic lights (the shaders run the same clock)

    static let signalCycle: Float = 26
    /// 0 green, 1 yellow, 2 red for traffic moving along x (axis 0) or z (axis 1) at node (i, j).
    static func signal(_ i: Int, _ j: Int, axis: Int, time t: Float) -> Int {
        let off = Float(fmodi(i * 7 + j * 11, 26))
        var p = (t + off).truncatingRemainder(dividingBy: signalCycle)
        if p < 0 { p += signalCycle }
        if axis == 0 { return p < 10 ? 0 : (p < 12.5 ? 1 : 2) }
        return p < 13 ? 2 : (p < 23 ? 0 : (p < 25.5 ? 1 : 2))
    }

    // MARK: Blocks

    private static let cacheLock = NSLock()
    private static var cache: [Int64: CityBlock] = [:]

    /// The block between x-lines bi, bi+1 and z-lines bj, bj+1 (cached; safe from any thread).
    static func block(_ bi: Int, _ bj: Int) -> CityBlock {
        let key = Int64(bi) << 32 ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: bj)))
        cacheLock.lock()
        if let b = cache[key] { cacheLock.unlock(); return b }
        cacheLock.unlock()
        let b = makeBlock(bi, bj)
        cacheLock.lock()
        if cache.count > 3000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = b
        cacheLock.unlock()
        return b
    }

    /// Block indices containing (x, z) (the street around it belongs to no block).
    static func blockIndex(_ x: Float, _ z: Float) -> (Int, Int) {
        (Int(floor(x / pitch)), Int(floor(z / pitch)))
    }

    private static let glassTints: [SIMD3<Float>] = [SIMD3(0.36, 0.52, 0.66), SIMD3(0.30, 0.55, 0.58), SIMD3(0.40, 0.56, 0.50),
                                                     SIMD3(0.56, 0.47, 0.38), SIMD3(0.62, 0.66, 0.72), SIMD3(0.24, 0.30, 0.38),
                                                     SIMD3(0.42, 0.48, 0.62)]
    private static let concretes: [SIMD3<Float>] = [SIMD3(0.76, 0.74, 0.70), SIMD3(0.84, 0.81, 0.75), SIMD3(0.64, 0.64, 0.64),
                                                    SIMD3(0.80, 0.74, 0.63), SIMD3(0.70, 0.66, 0.60)]
    private static let bricks: [SIMD3<Float>] = [SIMD3(0.56, 0.28, 0.21), SIMD3(0.64, 0.36, 0.25), SIMD3(0.52, 0.37, 0.29),
                                                 SIMD3(0.74, 0.57, 0.43), SIMD3(0.44, 0.25, 0.21), SIMD3(0.66, 0.46, 0.36)]
    private static let limestones: [SIMD3<Float>] = [SIMD3(0.85, 0.81, 0.71), SIMD3(0.77, 0.71, 0.61), SIMD3(0.91, 0.87, 0.79)]
    private static let moderns: [SIMD3<Float>] = [SIMD3(0.93, 0.93, 0.91), SIMD3(0.80, 0.83, 0.85), SIMD3(0.87, 0.79, 0.67),
                                                  SIMD3(0.55, 0.58, 0.62)]
    private static let pastels: [SIMD3<Float>] = [SIMD3(0.86, 0.72, 0.62), SIMD3(0.70, 0.78, 0.84), SIMD3(0.88, 0.84, 0.66),
                                                  SIMD3(0.74, 0.82, 0.72), SIMD3(0.84, 0.70, 0.72), SIMD3(0.58, 0.36, 0.28)]

    private static func pick(_ a: [SIMD3<Float>], _ rng: inout SplitMix64) -> SIMD3<Float> { a[Int(rng.float(0, Float(a.count) - 0.001))] }

    private static func makeBlock(_ bi: Int, _ bj: Int) -> CityBlock {
        let lx0 = lineX(bi), lx1 = lineX(bi + 1), lz0 = lineZ(bj), lz1 = lineZ(bj + 1)
        let lo = SIMD2(Float(bi) * pitch + lx0.halfWidth, Float(bj) * pitch + lz0.halfWidth)
        let hi = SIMD2(Float(bi + 1) * pitch - lx1.halfWidth, Float(bj + 1) * pitch - lz1.halfWidth)
        let c = (lo + hi) * 0.5
        let D = district(c.x, c.y)
        var rng = SplitMix64(seed: UInt64(ihash(bi, bj, 0xC17E)) | 1)
        var river: Float = .infinity
        for fx: Float in [0, 0.5, 1] {
            for fz: Float in [0, 0.5, 1] {
                let p = lo + (hi - lo) * SIMD2(fx, fz)
                river = min(river, riverDistance(p.x, p.y))
            }
        }
        var kind: CityBlock.Kind
        let r = rng.float()
        if river < riverHalf + 30 { kind = .waterfront }
        else if parkiness(c.x, c.y) > 0.6 - 0.06 * (1 - D) { kind = .park }
        else if r < 0.025 + 0.025 * (1 - D) { kind = .park }
        else if r < 0.10 && D > 0.45 { kind = .plaza }
        else if r < 0.14 && D > 0.25 { kind = .construction }
        else if r < 0.18 && D < 0.45 { kind = .parking }
        else if D > 0.6 { kind = .towers }
        else if D > 0.28 { kind = .midrise }
        else { kind = .residential }
        var b = CityBlock(kind: kind, bi: bi, bj: bj, lo: lo, hi: hi, district: D)
        func baseAt(_ a: SIMD2<Float>, _ z: SIMD2<Float>) -> Float {
            var g: Float = .infinity
            for p in [a, z, SIMD2(a.x, z.y), SIMD2(z.x, a.y), (a + z) * 0.5] { g = min(g, ground(p.x, p.y)) }
            return g
        }
        switch kind {
        case .park, .waterfront:
            if kind == .park && rng.float() < 0.45 {
                b.pond = (c + SIMD2(rng.float(-12, 12), rng.float(-12, 12)), rng.float(9, 15))
            } else if rng.float() < 0.35 {
                b.fountain = SIMD3(c.x, ground(c.x, c.y), c.y)
            }
        case .plaza:
            // A fountain in front, a tower at the back.
            var tlo = lo, thi = hi
            var fc: SIMD2<Float>
            let first = rng.float() < 0.5
            if (hi.x - lo.x) >= (hi.y - lo.y) {
                if first { tlo.x = c.x + 4; fc = SIMD2((lo.x + c.x) / 2, c.y) } else { thi.x = c.x - 4; fc = SIMD2((c.x + hi.x) / 2, c.y) }
            } else {
                if first { tlo.y = c.y + 4; fc = SIMD2(c.x, (lo.y + c.y) / 2) } else { thi.y = c.y - 4; fc = SIMD2(c.x, (c.y + hi.y) / 2) }
            }
            b.fountain = SIMD3(fc.x, ground(fc.x, fc.y), fc.y)
            b.buildings.append(tower(.glass, tlo + 3, thi - 3, base: baseAt(tlo, thi), D: D, &rng))
        case .construction:
            let inset: Float = 6
            let flo = lo + inset, fhi = hi - inset
            var f = CityBuilding(kind: .frame, base: baseAt(flo, fhi), seed: 0, storefront: false, lot: (flo, fhi))
            let floors = Int(rng.float(6, 18))
            let h = Float(floors) * 4
            // A concrete core you can hit; the steel frame around it is open.
            let cc = (flo + fhi) * 0.5
            f.parts.append(CityPart(shape: .box, lo: SIMD3(cc.x - 6, f.base - 1, cc.y - 6), hi: SIMD3(cc.x + 6, f.base + h + 4, cc.y + 6),
                                    style: 7, color: SIMD3(0.62, 0.61, 0.58)))
            f.top = f.base + h
            b.buildings.append(f)
            let corner = SIMD2(rng.float() < 0.5 ? flo.x - 2 : fhi.x + 2, rng.float() < 0.5 ? flo.y - 2 : fhi.y + 2)
            b.crane = CityCrane(mast: SIMD3(corner.x, ground(corner.x, corner.y), corner.y),
                                height: max(h + 22, rng.float(55, 95)), jib: rng.float(42, 58), phase: rng.float(0, 6.28))
        case .parking:
            break
        case .towers:
            let wx = hi.x - lo.x, wz = hi.y - lo.y
            let choice = rng.float()
            // Rare supertall where the district peaks.
            if D > 0.82 && hfloat(fdiv(bi, 3), fdiv(bj, 3), 0x5A9) > 0.55 && fmodi(bi, 3) == 1 && fmodi(bj, 3) == 1 {
                b.buildings.append(landmark(lo + 9, hi - 9, base: baseAt(lo, hi), &rng))
            } else if choice < 0.34 {
                let ins = rng.float(5, 13)
                let k: CityBuilding.Kind = rng.float() < 0.18 ? .round : (rng.float() < 0.12 ? .twisted : (rng.float() < 0.25 ? .deco : .glass))
                b.buildings.append(tower(k, lo + ins, hi - ins, base: baseAt(lo, hi), D: D, &rng))
            } else if choice < 0.78 {
                // Two towers, often joined by a skybridge.
                let gap = rng.float(12, 18)
                let alongX = wx >= wz
                let mid = alongX ? lo.x + wx * rng.float(0.42, 0.58) : lo.y + wz * rng.float(0.42, 0.58)
                let a0 = lo + SIMD2(3, 3), b1 = hi - SIMD2(3, 3)
                let a1 = alongX ? SIMD2(mid - gap / 2, b1.y) : SIMD2(b1.x, mid - gap / 2)
                let b0 = alongX ? SIMD2(mid + gap / 2, a0.y) : SIMD2(a0.x, mid + gap / 2)
                let k1: CityBuilding.Kind = rng.float() < 0.2 ? .deco : (rng.float() < 0.15 ? .round : .glass)
                let k2: CityBuilding.Kind = rng.float() < 0.3 ? .office : .glass
                let t1 = tower(k1, a0, a1, base: baseAt(a0, a1), D: D, &rng)
                let t2 = tower(k2, b0, b1, base: baseAt(b0, b1), D: D, &rng)
                b.buildings += [t1, t2]
                let low = min(t1.parts[0].hi.y, t2.parts[0].hi.y)
                if rng.float() < 0.55 && low - t1.base > 60 && t1.kind != .round && t2.kind != .round {
                    let y = t1.base + rng.float(32, min(70, low - t1.base - 18))
                    let w: Float = 3.2
                    let cm = (t1.parts[0].center + t2.parts[0].center) * 0.5
                    let sb: CitySkybridge
                    if alongX {
                        let z = clamp(cm.z, max(t1.parts[0].lo.z, t2.parts[0].lo.z) + w + 2, min(t1.parts[0].hi.z, t2.parts[0].hi.z) - w - 2)
                        sb = CitySkybridge(lo: SIMD3(t1.parts[0].hi.x - 0.5, y, z - w), hi: SIMD3(t2.parts[0].lo.x + 0.5, y + 4.5, z + w),
                                           color: pick(glassTints, &rng))
                    } else {
                        let x = clamp(cm.x, max(t1.parts[0].lo.x, t2.parts[0].lo.x) + w + 2, min(t1.parts[0].hi.x, t2.parts[0].hi.x) - w - 2)
                        sb = CitySkybridge(lo: SIMD3(x - w, y, t1.parts[0].hi.z - 0.5), hi: SIMD3(x + w, y + 4.5, t2.parts[0].lo.z + 0.5),
                                           color: pick(glassTints, &rng))
                    }
                    b.skybridges.append(sb)
                }
            } else {
                // A podium of shops covering the block with a tower rising from one side.
                let podH = Float(Int(rng.float(2, 4))) * 5
                var pod = CityBuilding(kind: .shops, base: baseAt(lo, hi), seed: 4 + Int(rng.float(0, 3.99)), storefront: true, lot: (lo, hi))
                pod.parts.append(CityPart(shape: .box, lo: SIMD3(lo.x, pod.base - 1, lo.y), hi: SIMD3(hi.x, pod.base + podH, hi.y),
                                          style: 1, color: pick(concretes, &rng)))
                let alongX = wx >= wz
                let tl = alongX ? SIMD2(lo.x + 8, lo.y + 8) : SIMD2(lo.x + 8, lo.y + 8)
                let th = alongX ? SIMD2(lo.x + wx * 0.55, hi.y - 8) : SIMD2(hi.x - 8, lo.y + wz * 0.55)
                var t = tower(.glass, tl, th, base: pod.base + podH, D: D, &rng)
                t.parts[0].lo.y = pod.base + podH - 0.5
                pod.top = pod.base + podH
                pod.parts[0].roof = true
                addRoofUnits(&pod, &rng, avoid: (tl, th))
                b.buildings += [pod, t]
            }
        case .midrise, .residential:
            subdivide(&b, D: D, &rng, baseAt: baseAt)
        }
        return b
    }

    /// Split a block into lots of mid-rise or residential buildings (sharing walls, now and then with an alley).
    private static func subdivide(_ b: inout CityBlock, D: Float, _ rng: inout SplitMix64,
                                  baseAt: (SIMD2<Float>, SIMD2<Float>) -> Float) {
        let lo = b.lo, hi = b.hi
        let mid = b.kind == .midrise
        let nx = mid ? Int(rng.float(2, 3.99)) : Int(rng.float(3, 4.99))
        let nz = mid ? 2 : Int(rng.float(2, 3.99))
        var xs: [Float] = [lo.x], zs: [Float] = [lo.y]
        for k in 1..<nx { xs.append(lo.x + (hi.x - lo.x) * (Float(k) / Float(nx) + rng.float(-0.06, 0.06))) }
        for k in 1..<nz { zs.append(lo.y + (hi.y - lo.y) * (Float(k) / Float(nz) + rng.float(-0.06, 0.06))) }
        xs.append(hi.x); zs.append(hi.y)
        // An alley through the middle (wide enough to fly) in some mid-rise blocks.
        let alley = mid && rng.float() < 0.35
        for a in 0..<nx {
            for c in 0..<nz {
                var l0 = SIMD2(xs[a], zs[c]), l1 = SIMD2(xs[a + 1], zs[c + 1])
                if alley && nz == 2 { if c == 0 { l1.y -= 6 } else { l0.y += 6 } }
                guard l1.x - l0.x > 12, l1.y - l0.y > 12 else { continue }
                let base = baseAt(l0, l1)
                let r = rng.float()
                var bld: CityBuilding
                if mid {
                    if r < 0.32 { bld = boxBuilding(.office, l0, l1, base: base, height: rng.float(24, 70) * (0.7 + D), &rng) }
                    else if r < 0.55 { bld = boxBuilding(.brick, l0, l1, base: base, height: rng.float(16, 40), &rng) }
                    else if r < 0.75 { bld = boxBuilding(.modern, l0, l1, base: base, height: rng.float(22, 60) * (0.7 + D), &rng) }
                    else if r < 0.85 { bld = boxBuilding(.deco, l0, l1, base: base, height: rng.float(30, 75), &rng) }
                    else if r < 0.93 { bld = boxBuilding(.shops, l0, l1, base: base, height: rng.float(8, 13), &rng) }
                    else { bld = boxBuilding(.garage, l0, l1, base: base, height: Float(Int(rng.float(4, 6.99))) * 3, &rng) }
                } else {
                    if r < 0.4 { bld = townhouses(l0, l1, base: base, &rng, alongX: c == 0 || c == nz - 1) }
                    else if r < 0.72 { bld = boxBuilding(.brick, l0, l1, base: base, height: rng.float(12, 26), &rng) }
                    else if r < 0.88 { bld = boxBuilding(.shops, l0, l1, base: base, height: rng.float(7, 11), &rng) }
                    else { bld = boxBuilding(.modern, l0, l1, base: base, height: rng.float(14, 30), &rng) }
                }
                b.buildings.append(bld)
            }
        }
    }

    private static func floorH(_ style: Int) -> Float { [3.9, 3.7, 3.6, 3.1, 3.8, 3.2, 3.0, 3.5][style] }

    private static func boxBuilding(_ kind: CityBuilding.Kind, _ l0: SIMD2<Float>, _ l1: SIMD2<Float>, base: Float, height: Float,
                                    _ rng: inout SplitMix64) -> CityBuilding {
        let style: Int, color: SIMD3<Float>
        switch kind {
        case .office: style = rng.float() < 0.6 ? 1 : 2; color = pick(concretes, &rng)
        case .brick: style = 3; color = pick(bricks, &rng)
        case .modern: style = 5; color = pick(moderns, &rng)
        case .deco: style = 4; color = pick(limestones, &rng)
        case .garage: style = 6; color = SIMD3(0.66, 0.66, 0.64)
        default: style = rng.float() < 0.5 ? 3 : 1; color = rng.float() < 0.5 ? pick(bricks, &rng) : pick(pastels, &rng)
        }
        let fh = floorH(style)
        let h = max(fh * 2, (height / fh).rounded() * fh) + (kind == .shops ? 1.4 : 0.8)
        let shops = kind == .shops || ((kind == .brick || kind == .office || kind == .deco) && rng.float() < 0.55)
        var bld = CityBuilding(kind: kind, base: base, seed: shops ? 4 + Int(rng.float(0, 3.99)) : Int(rng.float(0, 3.99)),
                               storefront: shops, lot: (l0, l1))
        bld.parts.append(CityPart(shape: .box, lo: SIMD3(l0.x, base - 1, l0.y), hi: SIMD3(l1.x, base + h, l1.y), style: style, color: color))
        // Deco blocks step back near the top.
        if kind == .deco && h > 36 {
            let ins = min(l1.x - l0.x, l1.y - l0.y) * 0.16
            bld.parts[0].hi.y = base + (h * 0.72 / fh).rounded() * fh
            bld.parts.append(CityPart(shape: .box, lo: SIMD3(l0.x + ins, bld.parts[0].hi.y - 0.3, l0.y + ins),
                                      hi: SIMD3(l1.x - ins, base + h, l1.y - ins), style: 4, color: color))
        }
        bld.top = bld.parts.map(\.hi.y).max()!
        if kind == .brick && rng.float() < 0.55 && h > 14 {
            let p = bld.parts[0]
            let at = SIMD3(rng.float(p.lo.x + 4, max(p.lo.x + 4.1, p.hi.x - 4)), bld.top, rng.float(p.lo.z + 4, max(p.lo.z + 4.1, p.hi.z - 4)))
            bld.roof.append(.waterTower(at, rng.float(2.2, 3.2)))
        }
        if kind == .shops && rng.float() < 0.3 {
            let p = bld.parts[0]
            let alongX = p.hi.x - p.lo.x > p.hi.z - p.lo.z
            let w = min(alongX ? p.hi.x - p.lo.x : p.hi.z - p.lo.z, 16) * 0.85
            bld.roof.append(.billboard(SIMD3(p.center.x, bld.top, p.center.z), w, alongX ? 0 : .pi / 2, Int(rng.float(0, 7.99))))
        }
        addRoofUnits(&bld, &rng)
        if kind == .modern && rng.float() < 0.25 {
            let p = bld.parts[0]
            bld.roof.append(rng.float() < 0.5 ? .garden(SIMD3(p.center.x, bld.top, p.center.z), SIMD2(p.half.x, p.half.z) * 0.55)
                                              : .pool(SIMD3(p.center.x, bld.top, p.center.z), SIMD2(p.half.x, p.half.z) * 0.4))
        }
        return bld
    }

    private static func townhouses(_ l0: SIMD2<Float>, _ l1: SIMD2<Float>, base: Float, _ rng: inout SplitMix64, alongX: Bool) -> CityBuilding {
        var bld = CityBuilding(kind: .townhouses, base: base, seed: Int(rng.float(0, 3.99)), storefront: false, lot: (l0, l1))
        let len = alongX ? l1.x - l0.x : l1.y - l0.y
        let n = max(2, Int(len / rng.float(6, 8)))
        let w = len / Float(n)
        for k in 0..<n {
            let a = (alongX ? l0.x : l0.y) + Float(k) * w
            let h = Float(Int(rng.float(3, 4.99))) * 3.1 + 0.6
            let col = rng.float() < 0.6 ? pick(bricks, &rng) : pick(pastels, &rng)
            let lo = alongX ? SIMD3(a, base - 1, l0.y) : SIMD3(l0.x, base - 1, a)
            let hi = alongX ? SIMD3(a + w, base + h, l1.y) : SIMD3(l1.x, base + h, a + w)
            bld.parts.append(CityPart(shape: .box, lo: lo, hi: hi, style: 3, color: col))
        }
        bld.top = bld.parts.map(\.hi.y).max()!
        return bld
    }

    /// Glass, deco, round or twisted tower on a lot.
    private static func tower(_ kind: CityBuilding.Kind, _ l0: SIMD2<Float>, _ l1: SIMD2<Float>, base: Float, D: Float,
                              _ rng: inout SplitMix64) -> CityBuilding {
        var bld = CityBuilding(kind: kind, base: base, seed: Int(rng.float(0, 3.99)), storefront: kind != .round && rng.float() < 0.5,
                               lot: (l0, l1))
        if bld.storefront { bld.seed += 4 }
        let w = l1.x - l0.x, d = l1.y - l0.y
        let slender = min(w, d)
        var h = (70 + 170 * D) * rng.float(0.62, 1.25)
        h = min(h, slender * 7.5)
        h = max(h, 45)
        switch kind {
        case .round:
            let style = 0
            let tint = pick(glassTints, &rng)
            let c = (l0 + l1) * 0.5
            let r = slender * 0.5 - 1
            let fh = floorH(style)
            let h1 = (h * rng.float(0.65, 0.85) / fh).rounded() * fh
            bld.parts.append(CityPart(shape: .cylinder, lo: SIMD3(c.x - r, base - 1, c.y - r), hi: SIMD3(c.x + r, base + h1, c.y + r),
                                      style: style, color: tint))
            let r2 = r * rng.float(0.6, 0.8)
            bld.parts.append(CityPart(shape: .cylinder, lo: SIMD3(c.x - r2, base + h1 - 0.3, c.y - r2),
                                      hi: SIMD3(c.x + r2, base + (h / fh).rounded() * fh, c.y + r2), style: style, color: tint))
        case .twisted:
            let tint = pick(glassTints, &rng)
            let c = (l0 + l1) * 0.5
            let half = slender * 0.5 * 0.82
            let seg = Int(h / 16)
            let twist = rng.float(0.035, 0.07) * (rng.float() < 0.5 ? -1 : 1)
            for k in 0..<seg {
                let y0 = base + Float(k) * 16 - (k == 0 ? 1 : 0.2), y1 = base + Float(k + 1) * 16
                bld.parts.append(CityPart(shape: .box, lo: SIMD3(c.x - half, y0, c.y - half), hi: SIMD3(c.x + half, y1, c.y + half),
                                          style: 0, color: tint, yaw: Float(k) * twist))
            }
        case .deco:
            let col = pick(limestones, &rng)
            var a = l0, b = l1
            let tiers = Int(rng.float(3, 5.99))
            var y = base - 1
            let fh = floorH(4)
            for k in 0..<tiers {
                let frac: Float = k == tiers - 1 ? 1 : [0.45, 0.68, 0.82, 0.9, 0.95][k]
                let top = base + ((h * frac) / fh).rounded() * fh
                guard top > y + 6 else { continue }
                bld.parts.append(CityPart(shape: .box, lo: SIMD3(a.x, y, a.y), hi: SIMD3(b.x, top, b.y), style: 4, color: col))
                y = top - 0.3
                let ins = min(b.x - a.x, b.y - a.y) * rng.float(0.1, 0.16)
                a += ins; b -= ins
            }
            let tp = bld.parts.last!
            bld.spire = (SIMD3(tp.center.x, tp.hi.y, tp.center.z), rng.float(18, 42))
        default:
            // Glass (or an office slab when asked): one to three tiers with setbacks.
            let office = kind == .office
            let style = office ? (rng.float() < 0.5 ? 1 : 2) : 0
            let col = office ? pick(concretes, &rng) : pick(glassTints, &rng)
            let fh = floorH(style)
            let tiers = rng.float() < 0.55 ? 1 : (rng.float() < 0.7 ? 2 : 3)
            let shape: CityPart.Shape = !office && rng.float() < 0.25 ? .octagon : .box
            var a = l0, b = l1
            var y = base - 1
            for k in 0..<tiers {
                let frac: Float = k == tiers - 1 ? 1 : (tiers == 2 ? rng.float(0.55, 0.75) : [0.45, 0.75][k])
                let top = base + ((h * frac) / fh).rounded() * fh + 0.4
                bld.parts.append(CityPart(shape: shape, lo: SIMD3(a.x, y, a.y), hi: SIMD3(b.x, top, b.y), style: style, color: col))
                y = top - 0.3
                let ins = rng.float(3, 7)
                a += ins; b -= ins
                if b.x - a.x < 14 || b.y - a.y < 14 { break }
            }
            let tp = bld.parts.last!
            let crownRoll = rng.float()
            if !office && crownRoll < 0.34 && tp.shape == .box {
                let ch = min(tp.hi.x - tp.lo.x, tp.hi.z - tp.lo.z) * rng.float(0.35, 0.6)
                bld.crown = crownRoll < 0.22 ? .wedge(alongX: rng.float() < 0.5, height: ch) : .pyramid(height: ch * 0.8)
            } else if rng.float() < 0.55 {
                // Mechanical penthouse.
                let ins = SIMD2(tp.hi.x - tp.lo.x, tp.hi.z - tp.lo.z) * rng.float(0.22, 0.32)
                bld.parts.append(CityPart(shape: .box, lo: SIMD3(tp.lo.x + ins.x, tp.hi.y - 0.2, tp.lo.z + ins.y),
                                          hi: SIMD3(tp.hi.x - ins.x, tp.hi.y + rng.float(4, 7), tp.hi.z - ins.y), style: 7,
                                          color: SIMD3(0.55, 0.56, 0.58)))
            }
            if !office && bld.crown == nil && rng.float() < 0.35 { bld.spire = (SIMD3(tp.center.x, bld.parts.last!.hi.y, tp.center.z), rng.float(12, 40)) }
            if rng.float() < 0.22 && tp.hi.x - tp.lo.x > 22 && tp.hi.z - tp.lo.z > 22 && bld.spire == nil && bld.crown == nil {
                bld.roof.append(.helipad(SIMD3(tp.center.x, tp.hi.y, tp.center.z), 7))
            }
        }
        bld.top = bld.parts.map(\.hi.y).max()!
        if kind != .round && kind != .twisted && bld.crown == nil { addRoofUnits(&bld, &rng) }
        if bld.spire == nil && bld.crown == nil && kind != .twisted && rng.float() < 0.5 {
            let tp = bld.parts.last!
            bld.roof.append(.antenna(SIMD3(tp.lo.x + (tp.hi.x - tp.lo.x) * rng.float(0.25, 0.75), tp.hi.y,
                                           tp.lo.z + (tp.hi.z - tp.lo.z) * rng.float(0.25, 0.75)), rng.float(6, 16)))
        }
        return bld
    }

    private static func landmark(_ l0: SIMD2<Float>, _ l1: SIMD2<Float>, base: Float, _ rng: inout SplitMix64) -> CityBuilding {
        var bld = CityBuilding(kind: .landmark, base: base, seed: 5, storefront: true, lot: (l0, l1))
        let h = rng.float(270, 360)
        let deco = rng.float() < 0.45
        let col = deco ? pick(limestones, &rng) : pick(glassTints, &rng)
        let style = deco ? 4 : 0
        let fh = floorH(style)
        var a = l0, b = l1
        var y = base - 1
        let tiers = 6
        for k in 0..<tiers {
            let top = base + ((h * Float(k + 1) / Float(tiers)) / fh).rounded() * fh
            bld.parts.append(CityPart(shape: .box, lo: SIMD3(a.x, y, a.y), hi: SIMD3(b.x, top, b.y), style: style, color: col))
            y = top - 0.3
            let ins = min(b.x - a.x, b.y - a.y) * 0.085
            a += ins; b -= ins
        }
        let tp = bld.parts.last!
        bld.spire = (SIMD3(tp.center.x, tp.hi.y, tp.center.z), rng.float(45, 80))
        bld.top = tp.hi.y
        return bld
    }

    private static func addRoofUnits(_ bld: inout CityBuilding, _ rng: inout SplitMix64, avoid: (SIMD2<Float>, SIMD2<Float>)? = nil) {
        guard let p = bld.parts.max(by: { $0.hi.y < $1.hi.y }), p.shape == .box, p.yaw == 0 else { return }
        let n = Int(rng.float(1, 4.99))
        for _ in 0..<n {
            let hs = SIMD3(rng.float(1.2, 3.2), rng.float(0.8, 1.8), rng.float(1.2, 3.2))
            let x = rng.float(p.lo.x + hs.x + 1.5, max(p.lo.x + hs.x + 1.6, p.hi.x - hs.x - 1.5))
            let z = rng.float(p.lo.z + hs.z + 1.5, max(p.lo.z + hs.z + 1.6, p.hi.z - hs.z - 1.5))
            if let (a, b) = avoid, x > a.x - 3, x < b.x + 3, z > a.y - 3, z < b.y + 3 { continue }
            bld.roof.append(.unit(SIMD3(x, p.hi.y, z), hs))
        }
    }

    // MARK: Queries

    /// Every block whose buildings could reach within `r` of (x, z).
    static func blocks(near x: Float, _ z: Float, radius r: Float) -> [CityBlock] {
        let i0 = Int(floor((x - r) / pitch)), i1 = Int(floor((x + r) / pitch))
        let j0 = Int(floor((z - r) / pitch)), j1 = Int(floor((z + r) / pitch))
        var out: [CityBlock] = []
        for bj in j0...j1 { for bi in i0...i1 { out.append(block(bi, bj)) } }
        return out
    }

    /// Height of the tallest solid thing at (x, z) (roofs; ground if none) — for rings, cameras and bots.
    static func roofHeight(_ x: Float, _ z: Float) -> Float {
        let (bi, bj) = blockIndex(x, z)
        let b = block(bi, bj)
        var top = ground(x, z)
        for bld in b.buildings {
            for p in bld.parts where p.lo.x - 1 <= x && x <= p.hi.x + 1 && p.lo.z - 1 <= z && z <= p.hi.z + 1 {
                top = max(top, p.hi.y)
            }
        }
        for s in b.skybridges where s.lo.x <= x && x <= s.hi.x && s.lo.z <= z && z <= s.hi.z { top = max(top, s.hi.y) }
        return top
    }

    /// Highest roof anywhere within `r` of (x, z).
    static func skyline(_ x: Float, _ z: Float, radius r: Float) -> Float {
        var top = ground(x, z)
        for b in blocks(near: x, z, radius: r) {
            for bld in b.buildings {
                let p = bld.lot
                let dx = max(p.lo.x - x, 0, x - p.hi.x), dz = max(p.lo.y - z, 0, z - p.hi.y)
                if dx * dx + dz * dz < r * r { top = max(top, bld.top + (bld.spire?.height ?? 0)) }
            }
            if let c = b.crane, simd_length(SIMD2(c.mast.x - x, c.mast.z - z)) < r + c.jib { top = max(top, c.mast.y + c.height + 6) }
        }
        return top
    }

    /// Distance from (x, z) to the nearest street centre line, which line and whether it runs along x.
    static func nearestStreet(_ x: Float, _ z: Float) -> (dist: Float, alongX: Bool, index: Int) {
        let i = Int((x / pitch).rounded()), j = Int((z / pitch).rounded())
        let dx = abs(x - Float(i) * pitch), dz = abs(z - Float(j) * pitch)
        return dx < dz ? (dx, false, i) : (dz, true, j)
    }

    /// True when (x, z) is on a street or sidewalk (not inside a block).
    static func onStreet(_ x: Float, _ z: Float) -> Bool {
        let i = Int((x / pitch).rounded()), j = Int((z / pitch).rounded())
        return abs(x - Float(i) * pitch) < lineX(i).halfWidth || abs(z - Float(j) * pitch) < lineZ(j).halfWidth
    }
}
