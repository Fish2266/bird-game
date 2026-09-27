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
    /// Glow only the wing tips (painted glows) instead of the whole bird (a species glow).
    var tipGlow = false
    /// 0 = matte feathers, 1 = polished metal (paint jobs).
    var metal: Float = 0
    var pattern: BirdPattern? = nil

    // Shape (1 = the standard bird).
    var headScale: Float = 1
    var beakLength: Float = 1
    var beakWidth: Float = 1
    /// How far the beak curves down (radians): owls hook theirs.
    var beakDown: Float = 0
    var bodyLength: Float = 1
    var bodyWidth: Float = 1
    var tailLength: Float = 1
    /// Eyes that face forward (owls) instead of to the sides.
    var eyesForward = false
    /// Colored eyes with a black pupil (nil = plain black eyes).
    var iris: SIMD3<Float>? = nil
    var eyeSize: Float = 1
    /// A patch of color under the chin (a hummingbird's ruby throat).
    var throat: SIMD3<Float>? = nil

    /// Middle of the head in the bird's own space (before its size scale): where portraits aim and hats sit.
    var headCenter: SIMD3<Float> { SIMD3(0, 0.07 + (headScale - 1) * 0.03, -0.47 * bodyLength) }

    /// Where the neck is (just behind the head) and how wide the body is there.
    var neckFit: (z: Float, size: SIMD2<Float>) {
        let z = headCenter.z + 0.115 * headScale + 0.02
        let a = 0.17 * 0.95 * bodyWidth, b: Float = 0.17 * 0.8, c = 0.17 * 2.8 * bodyLength
        let f = sqrt(max(0.05, 1 - (z / c) * (z / c)))
        return (z, SIMD2(a * f, b * f))
    }
}

private func nsColor(_ c: SIMD3<Float>) -> NSColor {
    NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
}

/// A low-poly bird whose wings are posed directly from the player's arms, wearing an outfit.
/// Local space: forward = -Z, up = +Y, right = +X.
final class BirdNode {
    let node = SCNNode()
    private let body = SCNNode()
    private var shoulder: [SCNNode] = []   // [left, right]
    private var elbow: [SCNNode] = []
    private let tail = SCNNode()
    private let head = SCNNode()

    // Where cosmetics go.
    private let headAnchor = SCNNode()
    private let neckAnchor = SCNNode()
    private let tailTip = SCNNode()
    private(set) var wingTips: [SCNNode] = []
    let outfit: Outfit
    /// The look as drawn (after the paint job).
    let look: BirdLook
    /// World-space trail effects; whoever owns the bird adds this next to it in the scene.
    let fxRoot = SCNNode()
    private(set) var trail: TrailFX?
    private var animators: [CosmeticAnimator] = []
    private var cosmeticTime: Float = 0

    // Smoothed display pose
    private var elev: [Float] = [0, 0]
    private var bend: [Float] = [0, 0]
    private var fold: Float = 0

    /// Current displayed wing elevations (left, right), used to drive the wingbeat sound.
    var wingElevations: (Float, Float) { (elev[0] * (1 - fold), elev[1] * (1 - fold)) }

