import SceneKit
import simd

// Wild West race obstacles: a sandstone arch to fly through, a slalom of hoodoos, an ore cart rattling across a rail
// bridge (time it), a windpump whose wheel turns right beside the line, and a low timber trestle to duck under.

/// Weathered sandstone: warm layers that differ only a little and blend into each other, with a paler one now and then.
private func sandstone(_ h: Float, _ n: Float) -> SIMD3<Float> {
    let bands: [SIMD3<Float>] = [SIMD3(0.78, 0.47, 0.31), SIMD3(0.69, 0.4, 0.27), SIMD3(0.8, 0.53, 0.36), SIMD3(0.67, 0.38, 0.26),
                                 SIMD3(0.76, 0.46, 0.31), SIMD3(0.86, 0.66, 0.48)]
    let x = h / 3.4 + n
    let k = Int(floor(x)), c = bands.count
    var f = x - floor(x)
    f = f * f * (3 - 2 * f)
    return simd_mix(bands[((k % c) + c) % c], bands[(((k + 1) % c) + c) % c], SIMD3<Float>(repeating: f))
}

/// A natural sandstone arch over the course.
final class SandArch: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 75
    private var caps: [Capsule] = []

    init(frame f: PathFrame) {
        center = f.origin
        var m = MeshBuilder()
        let halfW: Float = 11
        let spring = f.origin.y + 6
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        // Two legs rising from the ground, banded.
        for s: Float in [-1, 1] {
            let b = f.at(s * halfW, 0, 0)
            let g = TerrainShape.height(b.x, b.z) - 3
            var y = g
            while y < spring {
                let y1 = min(y + 3.2, spring + 1)
                let t = (y - g) / max(spring - g, 1)
                let r0 = 4.6 - 1.4 * t, r1 = 4.6 - 1.4 * min((y1 - g) / max(spring - g, 1), 1)
                m.tube(L(SIMD3(b.x, y, b.z)), L(SIMD3(b.x, y1, b.z)), r0: r0, r1: r1, sides: 8, sandstone(y, 0.3 * s), cap: y1 >= spring,
                       col1: sandstone(y1, 0.3 * s))
                y = y1
            }
            caps.append(Capsule(a: SIMD3(b.x, g, b.z), b: SIMD3(b.x, spring, b.z), r: 3.8))
        }
        // The span: a thick banded band of rock along a flattened half-circle.
        var prev: SIMD3<Float>?
        for k in 0...14 {
            let th = Float.pi * Float(k) / 14
            let p = f.at(-cos(th) * halfW, 0, 0) + SIMD3(0, spring - f.origin.y + sin(th) * halfW * 0.6, 0)
            if let q = prev {
                let r: Float = 3.0 + 0.5 * sin(Float(k) * 1.7)
                m.tube(L(q), L(p), r0: r, r1: r, sides: 8, sandstone(q.y, 0.2), col1: sandstone(p.y, 0.2))
                let ry = r * 0.95
                m.ellipsoid(L(p), SIMD3(r * 1.08, ry, r * 1.12), sandstone(p.y, 0.2), rings: 3, sides: 8,
                            shade: { u in sandstone(p.y + u.y * ry, 0.2) })
                caps.append(Capsule(a: q, b: p, r: 3.1))
            }
            prev = p
        }
        let g = m.geometry()
        g.materials = [WorldMaterials.vertexColor(rough: 0.9)]
        let n = SCNNode(geometry: g)
        n.simdPosition = f.origin
        n.castsShadow = true
        node.addChildNode(n)
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        for c in caps { if let v = c.push(p, radius) { return v } }
        return nil
    }
}

