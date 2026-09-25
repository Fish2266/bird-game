import SceneKit
import simd

// MARK: - Collision shapes

/// Sphere-vs-shape tests return the push that moves the sphere out (direction × depth), or nil.
struct Capsule {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var r: Float

    func push(_ p: SIMD3<Float>, _ rr: Float) -> SIMD3<Float>? {
        let ab = b - a
        let t = clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0, 1)
        let c = a + ab * t
        let d = p - c
        let len = simd_length(d)
        guard len < r + rr else { return nil }
        let n = len > 1e-4 ? d / len : SIMD3<Float>(0, 1, 0)
        return n * (r + rr - len)
    }
}

/// Oriented box.
struct OBox {
    var center: SIMD3<Float>
    var rot: simd_quatf
    var half: SIMD3<Float>

    func push(_ p: SIMD3<Float>, _ rr: Float) -> SIMD3<Float>? {
        let local = rot.inverse.act(p - center)
        let q = simd_clamp(local, -half, half)
        let d = local - q
        let len = simd_length(d)
        if len > 1e-4 {
            guard len < rr else { return nil }
            return rot.act(d / len * (rr - len))
        }
        // Centre inside the box: leave by the nearest face.
        let gap = half - simd_abs(local)
        var axis = 0
        if gap.y < gap[axis] { axis = 1 }
        if gap.z < gap[axis] { axis = 2 }
        var n = SIMD3<Float>(0, 0, 0)
        n[axis] = local[axis] >= 0 ? 1 : -1
        return rot.act(n * (gap[axis] + rr))
    }
}

// MARK: - Obstacles

protocol Obstacle: AnyObject {
    var node: SCNNode { get }
    /// Rough centre and radius for a cheap distance check.
    var center: SIMD3<Float> { get }
    var reach: Float { get }
    func update(time: Float)
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>?
    /// HUD warning when the bird is close (nil = nothing to say).
    func warning(_ p: SIMD3<Float>, time: Float) -> String?
}

extension Obstacle {
    func warning(_ p: SIMD3<Float>, time: Float) -> String? { nil }
}

func pbr(_ c: NSColor, rough: CGFloat = 0.8, metal: CGFloat = 0, emission: NSColor? = nil) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = c
    m.roughness.contents = rough
    m.metalness.contents = metal
    if let emission { m.emission.contents = emission }
    return m
}

func glowMat(_ c: NSColor, _ intensity: CGFloat = 1.6) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = c
    m.diffuse.intensity = intensity
    return m
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Places `n` (whose geometry runs along local +Y) between two points.
func orientBetween(_ n: SCNNode, _ a: SIMD3<Float>, _ b: SIMD3<Float>) {
    n.simdPosition = (a + b) * 0.5
    let d = b - a
    if simd_length(d) > 1e-4 { n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(d)) }
}

/// Frame for building things across a path: `fwd` along it, `side` to the right, `up`.
struct PathFrame {
    var origin: SIMD3<Float>
    var fwd: SIMD3<Float>
    var side: SIMD3<Float>
    var up: SIMD3<Float> { kUp }
    init(_ o: SIMD3<Float>, _ tangent: SIMD3<Float>) {
        origin = o
        var f = SIMD3(tangent.x, 0, tangent.z)
        if simd_length(f) < 1e-3 { f = SIMD3(0, 0, -1) }
        fwd = simd_normalize(f)
        side = simd_normalize(simd_cross(fwd, kUp))
    }
    var yaw: Float { atan2(-fwd.x, -fwd.z) }
    var rot: simd_quatf { simd_quatf(angle: yaw, axis: kUp) }
    func at(_ s: Float, _ f: Float, _ u: Float) -> SIMD3<Float> { origin + side * s + fwd * f + kUp * u }
}

// MARK: Pillars (sea stacks, obsidian spires, crystal columns, grain silos)

final class Pillars: Obstacle {
    enum Style { case seaStack, spire, crystal, silo }
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float
    private var shapes: [Capsule] = []

