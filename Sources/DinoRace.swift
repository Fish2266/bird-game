import SceneKit
import simd

// Dino Valley's race obstacles: a giant fossil ribcage to fly through, a fallen giant conifer to duck under, steam
// geysers that blow on a timer, and pterosaurs circling a gate. Also the skeleton builder the valley's landmark
// skeletons share.

extension MeshTemplate {
    /// A SceneKit geometry for a template (for the few creatures that are nodes rather than batched).
    func geometry(_ material: SCNMaterial) -> SCNGeometry {
        var m = MeshBuilder()
        for i in 0..<pos.count {
            m.pos += [pos[i].x, pos[i].y, pos[i].z]
            m.nrm += [nrm[i].x, nrm[i].y, nrm[i].z]
            m.col += [col[i].x, col[i].y, col[i].z]
            m.uv += [uv[i].x, uv[i].y]
        }
        m.idx = idx
        let g = m.geometry()
        g.materials = [material]
        return g
    }
}

/// A rig as a tree of nodes (one per bone), for creatures that aren't drawn in the batched mesh.
final class RigNodes {
    let root = SCNNode()
    let species: DinoSpecies
    private var nodes: [SCNNode] = []
    private var pose: [simd_quatf] = []

    init(_ sp: DinoSpecies, material: SCNMaterial, far: Bool = false) {
        species = sp
        let rig = sp.rig
        for (i, b) in rig.bones.enumerated() {
            let n = SCNNode()
            let t = far ? rig.far[i] : rig.near[i]
            if !t.isEmpty { n.geometry = t.geometry(material) }
            n.castsShadow = true
            (b.parent < 0 ? root : nodes[b.parent]).addChildNode(n)
            nodes.append(n)
        }
    }

    func apply(_ m: DinoMotion) {
        species.pose(m, into: &pose)
        for (i, b) in species.rig.bones.enumerated() {
            var t = simd_float4x4(b.rest * pose[i])
            t.columns.3 = SIMD4(b.offset, 1)
            nodes[i].simdTransform = t
        }
    }
}

// MARK: - Skeletons

enum Fossil {
    static let bone = SIMD3<Float>(0.88, 0.84, 0.72)
    static let boneDark = SIMD3<Float>(0.68, 0.63, 0.52)