/// Hoodoos: tall thin rock spires with cap rocks, slaloming either side of the course.
final class Hoodoos: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 130
    private var caps: [Capsule] = []

    init(frame f: PathFrame) {
        center = f.origin
        var m = MeshBuilder()
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Int(f.origin.x * 13 + f.origin.z * 7))))
        for i in 0..<4 {
            let side: Float = i % 2 == 0 ? -5.5 : 5.5
            let base = f.at(side, (Float(i) - 1.5) * 30, 0)
            let g = TerrainShape.height(base.x, base.z) - 3
            let top = f.origin.y + rng.float(10, 22)
            var y = g
            var k = 0
            // Pinched and swollen as the soft and hard layers weathered.
            while y < top {
                let y1 = min(y + 3, top)
                let wob0: Float = k % 2 == 0 ? 1.0 : 0.72, wob1: Float = (k + 1) % 2 == 0 ? 1.0 : 0.72
                let taper0 = 1 - 0.4 * (y - g) / max(top - g, 1), taper1 = 1 - 0.4 * (y1 - g) / max(top - g, 1)
                m.tube(L(SIMD3(base.x, y, base.z)), L(SIMD3(base.x, y1, base.z)), r0: 3.2 * wob0 * taper0, r1: 3.2 * wob1 * taper1, sides: 7,
                       sandstone(y, Float(i) * 0.4), col1: sandstone(y1, Float(i) * 0.4))
                y = y1; k += 1
            }
            // The cap rock.
            m.ellipsoid(L(SIMD3(base.x, top + 1.2, base.z)), SIMD3(4.2, 1.8, 4.0), SIMD3(0.88, 0.8, 0.66), rings: 3, sides: 9)
            caps.append(Capsule(a: SIMD3(base.x, g, base.z), b: SIMD3(base.x, top + 1.2, base.z), r: 3.2))
        }
        let g = m.geometry()
        g.materials = [WorldMaterials.vertexColor(rough: 0.9)]
        let n = SCNNode(geometry: g)
        n.simdPosition = f.origin
        n.castsShadow = true
        node.addChildNode(n)
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        for c in caps { if let v = c.push(p, radius) { return v } }
        return nil
    }
}

/// An ore cart rattling back and forth on a rail bridge across the course: go under it when it's clear.
final class CartBridge: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private let cart = SCNNode()
    private let side: SIMD3<Float>
    private let deckY: Float
    private let period: Float = 4.6
    private let phase: Float
    private var towers: [Capsule] = []
    private let span: Float = 16

    init(frame f: PathFrame, phase: Float) {
        center = f.origin
        side = f.side
        self.phase = phase
        deckY = f.origin.y + 3.2
        var m = MeshBuilder()
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        let wood = SIMD3<Float>(0.45, 0.33, 0.22)
        // Timber towers either side, the rail deck between them.
        for s: Float in [-1, 1] {
            let b = f.at(s * span, 0, 0)
            let g = TerrainShape.height(b.x, b.z) - 2
            for (dx, dz) in [(-1.6, -1.6), (1.6, -1.6), (1.6, 1.6), (-1.6, 1.6)] as [(Float, Float)] {
                let off = f.side * dx + f.fwd * dz
                m.tube(L(SIMD3(b.x, g, b.z) + off * 1.4), L(SIMD3(b.x, deckY + 1, b.z) + off), r0: 0.3, r1: 0.26, sides: 5, wood)
            }
            var y = g + 6
            while y < deckY {
                m.boxAA(L(SIMD3(b.x - 2, y, b.z - 2)), L(SIMD3(b.x + 2, y + 0.25, b.z + 2)), wood * 0.85)
                y += 6
            }
            towers.append(Capsule(a: SIMD3(b.x, g, b.z), b: SIMD3(b.x, deckY + 1, b.z), r: 2.6))
        }
        let a = f.at(-span - 2, 0, 0) + SIMD3(0, deckY - f.origin.y, 0), e = f.at(span + 2, 0, 0) + SIMD3(0, deckY - f.origin.y, 0)
        m.tube(L(a - f.fwd * 0.7), L(e - f.fwd * 0.7), r0: 0.12, r1: 0.12, sides: 4, SIMD3(0.35, 0.33, 0.32))
        m.tube(L(a + f.fwd * 0.7), L(e + f.fwd * 0.7), r0: 0.12, r1: 0.12, sides: 4, SIMD3(0.35, 0.33, 0.32))
        m.tube(L(a - SIMD3(0, 0.3, 0)), L(e - SIMD3(0, 0.3, 0)), r0: 0.25, r1: 0.25, sides: 5, wood * 0.8)
        let g = m.geometry()
        g.materials = [WorldMaterials.vertexColor(rough: 0.85)]
        let n = SCNNode(geometry: g)
        n.simdPosition = f.origin
        n.castsShadow = true
        node.addChildNode(n)
        // The cart, piled with ore.
        var c = MeshBuilder()
        c.box(SIMD3(0, 0.75, 0), SIMD3(1.2, 0.7, 1.0), SIMD3(0.32, 0.3, 0.32))
        c.ellipsoid(SIMD3(0, 1.5, 0), SIMD3(1.0, 0.45, 0.85), SIMD3(0.55, 0.42, 0.25), rings: 2, sides: 7)
        for (dx, dz) in [(-0.8, -0.7), (0.8, -0.7), (0.8, 0.7), (-0.8, 0.7)] as [(Float, Float)] {
            c.tube(SIMD3(dx, 0.3, dz - 0.1), SIMD3(dx, 0.3, dz + 0.1), r0: 0.3, r1: 0.3, sides: 8, SIMD3(0.18, 0.18, 0.18), cap: true)
        }
        let cg = c.geometry()
        cg.materials = [WorldMaterials.vertexColor(rough: 0.6)]
        cart.geometry = cg
        cart.castsShadow = true
        cart.simdOrientation = f.rot
        node.addChildNode(cart)
        update(time: 0)
    }

    private func cartAt(_ t: Float) -> SIMD3<Float> {
        let u = sin(t * 2 * .pi / period + phase)
        return center + side * (u * span * 0.9) + SIMD3(0, deckY - center.y, 0)
    }

    func update(time: Float) { cart.simdPosition = cartAt(time) }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        let c = cartAt(time)
        if let v = Capsule(a: c + SIMD3(0, 0.6, 0) - side * 1.0, b: c + SIMD3(0, 0.6, 0) + side * 1.0, r: 1.3).push(p, radius) { return v * 1.4 }
        for t in towers { if let v = t.push(p, radius) { return v } }
        // The deck itself.
        let a = center - side * (span + 2) + SIMD3(0, deckY - center.y - 0.3, 0), b = center + side * (span + 2) + SIMD3(0, deckY - center.y - 0.3, 0)
        return Capsule(a: a, b: b, r: 0.6).push(p, radius)
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 80 ? "Ore cart — time it!" : nil
    }
}