    /// A slalom of pillars rising from the ground, alternating sides of the path.
    init(style: Style, frame: PathFrame, count: Int = 3, spacing: Float = 34, offset: Float = 5, radius: Float = 3.4,
         top: Float, ceiling: ((Float, Float) -> Float?)? = nil, floating: Bool = false) {
        center = frame.origin
        reach = spacing * Float(count) + radius + 60
        for i in 0..<count {
            let side: Float = i % 2 == 0 ? -offset : offset
            let f = (Float(i) - Float(count - 1) / 2) * spacing
            let base = frame.at(side, f, 0)
            let g = TerrainShape.height(base.x, base.z)
            var bottom = SIMD3(base.x, min(g, TerrainShape.waterLevel > -1e8 ? TerrainShape.waterLevel : g) - 6, base.z)
            var tip = SIMD3(base.x, top + (style == .silo ? 0 : Float(i % 2) * 8), base.z)
            if let ceiling, let c = ceiling(base.x, base.z) {
                // Caves: floor-to-ceiling crystal columns.
                bottom.y = g - 2; tip.y = c + 2
            }
            if style == .silo { tip.y = max(bottom.y + 20, top) }
            if floating { bottom.y = frame.origin.y - 18 - Float(i % 2) * 5 }
            let h = tip.y - bottom.y
            let r = radius * (style == .crystal ? 0.8 : 1)
            shapes.append(Capsule(a: bottom, b: tip, r: r))
            let pn = SCNNode()
            pn.simdPosition = SIMD3(base.x, bottom.y, base.z)
            switch style {
            case .seaStack:
                var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Int(base.x * 7 + base.z * 13))))
                let rock = RockKit.material(rgb(0.62, 0.57, 0.51))
                pn.addChildNode(RockKit.stack(height: h, r0: r * 1.15, r1: r * 0.8, rock, &rng))
                pn.addChildNode(RockKit.mossTop(at: h, radius: r * 0.85, &rng))
                if floating { pn.addChildNode(RockKit.underside(radius: r * 1.1, rock, &rng)) }
            case .spire:
                var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Int(base.x * 11 + base.z * 5))))
                let basalt = RockKit.material(rgb(0.22, 0.19, 0.18), rough: 0.7)
                // A cluster of hexagonal basalt columns with a glowing seam of lava at the foot.
                for j in 0..<6 {
                    let rj = r * rng.float(0.45, 0.7)
                    let hj = h * (j == 0 ? 1 : rng.float(0.55, 0.92))
                    let a = Float(j) * 1.1 + rng.float(0, 0.5)
                    let off = j == 0 ? SIMD2<Float>(0, 0) : SIMD2(cos(a), sin(a)) * r * rng.float(0.5, 0.85)
                    let col = SCNCylinder(radius: CGFloat(rj), height: CGFloat(hj))
                    col.radialSegmentCount = 6
                    col.materials = [basalt]
                    let cn = SCNNode(geometry: col)
                    cn.simdPosition = SIMD3(off.x, hj / 2, off.y)
                    cn.eulerAngles.y = CGFloat(rng.float(0, 1))
                    cn.eulerAngles.z = CGFloat(rng.float(-0.05, 0.05))
                    pn.addChildNode(cn)
                    let capG = SCNCylinder(radius: CGFloat(rj) * 0.92, height: 0.15)
                    capG.radialSegmentCount = 6
                    capG.materials = [glowMat(rgb(1, 0.42, 0.1), 1.6)]
                    let cap = SCNNode(geometry: capG)
                    cap.simdPosition = SIMD3(off.x, hj + 0.05, off.y)
                    cap.eulerAngles.y = cn.eulerAngles.y
                    pn.addChildNode(cap)
                }
                if floating {
                    pn.addChildNode(RockKit.underside(radius: r * 1.2, basalt, &rng))
                } else {
                    let pool = SCNNode(geometry: SCNCylinder(radius: CGFloat(r) * 1.4, height: 0.3))
                    pool.geometry?.materials = [glowMat(rgb(1, 0.38, 0.08), 1.4)]
                    pool.simdPosition = SIMD3(0, max(g, TerrainShape.waterLevel) - bottom.y + 0.15, 0)
                    pn.addChildNode(pool)
                }
            case .crystal:
                let c = SCNCylinder(radius: CGFloat(r), height: CGFloat(h))
                c.radialSegmentCount = 6
                c.materials = [glowMat(rgb(0.30, 0.95, 0.90, 0.9), 1.4)]
                let body = SCNNode(geometry: c)
                body.position = SCNVector3(0, CGFloat(h / 2), 0)
                pn.addChildNode(body)
                let core = SCNNode(geometry: { let g = SCNCylinder(radius: CGFloat(r) * 0.45, height: CGFloat(h)); g.radialSegmentCount = 6; return g }())
                core.geometry?.materials = [glowMat(rgb(0.85, 1, 1), 2.5)]
                core.position = body.position
                pn.addChildNode(core)
                let light = SCNNode()
                light.light = SCNLight()
                light.light?.type = .omni
                light.light?.color = rgb(0.35, 1, 0.95)
                light.light?.intensity = 500
                light.light?.attenuationEndDistance = 40
                light.light?.categoryBitMask = 2
                light.simdPosition = SIMD3(0, h / 2, 0)
                pn.addChildNode(light)
            case .silo:
                let body = SCNNode(geometry: SCNCylinder(radius: CGFloat(r), height: CGFloat(h)))
                body.geometry?.materials = [pbr(rgb(0.72, 0.74, 0.76), rough: 0.35, metal: 0.7)]
                body.position = SCNVector3(0, CGFloat(h / 2), 0)
                pn.addChildNode(body)
                for k in 1..<Int(h / 5) {
                    let band = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(r) + 0.05, pipeRadius: 0.12))
                    band.geometry?.materials = [pbr(rgb(0.5, 0.52, 0.55), rough: 0.4, metal: 0.8)]
                    band.position = SCNVector3(0, CGFloat(k * 5), 0)
                    pn.addChildNode(band)
                }
                let dome = SCNNode(geometry: SCNSphere(radius: CGFloat(r)))
                dome.geometry?.materials = [pbr(rgb(0.78, 0.2, 0.15), rough: 0.5)]
                dome.position = SCNVector3(0, CGFloat(h), 0)
                dome.scale = SCNVector3(1, 0.6, 1)
                pn.addChildNode(dome)
            }
            node.addChildNode(pn)
        }
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for c in shapes { if let v = c.push(p, radius) { return v } }
        return nil
    }
}