    /// A giant skeleton: a spine from `a` to `b` arching a little, ribs curving down to the ground on both sides
    /// (`halfWidth` out), a skull resting at the `a` end and a tail trailing off past `b`. Builds into `m` (offset by
    /// `origin`) and returns collision capsules in world space.
    static func build(_ m: inout MeshBuilder, spine a: SIMD3<Float>, _ b: SIMD3<Float>, halfWidth w: Float, origin: SIMD3<Float>,
                      ground: (Float, Float) -> Float, ribEvery: Float = 3.4, skull: Bool = true) -> [Capsule] {
        var caps: [Capsule] = []
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }
        let len = simd_distance(a, b)
        let fwd = simd_normalize(b - a)
        var side = simd_normalize(simd_cross(fwd, kUp))
        if !side.x.isFinite { side = SIMD3(1, 0, 0) }
        let n = max(4, Int(len / 1.7))
        var spine: [SIMD3<Float>] = []
        for k in 0...n {
            let t = Float(k) / Float(n)
            spine.append(a + (b - a) * t + SIMD3(0, sin(t * .pi) * len * 0.05, 0))
        }
        // Vertebrae: knobbly bodies with a spine sticking up from each.
        for k in 0...n {
            let p = spine[k]
            m.ellipsoid(L(p), SIMD3(0.75, 0.6, 0.8), k % 2 == 0 ? bone : bone * 0.95, rings: 3, sides: 7)
            m.horn(L(p + SIMD3(0, 0.4, 0)), L(p + SIMD3(0, 1.8, 0) - fwd * 0.3), r: 0.25, bone * 0.97, sides: 4)
            if k > 0 { m.tube(L(spine[k - 1]), L(p), r0: 0.42, r1: 0.42, sides: 6, boneDark) }
        }
        for k in 1...n { caps.append(Capsule(a: spine[k - 1], b: spine[k], r: 0.95)) }
        // Ribs.
        var s: Float = ribEvery * 0.8
        while s < len - ribEvery * 0.5 {
            let t = s / len
            let top = a + (b - a) * t + SIMD3(0, sin(t * .pi) * len * 0.05, 0)
            let scale = 0.75 + 0.25 * sin(t * .pi)
            for sg: Float in [-1, 1] {
                var pts: [SIMD3<Float>] = []
                for q in 0...8 {
                    let u = Float(q) / 8
                    let ang = u * .pi / 2
                    let lat = sin(ang) * w * scale * (1 + 0.12 * sin(u * .pi))
                    let flat = top + side * sg * lat
                    let g = ground(flat.x, flat.z)
                    let y = g + 0.3 + (top.y - g - 0.3) * pow(cos(ang), 0.8)
                    pts.append(SIMD3(flat.x, y, flat.z) - fwd * u * 1.2)
                }
                for q in 1..<pts.count {
                    let r0 = 0.55 - 0.3 * Float(q - 1) / 8, r1 = 0.55 - 0.3 * Float(q) / 8
                    m.tube(L(pts[q - 1]), L(pts[q]), r0: r0, r1: r1, sides: 5, q % 3 == 0 ? bone * 0.96 : bone)
                    caps.append(Capsule(a: pts[q - 1], b: pts[q], r: r0 + 0.15))
                }
            }
            s += ribEvery
        }
        // The tail: smaller and smaller vertebrae trailing off along the ground.
        var prev = b
        for k in 1...10 {
            let t = Float(k) / 10
            var p = b + fwd * (len * 0.55 * t) + side * sin(t * 2.2) * len * 0.08
            p.y = ground(p.x, p.z) + 0.5 + (b.y - ground(b.x, b.z)) * pow(1 - t, 2.4)
            let r = 0.65 * (1 - t * 0.8)
            m.ellipsoid(L(p), SIMD3(r, r * 0.8, r * 1.2), bone, rings: 2, sides: 6)
            m.tube(L(prev), L(p), r0: r * 0.6, r1: r * 0.5, sides: 5, boneDark)
            if k < 5 { caps.append(Capsule(a: prev, b: p, r: r + 0.3)) }
            prev = p
        }
        guard skull else { return caps }
        // Neck down to the skull, resting on the ground in front.
        var neckEnd = a - fwd * len * 0.22
        neckEnd.y = ground(neckEnd.x, neckEnd.z) + 2.2
        m.tube(L(a), L(neckEnd), r0: 0.55, r1: 0.5, sides: 6, boneDark)
        for k in 1...4 {
            let p = a + (neckEnd - a) * (Float(k) / 5)
            m.ellipsoid(L(p), SIMD3(0.7, 0.6, 0.75), bone, rings: 2, sides: 6)
        }
        caps.append(Capsule(a: a, b: neckEnd, r: 0.9))
        let skullLen = len * 0.2
        var tip = neckEnd - fwd * skullLen
        tip.y = ground(tip.x, tip.z) + 1.1
        let pts = [neckEnd + fwd * 0.4, neckEnd - fwd * skullLen * 0.3 + SIMD3(0, 0.3, 0), neckEnd - fwd * skullLen * 0.7, tip]
        let rr: [SIMD2<Float>] = [SIMD2(1.5, 1.8), SIMD2(1.6, 1.9), SIMD2(1.1, 1.2), SIMD2(0.6, 0.55)].map { $0 * (skullLen / 6) }
        m.loft(pts.map(L), rr, skin: Skin(back: bone, belly: boneDark), sides: 9)
        // Eye sockets, nostril holes and a row of teeth.
        for sg: Float in [-1, 1] {
            let e = neckEnd - fwd * skullLen * 0.32 + side * sg * rr[1].x * 0.92 + SIMD3(0, rr[1].y * 0.35, 0)
            m.ellipsoid(L(e), SIMD3(repeating: rr[1].y * 0.32), SIMD3(0.12, 0.1, 0.09), rings: 3, sides: 7)
            for q in 0..<7 {
                let tq = 0.35 + Float(q) * 0.09
                let p = neckEnd - fwd * skullLen * tq + side * sg * (rr[2].x * 0.8) - SIMD3(0, rr[2].y * 0.7, 0)
                m.horn(L(p), L(p - SIMD3(0, skullLen * 0.08, 0)), r: skullLen * 0.022, SIMD3(0.95, 0.93, 0.85), sides: 4)
            }
        }
        caps.append(Capsule(a: neckEnd, b: tip, r: rr[1].y * 0.9))
        return caps
    }
}

