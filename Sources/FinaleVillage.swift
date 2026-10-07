import SceneKit
import simd

// The village below the castle: timber-framed cottages round a cobbled plaza with a well and market stalls, lamplight
// in the windows, and a windmill turning on the rise beyond. Built per terrain chunk like any other scenery.

enum FinaleVillage {
    struct Cottage {
        let c: SIMD2<Float>
        let yaw: Float
        let w: Float, d: Float
        let roof: SIMD3<Float>
        let plaster: SIMD3<Float>
    }

    static let cottages: [Cottage] = {
        let L = FinaleLayout.self
        var out: [Cottage] = []
        var rng = SplitMix64(seed: 0xC0_77)
        let roofs: [SIMD3<Float>] = [SIMD3(0.72, 0.30, 0.20), SIMD3(0.62, 0.26, 0.18), SIMD3(0.78, 0.66, 0.38), SIMD3(0.34, 0.36, 0.48)]
        let plasters: [SIMD3<Float>] = [SIMD3(0.96, 0.92, 0.84), SIMD3(0.94, 0.86, 0.72), SIMD3(0.90, 0.88, 0.86), SIMD3(0.98, 0.90, 0.80)]
        for ring in 0..<2 {
            let n = ring == 0 ? 12 : 16
            for k in 0..<n {
                let a = Float(k) / Float(n) * 2 * .pi + Float(ring) * 0.2 + rng.float(-0.08, 0.08)
                // Leave the road (north, toward the castle) and a lane out to the south clear.
                let toward = SIMD2(cos(a), sin(a))
                if toward.y < -0.88 || toward.y > 0.92 { continue }
                let r = (ring == 0 ? 62 : 108) + rng.float(-6, 8)
                let c = L.village + toward * r
                out.append(Cottage(c: c, yaw: atan2(toward.x, toward.y), w: rng.float(8, 11.5), d: rng.float(6, 8),
                                   roof: roofs[Int(rng.float(0, 3.99))], plaster: plasters[Int(rng.float(0, 3.99))]))
            }
        }
        return out
    }()

    static let windmill = SIMD2<Float>(150, 790)