// MARK: Spinning blades (wind turbine / farm windmill)

final class Windmill: Obstacle {
    enum Style { case turbine, farm }
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float
    private let rotor = SCNNode()
    private let hub: SIMD3<Float>
    private let axis: SIMD3<Float>
    private let blades: Int
    private let length: Float
    private let rate: Float
    private let phase: Float
    private let tower: Capsule

    init(style: Style, frame: PathFrame, length: Float = 13, phase: Float = 0) {
        hub = frame.origin
        center = hub
        axis = frame.fwd
        self.length = length
        blades = style == .turbine ? 3 : 4
        rate = style == .turbine ? 1.9 : 1.5
        self.phase = phase
        reach = length + 60
        let ground = TerrainShape.ground(hub.x, hub.z)
        let back: Float = style == .turbine ? 3.5 : 4
        tower = Capsule(a: SIMD3(hub.x, ground - 2, hub.z) - axis * back, b: hub - axis * back, r: style == .turbine ? 1.3 : 3.2)

        let base = SCNNode()
        base.simdPosition = hub
        base.simdOrientation = frame.rot
        node.addChildNode(base)
        let towerH = hub.y - ground + 2
        switch style {
        case .turbine:
            let white = pbr(rgb(0.93, 0.94, 0.95), rough: 0.4)
            let t = SCNNode(geometry: SCNCylinder(radius: 1.0, height: CGFloat(towerH)))
            t.geometry?.materials = [white]
            t.position = SCNVector3(0, -CGFloat(towerH / 2), 3.5)
            base.addChildNode(t)
            let nacelle = SCNNode(geometry: SCNCapsule(capRadius: 1.4, height: 6))
            nacelle.geometry?.materials = [white]
            nacelle.eulerAngles.x = .pi / 2
            nacelle.position = SCNVector3(0, 0, 3.2)
            base.addChildNode(nacelle)
            for b in 0..<blades {
                let blade = SCNNode(geometry: SCNBox(width: 1.3, height: CGFloat(length), length: 0.35, chamferRadius: 0.3))
                blade.geometry?.materials = [white]
                let tip = SCNNode(geometry: SCNBox(width: 1.32, height: 2.2, length: 0.37, chamferRadius: 0.3))
                tip.geometry?.materials = [pbr(rgb(0.9, 0.2, 0.15), rough: 0.5)]
                tip.position = SCNVector3(0, CGFloat(length / 2 - 1.1), 0)
                blade.addChildNode(tip)
                let arm = SCNNode()
                arm.eulerAngles.z = CGFloat(Float(b) / Float(blades) * 2 * .pi)
                blade.position = SCNVector3(0, CGFloat(length / 2), 0)
                arm.addChildNode(blade)
                rotor.addChildNode(arm)
            }
            let hubBall = SCNNode(geometry: SCNSphere(radius: 1.5))
            hubBall.geometry?.materials = [white]
            rotor.addChildNode(hubBall)
        case .farm:
            let wood = pbr(rgb(0.45, 0.30, 0.18), rough: 0.9)
            let sail = pbr(rgb(0.92, 0.88, 0.78), rough: 0.9)
            let t = SCNNode(geometry: SCNCone(topRadius: 2.2, bottomRadius: 4.2, height: CGFloat(towerH)))
            t.geometry?.materials = [pbr(rgb(0.80, 0.78, 0.72), rough: 0.9)]
            t.position = SCNVector3(0, -CGFloat(towerH / 2), 4)
            base.addChildNode(t)
            let cap = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 2.8, height: 3))
            cap.geometry?.materials = [pbr(rgb(0.55, 0.22, 0.16), rough: 0.8)]
            cap.position = SCNVector3(0, 1.5, 4)
            base.addChildNode(cap)
            for b in 0..<blades {
                let arm = SCNNode()
                arm.eulerAngles.z = CGFloat(Float(b) / Float(blades) * 2 * .pi)
                let spar = SCNNode(geometry: SCNBox(width: 0.4, height: CGFloat(length), length: 0.4, chamferRadius: 0))
                spar.geometry?.materials = [wood]
                spar.position = SCNVector3(0, CGFloat(length / 2), 0)
                arm.addChildNode(spar)
                let s = SCNNode(geometry: SCNBox(width: 2.4, height: CGFloat(length) * 0.75, length: 0.1, chamferRadius: 0))
                s.geometry?.materials = [sail]
                s.position = SCNVector3(1.3, CGFloat(length * 0.6), 0)
                arm.addChildNode(s)
                rotor.addChildNode(arm)
            }
            let hubBall = SCNNode(geometry: SCNCylinder(radius: 1, height: 1.2))
            hubBall.geometry?.materials = [wood]
            hubBall.eulerAngles.x = .pi / 2
            rotor.addChildNode(hubBall)
        }
        base.addChildNode(rotor)
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    func update(time: Float) {
        rotor.eulerAngles.z = CGFloat(time * rate + phase)
    }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        if let v = tower.push(p, radius) { return v }
        if let v = Capsule(a: hub + axis * 0.8, b: hub - axis * 6, r: 1.6).push(p, radius) { return v }
        // Blades lie in the plane across the path.
        let side = simd_normalize(simd_cross(axis, kUp))
        let up = simd_cross(side, axis)
        for b in 0..<blades {
            let a = time * rate + phase + Float(b) / Float(blades) * 2 * .pi
            // Local rotor rotation is about the path axis (+Z of the frame is backwards along the path).
            let dir = up * cos(a) - side * sin(a)
            if let v = Capsule(a: hub, b: hub + dir * length, r: 0.9).push(p, radius) { return v }
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        let d = simd_distance(p, hub)
        return d < 70 && simd_dot(hub - p, axis) > 0 ? "Spinning blades ahead!" : nil
    }
}

