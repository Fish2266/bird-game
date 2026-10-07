import SceneKit
import simd

// The jetpack: the reward at the very end. Two polished tanks strapped to the bird's back with gold trim and black
// nozzles; lit, it roars, throws flame and smoke, and pushes harder the longer it burns — with no top speed at all.
// Clap (or press B) to light it, clap again to let it go out; Settings has it on or off your back.

enum JetpackTuning {
    /// Thrust (m/s²) the moment it lights, and how much more each second it keeps burning. It never stops growing.
    static let thrust: Float = 30
    static let build: Float = 18
    /// Seconds after it goes out before the air gets its grip back (you coast).
    static let coast: Float = 3
    /// While burning or coasting the bird turns as if it were doing this speed (otherwise it couldn't turn at all).
    static let turnSpeed: Float = 55
}

/// The jetpack on a bird: the model on its back and the flames, built in the bird's body space (forward is −z, so the
/// nozzles point to +z).
final class JetpackRig {
    let node = SCNNode()
    private var flames: [SCNNode] = []
    private var fire: [SCNParticleSystem] = []
    private var smoke: [SCNParticleSystem] = []
    private var throttle: Float = 0
    /// The harness round the bird's body (hidden while the jetpack floats on its own).
    let straps = SCNNode()

    private static let flameMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)
        m.diffuse.intensity = 2.4
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }()
    private static let coreMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)
        m.diffuse.intensity = 3
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }()

    private static let puff: CGImage = makeImage(width: 32, height: 32) { x, y in
        let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, a * a)
    }

    init() {
        let chrome = Shapes.mat(NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1), rough: 0.15, metal: 1.0)
        let red = Shapes.mat(NSColor(srgbRed: 0.85, green: 0.12, blue: 0.12, alpha: 1), rough: 0.3)
        let gold = Shapes.mat(NSColor(srgbRed: 1, green: 0.78, blue: 0.3, alpha: 1), rough: 0.2, metal: 1.0)
        let black = Shapes.mat(NSColor(white: 0.08, alpha: 1), rough: 0.5, metal: 0.4)
        let strap = Shapes.mat(NSColor(srgbRed: 0.24, green: 0.16, blue: 0.1, alpha: 1), rough: 0.8)
        // The back plate the tanks hang from.
        node.addChildNode(Shapes.node(SCNBox(width: 0.14, height: 0.03, length: 0.26, chamferRadius: 0.012), black, at: SIMD3(0, 0.15, 0.04)))
        for s: Float in [-1, 1] {
            let x = s * 0.062
            // A tank: a capsule lying along the body, a red band, gold caps.
            let tank = SCNNode(geometry: SCNCapsule(capRadius: 0.048, height: 0.32))
            tank.geometry?.materials = [chrome]
            tank.simdPosition = SIMD3(x, 0.19, 0.03)
            tank.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            node.addChildNode(tank)
            let band = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.05))
            band.geometry?.materials = [red]
            band.simdPosition = SIMD3(x, 0.19, -0.02)
            band.simdOrientation = tank.simdOrientation
            node.addChildNode(band)
            node.addChildNode(Shapes.node(Shapes.ball(0.02, segments: 8), gold, at: SIMD3(x, 0.19, -0.14)))
            // The nozzle at the back.
            let nozzle = SCNNode(geometry: SCNCone(topRadius: 0.026, bottomRadius: 0.04, height: 0.06))
            nozzle.geometry?.materials = [black]
            nozzle.simdPosition = SIMD3(x, 0.19, 0.2)
            nozzle.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
            node.addChildNode(nozzle)
            // Fins.
            node.addChildNode(Shapes.node(SCNBox(width: 0.004, height: 0.05, length: 0.06, chamferRadius: 0.002), red, at: SIMD3(x + s * 0.045, 0.2, 0.15)))
            // The flame: an outer cone and a hot blue core, scaled by the throttle.
            let flame = SCNNode()
            flame.simdPosition = SIMD3(x, 0.19, 0.23)
            let outer = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.035, height: 0.3))
            outer.geometry?.materials = [JetpackRig.flameMat]
            outer.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            outer.simdPosition = SIMD3(0, 0, 0.15)
            flame.addChildNode(outer)
            let core = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.018, height: 0.14))
            core.geometry?.materials = [JetpackRig.coreMat]
            core.simdOrientation = outer.simdOrientation
            core.simdPosition = SIMD3(0, 0, 0.07)
            flame.addChildNode(core)
            flame.isHidden = true
            node.addChildNode(flame)
            flames.append(flame)
            // Fire and smoke left behind in the world.
            let f = SCNParticleSystem()
            f.birthRate = 0
            f.emitterShape = SCNSphere(radius: 0.03)
            f.emittingDirection = SCNVector3(0, 0, 1)
            f.spreadingAngle = 8
            f.particleVelocity = 3
            f.particleLifeSpan = 0.22
            f.particleLifeSpanVariation = 0.08
            f.particleSize = 0.09
            f.particleSizeVariation = 0.03
            f.particleImage = JetpackRig.puff
            f.particleColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 1)
            f.blendMode = .additive
            f.isLightingEnabled = false
            let shrink = CAKeyframeAnimation(); shrink.values = [1.0, 0.5]; shrink.keyTimes = [0, 1]
            f.propertyControllers = [.size: SCNParticlePropertyController(animation: shrink)]
            flame.addParticleSystem(f)
            fire.append(f)
            let sm = SCNParticleSystem()
            sm.birthRate = 0
            sm.emitterShape = SCNSphere(radius: 0.04)
            sm.particleVelocity = 0.6
            sm.spreadingAngle = 40
            sm.particleLifeSpan = 1.6
            sm.particleLifeSpanVariation = 0.5
            sm.particleSize = 0.18
            sm.particleImage = JetpackRig.puff
            sm.particleColor = NSColor(white: 0.85, alpha: 0.45)
            sm.blendMode = .alpha
            sm.isLightingEnabled = false
            let grow = CAKeyframeAnimation(); grow.values = [0.5, 2.6]; grow.keyTimes = [0, 1]
            let fade = CAKeyframeAnimation(); fade.values = [0.6, 0]; fade.keyTimes = [0, 1]
            sm.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
            flame.addParticleSystem(sm)
            smoke.append(sm)
        }
        // Straps round the body.
        for z: Float in [-0.06, 0.12] {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.155, pipeRadius: 0.009))
            ring.geometry?.materials = [strap]
            ring.simdPosition = SIMD3(0, 0.0, z)
            ring.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            ring.simdScale = SIMD3(1.05, 1, 0.92)
            straps.addChildNode(ring)
        }
        node.addChildNode(straps)
        node.enumerateHierarchy { n, _ in n.castsShadow = n.geometry?.firstMaterial !== JetpackRig.flameMat && n.geometry?.firstMaterial !== JetpackRig.coreMat }
    }

    /// 0 = out, 1 = full burn. `time` drives the flicker; `speed` stretches the flame and thins the smoke.
    func update(throttle t: Float, time: Float, speed: Float) {
        throttle += (t - throttle) * 0.35
        let on = throttle > 0.02
        for (k, f) in flames.enumerated() {
            f.isHidden = !on
            guard on else { continue }
            let flick = 0.85 + 0.15 * sin(time * 47 + Float(k) * 2) + 0.08 * sin(time * 91 + Float(k))
            let len = throttle * flick * (1 + min(speed / 120, 2.5))
            f.simdScale = SIMD3(0.8 + 0.4 * throttle, 0.8 + 0.4 * throttle, len)
        }
        for p in fire { p.birthRate = on ? CGFloat(140 * throttle) : 0 }
        for p in smoke { p.birthRate = on ? CGFloat(30 * throttle * (speed < 200 ? 1 : 0.3)) : 0 }
    }
}
