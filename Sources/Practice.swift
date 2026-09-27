import SceneKit
import simd

/// Floating balloon targets for practising attacks in the tutorial. They sit ahead of the bird, pop when hit
/// and come back a moment later.
final class PracticeTargets {
    let root = SCNNode()
    static let firstId = 900
    private struct Target {
        let id: Int
        var pos: SIMD3<Float>
        let node: SCNNode
        var away: Float = 0
    }
    private var targets: [Target] = []
    private(set) var hits = 0
    private var time: Float = 0

    init(count: Int = 3) {
        let stripes = Patterns.stripes(SIMD3(0.92, 0.18, 0.18), SIMD3(0.98, 0.97, 0.95), count: 3, diagonal: false)
        for k in 0..<count {
            let n = SCNNode()
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = stripes
            m.diffuse.wrapS = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 1, 1)
            m.roughness.contents = 0.35
            m.emission.contents = NSColor(white: 0.12, alpha: 1)
            let ball = SCNNode(geometry: SCNSphere(radius: 1.5))
            ball.geometry?.materials = [m]
            ball.scale = SCNVector3(1, 1.18, 1)
            n.addChildNode(ball)
            let knot = SCNNode(geometry: SCNCone(topRadius: 0.05, bottomRadius: 0.28, height: 0.4))
            knot.geometry?.materials = [Shapes.mat(NSColor(srgbRed: 0.85, green: 0.14, blue: 0.14, alpha: 1))]
            knot.position = SCNVector3(0, -1.85, 0)
            n.addChildNode(knot)
            let string = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 4))
            string.geometry?.materials = [Shapes.mat(NSColor(white: 0.95, alpha: 1))]
            string.position = SCNVector3(0, -4, 0)
            n.addChildNode(string)
            n.castsShadow = false
            n.isHidden = true
            root.addChildNode(n)
            targets.append(Target(id: PracticeTargets.firstId + k, pos: .zero, node: n))
        }
    }

    static func isPractice(_ id: Int) -> Bool { id >= firstId && id < firstId + 10 }

    /// Line the targets up ahead of the bird.
    func place(ahead of: FlightModel) {
        for i in targets.indices { respawn(i, around: of) }
    }

    private func respawn(_ i: Int, around f: FlightModel) {
        var fwd = f.forward
        fwd.y = 0
        fwd = simd_length(fwd) > 0.1 ? simd_normalize(fwd) : SIMD3(0, 0, -1)
        let side = simd_normalize(simd_cross(fwd, kUp))
        let lateral: [Float] = [0, -14, 14, -7, 7]
        var p = f.pos + fwd * (75 + Float(i) * 22) + side * lateral[i % lateral.count]
        p.y = max(f.pos.y + Float(i % 2) * 4, TerrainShape.ground(p.x, p.z) + 25)
        targets[i].pos = p
        targets[i].away = 0
        targets[i].node.isHidden = false
        targets[i].node.opacity = 1
        targets[i].node.simdScale = SIMD3(repeating: 1)
        targets[i].node.simdPosition = p
    }

    var active: [CombatTarget] {
        targets.filter { $0.away <= 0 }.map { CombatTarget(id: $0.id, pos: $0.pos, vel: .zero, radius: 1.9) }
    }

    func update(dt: Float, flight: FlightModel) {
        time += dt
        for i in targets.indices {
            if targets[i].away > 0 {
                targets[i].away -= dt
                if targets[i].away <= 0 { respawn(i, around: flight) }
                continue
            }
            // Bob gently; left far behind (or far away), come back in front.
            targets[i].node.simdPosition = targets[i].pos + SIMD3(0, sin(time * 1.3 + Float(i)) * 0.5, 0)
            let to = targets[i].pos - flight.pos
            if simd_length(to) > 420 || (simd_dot(to, flight.forward) < -40) { respawn(i, around: flight) }
        }
    }

    /// Pop a target. Returns true if it was one of ours.
    @discardableResult
    func hit(_ id: Int) -> Bool {
        guard let i = targets.firstIndex(where: { $0.id == id }), targets[i].away <= 0 else { return false }
        hits += 1
        targets[i].away = 2.5
        let n = targets[i].node
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        n.simdScale = SIMD3(repeating: 1.8)
        n.opacity = 0
        SCNTransaction.commit()
        let burst = SCNNode()
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.05
        ps.birthRate = 400
        ps.particleLifeSpan = 1.1
        ps.particleVelocity = 9
        ps.particleVelocityVariation = 4
        ps.spreadingAngle = 180
        ps.particleSize = 0.25
        ps.particleImage = TrailSprites.square
        ps.particleColor = NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
        ps.particleColorVariation = SCNVector4(1, 0.2, 0.1, 0)
        ps.acceleration = SCNVector3(0, -6, 0)
        ps.particleAngularVelocity = 300
        ps.isLightingEnabled = false
        burst.addParticleSystem(ps)
        burst.simdPosition = targets[i].pos
        root.addChildNode(burst)
        burst.runAction(.sequence([.wait(duration: 1.5), .removeFromParentNode()]))
        return true
    }

    func hideAll() { for t in targets { t.node.isHidden = true } }
}

extension Game {
    /// Tutorial: balloon targets to shoot at (nil = none).
    func setPracticeTargets(_ on: Bool) {
        enqueue { g in
            if on {
                if g.practice == nil {
                    let p = PracticeTargets()
                    g.scene.rootNode.addChildNode(p.root)
                    g.practice = p
                }
                g.practice?.place(ahead: g.flight)
                g.practiceCombat = true
            } else {
                g.practice?.root.removeFromParentNode()
                g.practice = nil
                g.practiceCombat = false
                g.reticle.isHidden = true
            }
        }
    }

    /// Tutorial: show the free-roam rings (easy ones close by) or hide them.
    func setTutorialRings(_ on: Bool) {
        enqueue { g in
            g.ringsEnabled = on
            g.rings.root.isHidden = !on
            guard on else { return }
            // Close, gentle rings straight ahead to start with.
            g.rings.params.firstDistance = 65...80
            g.rings.params.spacing = 95...120
            g.rings.params.climb = -10...10
            g.rings.params.yawJitter = 0.3
            g.rings.params.minAboveGround = 25...40
            g.rings.reset(from: g.flight.pos, heading: g.flight.forward)
        }
    }

    /// Back to the normal free-roam ring course.
    func restoreRings() {
        enqueue { g in
            g.rings.params = RingCourseParams()
            g.runtime?.configure(g.rings)
            g.ringsEnabled = true
            g.rings.root.isHidden = g.mode != .freeRoam
        }
    }
}