// MARK: Lava geysers (volcano)

/// Two lava geysers beside the course — the same vents as the free-roam Volcano — erupting in turn,
/// so there's always a way through if you time it.
final class LavaColumns: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 110
    private var vents: [(LavaVent, Float)] = []
    private let period: Float = 5
    private let radius: Float = 9.5

    init(frame: PathFrame, top: Float, count: Int = 2) {
        center = frame.origin
        for i in 0..<count {
            let lateral: Float = count == 2 ? (i == 0 ? -6 : 6) : Float(i - 1) * 9
            let b = frame.at(lateral, Float(i) * 24 - 12, 0)
            let g = TerrainShape.height(b.x, b.z)
            let v = LavaVent(pos: SIMD3(b.x, max(g, 0) - 0.5, b.z), seed: UInt64(i + 1) &* 7919 &+ UInt64(abs(Int(b.x))))
            node.addChildNode(v.node)
            vents.append((v, Float(i) / Float(count) * period))
        }
    }

    /// 0 idle, 1 warning, 2 erupting.
    private func state(_ offset: Float, _ time: Float) -> Int {
        let t = (time + offset).truncatingRemainder(dividingBy: period)
        return t < 1.4 ? 0 : (t < 2.6 ? 1 : 2)
    }

    func update(time: Float) {
        for (v, off) in vents {
            switch state(off, time) {
            case 0:
                v.crater.diffuse.intensity = 0.6; v.spout.birthRate = 0; v.smoke.birthRate = 0
            case 1:
                v.crater.diffuse.intensity = 0.8 + 2.2 * CGFloat(abs(sin(time * 14))); v.spout.birthRate = 0; v.smoke.birthRate = 35
            default:
                v.crater.diffuse.intensity = 3; v.spout.birthRate = 420; v.smoke.birthRate = 0
            }
        }
    }

    func push(_ p: SIMD3<Float>, radius r: Float, time: Float) -> SIMD3<Float>? {
        for (v, off) in vents {
            let flat = SIMD2(p.x - v.pos.x, p.z - v.pos.z)
            let d = simd_length(flat)
            // The vent cone is solid.
            if let c = Capsule(a: v.pos, b: v.pos + SIMD3(0, 2.5, 0), r: 5).push(p, r) { return c }
            guard state(off, time) == 2, d < radius + r, p.y > v.pos.y - 2, p.y < v.pos.y + 82 else { continue }
            let out = d > 0.1 ? SIMD3(flat.x / d, 0, flat.y / d) : SIMD3(1, 0, 0)
            return out * (radius + r - d) + SIMD3(0, 3, 0)
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        guard simd_distance(p, center) < 130 else { return nil }
        return vents.contains { state($0.1, time) == 1 } ? "Geyser about to blow!" : nil
    }
}