    /// `preview` fakes trails in the bird's own space (menu turntables) instead of leaving them in the world.
    init(look base: BirdLook = BirdLook(), outfit: Outfit = Outfit(), preview: Bool = false) {
        self.outfit = outfit
        let look = base.painted(outfit.paint)
        self.look = look
        node.addChildNode(body)
        body.simdScale = SIMD3(repeating: 1.25 * look.size)
        let glow = look.glow > 0 ? nsColor(look.wingTip * look.glow) : nil
        let pattern = BirdNode.patternTexture(look.pattern)

        let bodyMat = Self.material(nsColor(look.body), look: look, pattern: pattern, glow: look.tipGlow ? nil : glow.map { $0.withAlphaComponent(1) })
        let backMat = Self.material(nsColor(look.back), look: look, pattern: pattern)
        // Speckles stay off the face.
        let headMat = Self.material(nsColor(look.head), look: look, pattern: look.pattern == .speckle ? nil : pattern)
        let beakMat = Self.material(nsColor(look.beak), look: look, pattern: nil)
        let black = Self.material(NSColor(white: 0.05, alpha: 1), look: BirdLook(), pattern: nil)
        let L = look.bodyLength, W = look.bodyWidth

        // Body
        let torso = SCNNode(geometry: SCNSphere(radius: 0.17))
        torso.geometry?.materials = [bodyMat]
        torso.scale = SCNVector3(0.95 * W, 0.8, 2.8 * L)
        body.addChildNode(torso)
        let back = SCNNode(geometry: SCNSphere(radius: 0.14))
        back.geometry?.materials = [backMat]
        back.scale = SCNVector3(1.05 * W, 0.55, 2.2 * L)
        back.position = SCNVector3(0, 0.07, 0.02 * L)
        body.addChildNode(back)

        // Head (everything on it, hats and glasses included, scales with it)
        head.simdPosition = look.headCenter
        head.simdScale = SIMD3(repeating: look.headScale)
        let skull = SCNNode(geometry: SCNSphere(radius: 0.1))
        skull.geometry?.materials = [headMat]
        skull.scale = SCNVector3(0.95, 1, 1.15)
        head.addChildNode(skull)
        // The beak hinges at its base so it can hook downward.
        let beakBase = SCNNode()
        beakBase.simdPosition = SIMD3(0, -0.015, -0.07)
        beakBase.eulerAngles.x = CGFloat(-look.beakDown)
        let bl = 0.2 * look.beakLength
        let beak = SCNNode(geometry: SCNCone(topRadius: 0.004, bottomRadius: CGFloat(0.038 * look.beakWidth), height: CGFloat(bl)))
        beak.geometry?.materials = [beakMat]
        beak.eulerAngles.x = -.pi / 2
        beak.simdPosition = SIMD3(0, 0, -bl / 2)
        beakBase.addChildNode(beak)
        head.addChildNode(beakBase)
        let eyeR = 0.018 * look.eyeSize
        let irisMat = look.iris.map { Self.material(nsColor($0), look: BirdLook(), pattern: nil) }
        for s: Float in [-1, 1] {
            let at = look.eyesForward ? SIMD3<Float>(s * 0.042, 0.028, -0.093) : SIMD3<Float>(s * 0.066, 0.03, -0.06)
            let eye = SCNNode(geometry: SCNSphere(radius: CGFloat(eyeR)))
            eye.geometry?.materials = [irisMat ?? black]
            eye.simdPosition = at
            head.addChildNode(eye)
            if irisMat != nil {
                // A pupil on the front of the eye.
                let outward = simd_normalize(at * SIMD3(1, 0.6, 1))
                let pupil = SCNNode(geometry: SCNSphere(radius: CGFloat(eyeR * 0.58)))
                pupil.geometry?.materials = [black]
                pupil.simdPosition = at + outward * eyeR * 0.62
                head.addChildNode(pupil)
            }
        }
        if let throat = look.throat {
            var t = look
            t.metal = max(look.metal, 0.35)
            // Low on the front of the head, well under the beak: a throat patch rather than a lip.
            let patch = SCNNode(geometry: SCNSphere(radius: 0.075))
            patch.geometry?.materials = [Self.material(nsColor(throat), look: t, pattern: nil)]
            patch.scale = SCNVector3(0.88, 0.62, 1.0)
            patch.simdPosition = SIMD3(0, -0.07, -0.02)
            head.addChildNode(patch)
        }
        head.addChildNode(headAnchor)
        body.addChildNode(head)
        // Neckwear sits just behind the head and fits the body there, so big heads and stout bodies don't swallow it.
        let (neckZ, neckSize) = look.neckFit
        let (_, standard) = BirdLook().neckFit
        neckAnchor.simdPosition = SIMD3(0, 0, neckZ - BirdLook().neckFit.z)
        neckAnchor.simdScale = SIMD3(neckSize.x / standard.x, neckSize.y / standard.y, 1)
        body.addChildNode(neckAnchor)

        // Tail fan
        tail.position = SCNVector3(0, 0.03, 0.4 * CGFloat(L))
        let tl = look.tailLength
        let tailGeo = Self.panel(outline: [(-0.07, 0), (0.07, 0), (0.16, 0.36 * tl), (0, 0.4 * tl), (-0.16, 0.36 * tl)], look: look, pattern: pattern,
                                 glow: look.tipGlow ? nil : glow) { _, _ in look.tail }
        tail.addChildNode(SCNNode(geometry: tailGeo))
        tailTip.position = SCNVector3(0, 0, 0.36 * CGFloat(tl))
        tail.addChildNode(tailTip)
        body.addChildNode(tail)

        // Wings: inner panel from the shoulder, outer panel (with colored tips) from the "wrist".
        let sp = look.span, ch = look.chord
        for side in 0..<2 {
            let s: Float = side == 0 ? -1 : 1
            let sh = SCNNode()
            sh.simdPosition = SIMD3(s * 0.11 * W, 0.07, -0.1 * L)
            let innerOutline: [(Float, Float)] = [(0, -0.13), (0.62, -0.1), (0.62, 0.2), (0.25, 0.3), (0, 0.24)]
            let inner = Self.panel(outline: innerOutline.map { (s * $0.0 * sp, $0.1 * ch) }, flip: side == 0, look: look, pattern: pattern,
                                   glow: look.tipGlow ? nil : glow) { x, _ in
                let t = abs(x) / (0.62 * sp)
                return simd_mix(look.wingRoot, look.wingMid, SIMD3(repeating: t))
            }
            sh.addChildNode(SCNNode(geometry: inner))
            let el = SCNNode()
            el.simdPosition = SIMD3(s * 0.6 * sp, 0, 0)
            let outerOutline: [(Float, Float)] = [(0, -0.1), (0.5, -0.06), (0.78, 0.04), (0.72, 0.12), (0.45, 0.2), (0, 0.2)]
            let outer = Self.panel(outline: outerOutline.map { (s * $0.0 * sp, $0.1 * ch) }, flip: side == 0, look: look, pattern: pattern,
                                   glow: glow, glowFrom: look.tipGlow ? 0.45 * 0.78 * sp : nil, glowTo: 0.78 * sp) { x, _ in
                let t = abs(x) / (0.78 * sp)
                return simd_mix(look.wingMid, look.wingTip, SIMD3(repeating: smoothstep(0.45, 0.7, t)))
            }
            el.addChildNode(SCNNode(geometry: outer))
            let tip = SCNNode()
            tip.simdPosition = SIMD3(s * 0.74 * sp, 0, 0.05 * ch)
            el.addChildNode(tip)
            wingTips.append(tip)
            sh.addChildNode(el)
            body.addChildNode(sh)
            shoulder.append(sh)
            elbow.append(el)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
        wear(outfit, preview: preview)
    }

    private func wear(_ o: Outfit, preview: Bool) {
        if let id = o.hat, let n = CosmeticModels.hat(id, animators: &animators) { headAnchor.addChildNode(n) }
        if let id = o.eyes, let n = CosmeticModels.eyes(id, animators: &animators) {
            // Owls' big eyes face forward: the glasses sit a little further out so the eyes stay behind the lenses.
            if look.eyesForward { n.simdPosition += SIMD3(0, 0.004, -0.036) }
            headAnchor.addChildNode(n)
        }
        if let id = o.neck, let n = CosmeticModels.neck(id, animators: &animators) { neckAnchor.addChildNode(n) }
        for a in [headAnchor, neckAnchor] {
            a.enumerateHierarchy { n, _ in n.castsShadow = true }
        }
        if let id = o.trail, let t = TrailFX(kind: id, wingTips: wingTips, tail: tailTip, body: node, preview: preview) {
            trail = t
            if preview { node.addChildNode(t.root) } else { fxRoot.addChildNode(t.root) }
        }
        tick(dt: 0, speed: 0, camera: .zero, emitting: false)
    }

    /// Animate the outfit (spinning propellers, fluttering scarves) and the trail. Call once per frame.
    func tick(dt: Float, speed: Float, camera: SIMD3<Float>, emitting: Bool) {
        cosmeticTime += dt
        for a in animators { a(dt, speed, cosmeticTime) }
        trail?.update(dt: dt, speed: speed, camera: camera, emitting: emitting)
    }

    /// Start the trail afresh (after a teleport).
    func resetTrail() { trail?.reset() }

    private var outline: [SCNNode] = []

    /// "Show location" glow: a see-through-walls shell in `color` around every part of the bird
    /// (brightest at the silhouette edge). nil removes it.
    func setOutline(_ color: NSColor?) {
        outline.forEach { $0.removeFromParentNode() }
        outline.removeAll()
        guard let color else { return }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: """
        #pragma transparent
        #pragma body
        float rim = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));
        float a = 0.28 + 0.72 * rim * rim;
        _output.color = float4(_output.color.rgb * a, a);
        """]
        var parts: [SCNNode] = []
        // The bird itself, not its outfit (hats would just blur the silhouette).
        body.enumerateHierarchy { n, stop in
            if n.name == "cosmetic" { return }
            if n.geometry != nil && !BirdNode.isInsideCosmetic(n) { parts.append(n) }
        }
        for p in parts {
            guard let g = p.geometry?.copy() as? SCNGeometry else { continue }
            g.materials = [m]
            let shell = SCNNode(geometry: g)
            shell.simdScale = SIMD3(repeating: 1.18)
            shell.renderingOrder = 1000
            shell.castsShadow = false
            p.addChildNode(shell)
            outline.append(shell)
        }
    }

