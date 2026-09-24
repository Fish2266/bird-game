import SceneKit
import simd

/// Colors and proportions for one bird species (colors in sRGB 0…1).
struct BirdLook {
    var body = SIMD3<Float>(0.78, 0.78, 0.78)
    var back = SIMD3<Float>(0.46, 0.50, 0.56)
    var head = SIMD3<Float>(0.78, 0.78, 0.78)
    var wingRoot = SIMD3<Float>(0.62, 0.66, 0.72)
    var wingMid = SIMD3<Float>(0.50, 0.54, 0.60)
    var wingTip = SIMD3<Float>(0.06, 0.06, 0.07)
    var tail = SIMD3<Float>(0.85, 0.85, 0.85)
    var beak = SIMD3<Float>(1.0, 0.78, 0.15)
    /// Wing span / chord multipliers and overall body size.
    var span: Float = 1
    var chord: Float = 1
    var size: Float = 1
    /// Self-illumination (0 = none) in the wing-tip color.
    var glow: Float = 0
}

private func nsColor(_ c: SIMD3<Float>) -> NSColor {
    NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
}

/// A low-poly bird whose wings are posed directly from the player's arms.
/// Local space: forward = -Z, up = +Y, right = +X.
final class BirdNode {
    let node = SCNNode()
    private let body = SCNNode()
    private var shoulder: [SCNNode] = []   // [left, right]
    private var elbow: [SCNNode] = []
    private let tail = SCNNode()
    private let head = SCNNode()

    // Smoothed display pose
    private var elev: [Float] = [0, 0]
    private var bend: [Float] = [0, 0]
    private var fold: Float = 0

    /// Current displayed wing elevations (left, right), used to drive the wingbeat sound.
    var wingElevations: (Float, Float) { (elev[0] * (1 - fold), elev[1] * (1 - fold)) }