// MARK: Stalactite crushers (caves)

final class Crushers: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float
    private struct Rock {
        let pos: SIMD2<Float>
        let floor: Float
        let ceiling: Float
        let offset: Float
        let node: SCNNode
        let length: Float
    }
    private var rocks: [Rock] = []
    private let period: Float = 3.6
    private let radius: Float = 3.2

    init(frame: PathFrame, terrain: WorldTerrain, count: Int = 2) {
        center = frame.origin
        reach = 70
        for i in 0..<count {
            let lateral: Float = count == 1 ? 0 : (i % 2 == 0 ? -2.5 : 2.5)
            let b = frame.at(lateral, (Float(i) - Float(count - 1) / 2) * 26, 0)
            let floor = terrain.height(b.x, b.z)
            let ceil = terrain.ceiling(b.x, b.z) ?? (floor + 30)
            let length = max(ceil - floor, 6)
            let n = SCNNode()
            let rockMat = pbr(rgb(0.34, 0.33, 0.36), rough: 0.9)
            let cone = SCNNode(geometry: SCNCone(topRadius: CGFloat(radius * 1.3), bottomRadius: 0.4, height: CGFloat(length)))
            cone.geometry?.materials = [rockMat]
            cone.position = SCNVector3(0, CGFloat(length / 2), 0)
            n.addChildNode(cone)
            let shaft = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius * 1.3), height: 40))
            shaft.geometry?.materials = [rockMat]
            shaft.position = SCNVector3(0, CGFloat(length) + 20, 0)
            n.addChildNode(shaft)
            for k in 0..<5 {
                let gem = SCNNode(geometry: SCNBox(width: 0.6, height: 1.2, length: 0.6, chamferRadius: 0.1))
                gem.geometry?.materials = [glowMat(rgb(1, 0.35, 0.55), 2.2)]
                let a = Float(k) * 1.3
                let y = length * (0.35 + 0.12 * Float(k))
                let rr = radius * 1.3 * (y / length) + 0.3
                gem.simdPosition = SIMD3(cos(a) * rr, y, sin(a) * rr)
                n.addChildNode(gem)
            }
            node.addChildNode(n)
            rocks.append(Rock(pos: SIMD2(b.x, b.z), floor: floor, ceiling: ceil, offset: Float(i) * period * 0.5, node: n, length: length))
        }
    }

    /// Tip height of a crusher: hangs at the ceiling, slams to the floor, grinds back up.
    private func tip(_ r: Rock, _ time: Float) -> Float {
        let t = (time + r.offset).truncatingRemainder(dividingBy: period)
        let up = r.ceiling - 1.5, down = r.floor + 0.8
        switch t {
        case ..<1.4: return up
        case ..<1.7: return lerp(up, down, smoothstep(1.4, 1.7, t))
        case ..<2.4: return down
        default: return lerp(down, up, smoothstep(2.4, period, t))
        }
    }

    func update(time: Float) {
        for r in rocks { r.node.simdPosition = SIMD3(r.pos.x, tip(r, time), r.pos.y) }
    }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for r in rocks {
            let y = tip(r, time)
            let c = Capsule(a: SIMD3(r.pos.x, y + 1.5, r.pos.y), b: SIMD3(r.pos.x, y + r.length, r.pos.y), r: self.radius)
            if let v = c.push(p, radius) { return v + SIMD3(0, -1.5, 0) }
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 80 ? "Crushers ahead — time it!" : nil
    }
}

// MARK: Barn (dogfight): fly in one door and out the other