/// Fly through the ribcage of a giant fossil skeleton.
final class FossilRibs: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private var caps: [Capsule] = []

    init(frame f: PathFrame) {
        center = f.origin
        var m = MeshBuilder()
        let a = f.at(0, -22, 9), b = f.at(0, 22, 9)
        caps = Fossil.build(&m, spine: a, b, halfWidth: 13, origin: f.origin, ground: { TerrainShape.ground($0, $1) })
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
        for c in caps { if let v = c.push(p, radius) { return v } }
        return nil
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 80 ? "Thread the ribcage!" : nil
    }
}

/// A giant conifer fallen across the course: its roots up on one bank, its crown on a boulder on the other. Under or over.
final class FallenGiant: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 60
    private var caps: [Capsule] = []

    init(frame f: PathFrame) {
        center = f.origin
        var m = MeshBuilder()
        let bark = SIMD3<Float>(0.4, 0.31, 0.22), moss = SIMD3<Float>(0.3, 0.45, 0.17)
        let rootEnd = f.at(-30, 4, 0), crownEnd = f.at(30, -4, 0)
        let gR = TerrainShape.ground(rootEnd.x, rootEnd.z), gC = TerrainShape.ground(crownEnd.x, crownEnd.z)
        // Across the path a couple of metres above the line, sloping down to each end.
        let mid = f.origin + SIMD3(0, 2.6, 0)
        let r0 = SIMD3(rootEnd.x, max(gR + 2.5, mid.y - 9), rootEnd.z), c0 = SIMD3(crownEnd.x, max(gC + 6, mid.y - 6), crownEnd.z)
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - f.origin }
        m.tube(L(r0), L(mid), r0: 3.4, r1: 3.0, sides: 11, bark, cap: true)
        m.tube(L(mid), L(c0), r0: 3.0, r1: 1.6, sides: 11, bark, cap: true)
        m.tube(L(r0) + SIMD3(0, 1.3, 0), L(mid) + SIMD3(0, 1.2, 0), r0: 3.0, r1: 2.6, sides: 8, moss)
        caps += [Capsule(a: r0, b: mid, r: 3.5), Capsule(a: mid, b: c0, r: 3.1)]
        // The root plate: a ragged disc of earth and roots standing on end.
        let axis = simd_normalize(r0 - mid)
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Int(f.origin.x * 7 + f.origin.z))))
        m.ellipsoid(L(r0 + axis * 1.5), SIMD3(5.5, 5.5, 5.5) * SIMD3(abs(axis.x) > 0.5 ? 0.35 : 1, 1, abs(axis.z) > 0.5 ? 0.35 : 1),
                    SIMD3(0.36, 0.28, 0.2), rings: 4, sides: 9)
        for _ in 0..<9 {
            let d = simd_normalize(SIMD3(rng.float(-1, 1), rng.float(-1, 1), rng.float(-1, 1)) - axis * 0.5)
            m.limb(from: L(r0 + axis), to: L(r0 + axis * 2 + d * rng.float(4, 7)), r0: 0.45, r1: 0.05, sides: 4, color: SIMD3(0.42, 0.33, 0.24))
        }
        caps.append(Capsule(a: r0, b: r0 + axis * 2.5, r: 5))
        // Broken branches and a boulder under the crown.
        for k in 0..<6 {
            let p = mid + (c0 - mid) * (0.3 + Float(k) * 0.11)
            let d = simd_normalize(SIMD3(rng.float(-1, 1), rng.float(0.2, 1), rng.float(-1, 1)))
            m.limb(from: L(p), to: L(p + d * rng.float(3, 6)), r0: 0.35, r1: 0.06, sides: 4, color: bark * 1.1)
        }
        let rock = SIMD3(c0.x, gC, c0.z)
        m.boulder(at: L(rock + SIMD3(0, 2.5, 0)), radius: 6, color: SIMD3(0.5, 0.45, 0.38), grass: moss, &rng)
        caps.append(Capsule(a: rock, b: rock + SIMD3(0, 4, 0), r: 5.5))
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
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 70 ? "Fallen tree — under or over!" : nil
    }
}