/// A low timber trestle across the course: duck under the deck between the bents.
final class LowTrestle: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 60
    private var caps: [Capsule] = []
    private var deck: OBox

    init(frame f: PathFrame) {
        center = f.origin
        var m = MeshBuilder()
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        let wood = SIMD3<Float>(0.44, 0.33, 0.23), dark = SIMD3<Float>(0.34, 0.26, 0.19)
        let deckY = f.origin.y + 3.6
        // Bents at ±9 and ±24 across the course.
        for s in [-24, -9, 9, 24] as [Float] {
            let b = f.at(s, 0, 0)
            let g = TerrainShape.height(b.x, b.z) - 2
            for d: Float in [-1, 1] {
                let foot = SIMD3(b.x, g, b.z) + f.fwd * d * (2.5 + (deckY - g) * 0.06)
                let top = SIMD3(b.x, deckY, b.z) + f.fwd * d * 1.6
                m.tube(L(foot), L(top), r0: 0.36, r1: 0.3, sides: 5, wood)
                caps.append(Capsule(a: foot, b: top, r: 0.5))
            }
            var y = deckY - 7
            while y > g + 2 {
                m.boxAA(simd_min(L(SIMD3(b.x, y, b.z) - f.fwd * 3 - f.side * 0.2), L(SIMD3(b.x, y + 0.3, b.z) + f.fwd * 3 + f.side * 0.2)),
                        simd_max(L(SIMD3(b.x, y, b.z) - f.fwd * 3 - f.side * 0.2), L(SIMD3(b.x, y + 0.3, b.z) + f.fwd * 3 + f.side * 0.2)), dark)
                y -= 7
            }
        }
        let a = f.at(-27, 0, 0) + SIMD3(0, deckY - f.origin.y, 0), e = f.at(27, 0, 0) + SIMD3(0, deckY - f.origin.y, 0)
        m.boxAA(simd_min(L(a - f.fwd * 2.2), L(e + f.fwd * 2.2 + SIMD3(0, 1.1, 0))), simd_max(L(a - f.fwd * 2.2), L(e + f.fwd * 2.2 + SIMD3(0, 1.1, 0))), dark)
        for d: Float in [-0.75, 0.75] {
            m.tube(L(a + f.fwd * d + SIMD3(0, 1.25, 0)), L(e + f.fwd * d + SIMD3(0, 1.25, 0)), r0: 0.08, r1: 0.08, sides: 4, SIMD3(0.35, 0.33, 0.32))
        }
        deck = OBox(center: (a + e) / 2 + SIMD3(0, 0.55, 0), rot: f.rot, half: SIMD3(27, 0.6, 2.2))
        let g = m.geometry()
        g.materials = [WorldMaterials.vertexColor(rough: 0.85)]
        let n = SCNNode(geometry: g)
        n.simdPosition = f.origin
        n.castsShadow = true
        node.addChildNode(n)
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        if let v = deck.push(p, radius) { return v }
        for c in caps { if let v = c.push(p, radius) { return v } }
        return nil
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 70 ? "Trestle — duck under!" : nil
    }
}