final class Barn: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private var boxes: [OBox] = []
    static let length: Float = 32, halfWidth: Float = 8.5, wallH: Float = 11, doorHalf: Float = 6, doorH: Float = 9

    init(frame: PathFrame) {
        let g = TerrainShape.ground(frame.origin.x, frame.origin.z)
        let f = PathFrame(SIMD3(frame.origin.x, g, frame.origin.z), frame.fwd)
        center = f.origin + SIMD3(0, 6, 0)
        let rot = f.rot
        let red = pbr(rgb(0.62, 0.14, 0.10), rough: 0.85)
        let trim = pbr(rgb(0.93, 0.92, 0.88), rough: 0.8)
        let roofM = pbr(rgb(0.30, 0.28, 0.27), rough: 0.7, metal: 0.3)
        let L = Barn.length, W = Barn.halfWidth, H = Barn.wallH
        func add(_ c: SIMD3<Float>, _ half: SIMD3<Float>, _ m: SCNMaterial, localRot: simd_quatf = simd_quatf(angle: 0, axis: kUp), collide: Bool = true) {
            let world = f.origin + rot.act(c)
            let q = rot * localRot
            let n = SCNNode(geometry: SCNBox(width: CGFloat(half.x * 2), height: CGFloat(half.y * 2), length: CGFloat(half.z * 2), chamferRadius: 0.05))
            n.geometry?.materials = [m]
            n.simdPosition = world
            n.simdOrientation = q
            node.addChildNode(n)
            if collide { boxes.append(OBox(center: world, rot: q, half: half)) }
        }
        // Side walls
        add(SIMD3(-W, H / 2, 0), SIMD3(0.4, H / 2, L / 2), red)
        add(SIMD3(W, H / 2, 0), SIMD3(0.4, H / 2, L / 2), red)
        // Gable ends with door openings
        for e: Float in [-1, 1] {
            let z = e * L / 2
            let jamb = (W - Barn.doorHalf) / 2
            add(SIMD3(-W + jamb, H / 2, z), SIMD3(jamb, H / 2, 0.4), red)
            add(SIMD3(W - jamb, H / 2, z), SIMD3(jamb, H / 2, 0.4), red)
            add(SIMD3(0, (Barn.doorH + H) / 2, z), SIMD3(Barn.doorHalf, (H - Barn.doorH) / 2, 0.4), red)
            add(SIMD3(0, Barn.doorH + 0.2, z + e * 0.1), SIMD3(Barn.doorHalf + 0.3, 0.25, 0.5), trim, collide: false)
            // Gable triangle (approximated by a stepped box)
            add(SIMD3(0, H + 2, z), SIMD3(W * 0.6, 2, 0.4), red)
            // Open doors swung outward
            for s: Float in [-1, 1] {
                add(SIMD3(s * (Barn.doorHalf + 0.2), Barn.doorH / 2, z + e * 3.2), SIMD3(0.2, Barn.doorH / 2, 3), trim,
                    localRot: simd_quatf(angle: s * e * 0.25, axis: kUp), collide: false)
            }
        }
        // Roof: two slabs
        let slope: Float = 0.55
        for s: Float in [-1, 1] {
            add(SIMD3(s * W * 0.5, H + 2.4, 0), SIMD3(W * 0.62, 0.35, L / 2 + 1), roofM, localRot: simd_quatf(angle: -s * slope, axis: SIMD3(0, 0, 1)))
        }
        // Hay bales inside, off to the sides
        let hay = pbr(rgb(0.86, 0.72, 0.36), rough: 1)
        for i in 0..<4 {
            let s: Float = i % 2 == 0 ? -1 : 1
            add(SIMD3(s * (W - 1.6), 0.9, Float(i) * 6 - 9), SIMD3(1.1, 0.9, 1.6), hay, collide: false)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for b in boxes { if let v = b.push(p, radius) { return v } }
        return nil
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 90 ? "Fly through the barn!" : nil
    }
}

// MARK: Barrage balloons (dogfight): cables to weave through

final class Balloons: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 90
    private var cables: [Capsule] = []
    private var bodies: [Capsule] = []
    private var balloonNodes: [(SCNNode, SIMD3<Float>, Float)] = []

    init(frame: PathFrame, pathY: Float) {
        center = frame.origin
        let layout: [(Float, Float)] = [(-7, -24), (4, -8), (-3, 9), (7, 25)]
        for (i, (s, f)) in layout.enumerated() {
            let b = frame.at(s, f, 0)
            let g = TerrainShape.ground(b.x, b.z)
            let top = SIMD3(b.x, pathY + 26 + Float(i % 2) * 6, b.z)
            cables.append(Capsule(a: SIMD3(b.x, g, b.z), b: top, r: 0.5))
            bodies.append(Capsule(a: top + frame.fwd * 5 + SIMD3(0, 3, 0), b: top - frame.fwd * 5 + SIMD3(0, 3, 0), r: 4))
            let cable = SCNNode(geometry: SCNCylinder(radius: 0.12, height: CGFloat(top.y - g)))
            cable.geometry?.materials = [pbr(rgb(0.15, 0.15, 0.15), rough: 0.6, metal: 0.6)]
            orientBetween(cable, SIMD3(b.x, g, b.z), top)
            node.addChildNode(cable)
            let bal = SCNNode()
            let body = SCNNode(geometry: SCNSphere(radius: 4))
            body.geometry?.materials = [pbr(rgb(0.72, 0.74, 0.70), rough: 0.6)]
            body.scale = SCNVector3(1, 1, 2.2)
            bal.addChildNode(body)
            for k in 0..<3 {
                let fin = SCNNode(geometry: SCNBox(width: 0.2, height: 3.2, length: 3, chamferRadius: 0.1))
                fin.geometry?.materials = [pbr(rgb(0.62, 0.64, 0.60), rough: 0.6)]
                fin.eulerAngles.z = CGFloat(Float(k) * 2.1)
                fin.position = SCNVector3(0, 0, 8)
                fin.pivot = SCNMatrix4MakeTranslation(0, -2.4, 0)
                bal.addChildNode(fin)
            }
            bal.simdPosition = top + SIMD3(0, 3, 0)
            bal.simdOrientation = frame.rot
            node.addChildNode(bal)
            balloonNodes.append((bal, top + SIMD3(0, 3, 0), Float(i) * 1.7))
        }
    }

    func update(time: Float) {
        for (n, p, ph) in balloonNodes { n.simdPosition = p + SIMD3(0, sin(time * 0.7 + ph) * 0.6, 0) }
    }
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for c in cables { if let v = c.push(p, radius) { return v } }
        for c in bodies { if let v = c.push(p, radius) { return v } }
        return nil
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 90 ? "Balloon cables — weave through!" : nil
    }
}

