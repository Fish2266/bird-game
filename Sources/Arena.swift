import SceneKit
import simd

/// PvP fight arena: a glowing wall around the spawn that slowly closes in.
final class Arena {
    let root = SCNNode()
    let center: SIMD3<Float>
    let baseRadius: Float
    private(set) var radius: Float
    /// Highest you can fly.
    let top: Float
    private let wall = SCNNode()
    private let material = SCNMaterial()
    private let caves: Bool
    /// Seconds before the wall starts to close, and how long it takes to reach its smallest size.
    static let holdTime: Float = 45, shrinkTime: Float = 100, minFraction: Float = 0.3

    init(spawn: SIMD3<Float>, world: WorldID) {
        caves = world == .caves
        center = SIMD3(spawn.x, TerrainShape.ground(spawn.x, spawn.z), spawn.z)
        baseRadius = caves ? 170 : 330
        radius = baseRadius
        var hi: Float = center.y
        for a in stride(from: Float(0), to: 2 * .pi, by: .pi / 8) {
            for r in [baseRadius * 0.3, baseRadius * 0.6, baseRadius * 0.9] {
                hi = max(hi, TerrainShape.ground(center.x + cos(a) * r, center.z + sin(a) * r))
            }
        }
        top = caves ? center.y + 200 : max(hi, center.y) + 260
        let bottom = center.y - 120
        let cyl = SCNCylinder(radius: CGFloat(baseRadius), height: CGFloat(top - bottom))
        cyl.radialSegmentCount = 96
        cyl.heightSegmentCount = 1
        material.lightingModel = .constant
        let tex = Arena.stripes()
        material.diffuse.contents = tex
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(baseRadius / 9.5), CGFloat((top - bottom) / 60), 1)
        material.isDoubleSided = true
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.transparency = 0.6
        // A force field: only shows up when you get near it.
        material.shaderModifiers = [.fragment: """
        #pragma transparent
        #pragma body
        float d = length(_surface.position);
        _output.color *= smoothstep(150.0, 45.0, d);
        """]
        let clear = SCNMaterial()
        clear.transparency = 0
        clear.writesToDepthBuffer = false
        cyl.materials = [material, clear, clear]
        wall.geometry = cyl
        wall.simdPosition = SIMD3(center.x, (top + bottom) / 2, center.z)
        wall.castsShadow = false
        wall.renderingOrder = 15
        root.addChildNode(wall)
    }

    func reset() { radius = baseRadius; wall.simdScale = SIMD3(1, 1, 1) }

    /// `t` is seconds since the fight started (nil = not running: full size).
    func update(fightTime t: Float?, time: Float) {
        if let t {
            let k = smoothstep(Arena.holdTime, Arena.holdTime + Arena.shrinkTime, t)
            radius = baseRadius * lerp(1, Arena.minFraction, k)
        } else {
            radius = baseRadius
        }
        let s = radius / baseRadius
        wall.simdScale = SIMD3(s, 1, s)
        var m = SCNMatrix4MakeScale(CGFloat(radius / 9.5), CGFloat((top - center.y + 120) / 60), 1)
        m = SCNMatrix4Translate(m, CGFloat(time * 0.15), CGFloat(time * 0.4), 0)
        material.diffuse.contentsTransform = m
    }

    var shrinking: Bool { radius < baseRadius - 1 }

    /// Keeps a bird inside. Returns the inward push if it touched the wall.
    func constrain(_ f: FlightModel) -> SIMD3<Float>? {
        var push: SIMD3<Float>?
        let flat = SIMD2(f.pos.x - center.x, f.pos.z - center.z)
        let d = simd_length(flat)
        if d > radius - 1.5 {
            let n = flat / max(d, 1e-3)
            f.pos.x = center.x + n.x * (radius - 1.5)
            f.pos.z = center.z + n.y * (radius - 1.5)
            // Turn to glance off the wall.
            let fwd = SIMD2(f.forward.x, f.forward.z)
            let into = simd_dot(fwd, n)
            if into > 0 {
                let out = simd_normalize(fwd - n * into * 1.3)
                f.yaw = atan2(-out.x, -out.y)
            }
            push = SIMD3(-n.x, 0.25, -n.y)
        }
        if f.pos.y > top {
            f.pos.y = top
            f.pitch = min(f.pitch, -0.1)
        }
        return push
    }

    /// Distance to the wall (for the HUD warning).
    func distanceToWall(_ p: SIMD3<Float>) -> Float { radius - simd_length(SIMD2(p.x - center.x, p.z - center.z)) }

    /// Starting spots in a circle facing the middle. Caves: along the tunnel from the spawn.
    func spawn(slot: Int, count: Int, spawnYaw: Float) -> (SIMD3<Float>, Float) {
        if caves, let cave = TerrainShape.active as? CaveTerrain {
            var p = SIMD2(center.x, center.z)
            var d = SIMD2(-sin(spawnYaw), -cos(spawnYaw)) * (slot % 2 == 0 ? 1 : -1)
            let steps = 8 + (slot / 2) * 14
            for _ in 0..<steps {
                d = cave.tangent(p.x, p.y, prefer: d)
                p = cave.recenter(p + d * 4)
            }
            let s = cave.sample(p.x, p.y)
            // Face back toward the others.
            let back = -d
            return (SIMD3(p.x, (s.floor + s.ceiling) * 0.5, p.y), atan2(-back.x, -back.y))
        }
        let a = Float(slot) / Float(max(count, 2)) * 2 * .pi + 0.4
        let r = baseRadius * 0.55
        let x = center.x + cos(a) * r, z = center.z + sin(a) * r
        var g: Float = -1e9
        for (dx, dz) in [(0, 0), (20, 0), (-20, 0), (0, 20), (0, -20)] as [(Float, Float)] { g = max(g, TerrainShape.ground(x + dx, z + dz)) }
        let to = SIMD2(center.x - x, center.z - z)
        return (SIMD3(x, max(g + 45, center.y + 70), z), atan2(-to.x, -to.y))
    }

    private static func stripes() -> CGImage {
        makeImage(width: 64, height: 64) { x, y in
            let u = Float(x) / 64, v = Float(y) / 64
            // Soft hexagon-ish lattice: diagonal bands both ways plus a faint wash.
            let d1 = (u + v).truncatingRemainder(dividingBy: 1), d2 = (u - v + 1).truncatingRemainder(dividingBy: 1)
            let band = max(smoothstep(0.06, 0.0, abs(d1 - 0.5)), smoothstep(0.06, 0.0, abs(d2 - 0.5)))
            let a = max(band * 0.75, 0.08)
            return SIMD4(1.0, 0.4 + band * 0.3, 0.2, a)
        }
    }
}