/// A desert windpump beside the course, its many-bladed wheel turning across half of it.
final class Windpump: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 60
    private let hub: SIMD3<Float>
    private let wheel = SCNNode()
    private var tower: Capsule
    private let wheelR: Float = 5
    /// Which way the wheel faces (the spin goes on top).
    private let facing: simd_quatf

    init(frame f: PathFrame) {
        center = f.origin
        facing = f.rot
        hub = f.at(4.2, 0, 0) + SIMD3(0, 1.5, 0)
        let base = SIMD3(hub.x, TerrainShape.height(hub.x, hub.z) - 1, hub.z)
        var m = MeshBuilder()
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        let steel = SIMD3<Float>(0.52, 0.52, 0.54)
        for (dx, dz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            let off = f.side * dx + f.fwd * dz
            m.tube(L(base + off * 3.2), L(hub - SIMD3(0, 0.6, 0) + off * 0.5), r0: 0.12, r1: 0.1, sides: 4, steel)
        }
        var y = base.y + 4
        while y < hub.y - 2 {
            let t = (y - base.y) / max(hub.y - base.y, 1)
            let w = 3.2 * (1 - t) + 0.5 * t
            m.boxAA(L(SIMD3(base.x - w, y, base.z - w)), L(SIMD3(base.x + w, y + 0.12, base.z + w)), steel * 0.9)
            y += 4.5
        }
        // The tail vane behind the wheel.
        m.boxAA(simd_min(L(hub + f.fwd * 0.6 - f.side * 0.06 - SIMD3(0, 0.8, 0)), L(hub + f.fwd * 4.5 + f.side * 0.06 + SIMD3(0, 1.2, 0))),
                simd_max(L(hub + f.fwd * 0.6 - f.side * 0.06 - SIMD3(0, 0.8, 0)), L(hub + f.fwd * 4.5 + f.side * 0.06 + SIMD3(0, 1.2, 0))), SIMD3(0.75, 0.2, 0.15))
        tower = Capsule(a: base, b: hub - SIMD3(0, 1, 0), r: 1.6)
        let g = m.geometry()
        g.materials = [WorldMaterials.vertexColor(rough: 0.6)]
        let n = SCNNode(geometry: g)
        n.simdPosition = f.origin
        n.castsShadow = true
        node.addChildNode(n)
        // The wheel faces down the course (so it turns across it).
        var w = MeshBuilder()
        for k in 0..<16 {
            let a = Float(k) / 16 * 2 * .pi
            let d = SIMD3(cos(a), sin(a), 0), sd = SIMD3(-sin(a), cos(a), 0)
            w.quad(d * 0.7 - sd * 0.15, d * wheelR - sd * 0.5, d * wheelR + sd * 0.5, d * 0.7 + sd * 0.15, SIMD3(0.85, 0.83, 0.78), facing: SIMD3(0, 0, -1))
            w.quad(d * 0.7 + sd * 0.15, d * wheelR + sd * 0.5, d * wheelR - sd * 0.5, d * 0.7 - sd * 0.15, SIMD3(0.7, 0.68, 0.64), facing: SIMD3(0, 0, 1))
        }
        w.tube(SIMD3(0, 0, -0.3), SIMD3(0, 0, 0.3), r0: 0.5, r1: 0.5, sides: 8, steel, cap: true)
        let wg = w.geometry()
        wg.materials = [WorldMaterials.vertexColor(rough: 0.7, doubleSided: true)]
        wheel.geometry = wg
        wheel.simdPosition = hub
        wheel.castsShadow = true
        node.addChildNode(wheel)
        update(time: 0)
    }

    func update(time: Float) { wheel.simdOrientation = facing * rotZ(time * 1.6) }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        if let v = tower.push(p, radius) { return v }
        // The wheel's disc (it's turning: treat it as solid).
        let d = p - hub
        let flat = simd_length(d)
        if flat < wheelR + radius {
            let n = flat > 1e-3 ? d / flat : SIMD3<Float>(0, 1, 0)
            return n * (wheelR + radius - flat)
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 70 ? "Windpump — keep left!" : nil
    }
}