// MARK: Stone arch (meadow)

final class StoneArch: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private var shapes: [Capsule] = []
    private var bases: [OBox] = []

    /// A natural rock arch the course flies under: two boulder legs joined by a curved span.
    init(frame: PathFrame, halfWidth: Float = 10, floating: Bool = false) {
        center = frame.origin
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Int(frame.origin.x * 3 + frame.origin.z * 17))))
        let rock = RockKit.material(rgb(0.66, 0.60, 0.52))
        let springY = frame.origin.y + 7
        if floating {
            // Floating arch: a rocky base under the path holds the two legs.
            let base = OBox(center: frame.origin - SIMD3(0, 14, 0), rot: frame.rot, half: SIMD3(halfWidth + 4, 3, 4))
            bases.append(base)
            for k in 0..<7 {
                let t = Float(k) / 6 * 2 - 1
                let b = RockKit.boulder(4.2 * (1 - abs(t) * 0.3), rock, &rng)
                b.simdPosition = frame.at(t * (halfWidth + 2), rng.float(-1, 1), -14)
                node.addChildNode(b)
            }
            let under = RockKit.underside(radius: halfWidth * 0.7, rock, &rng)
            under.simdPosition = frame.origin - SIMD3(0, 16, 0)
            node.addChildNode(under)
        }
        for sgn: Float in [-1, 1] {
            let b = frame.at(sgn * halfWidth, 0, 0)
            let g = TerrainShape.height(b.x, b.z)
            let bottomY = floating ? frame.origin.y - 13 : min(g, 0) - 4
            let h = springY - bottomY
            shapes.append(Capsule(a: SIMD3(b.x, bottomY, b.z), b: SIMD3(b.x, springY, b.z), r: 3.3))
            let leg = RockKit.stack(height: h, r0: 4.2, r1: 3.2, rock, &rng)
            leg.simdPosition = SIMD3(b.x, bottomY, b.z)
            node.addChildNode(leg)
        }
        // The span: boulders along a flattened half circle.
        var last: SIMD3<Float>?
        let n = 11
        for k in 0...n {
            let th = Float.pi * Float(k) / Float(n)
            let p = frame.at(-cos(th) * halfWidth, 0, 0) + SIMD3(0, (springY - frame.origin.y) + sin(th) * halfWidth * 0.55, 0)
            let b = RockKit.boulder(3.3 + (k == 0 || k == n ? 0.6 : 0), rock, &rng)
            b.simdPosition = p
            node.addChildNode(b)
            if let l = last { shapes.append(Capsule(a: l, b: p, r: 3)) }
            last = p
        }
        node.addChildNode(RockKit.mossTop(at: 0, radius: 3, &rng).then {
            $0.simdPosition = frame.origin + SIMD3(0, springY - frame.origin.y + halfWidth * 0.55 + 2.2, 0)
        })
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for c in shapes { if let v = c.push(p, radius) { return v } }
        for b in bases { if let v = b.push(p, radius) { return v } }
        return nil
    }
}

/// Natural-looking rock pieces built from lumpy, textured boulders.
enum RockKit {
    static let texture: CGImage = TerrainManager.detailTexture()

