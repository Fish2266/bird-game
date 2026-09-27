import SceneKit
import simd

/// Faceted, flat-shaded rocks in the same low-poly style as the terrain and its trees: sea stacks, boulders, natural
/// arches and the rocky bottoms of floating islands. Each piece is one mesh whose faces get small colour changes and
/// horizontal strata, so it reads as layered rock rather than a pile of smooth blobs.
enum Rocks {
    /// Vertex colours × the terrain's speckle texture (so rocks and ground look like the same stuff).
    static func material() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = TerrainManager.detailTexture()
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.92
        m.metalness.contents = 0.0
        return m
    }

    /// Flat triangles with their own normals and colours.
    struct Builder {
        var m = MeshBuilder()

        mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ color: SIMD3<Float>) { m.flatTri(a, b, c, color) }

        /// Two triangles; a b c d go counter-clockwise seen from outside.
        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ color: SIMD3<Float>,
                           _ color2: SIMD3<Float>? = nil) {
            m.flatTri(a, b, c, color); m.flatTri(a, c, d, color2 ?? color)
        }

        func node(_ material: SCNMaterial) -> SCNNode {
            let g = m.geometry()
            g.materials = [material]
            return SCNNode(geometry: g)
        }
    }

    /// Colour of one face: the base with a little random variation, lighter strata bands, and moss or grass on faces
    /// that look up.
    static func shade(_ base: SIMD3<Float>, normal n: SIMD3<Float>, band: Int, grass: SIMD3<Float>?, _ rng: inout SplitMix64) -> SIMD3<Float> {
        var c = base * rng.float(0.9, 1.07)
        c *= band % 3 == 0 ? 1.08 : (band % 3 == 1 ? 0.95 : 1.0)
        if n.y < -0.3 { c *= 0.82 }            // overhangs are darker
        if let grass, n.y > 0.62 { c = simd_mix(c, grass, SIMD3(repeating: 0.75)) }
        return c
    }

    private static func normalOf(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        return simd_length(n) > 1e-6 ? simd_normalize(n) : kUp
    }

    // MARK: Pieces

    /// A rock column from y = 0 up to `h` (sea stack, arch leg): rings of corners that wobble in size and position,
    /// with overhanging ledges between strata. Returns the node and the top ring (for a grassy cap).
    static func column(height h: Float, r0: Float, r1: Float, color: SIMD3<Float>, grass: SIMD3<Float>? = nil, sides: Int = 7,
                       material: SCNMaterial, _ rng: inout SplitMix64) -> (node: SCNNode, top: [SIMD3<Float>]) {
        var b = Builder()
        var rings: [[SIMD3<Float>]] = []
        var bands: [Int] = []
        var y: Float = 0
        var center = SIMD2<Float>(0, 0)
        var twist = rng.float(0, 1)
        var band = 0
        // Wobble per corner stays similar from ring to ring, so the column has ribs instead of noise.
        let lean = (0..<sides).map { _ in rng.float(0.84, 1.14) }
        let bulgePhase = rng.float(0, 6.28), bulgeRate = rng.float(0.12, 0.2)
        while true {
            let t = min(y / max(h, 1), 1)
            // Wider foot, a slow taper, and a gentle swell or two along the way.
            var r = lerp(r0, r1, t) * (1 + 0.28 * smoothstep(0.18, 0, t)) * (1 + 0.1 * sin(y * bulgeRate + bulgePhase))
            // Every other ring steps in: stratum top, then the next stratum pokes out a little (a ledge).
            let ledge = rings.count % 2 == 1
            r *= ledge ? rng.float(0.84, 0.92) : rng.float(0.98, 1.08)
            var ring: [SIMD3<Float>] = []
            for s in 0..<sides {
                let a = twist + Float(s) / Float(sides) * 2 * .pi
                let rr = r * lean[s] * rng.float(0.93, 1.07)
                ring.append(SIMD3(center.x + cos(a) * rr, y + rng.float(-0.3, 0.3) * (y > 0 && t < 1 ? 1 : 0), center.y + sin(a) * rr))
            }
            rings.append(ring)
            bands.append(band)
            if y >= h { break }
            let step = ledge ? rng.float(2.8, 4.6) : rng.float(0.5, 0.9)
            y = min(y + step, h)
            if !ledge { band += 1 }
            center += SIMD2(rng.float(-0.25, 0.25), rng.float(-0.25, 0.25)) * r0 * 0.12
            twist += rng.float(-0.12, 0.12)
        }
        for k in 0..<(rings.count - 1) {
            let lo = rings[k], hi = rings[k + 1]
            for s in 0..<sides {
                let s1 = (s + 1) % sides
                let n = normalOf(lo[s], hi[s1], lo[s1])
                let c1 = shade(color, normal: n, band: bands[k], grass: grass, &rng)
                let c2 = shade(color, normal: n, band: bands[k], grass: grass, &rng)
                b.quad(lo[s], hi[s], hi[s1], lo[s1], c1, c2)
            }
        }
        // Flat top with a slight dome (covered by grass when there is a cap).
        let top = rings[rings.count - 1]
        let mid = top.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides) + SIMD3(0, 0.4, 0)
        for s in 0..<sides {
            b.tri(mid, top[(s + 1) % sides], top[s], shade(color, normal: kUp, band: band, grass: nil, &rng) * 1.05)
        }
        return (b.node(material), top)
    }

    /// A grassy cap on a rock top: the top outline grown outward, drooping at the edge, with a few little pines.
    static func turf(on top: [SIMD3<Float>], color: SIMD3<Float>, trees: Int, _ rng: inout SplitMix64) -> SCNNode {
        var b = Builder()
        let n = top.count
        let mid = top.reduce(SIMD3<Float>(repeating: 0), +) / Float(n)
        let rim = top.map { p -> SIMD3<Float> in
            let d = SIMD3(p.x - mid.x, 0, p.z - mid.z)
            return p + d * 0.12 + SIMD3(0, -0.7, 0)
        }
        let inner = top.map { p -> SIMD3<Float> in simd_mix(p, mid, SIMD3(repeating: 0.35)) + SIMD3(0, 0.55, 0) }
        let peak = mid + SIMD3(0, 0.8, 0)
        for s in 0..<n {
            let s1 = (s + 1) % n
            b.quad(rim[s], inner[s], inner[s1], rim[s1], color * rng.float(0.85, 0.97), color * rng.float(0.85, 0.97))
            b.tri(peak, inner[s1], inner[s], color * rng.float(0.97, 1.1))
        }
        let node = SCNNode()
        let m = material()
        node.addChildNode(b.node(m))
        if trees > 0 {
            var t = MeshBuilder()
            let radius = top.map { simd_distance(SIMD2($0.x, $0.z), SIMD2(mid.x, mid.z)) }.min() ?? 2
            for k in 0..<trees {
                let a = rng.float(0, 6.28)
                let d = k == 0 ? rng.float(0, 0.25) * radius : rng.float(0.3, 0.6) * radius
                let hgt = rng.float(3.2, 5.5) * (k == 0 ? 1.15 : 0.9)
                let tint = rng.float(-0.04, 0.04)
                TerrainManager.addPine(&t, base: mid + SIMD3(cos(a) * d, 0.3, sin(a) * d), height: hgt, radius: hgt * 0.3,
                                       foliage: SIMD3(0.12 + tint, 0.30 + tint * 1.5, 0.13), yaw: rng.float(0, 6.28))
            }
            let g = t.geometry()
            g.materials = [m]
            node.addChildNode(SCNNode(geometry: g))
        }
        return node
    }

    /// A chunky faceted boulder about `r` across (a jittered, squashed icosahedron).
    static func boulder(_ r: Float, color: SIMD3<Float>, grass: SIMD3<Float>? = nil, material: SCNMaterial,
                        _ rng: inout SplitMix64) -> SCNNode {
        var b = MeshBuilder()
        b.boulder(at: .zero, radius: r, color: color, grass: grass, &rng)
        let g = b.geometry()
        g.materials = [material]
        return SCNNode(geometry: g)
    }

    /// The bottom of a floating island: a jagged cone of rock pointing down from y = 0 to about -depth.
    static func underside(radius r: Float, depth: Float, color: SIMD3<Float>, sides: Int = 8, material: SCNMaterial,
                          _ rng: inout SplitMix64) -> SCNNode {
        var b = Builder()
        var rings: [[SIMD3<Float>]] = []
        let levels = 5
        var center = SIMD2<Float>(0, 0)
        for k in 0..<levels {
            let t = Float(k) / Float(levels)
            let rr = r * pow(1 - t, 0.8)
            var ring: [SIMD3<Float>] = []
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi + Float(k) * 0.3
                let w = rr * rng.float(0.78, 1.15)
                ring.append(SIMD3(center.x + cos(a) * w, -depth * t + rng.float(-0.6, 0.6) * (k > 0 ? 1 : 0), center.y + sin(a) * w))
            }
            rings.append(ring)
            center += SIMD2(rng.float(-0.12, 0.12), rng.float(-0.12, 0.12)) * r
        }
        let tip = SIMD3(center.x, -depth * rng.float(1.0, 1.15), center.y)
        for k in 0..<(levels - 1) {
            for s in 0..<sides {
                let s1 = (s + 1) % sides
                let hi = rings[k], lo = rings[k + 1]
                let n = normalOf(lo[s], hi[s], hi[s1])
                b.quad(lo[s], lo[s1], hi[s1], hi[s], shade(color, normal: n, band: k, grass: nil, &rng) * 0.92,
                       shade(color, normal: n, band: k, grass: nil, &rng) * 0.92)
            }
        }
        let last = rings[levels - 1]
        for s in 0..<sides {
            b.tri(tip, last[(s + 1) % sides], last[s], color * rng.float(0.7, 0.85))
        }
        // Lid (usually hidden under the island top).
        let top = rings[0]
        let mid = top.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides)
        for s in 0..<sides { b.tri(mid, top[(s + 1) % sides], top[s], color) }
        return b.node(material)
    }

    /// A rock span along `path` (the arch's bridge): a lumpy tube with a polygon cross-section, thicker at the ends.
    static func span(_ path: [SIMD3<Float>], radius: Float, color: SIMD3<Float>, grass: SIMD3<Float>?, sides: Int = 7,
                     material: SCNMaterial, _ rng: inout SplitMix64) -> SCNNode {
        var b = Builder()
        var rings: [[SIMD3<Float>]] = []
        let lean = (0..<sides).map { _ in rng.float(0.85, 1.12) }
        for (i, p) in path.enumerated() {
            let prev = path[max(i - 1, 0)], next = path[min(i + 1, path.count - 1)]
            let fwd = simd_normalize(next - prev)
            var side = simd_cross(fwd, kUp)
            if simd_length(side) < 1e-3 { side = SIMD3(1, 0, 0) }
            side = simd_normalize(side)
            let up = simd_normalize(simd_cross(side, fwd))
            let t = Float(i) / Float(max(path.count - 1, 1))
            let r = radius * (1 + 0.35 * pow(abs(t * 2 - 1), 3))
            var ring: [SIMD3<Float>] = []
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi + 0.3
                let w = r * lean[s] * rng.float(0.92, 1.08)
                // A slightly flattened section: taller than wide reads better from below.
                ring.append(p + side * cos(a) * w * 0.95 + up * sin(a) * w * 1.1)
            }
            rings.append(ring)
        }
        for k in 0..<(rings.count - 1) {
            for s in 0..<sides {
                let s1 = (s + 1) % sides
                let a = rings[k], c = rings[k + 1]
                let n = normalOf(a[s], a[s1], c[s1])
                b.quad(a[s], a[s1], c[s1], c[s], shade(color, normal: n, band: k / 2, grass: grass, &rng),
                       shade(color, normal: n, band: k / 2, grass: grass, &rng))
            }
        }
        for (ring, flip) in [(rings[0], true), (rings[rings.count - 1], false)] {
            let mid = ring.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides)
            for s in 0..<sides {
                let s1 = (s + 1) % sides
                if flip { b.tri(mid, ring[s1], ring[s], color) } else { b.tri(mid, ring[s], ring[s1], color) }
            }
        }
        return b.node(material)
    }

    /// A long jagged spike of rock pointing down: the tip at y = 0, widening to `radius` at `length`, then straight up
    /// to `top` (buried in the ceiling). Glowing crystals poke out of its sides.
    static func stalactite(length: Float, top: Float, radius: Float, color: SIMD3<Float>, crystal: SIMD3<Float>,
                           material: SCNMaterial, _ rng: inout SplitMix64) -> SCNNode {
        var b = Builder(), glow = MeshBuilder()
        let sides = 7
        let levels: [Float] = [0.1, 0.24, 0.42, 0.62, 0.82, 1.0].map { $0 * length } + [length + (top - length) * 0.5, top]
        func r(_ y: Float) -> Float { radius * pow(min(y / length, 1), 0.75) }
        var rings: [[SIMD3<Float>]] = []
        var twist = rng.float(0, 1)
        for y in levels {
            var ring: [SIMD3<Float>] = []
            for s in 0..<sides {
                let a = twist + Float(s) / Float(sides) * 2 * .pi
                let w = r(y) * rng.float(0.82, 1.14)
                ring.append(SIMD3(cos(a) * w, y + rng.float(-0.3, 0.3) * (y < top ? 1 : 0), sin(a) * w))
            }
            rings.append(ring)
            twist += rng.float(-0.25, 0.25)
        }
        let tip = SIMD3<Float>(rng.float(-0.1, 0.1), 0, rng.float(-0.1, 0.1))
        let first = rings[0]
        for s in 0..<sides {
            let s1 = (s + 1) % sides
            b.tri(tip, first[s], first[s1], color * rng.float(0.8, 0.95))
        }
        for k in 0..<(rings.count - 1) {
            let lo = rings[k], hi = rings[k + 1]
            for s in 0..<sides {
                let s1 = (s + 1) % sides
                let n = normalOf(lo[s], hi[s], hi[s1])
                b.quad(lo[s], hi[s], hi[s1], lo[s1], shade(color, normal: n, band: k, grass: nil, &rng),
                       shade(color, normal: n, band: k, grass: nil, &rng))
            }
        }
        let cap = rings[rings.count - 1]
        let mid = cap.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides)
        for s in 0..<sides { b.tri(mid, cap[(s + 1) % sides], cap[s], color) }
        // Crystal clusters on the lower half, pointing out and a little down.
        for _ in 0..<4 {
            let y = length * rng.float(0.3, 0.8)
            let a = rng.float(0, 6.28)
            let base = SIMD3(cos(a) * r(y) * 0.85, y, sin(a) * r(y) * 0.85)
            for k in 0..<3 {
                let spread = SIMD3(rng.float(-0.35, 0.35), rng.float(-0.25, 0.2), rng.float(-0.35, 0.35))
                let dir = SIMD3(cos(a), -0.35, sin(a)) + spread
                let len = (k == 0 ? 1.8 : 1.1) * rng.float(0.8, 1.2)
                glow.crystal(base: base, dir: dir, length: len, radius: len * 0.18, color: crystal * rng.float(0.85, 1.05), twist: rng.float(0, 1))
            }
        }
        let n = b.node(material)
        let g = glow.geometry()
        g.materials = [glowMat(.white, 1.8)]
        n.addChildNode(SCNNode(geometry: g))
        return n
    }

    /// A six-sided basalt column from y = 0 to `h` (volcano spires): straight faces, a slightly tilted top.
    @discardableResult
    static func basalt(radius r: Float, height h: Float, color: SIMD3<Float>, into b: inout Builder, at o: SIMD3<Float>,
                       yaw: Float, _ rng: inout SplitMix64) -> [SIMD3<Float>] {
        let sides = 6
        var lo: [SIMD3<Float>] = [], hi: [SIMD3<Float>] = []
        let tilt = SIMD2<Float>(rng.float(-0.12, 0.12), rng.float(-0.12, 0.12))
        for s in 0..<sides {
            let a = yaw + Float(s) / Float(sides) * 2 * .pi
            let x = cos(a) * r * rng.float(0.94, 1.06), z = sin(a) * r * rng.float(0.94, 1.06)
            lo.append(o + SIMD3(x, 0, z))
            hi.append(o + SIMD3(x * 0.96, h + x * tilt.x + z * tilt.y, z * 0.96))
        }
        for s in 0..<sides {
            let s1 = (s + 1) % sides
            let shadeK: Float = s % 2 == 0 ? 1.0 : 0.88
            b.quad(lo[s], hi[s], hi[s1], lo[s1], color * shadeK * rng.float(0.92, 1.06))
        }
        let mid = hi.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides)
        for s in 0..<sides { b.tri(mid, hi[(s + 1) % sides], hi[s], color * 1.12) }
        return hi
    }
}