/// Floating health orbs in the arena. Fly through one for +35 health; it comes back after a while.
final class HealthOrbs {
    let root = SCNNode()
    static let heal: Float = 35
    static let respawnTime: Float = 25
    private struct Orb {
        var pos: SIMD3<Float>
        var node: SCNNode
        var away: Float = 0
    }
    private var orbs: [Orb] = []
    private weak var arena: Arena?

    init(arena: Arena, spawnYaw: Float, caves: Bool) {
        self.arena = arena
        let mat = glowMat(rgb(0.35, 1, 0.5), 2)
        let core = glowMat(.white, 3)
        for k in 0..<6 {
            var p: SIMD3<Float>
            if caves {
                p = arena.spawn(slot: k + 8, count: 6, spawnYaw: spawnYaw).0
            } else {
                let a = Float(k) / 6 * 2 * .pi + 0.9
                let r = arena.baseRadius * (k % 2 == 0 ? 0.3 : 0.62)
                let x = arena.center.x + cos(a) * r, z = arena.center.z + sin(a) * r
                p = SIMD3(x, max(TerrainShape.ground(x, z) + 38, arena.center.y + 50), z)
            }
            let n = SCNNode()
            let ball = SCNNode(geometry: SCNSphere(radius: 1.1))
            ball.geometry?.materials = [mat]
            ball.opacity = 0.75
            n.addChildNode(ball)
            for rot: CGFloat in [0, .pi / 2] {
                let bar = SCNNode(geometry: SCNBox(width: 1.3, height: 0.35, length: 0.35, chamferRadius: 0.1))
                bar.geometry?.materials = [core]
                bar.eulerAngles.z = rot
                n.addChildNode(bar)
            }
            let halo = SCNNode(geometry: SCNTorus(ringRadius: 1.8, pipeRadius: 0.08))
            halo.geometry?.materials = [mat]
            n.addChildNode(halo)
            n.simdPosition = p
            n.castsShadow = false
            root.addChildNode(n)
            orbs.append(Orb(pos: p, node: n))
        }
    }

    func reset() {
        for i in orbs.indices { orbs[i].away = 0; orbs[i].node.isHidden = false }
    }

    private func available(_ o: Orb) -> Bool {
        guard o.away <= 0 else { return false }
        guard let a = arena else { return true }
        return a.distanceToWall(o.pos) > 5
    }

    /// Orbs that can be taken right now (for bots).
    var active: [SIMD3<Float>] { orbs.filter(available).map(\.pos) }

    func update(dt: Float, time: Float) {
        for i in orbs.indices {
            if orbs[i].away > 0 { orbs[i].away -= dt }
            let o = orbs[i]
            o.node.isHidden = !available(o)
            o.node.simdPosition = o.pos + SIMD3(0, sin(time * 1.5 + Float(i)) * 0.6, 0)
            o.node.eulerAngles.y = CGFloat(time * 1.4 + Float(i))
        }
    }

    /// Index of an orb a bird at `p` is touching, if any.
    func touching(_ p: SIMD3<Float>) -> Int? {
        orbs.indices.first { available(orbs[$0]) && simd_distance(orbs[$0].pos, p) < 4 }
    }

    func take(_ i: Int) {
        guard orbs.indices.contains(i) else { return }
        orbs[i].away = HealthOrbs.respawnTime
        orbs[i].node.isHidden = true
    }
}