    init(look: BirdLook = BirdLook()) {
        node.addChildNode(body)
        body.simdScale = SIMD3(repeating: 1.25 * look.size)
        let glow = look.glow > 0 ? nsColor(look.wingTip * look.glow) : nil

        let bodyMat = Self.material(nsColor(look.body), glow: glow.map { $0.withAlphaComponent(1) })
        let backMat = Self.material(nsColor(look.back))
        let headMat = Self.material(nsColor(look.head))
        let beakMat = Self.material(nsColor(look.beak))
        let black = Self.material(NSColor(white: 0.05, alpha: 1))

        // Body
        let torso = SCNNode(geometry: SCNSphere(radius: 0.17))
        torso.geometry?.materials = [bodyMat]
        torso.scale = SCNVector3(0.95, 0.8, 2.8)
        body.addChildNode(torso)
        let back = SCNNode(geometry: SCNSphere(radius: 0.14))
        back.geometry?.materials = [backMat]
        back.scale = SCNVector3(1.05, 0.55, 2.2)
        back.position = SCNVector3(0, 0.07, 0.02)
        body.addChildNode(back)

        // Head
        head.position = SCNVector3(0, 0.07, -0.47)
        let skull = SCNNode(geometry: SCNSphere(radius: 0.1))
        skull.geometry?.materials = [headMat]
        skull.scale = SCNVector3(0.95, 1, 1.15)
        head.addChildNode(skull)
        let beak = SCNNode(geometry: SCNCone(topRadius: 0.004, bottomRadius: 0.038, height: 0.2))
        beak.geometry?.materials = [beakMat]
        beak.eulerAngles.x = -.pi / 2
        beak.position = SCNVector3(0, -0.015, -0.17)
        head.addChildNode(beak)
        for s: CGFloat in [-1, 1] {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.018))
            eye.geometry?.materials = [black]
            eye.position = SCNVector3(s * 0.066, 0.03, -0.06)
            head.addChildNode(eye)
        }
        body.addChildNode(head)

        // Tail fan
        tail.position = SCNVector3(0, 0.03, 0.4)
        let tailGeo = Self.panel(outline: [(-0.07, 0), (0.07, 0), (0.16, 0.36), (0, 0.4), (-0.16, 0.36)], glow: glow) { _, _ in look.tail }
        tail.addChildNode(SCNNode(geometry: tailGeo))
        body.addChildNode(tail)

        // Wings: inner panel from the shoulder, outer panel (with colored tips) from the "wrist".
        let sp = look.span, ch = look.chord
        for side in 0..<2 {
            let s: Float = side == 0 ? -1 : 1
            let sh = SCNNode()
            sh.simdPosition = SIMD3(s * 0.11, 0.07, -0.1)
            let innerOutline: [(Float, Float)] = [(0, -0.13), (0.62, -0.1), (0.62, 0.2), (0.25, 0.3), (0, 0.24)]
            let inner = Self.panel(outline: innerOutline.map { (s * $0.0 * sp, $0.1 * ch) }, flip: side == 0, glow: glow) { x, _ in
                let t = abs(x) / (0.62 * sp)
                return simd_mix(look.wingRoot, look.wingMid, SIMD3(repeating: t))
            }
            sh.addChildNode(SCNNode(geometry: inner))
            let el = SCNNode()
            el.simdPosition = SIMD3(s * 0.6 * sp, 0, 0)
            let outerOutline: [(Float, Float)] = [(0, -0.1), (0.5, -0.06), (0.78, 0.04), (0.72, 0.12), (0.45, 0.2), (0, 0.2)]
            let outer = Self.panel(outline: outerOutline.map { (s * $0.0 * sp, $0.1 * ch) }, flip: side == 0, glow: glow) { x, _ in
                let t = abs(x) / (0.78 * sp)
                return simd_mix(look.wingMid, look.wingTip, SIMD3(repeating: smoothstep(0.45, 0.7, t)))
            }
            el.addChildNode(SCNNode(geometry: outer))
            sh.addChildNode(el)
            body.addChildNode(sh)
            shoulder.append(sh)
            elbow.append(el)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    private static func material(_ c: NSColor, glow: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        if let glow { m.emission.contents = glow; m.emission.intensity = 0.5 }
        m.roughness.contents = 0.75
        return m
    }

    /// Flat double-sided polygon in the XZ plane (convex outline, fan-triangulated from its centroid).
    private static func panel(outline: [(Float, Float)], flip: Bool = false, glow: NSColor? = nil, color: (Float, Float) -> SIMD3<Float>) -> SCNGeometry {
        var m = MeshBuilder()
        let cx = outline.map(\.0).reduce(0, +) / Float(outline.count)
        let cz = outline.map(\.1).reduce(0, +) / Float(outline.count)
        let n = SIMD3<Float>(0, 1, 0)
        m.vertex(SIMD3(cx, 0, cz), n, color(cx, cz))
        for (x, z) in outline { m.vertex(SIMD3(x, 0, z), n, color(x, z)) }
        let k = UInt32(outline.count)
        for i in 0..<k {
            let a = 1 + i, b = 1 + (i + 1) % k
            if flip { m.tri(0, a, b) } else { m.tri(0, b, a) }
        }
        let g = m.geometry()
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor.white
        mat.roughness.contents = 0.8
        mat.isDoubleSided = true
        if let glow { mat.emission.contents = glow }
        g.materials = [mat]
        return g
    }

    /// Pose the wings. `elevation`/`bend` in radians from the arm tracker, `fold` 0…1 (tucked dive),
    /// `pitchIn`/`rollIn` flex the tail like an elevator/rudder.
    func pose(left: WingPose, right: WingPose, fold targetFold: Float, pitchIn: Float, rollIn: Float, dt: Float) {
        let k = approach(28, dt)
        let tgtE = [left.elevation, right.elevation]
        let tgtB = [left.bend, right.bend]
        for i in 0..<2 {
            elev[i] += k * (clamp(tgtE[i], -1.2, 1.35) - elev[i])
            bend[i] += k * (clamp(tgtB[i], -1.2, 1.2) - bend[i])
        }
        fold += approach(10, dt) * (targetFold - fold)

        for i in 0..<2 {
            let s: Float = i == 0 ? -1 : 1
            // Elevation rotates about the body's forward axis; tucked wings sweep back along the body.
            let e = lerp(elev[i], -0.25, fold)
            let sweep = lerp(-0.08 - max(0, -elev[i]) * 0.15, -1.25, fold)
            let qElev = simd_quatf(angle: s * e, axis: SIMD3(0, 0, 1))
            let qSweep = simd_quatf(angle: s * sweep, axis: SIMD3(0, 1, 0))
            // Slight twist so the wing "bites" on the downstroke.
            let qTwist = simd_quatf(angle: 0.08, axis: SIMD3(1, 0, 0))
            shoulder[i].simdOrientation = qElev * qSweep * qTwist

            let b = lerp(bend[i] * 0.9, 0.1, fold)
            let outerSweep = lerp(-0.1 - abs(bend[i]) * 0.35, -2.5, fold)
            elbow[i].simdOrientation = simd_quatf(angle: s * b, axis: SIMD3(0, 0, 1)) *
                simd_quatf(angle: s * outerSweep, axis: SIMD3(0, 1, 0))
        }
        tail.simdOrientation = simd_quatf(angle: -pitchIn * 0.35, axis: SIMD3(1, 0, 0)) *
            simd_quatf(angle: rollIn * 0.25, axis: SIMD3(0, 0, 1))
        // Head stays level-ish, like a real bird's.
        head.simdOrientation = simd_quatf(angle: pitchIn * -0.15, axis: SIMD3(1, 0, 0))
    }
}