    static func material(_ c: NSColor, rough: CGFloat = 0.95) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = texture
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        m.multiply.contents = c
        m.roughness.contents = rough
        return m
    }

    /// A lumpy boulder about `r` across.
    static func boulder(_ r: Float, _ m: SCNMaterial, _ rng: inout SplitMix64) -> SCNNode {
        let g = SCNSphere(radius: CGFloat(r))
        g.segmentCount = 10
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.scale = SCNVector3(rng.float(0.85, 1.15), rng.float(0.6, 0.85), rng.float(0.85, 1.15))
        n.eulerAngles = SCNVector3(rng.float(-0.25, 0.25), rng.float(0, 6.28), rng.float(-0.25, 0.25))
        return n
    }

    /// A column of stacked boulders from y = 0 up to `h`, tapering from `r0` to `r1`, with a few ledges.
    static func stack(height h: Float, r0: Float, r1: Float, _ m: SCNMaterial, _ rng: inout SplitMix64) -> SCNNode {
        let n = SCNNode()
        var y: Float = 0
        while y < h {
            let t = y / max(h, 1)
            let r = lerp(r0 * 1.2, r1, sqrt(t)) * rng.float(0.8, 1.15)
            let b = boulder(r, m, &rng)
            b.simdPosition = SIMD3(rng.float(-0.35, 0.35) * r, y + r * 0.5, rng.float(-0.35, 0.35) * r)
            n.addChildNode(b)
            if rng.float() < 0.55 {
                let a = rng.float(0, 6.28)
                let side = boulder(r * rng.float(0.45, 0.65), m, &rng)
                side.simdPosition = SIMD3(cos(a) * r * 0.85, y + r * 0.4, sin(a) * r * 0.85)
                n.addChildNode(side)
            }
            y += r * 0.6
        }
        return n
    }

    /// Grass and a couple of little trees on top of a rock.
    static func mossTop(at h: Float, radius r: Float, _ rng: inout SplitMix64) -> SCNNode {
        let n = SCNNode()
        let moss = SCNNode(geometry: SCNSphere(radius: CGFloat(r)))
        moss.geometry?.materials = [pbr(rgb(0.30, 0.46, 0.20), rough: 0.95)]
        moss.scale = SCNVector3(1.1, 0.35, 1.1)
        moss.simdPosition = SIMD3(0, h + r * 0.15, 0)
        n.addChildNode(moss)
        for _ in 0..<Int(rng.float(1, 3.99)) {
            let t = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(r * 0.3), height: CGFloat(r * 1.1)))
            t.geometry?.materials = [pbr(rgb(0.13, 0.30, 0.14), rough: 0.9)]
            t.simdPosition = SIMD3(rng.float(-0.5, 0.5) * r, h + r * 0.6, rng.float(-0.5, 0.5) * r)
            n.addChildNode(t)
        }
        return n
    }

    /// The tapering rocky bottom of a floating island (points down from y = 0).
    static func underside(radius r: Float, _ m: SCNMaterial, _ rng: inout SplitMix64) -> SCNNode {
        let n = SCNNode()
        for k in 0..<5 {
            let rr = r * (1 - Float(k) * 0.19)
            let b = boulder(rr, m, &rng)
            b.simdPosition = SIMD3(rng.float(-0.2, 0.2) * r, -Float(k) * r * 0.55, rng.float(-0.2, 0.2) * r)
            n.addChildNode(b)
        }
        return n
    }
}

extension SCNNode {
    /// Configure inline.
    func then(_ f: (SCNNode) -> Void) -> SCNNode { f(self); return self }
}

// MARK: Boost rings

final class BoostRing {
    let node = SCNNode()
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let radius: Float
    private var cooldown: Float = 0
    private let inner: SCNNode

    init(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float, color: NSColor = rgb(0.25, 0.85, 1)) {
        self.center = center
        self.normal = simd_normalize(normal)
        self.radius = radius
        let t = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: 0.45)
        t.ringSegmentCount = 40
        t.pipeSegmentCount = 10
        t.materials = [glowMat(color, 2.2)]
        let ring = SCNNode(geometry: t)
        ring.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: self.normal)
        node.addChildNode(ring)
        let disc = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: 0.05))
        let m = glowMat(color.withAlphaComponent(0.18), 1)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        disc.geometry?.materials = [m]
        disc.simdOrientation = ring.simdOrientation
        node.addChildNode(disc)
        // Chevrons pointing through the ring.
        inner = SCNNode()
        for k in 0..<3 {
            let chev = SCNNode(geometry: SCNPyramid(width: CGFloat(radius) * 0.6, height: CGFloat(radius) * 0.5, length: 0.2))
            chev.geometry?.materials = [glowMat(color, 1.5)]
            chev.simdPosition = SIMD3(0, 0, -Float(k) * 1.6 + 1.6)
            chev.eulerAngles.x = -.pi / 2
            inner.addChildNode(chev)
        }
        inner.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: self.normal)
        node.addChildNode(inner)
        node.simdPosition = center
        node.castsShadow = false
    }

    func update(time: Float, dt: Float) {
        cooldown = max(0, cooldown - dt)
        inner.opacity = CGFloat(0.5 + 0.5 * sin(time * 8))
    }

    /// True when the bird flew through this step.
    func passed(prev: SIMD3<Float>, now: SIMD3<Float>) -> Bool {
        guard cooldown == 0 else { return false }
        let a = simd_dot(prev - center, normal), b = simd_dot(now - center, normal)
        guard (a < 0) != (b < 0) else { return false }
        let hit = prev + (now - prev) * (a / (a - b))
        guard simd_distance(hit, center) < radius + 1 else { return false }
        cooldown = 1
        return true
    }
}