/// Hot springs under the course that blast steam on a timer: time your pass (it'll throw you if you don't).
final class SteamGeysers: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 110
    private var vents: [(pos: SIMD3<Float>, offset: Float, steam: SCNParticleSystem, wisps: SCNParticleSystem, pool: SCNMaterial)] = []
    private let period: Float = 5.2
    private let radius: Float = 8.5

    private static let puff: CGImage = makeImage(width: 64, height: 64) { x, y in
        let d = simd_length(SIMD2(Float(x) - 31.5, Float(y) - 31.5)) / 32
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, a * a * (3 - 2 * a))
    }

    init(frame f: PathFrame) {
        center = f.origin
        for i in 0..<3 {
            let b = f.at(Float(i - 1) * 7, Float(i) * 20 - 20, 0)
            let g = max(TerrainShape.ground(b.x, b.z), 0)
            let pos = SIMD3(b.x, g, b.z)
            // A crusted mound with a steaming turquoise pool.
            var m = MeshBuilder()
            m.cylinder(.zero, r0: 7.5, r1: 4.2, y0: -1, y1: 1.6, sides: 14, SIMD3(0.86, 0.6, 0.32))
            m.cylinder(SIMD3(0, 0, 0), r0: 4.6, r1: 3.6, y0: 1.5, y1: 1.9, sides: 14, SIMD3(0.92, 0.88, 0.78))
            let mound = m.geometry()
            mound.materials = [WorldMaterials.vertexColor(rough: 0.7)]
            let mn = SCNNode(geometry: mound)
            mn.simdPosition = pos
            node.addChildNode(mn)
            let pool = SCNMaterial()
            pool.lightingModel = .constant
            pool.diffuse.contents = NSColor(srgbRed: 0.25, green: 0.8, blue: 0.78, alpha: 1)
            pool.diffuse.intensity = 0.9
            let disc = SCNNode(geometry: SCNCylinder(radius: 3.4, height: 0.2))
            disc.geometry?.materials = [pool]
            disc.simdPosition = pos + SIMD3(0, 1.95, 0)
            node.addChildNode(disc)
            let emitter = SCNNode()
            emitter.simdPosition = pos + SIMD3(0, 2, 0)
            let steam = SteamGeysers.steam(), wisps = SteamGeysers.wisps()
            emitter.addParticleSystem(steam)
            emitter.addParticleSystem(wisps)
            node.addChildNode(emitter)
            vents.append((pos, Float(i) / 3 * period, steam, wisps, pool))
        }
    }

    private static func steam() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 0
        s.emitterShape = SCNSphere(radius: 2.2)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 9
        s.particleVelocity = 58
        s.particleVelocityVariation = 10
        s.particleLifeSpan = 1.9
        s.particleLifeSpanVariation = 0.4
        s.particleSize = 4
        s.particleSizeVariation = 1.5
        s.acceleration = SCNVector3(0, -14, 0)
        s.dampingFactor = 0.6
        s.particleImage = puff
        s.particleColor = NSColor(white: 0.97, alpha: 0.7)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        let grow = CAKeyframeAnimation()
        grow.values = [0.6, 1.6, 3.2]
        grow.keyTimes = [0, 0.4, 1]
        let fade = CAKeyframeAnimation()
        fade.values = [0.9, 0.7, 0]
        fade.keyTimes = [0, 0.6, 1]
        s.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
        return s
    }

    private static func wisps() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 6
        s.emitterShape = SCNSphere(radius: 2.5)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 25
        s.particleVelocity = 3
        s.particleLifeSpan = 3
        s.particleSize = 2.5
        s.particleImage = puff
        s.particleColor = NSColor(white: 0.95, alpha: 0.35)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [0, 0.6, 0]
        fade.keyTimes = [0, 0.3, 1]
        s.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return s
    }

    /// 0 simmering, 1 about to go, 2 blowing.
    private func state(_ offset: Float, _ time: Float) -> Int {
        let t = (time + offset).truncatingRemainder(dividingBy: period)
        return t < 1.8 ? 0 : (t < 3.0 ? 1 : 2)
    }

    func update(time: Float) {
        for v in vents {
            switch state(v.offset, time) {
            case 0: v.steam.birthRate = 0; v.wisps.birthRate = 6; v.pool.diffuse.intensity = 0.9
            case 1: v.steam.birthRate = 0; v.wisps.birthRate = 30; v.pool.diffuse.intensity = 0.9 + 0.5 * CGFloat(abs(sin(time * 12)))
            default: v.steam.birthRate = 260; v.wisps.birthRate = 10; v.pool.diffuse.intensity = 1.3
            }
        }
    }

    func push(_ p: SIMD3<Float>, radius r: Float, time: Float) -> SIMD3<Float>? {
        for v in vents {
            if let c = Capsule(a: v.pos - SIMD3(0, 1, 0), b: v.pos + SIMD3(0, 1, 0), r: 6).push(p, r) { return c }
            let flat = SIMD2(p.x - v.pos.x, p.z - v.pos.z)
            let d = simd_length(flat)
            guard state(v.offset, time) == 2, d < radius + r, p.y > v.pos.y, p.y < v.pos.y + 70 else { continue }
            let out = d > 0.1 ? SIMD3(flat.x / d, 0, flat.y / d) : SIMD3(1, 0, 0)
            return out * (radius + r - d) + SIMD3(0, 3.5, 0)
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        guard simd_distance(p, center) < 120 else { return nil }
        return vents.contains { state($0.offset, time) == 1 } ? "Geyser about to blow!" : nil
    }
}