// MARK: - Flat-shaded pieces for chunk meshes

extension MeshBuilder {
    /// One flat triangle (counter-clockwise seen from outside) with planar texture coordinates for the speckle.
    mutating func flatTri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ color: SIMD3<Float>) {
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        guard len > 1e-6 else { return }
        n /= len
        func uv(_ p: SIMD3<Float>) -> SIMD2<Float> {
            if abs(n.y) > 0.6 { return SIMD2(p.x, p.z) / 9 }
            return (abs(n.x) > abs(n.z) ? SIMD2(p.z, p.y) : SIMD2(p.x, p.y)) / 9
        }
        let i = vertexCount
        vertex(a, n, color, uv: uv(a)); vertex(b, n, color, uv: uv(b)); vertex(c, n, color, uv: uv(c))
        tri(i, i + 1, i + 2)
    }

    /// A triangle facing away from `inside` whichever way its corners were listed.
    mutating func outwardTri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, inside: SIMD3<Float>, _ color: SIMD3<Float>) {
        let n = simd_cross(b - a, c - a)
        if simd_dot(n, (a + b + c) / 3 - inside) >= 0 { flatTri(a, b, c, color) } else { flatTri(a, c, b, color) }
    }

    /// A tapered prism from `a` to `b` (a branch, a vine, a crystal body); `r1` = 0 ends in a point.
    mutating func limb(from a: SIMD3<Float>, to b: SIMD3<Float>, r0: Float, r1: Float, sides: Int, color: SIMD3<Float>,
                       tipColor: SIMD3<Float>? = nil, twist: Float = 0) {
        let axis = simd_normalize(b - a)
        var side = simd_cross(axis, kUp)
        if simd_length(side) < 1e-3 { side = SIMD3(1, 0, 0) }
        side = simd_normalize(side)
        let up = simd_cross(side, axis)
        let mid = (a + b) / 2
        for s in 0..<sides {
            let a0 = twist + Float(s) / Float(sides) * 2 * .pi, a1 = twist + Float(s + 1) / Float(sides) * 2 * .pi
            let d0 = side * cos(a0) + up * sin(a0), d1 = side * cos(a1) + up * sin(a1)
            let p0 = a + d0 * r0, p1 = a + d1 * r0
            let shadeK: Float = s % 2 == 0 ? 1 : 0.9
            if r1 <= 0.001 {
                outwardTri(p0, p1, b, inside: mid - axis * 0.01, (tipColor ?? color) * shadeK)
            } else {
                let q0 = b + d0 * r1, q1 = b + d1 * r1
                outwardTri(p0, p1, q1, inside: mid, color * shadeK)
                outwardTri(p0, q1, q0, inside: mid, (tipColor ?? color) * shadeK)
            }
        }
    }

    /// A six-sided crystal growing from `base` along `dir`: a prism with a pointed tip.
    mutating func crystal(base: SIMD3<Float>, dir: SIMD3<Float>, length: Float, radius: Float, color: SIMD3<Float>, twist: Float) {
        let d = simd_normalize(dir)
        let shoulder = base + d * length * 0.72
        limb(from: base - d * 0.4, to: shoulder, r0: radius, r1: radius * 0.92, sides: 6, color: color * 0.8, tipColor: color, twist: twist)
        limb(from: shoulder, to: base + d * length, r0: radius * 0.92, r1: 0, sides: 6, color: color * 1.1, tipColor: color * 1.3, twist: twist)
    }

    /// A chunky faceted boulder (a jittered, squashed icosahedron) centred on `p`.
    mutating func boulder(at p: SIMD3<Float>, radius r: Float, color: SIMD3<Float>, grass: SIMD3<Float>? = nil, _ rng: inout SplitMix64) {
        let t = (1 + sqrt(Float(5))) / 2
        var v: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1)].map { simd_normalize($0) }
        let faces: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
                                        (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
                                        (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        let squash = SIMD3<Float>(rng.float(0.9, 1.15), rng.float(0.62, 0.8), rng.float(0.9, 1.15))
        let q = simd_quatf(angle: rng.float(0, 6.28), axis: kUp)
        v = v.map { p + q.act($0 * squash * r * rng.float(0.82, 1.12)) }
        for (i, j, k) in faces {
            let n = simd_normalize(simd_cross(v[j] - v[i], v[k] - v[i]))
            flatTri(v[i], v[j], v[k], Rocks.shade(color, normal: n, band: 0, grass: grass, &rng))
        }
    }

    /// A charred dead tree: a leaning trunk with a few bare branches.
    mutating func snag(at p: SIMD3<Float>, height h: Float, color: SIMD3<Float>, _ rng: inout SplitMix64) {
        let lean = SIMD3(rng.float(-0.12, 0.12), 1, rng.float(-0.12, 0.12))
        let top = p + simd_normalize(lean) * h
        limb(from: p - SIMD3(0, 0.6, 0), to: top, r0: h * 0.055, r1: h * 0.012, sides: 5, color: color, twist: rng.float(0, 6))
        let branches = Int(rng.float(2, 4.99))
        for k in 0..<branches {
            let at = rng.float(0.42, 0.8)
            let start = p + (top - p) * at
            let a = Float(k) / Float(branches) * 2 * .pi + rng.float(-0.5, 0.5)
            let out = SIMD3(cos(a), rng.float(0.7, 1.3), sin(a))
            let len = h * rng.float(0.2, 0.36) * (1.1 - at * 0.5)
            let end = start + simd_normalize(out) * len
            limb(from: start, to: end, r0: h * 0.022, r1: 0, sides: 4, color: color * 1.05)
            // A twig off the branch.
            if rng.float() < 0.6 {
                let mid = start + (end - start) * 0.55
                let tw = mid + simd_normalize(SIMD3(-sin(a), 1.2, cos(a)) * rng.float(-1, 1) + SIMD3(0, 1, 0)) * len * 0.4
                limb(from: mid, to: tw, r0: h * 0.012, r1: 0, sides: 3, color: color * 1.05)
            }
        }
    }
}