    static func nodes(key: ChunkKey, ox: Float, oz: Float, _ t: FinaleTerrain) -> [SCNNode] {
        let L = FinaleLayout.self
        let lo = SIMD2(ox, oz), hi = lo + SIMD2(repeating: t.chunkSize)
        func inside(_ p: SIMD2<Float>) -> Bool { p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y }
        var house = MeshBuilder(), glow = MeshBuilder()
        let origin = SIMD3(ox, 0, oz)
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }
        for c in cottages where inside(c.c) {
            let y = L.villageY
            let rot = yawQuat(c.yaw)
            func P(_ x: Float, _ yy: Float, _ z: Float) -> SIMD3<Float> { local(SIMD3(c.c.x, 0, c.c.y) + rot.act(SIMD3(x, 0, z)) + SIMD3(0, yy, 0)) }
            let w = c.w / 2, d = c.d / 2, eave = y + 4.6, ridge = eave + c.d * 0.55
            house.box(P(0, (y - 1 + eave) / 2, 0), SIMD3(w, (eave - y + 1) / 2, d), c.plaster, rot: rot)
            // Timber framing: posts and a beam across the front and back.
            let timber = SIMD3<Float>(0.32, 0.22, 0.15)
            for s: Float in [-1, 1] {
                for x in stride(from: -w, through: w + 0.01, by: c.w / 3) {
                    house.box(P(x, (y + eave) / 2, s * (d + 0.06)), SIMD3(0.16, (eave - y) / 2, 0.06), timber, rot: rot)
                }
                house.box(P(0, y + 2.4, s * (d + 0.07)), SIMD3(w, 0.12, 0.06), timber, rot: rot)
                // Gables.
                house.quad(P(-w, eave, s * d), P(w, eave, s * d), P(0, ridge, s * d), P(0, ridge, s * d), c.plaster, facing: rot.act(SIMD3(0, 0, s)))
            }
            // The roof (overhanging), and a chimney.
            for s: Float in [-1, 1] {
                house.quadUV(P(s * (w + 0.7), eave - 0.4, -d - 0.6), P(s * (w + 0.7), eave - 0.4, d + 0.6), P(0, ridge + 0.2, d + 0.6), P(0, ridge + 0.2, -d - 0.6),
                             c.roof, SIMD2(1, 0), SIMD2(1, 0), SIMD2(1, 0), SIMD2(1, 0), facing: rot.act(SIMD3(s, 1, 0)))
            }
            house.box(P(w * 0.5, ridge, -d * 0.3), SIMD3(0.5, 1.6, 0.5), SIMD3(0.62, 0.5, 0.42), rot: rot)
            // Windows lit warm, a door facing the plaza (the cottage's −z side faces in).
            for s: Float in [-1, 1] {
                for x: Float in [-w * 0.55, w * 0.55] {
                    let base = P(x, y + 2.1, s * (d + 0.08))
                    let right = rot.act(SIMD3(0.55, 0, 0)), up = SIMD3<Float>(0, 1.1, 0)
                    glow.quad(base - right, base + right, base + right + up, base - right + up, SIMD3(1, 0.8, 0.5), facing: rot.act(SIMD3(0, 0, s)))
                }
            }
            let door = P(0, y, -d - 0.09)
            let dr = rot.act(SIMD3(0.7, 0, 0))
            house.quad(door - dr, door + dr, door + dr + SIMD3(0, 2.3, 0), door - dr + SIMD3(0, 2.3, 0), SIMD3(0.42, 0.26, 0.14), facing: rot.act(SIMD3(0, 0, -1)))
        }
        // The plaza: a well and market stalls with striped awnings.
        if inside(L.village) {
            let c = SIMD3(L.village.x, L.villageY, L.village.y)
            house.cylinder(local(c), r0: 2.2, r1: 2.2, y0: 0, y1: 1.1, sides: 14, SIMD3(0.7, 0.66, 0.6))
            for s: Float in [-1, 1] { house.tube(local(c + SIMD3(s * 1.8, 1, 0)), local(c + SIMD3(s * 1.8, 3.4, 0)), r0: 0.12, r1: 0.12, sides: 5, SIMD3(0.36, 0.26, 0.18)) }
            house.cylinder(local(c + SIMD3(0, 3.4, 0)), r0: 2.6, r1: 0.2, y0: 0, y1: 1.4, sides: 10, SIMD3(0.62, 0.28, 0.18), yaw: 0.3)
            for k in 0..<6 {
                let a = Float(k) / 6 * 2 * .pi + 0.4
                let p = c + SIMD3(cos(a), 0, sin(a)) * 24
                let col: SIMD3<Float> = k % 2 == 0 ? SIMD3(0.75, 0.15, 0.15) : SIMD3(0.2, 0.36, 0.7)
                house.boxAA(local(p + SIMD3(-1.6, 0, -1)), local(p + SIMD3(1.6, 1.1, 1)), SIMD3(0.52, 0.38, 0.24))
                for (dx, dz) in [(-1.5, -0.9), (1.5, -0.9), (1.5, 0.9), (-1.5, 0.9)] as [(Float, Float)] {
                    house.tube(local(p + SIMD3(dx, 0, dz)), local(p + SIMD3(dx, 2.6, dz)), r0: 0.06, r1: 0.06, sides: 4, SIMD3(0.4, 0.3, 0.2))
                }
                for j in 0..<6 {
                    let x0 = -1.8 + Float(j) * 0.6
                    house.quad(local(p + SIMD3(x0, 2.6, -1.1)), local(p + SIMD3(x0 + 0.6, 2.6, -1.1)), local(p + SIMD3(x0 + 0.6, 3.1, 1.1)),
                               local(p + SIMD3(x0, 3.1, 1.1)), j % 2 == 0 ? col : SIMD3(0.96, 0.94, 0.9), facing: SIMD3(0, 1, -0.2))
                }
            }
        }
        var out: [SCNNode] = []
        if !house.isEmpty {
            let g = house.geometry()
            g.materials = [FinaleShaders.trim]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 2400)]
            let n = SCNNode(geometry: g)
            n.name = "village"
            n.castsShadow = true
            out.append(n)
        }
        if !glow.isEmpty {
            let g = glow.geometry()
            g.materials = [FinaleShaders.glow]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1600)]
            let n = SCNNode(geometry: g)
            n.name = "village lights"
            out.append(n)
        }
        // The windmill on the rise, sails turning.
        if inside(windmill) {
            let base = SIMD3(windmill.x, t.height(windmill.x, windmill.y), windmill.y)
            var m = MeshBuilder()
            m.cylinder(local(base), r0: 4.2, r1: 2.8, y0: -1, y1: 14, sides: 10, SIMD3(0.92, 0.88, 0.8))
            m.cylinder(local(base + SIMD3(0, 14, 0)), r0: 3.3, r1: 0.3, y0: 0, y1: 4.5, sides: 10, SIMD3(0.56, 0.3, 0.2), uv: SIMD2(1, 0))
            let g = m.geometry()
            g.materials = [FinaleShaders.trim]
            let tower = SCNNode(geometry: g)
            tower.name = "windmill"
            tower.castsShadow = true
            out.append(tower)
            var sails = MeshBuilder()
            for k in 0..<4 {
                let a = Float(k) * .pi / 2
                let dir = SIMD3(cos(a), sin(a), 0)
                let side = SIMD3(-sin(a), cos(a), 0)
                sails.tube(.zero, dir * 11, r0: 0.18, r1: 0.12, sides: 4, SIMD3(0.36, 0.26, 0.18))
                sails.quad(dir * 2 + side * 0.2, dir * 11 + side * 0.2, dir * 11 + side * 2.2, dir * 2 + side * 2.2, SIMD3(0.95, 0.93, 0.88))
            }
            let sg = sails.geometry()
            sg.materials = [WorldMaterials.vertexColor(rough: 0.9, doubleSided: true)]
            let hub = SCNNode(geometry: sg)
            hub.simdPosition = local(base + SIMD3(0, 13.5, 3.6))
            hub.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 9)))
            hub.castsShadow = true
            out.append(hub)
        }
        return out
    }
}