    private static func isInsideCosmetic(_ n: SCNNode) -> Bool {
        var p: SCNNode? = n
        while let c = p { if c.name == "cosmetic" { return true }; p = c.parent }
        return false
    }

    private static func material(_ c: NSColor, look: BirdLook, pattern: CGImage?, glow: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        if let glow { m.emission.contents = glow; m.emission.intensity = 0.5 }
        m.roughness.contents = look.metal > 0 ? 0.3 : 0.75
        m.metalness.contents = look.metal
        applyPattern(m, pattern, look: look, tint: c)
        return m
    }

    /// Patterned paints: stripes and camo multiply over the color; galaxy stars glow.
    private static func applyPattern(_ m: SCNMaterial, _ img: CGImage?, look: BirdLook, tint: NSColor?) {
        guard let img, let kind = look.pattern else { return }
        switch kind {
        case .galaxy:
            m.emission.contents = img
            m.emission.wrapS = .repeat; m.emission.wrapT = .repeat
            m.emission.intensity = 1.4
        default:
            if let tint { m.diffuse.contents = img; m.multiply.contents = tint } else { m.diffuse.contents = img }
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        }
    }

    private static func patternTexture(_ p: BirdPattern?) -> CGImage? {
        switch p {
        case .camo?:
            return Patterns.cached("birdcamo") {
                makeImage(width: 128, height: 128) { x, y in
                    let u = Float(x) / 128, v = Float(y) / 128
                    func blob(_ s: Float, _ o: Float) -> Float {
                        let n = sin(u * 2 * .pi * s + o) + sin(v * 2 * .pi * s * 1.3 + o * 1.7) + sin((u + v) * 2 * .pi * s * 0.7 + o * 2.3)
                        return n
                    }
                    let a = blob(2, 0.3), b = blob(3, 2.1)
                    let shade: Float = a > 0.9 ? 0.55 : (b > 0.6 ? 0.75 : (a < -1.1 ? 1.15 : 1.0))
                    return SIMD4(repeating: 1) * SIMD4(shade, shade, shade * 0.95, 1)
                }
            }
        case .tiger?:
            return Patterns.cached("birdtiger") {
                makeImage(width: 128, height: 128) { x, y in
                    let u = Float(x) / 128, v = Float(y) / 128
                    let wob = sin(v * 2 * .pi * 3) * 0.05 + sin(v * 2 * .pi * 7 + 1) * 0.02
                    let s = sin((u + wob) * 2 * .pi * 5)
                    let stripe = smoothstep(0.55, 0.75, s) * (0.7 + 0.3 * sin(v * 2 * .pi * 2 + u * 9))
                    let k = 1 - 0.88 * max(0, stripe)
                    return SIMD4(k, k, k, 1)
                }
            }
        case .speckle?:
            // Snowy owl: short dark bars scattered over white.
            return Patterns.cached("birdspeckle") {
                var rng = SplitMix64(seed: 77)
                let marks = (0..<46).map { _ in (rng.float(0, 1), rng.float(0, 1), rng.float(0.018, 0.034), rng.float(0.006, 0.011)) }
                return makeImage(width: 128, height: 128) { x, y in
                    let u = Float(x) / 128, v = Float(y) / 128
                    var k: Float = 1
                    for (mx, my, w, h) in marks {
                        var dx = abs(u - mx), dy = abs(v - my)
                        dx = min(dx, 1 - dx); dy = min(dy, 1 - dy)
                        let d = (dx * dx) / (w * w) + (dy * dy) / (h * h)
                        if d < 1 { k = min(k, 0.3 + 0.3 * d) }
                    }
                    return SIMD4(k, k * 0.97, k * 0.93, 1)
                }
            }
        case .galaxy?:
            return Patterns.cached("birdgalaxy") {
                var rng = SplitMix64(seed: 404)
                let stars = (0..<55).map { _ in (rng.float(0, 1), rng.float(0, 1), rng.float(0.004, 0.012), rng.float(0.5, 1)) }
                return makeImage(width: 256, height: 256) { x, y in
                    let u = Float(x) / 256, v = Float(y) / 256
                    var c = SIMD3<Float>(0.05, 0.03, 0.12) * (0.6 + 0.4 * sin(u * 9 + v * 5))
                    for (sx, sy, r, b) in stars {
                        var dx = u - sx, dy = v - sy
                        dx -= dx.rounded(); dy -= dy.rounded()
                        let d = simd_length(SIMD2(dx, dy))
                        c += SIMD3(0.9, 0.92, 1) * b * smoothstep(r, 0, d)
                    }
                    return SIMD4(c, 1)
                }
            }
        case nil:
            return nil
        }
    }