/// Pteranodons wheeling around a gate: slip between them.
final class PteroOrbit: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 60
    private var birds: [RigNodes] = []
    private let radius: Float = 13
    private let period: Float = 6.5
    private let phase: Float

    init(frame f: PathFrame, phase: Float) {
        center = f.origin
        self.phase = phase
        let mat = WorldMaterials.vertexColor(rough: 0.75)
        for _ in 0..<3 {
            let r = RigNodes(DinoSpecies.all[.ptero]!, material: mat)
            r.root.simdScale = SIMD3(repeating: 1.25)
            node.addChildNode(r.root)
            birds.append(r)
        }
        update(time: 0)
    }

    private func place(_ k: Int, _ t: Float) -> (SIMD3<Float>, Float) {
        let a = (t / period + Float(k) / 3) * 2 * .pi + phase
        let p = center + SIMD3(cos(a) * radius, sin(a * 2 + Float(k)) * 2.5, sin(a) * radius)
        // Flying along the circle (counter-clockwise seen from above).
        let yaw = atan2(-(-sin(a)), -(cos(a)))
        return (p, yaw)
    }

    func update(time: Float) {
        for (k, b) in birds.enumerated() {
            let (p, yaw) = place(k, time)
            b.root.simdPosition = p
            b.root.simdOrientation = yawQuat(yaw) * rotZ(0.35)
            var m = DinoMotion()
            m.flap = 0.8
            m.phase = (time * 1.4 + Float(k) * 0.3).truncatingRemainder(dividingBy: 1)
            b.apply(m)
        }
    }

    func push(_ p: SIMD3<Float>, radius r: Float, time: Float) -> SIMD3<Float>? {
        guard simd_distance(p, center) < reach else { return nil }
        for k in 0..<birds.count {
            let (q, _) = place(k, time)
            if let v = Capsule(a: q, b: q, r: 2.6).push(p, r) { return v * 1.5 }
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 70 ? "Pteranodons circling — slip between!" : nil
    }
}
