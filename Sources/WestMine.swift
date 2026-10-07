import SceneKit
import simd

// Old mines: a straight timbered tunnel driven right through one of the buttes in the canyon, open at both ends —
// lanterns on the props, rails on the floor, a cart left outside. Fly in one side and out the other.

struct WestMineTunnel {
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let floorY: Float
    let axis: SIMD3<Float>
    let side: SIMD3<Float>
    let length: Float
    static let halfWidth: Float = 3.3
    static let height: Float = 6.4
    var mid: SIMD3<Float> { (a + b) * 0.5 }

    /// (along, across) of a point, along from `a`.
    @inline(__always) func local(_ p: SIMD3<Float>) -> (Float, Float) { (simd_dot(p - a, axis), simd_dot(p - a, side)) }

    var air: CitySubway.Air {
        let c = mid + SIMD3(0, Self.height / 2, 0)
        let rot = simd_quatf(from: SIMD3(0, 0, 1), to: axis)
        return CitySubway.Air(box: OBox(center: c, rot: rot, half: SIMD3(Self.halfWidth, Self.height / 2, length / 2 + 12)))
    }
}

enum WestMine {
    private static let lock = NSLock()
    private static var cache: [ChunkKey: WestMineTunnel?] = [:]

    /// The mine through the butte in a cell, if it has one.
    static func tunnel(_ i: Int, _ j: Int, _ t: WestTerrain) -> WestMineTunnel? {
        let k = ChunkKey(x: i, z: j)
        lock.lock()
        if let v = cache[k] { lock.unlock(); return v }
        lock.unlock()
        let v = make(i, j, t)
        lock.lock()
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        cache[k] = v
        lock.unlock()
        return v
    }

    private static func make(_ i: Int, _ j: Int, _ t: WestTerrain) -> WestMineTunnel? {
        guard let b = t.butte(i, j) else { return nil }
        var rng = cellRNG(i, j, 0x31_7E)
        guard rng.float() < 0.55 else { return nil }
        let c = SIMD3(b.x, 0, b.y)
        for _ in 0..<6 {
            let ang = rng.float(0, 6.28)
            let dir = SIMD3(cos(ang), 0, sin(ang))
            let rt = b.z * 0.68
            // The ground in front of each mouth (out to 30 m), and the floor a few metres above the highest of it.
            var gm: Float = -1e9
            for s in stride(from: rt + 4, through: rt + 34, by: 3) {
                for q in [c - dir * s, c + dir * s] { gm = max(gm, t.height(q.x, q.z)) }
            }
            let floorY = gm + 3.5
            // The rock has to stand well above the tunnel all the way through.
            var solid = true
            for s in stride(from: -rt + 3, through: rt - 3, by: 6) {
                let q = c + dir * s
                if t.height(q.x, q.z) < floorY + WestMineTunnel.height + 6 { solid = false; break }
            }
            guard solid, gm > 1 else { continue }
            let a = c - dir * (rt + 2), e = c + dir * (rt + 2)
            return WestMineTunnel(a: SIMD3(a.x, floorY, a.z), b: SIMD3(e.x, floorY, e.z), floorY: floorY, axis: dir,
                                  side: simd_normalize(simd_cross(dir, kUp)), length: simd_distance(a, e))
        }
        return nil
    }

    static func near(_ x: Float, _ z: Float, _ t: WestTerrain) -> [WestMineTunnel] {
        let c = WestTerrain.butteCell
        let ci = Int(floor(x / c)), cj = Int(floor(z / c))
        var out: [WestMineTunnel] = []
        for dj in -1...1 { for di in -1...1 { if let m = tunnel(ci + di, cj + dj, t) { out.append(m) } } }
        return out
    }