    /// Flat double-sided polygon in the XZ plane (convex outline, fan-triangulated from its centroid).
    /// `glowFrom`/`glowTo`: glow only from that distance out from the root to the tip (painted glowing tips).
    private static func panel(outline: [(Float, Float)], flip: Bool = false, look: BirdLook, pattern: CGImage?, glow: NSColor? = nil,
                              glowFrom: Float? = nil, glowTo: Float = 1,
                              color: (Float, Float) -> SIMD3<Float>) -> SCNGeometry {
        var m = MeshBuilder()
        let cx = outline.map(\.0).reduce(0, +) / Float(outline.count)
        let cz = outline.map(\.1).reduce(0, +) / Float(outline.count)
        let n = SIMD3<Float>(0, 1, 0)
        m.vertex(SIMD3(cx, 0, cz), n, color(cx, cz), uv: SIMD2(cx, cz) * 2.5)
        for (x, z) in outline { m.vertex(SIMD3(x, 0, z), n, color(x, z), uv: SIMD2(x, z) * 2.5) }
        let k = UInt32(outline.count)
        for i in 0..<k {
            let a = 1 + i, b = 1 + (i + 1) % k
            if flip { m.tri(0, a, b) } else { m.tri(0, b, a) }
        }
        let g = m.geometry()
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor.white
        mat.roughness.contents = look.metal > 0 ? 0.3 : 0.8
        mat.metalness.contents = look.metal
        mat.isDoubleSided = true
        if let glow {
            if let from = glowFrom {
                // Emission ramps up toward the tip. Panel UVs are (x, z) × 2.5, so map |x| from `from`…`glowTo` onto the ramp.
                mat.emission.contents = BirdNode.tipRamp(glow)
                mat.emission.wrapS = .clamp
                let scale = 1 / ((glowTo - from) * 2.5)
                var t = SCNMatrix4MakeTranslation(CGFloat(flip ? from * 2.5 : -from * 2.5), 0, 0)
                t = SCNMatrix4Mult(t, SCNMatrix4MakeScale(CGFloat(flip ? -scale : scale), 1, 1))
                mat.emission.contentsTransform = t
            } else {
                mat.emission.contents = glow
            }
        }
        applyPattern(mat, pattern, look: look, tint: nil)
        g.materials = [mat]
        return g
    }

    /// Black → `c` from left to right, for glowing wing tips.
    private static func tipRamp(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 4), flipped: false) { r in
            NSGradient(colors: [.black, .black, c, c], atLocations: [0, 0.05, 0.7, 1], colorSpace: .sRGB)?.draw(in: r, angle: 0)
            return true
        }
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