    /// Cells cut out where a tunnel comes out of the rock.
    static func isHole(_ x: Float, _ z: Float, _ t: WestTerrain) -> Bool {
        for m in near(x, z, t) {
            let (s, l) = m.local(SIMD3(x, 0, z))
            guard abs(l) < WestMineTunnel.halfWidth + 1.6 else { continue }
            if (s > -4 && s < 4) || (s > m.length - 4 && s < m.length + 4) {
                if t.height(x, z) > m.floorY + 0.5 { return true }
            }
        }
        return false
    }

    /// Gold nuggets glinting along a tunnel's walls, swapping sides every 15 m, low and high — fly close to take them.
    static func nuggets(_ m: WestMineTunnel) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let heights: [Float] = [1.5, 3.9, 2.4, 4.5, 1.9]
        var s: Float = 12, k = 0
        while s < m.length - 8 {
            let l = (k % 2 == 0 ? 1 : -1) * (WestMineTunnel.halfWidth - 1.0)
            out.append(m.a + m.axis * s + m.side * l + SIMD3(0, heights[k % heights.count], 0))
            s += 15; k += 1
        }
        return out
    }

    static func floorUnder(_ p: SIMD3<Float>, _ t: WestTerrain) -> Float? {
        for m in near(p.x, p.z, t) {
            let (s, l) = m.local(p)
            if s > -5 && s < m.length + 5 && abs(l) < WestMineTunnel.halfWidth + 1.2 && p.y > m.floorY - 0.8 && p.y < m.floorY + WestMineTunnel.height + 1 {
                return m.floorY
            }
        }
        return nil
    }

    /// The tunnel's insides, the timber portals and a cart, for the chunk the tunnel's middle is in.
    static func nodes(key: ChunkKey, ox: Float, oz: Float, _ t: WestTerrain) -> [SCNNode] {
        var rock = MeshBuilder(), timber = MeshBuilder(), glow = MeshBuilder()
        let origin = SIMD3(ox, 0, oz)
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }
        for m in near(ox + t.chunkSize / 2, oz + t.chunkSize / 2, t) {
            let mid = m.mid
            guard mid.x >= ox, mid.x < ox + t.chunkSize, mid.z >= oz, mid.z < oz + t.chunkSize else { continue }
            let W = WestMineTunnel.halfWidth, H = WestMineTunnel.height
            let rockC = SIMD3<Float>(0.36, 0.3, 0.26), wood = SIMD3<Float>(0.45, 0.33, 0.22)
            func P(_ s: Float, _ l: Float, _ y: Float) -> SIMD3<Float> { L(m.a + m.axis * s + m.side * l + SIMD3(0, y, 0)) }
            func lamp(_ s: Float) -> Float {
                let d = abs(s - (s / 8).rounded() * 8)
                return 0.16 + 0.9 / (1 + d * d / 6)
            }
            var s: Float = -3
            while s < m.length + 3 {
                let e = min(s + 2, m.length + 3)
                let k0 = lamp(s), k1 = lamp(e)
                func q(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD3<Float>, _ f: SIMD3<Float>) {
                    rock.quadColors(a, b, c, d, col * k0, col * k1, col * k1, col * k0, facing: f)
                }
                let wob = Float(Int(s / 2) % 3) * 0.12
                q(P(s, -W, 0.02), P(e, -W, 0.02), P(e, W, 0.02), P(s, W, 0.02), SIMD3(0.3, 0.26, 0.22), kUp)
                q(P(s, -W + wob, 0), P(e, -W, 0), P(e, -W, H * 0.8), P(s, -W + wob, H * 0.8), rockC, m.side)
                q(P(e, W, 0), P(s, W - wob, 0), P(s, W - wob, H * 0.8), P(e, W, H * 0.8), rockC, -m.side)
                q(P(s, -W + wob, H * 0.8), P(e, -W, H * 0.8), P(e, -W * 0.5, H), P(s, -W * 0.5, H), rockC * 0.9, m.side - kUp)
                q(P(e, W, H * 0.8), P(s, W - wob, H * 0.8), P(s, W * 0.5, H), P(e, W * 0.5, H), rockC * 0.9, -m.side - kUp)
                q(P(s, -W * 0.5, H), P(e, -W * 0.5, H), P(e, W * 0.5, H), P(s, W * 0.5, H), rockC * 0.8, -kUp)
                s = e
            }
            // Timber sets every 4 m; rails; lanterns.
            var ts: Float = 0
            while ts <= m.length {
                for l: Float in [-W + 0.35, W - 0.35] {
                    timber.tube(P(ts, l, 0), P(ts, l * 0.92, H - 0.4), r0: 0.18, r1: 0.16, sides: 4, wood)
                }
                timber.tube(P(ts, -W + 0.2, H - 0.45), P(ts, W - 0.2, H - 0.45), r0: 0.2, r1: 0.2, sides: 4, wood * 0.9)
                if Int((ts / 4).rounded()) % 2 == 0 { glow.ellipsoid(P(ts, 0, H - 1.0), SIMD3(repeating: 0.2), SIMD3(1, 0.75, 0.4), rings: 2, sides: 6) }
                ts += 4
            }
            for l: Float in [-0.55, 0.55] {
                timber.boxAA(simd_min(P(-6, l - 0.04, 0.02), P(m.length + 6, l + 0.04, 0.14)), simd_max(P(-6, l - 0.04, 0.02), P(m.length + 6, l + 0.04, 0.14)),
                             SIMD3(0.35, 0.33, 0.32))
            }
            // Heavy portals at both ends, and an ore cart outside one of them.
            for (sEnd, out) in [(Float(0), Float(-1)), (m.length, Float(1))] {
                for l: Float in [-W - 0.3, W + 0.3] {
                    timber.tube(P(sEnd + out * 0.4, l, -0.5), P(sEnd + out * 0.4, l, H + 0.6), r0: 0.35, r1: 0.33, sides: 5, wood * 0.85)
                }
                timber.tube(P(sEnd + out * 0.4, -W - 1.2, H + 0.35), P(sEnd + out * 0.4, W + 1.2, H + 0.35), r0: 0.4, r1: 0.4, sides: 5, wood * 0.8)
                glow.ellipsoid(P(sEnd + out * 0.8, W + 0.6, H - 1.2), SIMD3(repeating: 0.24), SIMD3(1, 0.72, 0.38), rings: 2, sides: 6)
            }
            let cart = m.a - m.axis * 5 + SIMD3(0, 0.15, 0)
            timber.boxAA(L(cart + SIMD3(-0.8, 0.5, -0.8)), L(cart + SIMD3(0.8, 1.6, 0.8)), SIMD3(0.3, 0.3, 0.32))
            for (dx, dz) in [(-0.6, -0.6), (0.6, -0.6), (0.6, 0.6), (-0.6, 0.6)] as [(Float, Float)] {
                timber.cylinder(L(cart + SIMD3(dx, 0.3, dz)), r0: 0.3, r1: 0.3, y0: -0.12, y1: 0.12, sides: 8, SIMD3(0.2, 0.2, 0.2))
            }
            timber.ellipsoid(L(cart + SIMD3(0, 1.7, 0)), SIMD3(0.7, 0.3, 0.7), SIMD3(0.55, 0.45, 0.25), rings: 2, sides: 6)
        }
        var out: [SCNNode] = []
        for (name, mesh, mat, hide) in [("mine", rock, WestMine.inside, Float(500)), ("mine timbers", timber, WestTerrain.townProps, Float(900)),
                                        ("mine lamps", glow, WestTerrain.lampGlow, Float(700))] as [(String, MeshBuilder, SCNMaterial, Float)] where !mesh.isEmpty {
            let g = mesh.geometry()
            g.materials = [mat]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: CGFloat(hide))]
            let n = SCNNode(geometry: g)
            n.name = name
            n.castsShadow = name != "mine"
            out.append(n)
        }
        return out
    }

    /// Lit only by its lanterns (baked into the colours), dark from outside — like the subway.
    static let inside: SCNMaterial = CityShaders.subway
}
