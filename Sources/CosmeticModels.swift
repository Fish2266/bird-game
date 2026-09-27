import SceneKit
import simd

/// Something a cosmetic animates every frame (a spinning propeller, a fluttering scarf).
typealias CosmeticAnimator = (_ dt: Float, _ speed: Float, _ time: Float) -> Void

/// The 3D models for hats, glasses and neckwear. Hats and glasses are built in the bird's head space (head centre at the
/// origin, radius ~0.1, +Y up, forward = -Z; the eyes sit at (±0.066, 0.03, -0.06)). Neckwear is built in body space.
/// Because the head and body are scaled with the bird, every item fits every species.
enum CosmeticModels {
    private static func c(_ r: Float, _ g: Float, _ b: Float) -> NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    private static func tex(_ img: CGImage, rough: CGFloat = 0.7, scale: (CGFloat, CGFloat) = (1, 1)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = img
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(scale.0, scale.1, 1)
        m.roughness.contents = rough
        return m
    }
    private static let head = (x: Float(0.095), y: Float(0.1), z: Float(0.115))
    /// Head cross-section radius (x) at height y, for fitting bands and domes.
    private static func headRadius(atY y: Float) -> Float { head.x * sqrt(max(0, 1 - (y / head.y) * (y / head.y))) }
    private static let zStretch: Float = 1.2

    /// A rounded cap over the top of the head: as wide as the head (plus `grow`) at `baseY`, closing at `topY`.
    /// `fullness` > 2 gives a boxier, fuller crown (2 = a plain half-ellipse).
    private static func headDome(baseY: Float, topY: Float, grow: Float = 0.008, fullness: Float = 2.4, segments: Int = 28) -> SCNGeometry {
        let r0 = headRadius(atY: baseY) + grow, h = topY - baseY
        let n = 12
        let e = 2 / fullness
        let profile = (0...n).map { i -> SIMD2<Float> in
            let th = Float(i) / Float(n) * .pi / 2
            return SIMD2(r0 * pow(cos(th), e), baseY + h * pow(sin(th), e))
        }
        return Shapes.lathe(profile, segments: segments, stretchZ: zStretch)
    }

    // MARK: Hats

    static func hat(_ id: String, animators: inout [CosmeticAnimator]) -> SCNNode? {
        let n = SCNNode()
        switch id {
        case "party":
            let cone = SCNCone(topRadius: 0.003, bottomRadius: 0.062, height: 0.19)
            cone.radialSegmentCount = 24
            let m = tex(Patterns.stripes(SIMD3(0.97, 0.32, 0.62), SIMD3(1.0, 0.86, 0.24), count: 3), rough: 0.55, scale: (2, 1.5))
            cone.materials = [m]
            let body = SCNNode(geometry: cone)
            body.simdPosition = SIMD3(0, 0.095 + 0.095, 0)
            n.addChildNode(body)
            let trim = SCNNode(geometry: SCNTorus(ringRadius: 0.062, pipeRadius: 0.009))
            trim.geometry?.materials = [Shapes.mat(c(1, 1, 1), rough: 0.9)]
            trim.simdPosition = SIMD3(0, 0.097, 0)
            n.addChildNode(trim)
            n.addChildNode(Shapes.node(Shapes.ball(0.026, segments: 12), Shapes.mat(c(0.35, 0.85, 0.95), rough: 0.9), at: SIMD3(0, 0.29, 0)))
            n.simdPosition = SIMD3(0.012, -0.012, 0.012)
            n.simdOrientation = simd_quatf(angle: -0.22, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: 0.12, axis: SIMD3(1, 0, 0))

        case "beanie":
            n.addChildNode(Shapes.node(headDome(baseY: 0.045, topY: 0.158, grow: 0.01), tex(Patterns.knit(SIMD3(0.86, 0.20, 0.22)), rough: 0.95, scale: (3, 2))))
            let cuff = Shapes.lathe([SIMD2(headRadius(atY: 0.035) + 0.012, 0.028), SIMD2(headRadius(atY: 0.04) + 0.02, 0.04),
                                     SIMD2(headRadius(atY: 0.06) + 0.02, 0.068), SIMD2(headRadius(atY: 0.07) + 0.012, 0.078)],
                                    segments: 28, stretchZ: zStretch)
            n.addChildNode(Shapes.node(cuff, tex(Patterns.knit(SIMD3(0.96, 0.95, 0.92)), rough: 0.95, scale: (3, 1))))
            n.addChildNode(Shapes.node(Shapes.ball(0.034, segments: 12), Shapes.mat(c(0.97, 0.96, 0.93), rough: 1), at: SIMD3(0, 0.172, 0.004)))

        case "cap":
            let blue = c(0.16, 0.38, 0.82)
            n.addChildNode(Shapes.node(headDome(baseY: 0.04, topY: 0.14, grow: 0.008), Shapes.mat(blue, rough: 0.8)))
            n.addChildNode(Shapes.node(Shapes.ball(0.012, segments: 8), Shapes.mat(blue, rough: 0.8), at: SIMD3(0, 0.142, 0)))
            // Visor out the back (worn backwards).
            var visor = Shapes.circle(0.075, 28, rx: 0.07)
            visor = visor.filter { $0.y >= -0.001 }.map { SIMD2($0.x, $0.y) }
            visor.append(SIMD2(-0.07, 0))
            let v = Shapes.node(Shapes.extrude(visor.map { SIMD2($0.x, $0.y) }, depth: 0.008), Shapes.mat(c(0.10, 0.24, 0.62), rough: 0.7))
            v.simdOrientation = simd_quatf(angle: .pi / 2 - 0.22, axis: SIMD3(1, 0, 0))
            v.simdPosition = SIMD3(0, 0.056, 0.092)
            n.addChildNode(v)
            // A white front panel with a letter-ish badge.
            let badge = Shapes.node(Shapes.extrude(Shapes.circle(0.018, 16), depth: 0.004), Shapes.mat(c(0.98, 0.84, 0.2), rough: 0.6))
            badge.simdPosition = SIMD3(0, 0.1, -0.104)
            badge.simdOrientation = simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0))
            n.addChildNode(badge)

        case "propeller":
            let quad = Patterns.cached("propcap") {
                makeImage(width: 64, height: 16) { x, _ in
                    let cols: [SIMD3<Float>] = [SIMD3(0.92, 0.22, 0.20), SIMD3(0.99, 0.82, 0.18), SIMD3(0.20, 0.52, 0.92), SIMD3(0.28, 0.75, 0.32)]
                    return SIMD4(cols[(x / 8) % 4], 1)
                }
            }
            n.addChildNode(Shapes.node(headDome(baseY: 0.04, topY: 0.145, grow: 0.008), tex(quad, rough: 0.7)))
            var visor = Shapes.circle(0.06, 24, rx: 0.06).filter { $0.y >= -0.001 }
            visor.append(SIMD2(-0.06, 0))
            let v = Shapes.node(Shapes.extrude(visor, depth: 0.007), Shapes.mat(c(0.99, 0.82, 0.18), rough: 0.7))
            v.simdOrientation = simd_quatf(angle: -.pi / 2 - 0.2, axis: SIMD3(1, 0, 0))
            v.simdPosition = SIMD3(0, 0.045, -0.1)
            n.addChildNode(v)
            let stem = SCNNode(geometry: SCNCylinder(radius: 0.006, height: 0.04))
            stem.geometry?.materials = [Shapes.mat(c(0.9, 0.9, 0.92), rough: 0.3, metal: 0.8)]
            stem.simdPosition = SIMD3(0, 0.162, 0)
            n.addChildNode(stem)
            let prop = SCNNode()
            prop.simdPosition = SIMD3(0, 0.182, 0)
            for s: Float in [-1, 1] {
                let blade = Shapes.node(Shapes.extrude(Shapes.roundedRect(0.085, 0.026, 0.012), depth: 0.004), Shapes.mat(c(0.92, 0.22, 0.2), rough: 0.5))
                blade.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: s * 0.25, axis: SIMD3(1, 0, 0))
                blade.simdPosition = SIMD3(s * 0.045, 0, 0)
                prop.addChildNode(blade)
            }
            prop.addChildNode(Shapes.node(Shapes.ball(0.01, segments: 8), Shapes.mat(c(0.99, 0.82, 0.18), rough: 0.5)))
            n.addChildNode(prop)
            var angle: Float = 0
            animators.append { dt, speed, _ in
                angle += dt * (6 + min(speed, 60) * 0.9)
                prop.simdOrientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
            }

        case "chef":
            let white = Shapes.mat(c(0.97, 0.96, 0.94), rough: 0.9)
            let band = Shapes.lathe([SIMD2(headRadius(atY: 0.04) + 0.01, 0.036), SIMD2(0.094, 0.075), SIMD2(0.098, 0.11)], segments: 28, stretchZ: 1.1)
            n.addChildNode(Shapes.node(band, white))
            let puffs: [(SIMD3<Float>, Float)] = [(SIMD3(0, 0.17, 0), 0.07), (SIMD3(0.052, 0.145, 0.0), 0.052), (SIMD3(-0.052, 0.145, 0.0), 0.052),
                                                 (SIMD3(0, 0.145, 0.058), 0.052), (SIMD3(0, 0.145, -0.058), 0.052),
                                                 (SIMD3(0.04, 0.16, 0.04), 0.05), (SIMD3(-0.04, 0.16, -0.04), 0.05),
                                                 (SIMD3(0.04, 0.16, -0.04), 0.05), (SIMD3(-0.04, 0.16, 0.04), 0.05)]
            for (p, r) in puffs { n.addChildNode(Shapes.node(Shapes.ball(r, segments: 14), white, at: p)) }

        case "tophat":
            let black = Shapes.mat(c(0.07, 0.07, 0.08), rough: 0.45)
            let brim = Shapes.lathe([SIMD2(0.13, 0.083), SIMD2(0.125, 0.074), SIMD2(0.06, 0.072), SIMD2(0.06, 0.08)], segments: 32, crease: 0.5, stretchZ: 1.12)
            n.addChildNode(Shapes.node(brim, Shapes.mat(c(0.07, 0.07, 0.08), rough: 0.8, doubleSided: true)))
            let crown = Shapes.lathe([SIMD2(0.064, 0.074), SIMD2(0.068, 0.15), SIMD2(0.072, 0.232)], segments: 32, capTop: true)
            n.addChildNode(Shapes.node(crown, black))
            let band = Shapes.lathe([SIMD2(0.0665, 0.08), SIMD2(0.069, 0.108)], segments: 32)
            n.addChildNode(Shapes.node(band, Shapes.mat(c(0.72, 0.10, 0.14), rough: 0.35)))
            n.simdOrientation = simd_quatf(angle: -0.12, axis: SIMD3(1, 0, 0))
            n.simdPosition = SIMD3(0, 0.0, 0.01)

        case "sombrero":
            let straw = Shapes.mat(c(0.93, 0.78, 0.46), rough: 0.9, doubleSided: true)
            let brim = Shapes.lathe([SIMD2(0.235, 0.105), SIMD2(0.225, 0.088), SIMD2(0.19, 0.07), SIMD2(0.1, 0.072), SIMD2(0.07, 0.08)],
                                    segments: 40, crease: 1.2)
            n.addChildNode(Shapes.node(brim, straw))
            let rim = SCNNode(geometry: SCNTorus(ringRadius: 0.232, pipeRadius: 0.012))
            rim.geometry?.materials = [Shapes.mat(c(0.85, 0.20, 0.18), rough: 0.8)]
            rim.simdPosition = SIMD3(0, 0.104, 0)
            n.addChildNode(rim)
            let crown = Shapes.lathe([SIMD2(0.078, 0.075), SIMD2(0.075, 0.12), SIMD2(0.064, 0.19), SIMD2(0.04, 0.228), SIMD2(0, 0.238)], segments: 32)
            n.addChildNode(Shapes.node(crown, straw))
            let band = Shapes.lathe([SIMD2(0.0775, 0.082), SIMD2(0.0755, 0.118)], segments: 32)
            n.addChildNode(Shapes.node(band, tex(Patterns.zigzag([SIMD3(0.85, 0.18, 0.16), SIMD3(0.98, 0.96, 0.9), SIMD3(0.18, 0.62, 0.30)]), rough: 0.8, scale: (2, 1))))

        case "cowboy":
            let leather = c(0.60, 0.40, 0.22)
            n.addChildNode(Shapes.node(cowboyBrim(), Shapes.mat(leather, rough: 0.85, doubleSided: true)))
            let crown = Shapes.lathe([SIMD2(0.074, 0.074), SIMD2(0.073, 0.13), SIMD2(0.064, 0.172), SIMD2(0.035, 0.182), SIMD2(0, 0.17)],
                                     segments: 32, stretchZ: 1.22)
            n.addChildNode(Shapes.node(crown, Shapes.mat(leather.blended(withFraction: 0.08, of: .white)!, rough: 0.85)))
            let band = Shapes.lathe([SIMD2(0.0745, 0.08), SIMD2(0.0738, 0.098)], segments: 32, stretchZ: 1.22)
            n.addChildNode(Shapes.node(band, Shapes.mat(c(0.22, 0.14, 0.09), rough: 0.6)))
            n.simdOrientation = simd_quatf(angle: -0.06, axis: SIMD3(1, 0, 0))

        case "pirate":
            let black = Shapes.mat(c(0.08, 0.07, 0.07), rough: 0.7)
            // A bicorne worn side to side: a crescent standing on the head.
            var outline: [SIMD2<Float>] = []
            for i in 0...24 {
                let t = Float(i) / 24 * .pi
                outline.append(SIMD2(-cos(t) * 0.17, sin(t) * 0.125 + 0.015 * (1 - sin(t))))
            }
            for i in stride(from: 23, through: 1, by: -1) {
                let t = Float(i) / 24 * .pi
                outline.append(SIMD2(-cos(t) * 0.12, 0.02 + sin(t) * 0.02))
            }
            let shell = Shapes.node(Shapes.extrude(outline, depth: 0.075), black)
            shell.simdPosition = SIMD3(0, 0.06, 0.005)
            n.addChildNode(shell)
            let trimPath = (0...24).map { i -> SIMD3<Float> in
                let t = Float(i) / 24 * .pi
                return SIMD3(-cos(t) * 0.172, 0.06 + sin(t) * 0.127 + 0.015 * (1 - sin(t)), 0)
            }
            for z: Float in [-0.038, 0.038] {
                let trim = Shapes.node(Shapes.tube(trimPath.map { $0 + SIMD3(0, 0, z) }, radii: Array(repeating: 0.0055, count: 25), sides: 6),
                                       Shapes.mat(c(0.98, 0.78, 0.25), rough: 0.3, metal: 0.9))
                n.addChildNode(trim)
            }
            // Skull and crossbones on the front.
            let white = Shapes.mat(c(0.97, 0.96, 0.92), rough: 0.6)
            let skull = Shapes.node(Shapes.extrude(Shapes.circle(0.024, 20), depth: 0.006), white, at: SIMD3(0, 0.125, -0.041))
            n.addChildNode(skull)
            let jaw = Shapes.node(Shapes.extrude(Shapes.roundedRect(0.026, 0.016, 0.004), depth: 0.006), white, at: SIMD3(0, 0.1, -0.041))
            n.addChildNode(jaw)
            for s: Float in [-1, 1] {
                n.addChildNode(Shapes.node(Shapes.ball(0.0065, segments: 8), Shapes.mat(c(0.05, 0.05, 0.05)), at: SIMD3(s * 0.009, 0.126, -0.045)))
                let bone = Shapes.node(Shapes.extrude(Shapes.roundedRect(0.07, 0.009, 0.004), depth: 0.005), white, at: SIMD3(0, 0.1, -0.043))
                bone.simdOrientation = simd_quatf(angle: s * 0.6, axis: SIMD3(0, 0, 1))
                n.insertChildNode(bone, at: 0)
            }

        case "wizard":
            let starry = tex(Patterns.starry(SIMD3(0.24, 0.20, 0.62), SIMD3(1.0, 0.86, 0.3)), rough: 0.8, scale: (3, 3))
            let brim = Shapes.lathe([SIMD2(0.15, 0.078), SIMD2(0.145, 0.07), SIMD2(0.07, 0.072), SIMD2(0.07, 0.08)], segments: 36, crease: 0.5, stretchZ: 1.1)
            let brimNode = Shapes.node(brim, starry)
            brimNode.geometry?.firstMaterial?.isDoubleSided = true
            n.addChildNode(brimNode)
            let path = Shapes.curve(SIMD3(0, 0.074, 0), SIMD3(0, 0.3, 0.01), SIMD3(0.02, 0.36, 0.1), 12)
            let radii = (0...12).map { i -> Float in 0.074 * pow(1 - Float(i) / 12, 1.1) + 0.002 }
            n.addChildNode(Shapes.node(Shapes.tube(path, radii: radii, sides: 20), starry))
            let band = Shapes.lathe([SIMD2(0.074, 0.08), SIMD2(0.07, 0.098)], segments: 32)
            n.addChildNode(Shapes.node(band, Shapes.mat(c(0.98, 0.80, 0.25), rough: 0.35, metal: 0.7)))
            n.addChildNode(Shapes.node(Shapes.extrude(Shapes.star(0.028, 0.012), depth: 0.006), Shapes.mat(c(1.0, 0.86, 0.3), rough: 0.3, metal: 0.6),
                                       at: SIMD3(0, 0.15, -0.066)).then { $0.simdOrientation = simd_quatf(angle: 0.25, axis: SIMD3(1, 0, 0)) })

        case "unicorn":
            let spiral = tex(Patterns.stripes(SIMD3(0.99, 0.96, 0.93), SIMD3(0.98, 0.78, 0.86), count: 3), rough: 0.35, scale: (1, 3))
            spiral.emission.contents = NSColor(white: 0.12, alpha: 1)
            let horn = SCNCone(topRadius: 0.001, bottomRadius: 0.03, height: 0.2)
            horn.radialSegmentCount = 20
            horn.materials = [spiral]
            let h = SCNNode(geometry: horn)
            h.simdPosition = SIMD3(0, 0.1, 0)
            let holder = SCNNode()
            holder.addChildNode(h)
            holder.simdPosition = SIMD3(0, 0.075, -0.045)
            holder.simdOrientation = simd_quatf(angle: -0.42, axis: SIMD3(1, 0, 0))
            n.addChildNode(holder)
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.03, pipeRadius: 0.006))
            ring.geometry?.materials = [Shapes.mat(c(0.98, 0.80, 0.30), rough: 0.3, metal: 0.9)]
            ring.simdPosition = SIMD3(0, 0.006, 0)
            holder.addChildNode(ring)
            // Two little flowers at the base.
            for s: Float in [-1, 1] {
                let f = flower(0.02, c(0.99, 0.62, 0.82), c(1, 0.9, 0.35))
                f.simdPosition = SIMD3(s * 0.045, 0.085, -0.035)
                f.simdOrientation = simd_quatf(angle: -0.9, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: s * 0.4, axis: SIMD3(0, 0, 1))
                n.addChildNode(f)
            }

        case "crown":
            let gold = Shapes.mat(c(1.0, 0.78, 0.30), rough: 0.22, metal: 1.0, doubleSided: true)
            let band = Shapes.lathe([SIMD2(0.078, 0.062), SIMD2(0.081, 0.068), SIMD2(0.081, 0.105), SIMD2(0.078, 0.11)], segments: 36, stretchZ: 1.12)
            n.addChildNode(Shapes.node(band, gold))
            n.addChildNode(Shapes.node(headDome(baseY: 0.064, topY: 0.13, grow: 0.004), Shapes.mat(c(0.62, 0.08, 0.14), rough: 0.9)))
            let points = 8
            for k in 0..<points {
                let a = Float(k) / Float(points) * 2 * .pi
                let p = SIMD3(cos(a) * 0.079, 0.108, sin(a) * 0.079 * 1.12)
                let spike = SCNPyramid(width: 0.03, height: 0.045, length: 0.012)
                let sn = Shapes.node(spike, gold, at: p)
                sn.simdOrientation = simd_quatf(angle: -a + .pi / 2, axis: SIMD3(0, 1, 0))
                n.addChildNode(sn)
                n.addChildNode(Shapes.node(Shapes.ball(0.0075, segments: 8), gold, at: p + SIMD3(0, 0.047, 0)))
            }
            let gems = [c(0.85, 0.08, 0.15), c(0.10, 0.35, 0.95), c(0.10, 0.75, 0.35), c(0.85, 0.08, 0.15)]
            for (k, g) in gems.enumerated() {
                let a = Float(k) / 4 * 2 * .pi + .pi / 4
                let m = Shapes.mat(g, rough: 0.1, metal: 0.3, glow: g.blended(withFraction: 0.75, of: .black))
                n.addChildNode(Shapes.node(Shapes.ball(0.011, segments: 8), m, at: SIMD3(cos(a) * 0.084, 0.086, sin(a) * 0.084 * 1.12)))
            }

        case "grad":
            let black = Shapes.mat(c(0.08, 0.08, 0.10), rough: 0.6)
            n.addChildNode(Shapes.node(headDome(baseY: 0.045, topY: 0.128, grow: 0.008), black))
            let board = Shapes.node(SCNBox(width: 0.21, height: 0.012, length: 0.21, chamferRadius: 0.002), black, at: SIMD3(0, 0.132, 0))
            board.simdOrientation = simd_quatf(angle: .pi / 4, axis: SIMD3(0, 1, 0))
            n.addChildNode(board)
            let gold = Shapes.mat(c(0.99, 0.80, 0.26), rough: 0.5)
            n.addChildNode(Shapes.node(SCNCylinder(radius: 0.012, height: 0.008), gold, at: SIMD3(0, 0.141, 0)))
            let cord = Shapes.tube([SIMD3(0, 0.142, 0), SIMD3(0.07, 0.141, 0.0), SIMD3(0.105, 0.139, 0.0), SIMD3(0.108, 0.11, 0.0), SIMD3(0.108, 0.075, 0.0)],
                                   radii: [0.003, 0.003, 0.003, 0.003, 0.003], sides: 6)
            n.addChildNode(Shapes.node(cord, gold))
            let tassel = Shapes.lathe([SIMD2(0.004, 0.08), SIMD2(0.012, 0.06), SIMD2(0.014, 0.035), SIMD2(0.0, 0.03)], segments: 12)
            n.addChildNode(Shapes.node(tassel, gold, at: SIMD3(0.108, -0.005, 0)))

        case "explorer":
            let khaki = Shapes.mat(c(0.88, 0.76, 0.50), rough: 0.9, doubleSided: true)
            let helmet = Shapes.lathe([SIMD2(0.135, 0.045), SIMD2(0.128, 0.052), SIMD2(0.104, 0.064), SIMD2(0.097, 0.085), SIMD2(0.088, 0.115),
                                       SIMD2(0.066, 0.145), SIMD2(0.036, 0.162), SIMD2(0, 0.167)], segments: 32, crease: 0.7, stretchZ: 1.28)
            n.addChildNode(Shapes.node(helmet, khaki))
            let band = Shapes.lathe([SIMD2(0.1, 0.068), SIMD2(0.097, 0.086)], segments: 32, stretchZ: 1.28)
            n.addChildNode(Shapes.node(band, Shapes.mat(c(0.46, 0.36, 0.22), rough: 0.8)))
            n.addChildNode(Shapes.node(Shapes.ball(0.012, segments: 8), khaki, at: SIMD3(0, 0.167, 0)))

        case "viking":
            let steel = Shapes.mat(c(0.72, 0.74, 0.78), rough: 0.32, metal: 0.85)
            n.addChildNode(Shapes.node(headDome(baseY: 0.035, topY: 0.155, grow: 0.01), steel))
            let band = Shapes.lathe([SIMD2(headRadius(atY: 0.035) + 0.018, 0.03), SIMD2(headRadius(atY: 0.05) + 0.018, 0.06)], segments: 32, stretchZ: zStretch)
            let bronze = Shapes.mat(c(0.80, 0.55, 0.26), rough: 0.35, metal: 0.9)
            n.addChildNode(Shapes.node(band, bronze))
            let ridge = Shapes.tube((0...10).map { i -> SIMD3<Float> in
                let t = Float(i) / 10 * .pi
                return SIMD3(0, 0.045 + sin(t) * 0.113, -cos(t) * 0.122)
            }, radii: Array(repeating: 0.008, count: 11), sides: 6)
            n.addChildNode(Shapes.node(ridge, bronze))
            for k in 0..<10 {
                let a = Float(k) / 10 * 2 * .pi
                let r = headRadius(atY: 0.045) + 0.021
                n.addChildNode(Shapes.node(Shapes.ball(0.006, segments: 6), bronze, at: SIMD3(cos(a) * r, 0.045, sin(a) * r * zStretch)))
            }
            let ivory = Shapes.mat(c(0.96, 0.92, 0.80), rough: 0.5)
            for s: Float in [-1, 1] {
                let path = Shapes.curve(SIMD3(s * 0.088, 0.085, 0.005), SIMD3(s * 0.19, 0.095, 0.0), SIMD3(s * 0.2, 0.215, -0.03), 12)
                let radii = (0...12).map { i -> Float in 0.024 * (1 - Float(i) / 12) + 0.001 }
                n.addChildNode(Shapes.node(Shapes.tube(path, radii: radii, sides: 12), ivory))
            }

        case "halo":
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.09, pipeRadius: 0.013))
            (ring.geometry as? SCNTorus)?.ringSegmentCount = 40
            ring.geometry?.materials = [Shapes.glow(c(1.0, 0.86, 0.45), 2.4)]
            let holder = SCNNode()
            holder.addChildNode(ring)
            holder.simdPosition = SIMD3(0, 0.2, 0.01)
            holder.simdOrientation = simd_quatf(angle: -0.18, axis: SIMD3(1, 0, 0))
            n.addChildNode(holder)
            animators.append { _, _, t in holder.simdPosition = SIMD3(0, 0.2 + 0.01 * sin(t * 2.2), 0.01) }

        default:
            return nil
        }
        n.name = "cosmetic"
        return n
    }

    /// Wide brim with the sides curled up (cowboy hat).
    private static func cowboyBrim() -> SCNGeometry {
        var m = MeshBuilder()
        let seg = 40, rings = 6
        let r0: Float = 0.07, r1: Float = 0.17
        let white = SIMD3<Float>(1, 1, 1)
        func pos(_ a: Float, _ t: Float) -> SIMD3<Float> {
            let r = r0 + (r1 - r0) * t
            let side = pow(abs(cos(a)), 1.5)            // 1 at the sides (x), 0 front/back
            let y = 0.074 + pow(t, 2) * (0.07 * side - 0.012 * (1 - side))
            return SIMD3(cos(a) * r, y, sin(a) * r * 1.25)
        }
        for j in 0...rings {
            for k in 0...seg {
                let a = Float(k) / Float(seg) * 2 * .pi, t = Float(j) / Float(rings)
                let p = pos(a, t)
                let e: Float = 0.01
                let du = pos(a + e, t) - p, dv = pos(a, min(t + e, 1)) - pos(a, max(t - e, 0))
                var nrm = simd_normalize(simd_cross(du, dv))
                if nrm.y < 0 { nrm = -nrm }
                m.vertex(p, nrm, white)
            }
        }
        let row = UInt32(seg + 1)
        for j in 0..<UInt32(rings) {
            for k in 0..<UInt32(seg) {
                let a = j * row + k, b = a + 1, c = a + row, d = c + 1
                m.tri(a, c, b); m.tri(b, c, d)
            }
        }
        return m.geometry()
    }

    /// A small five-petal flower facing +Y.
    static func flower(_ size: Float, _ petal: NSColor, _ middle: NSColor) -> SCNNode {
        let n = SCNNode()
        var outline: [SIMD2<Float>] = []
        for i in 0..<40 {
            let a = Float(i) / 40 * 2 * .pi
            let r = size * (0.62 + 0.38 * abs(cos(a * 2.5)))
            outline.append(SIMD2(cos(a) * r, sin(a) * r))
        }
        let p = Shapes.node(Shapes.extrude(outline, depth: size * 0.25), Shapes.mat(petal, rough: 0.8))
        p.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        n.addChildNode(p)
        n.addChildNode(Shapes.node(Shapes.ball(size * 0.32, segments: 8), Shapes.mat(middle, rough: 0.7), at: SIMD3(0, size * 0.14, 0)))
        return n
    }

    // MARK: Glasses

    /// Lens centres (head space) and how far each lens is turned outward.
    private static let lensY: Float = 0.036
    private static let lensX: Float = 0.052
    private static let lensZ: Float = -0.094
    private static let lensTurn: Float = 0.62

    /// Places a flat lens-shaped part (built in XY, facing +Z) over each eye.
    private static func pair(_ build: () -> SCNNode, into n: SCNNode, scale: Float = 1) {
        for s: Float in [-1, 1] {
            let part = build()
            // Face forward (-Z) and turn outward toward each eye.
            part.simdOrientation = simd_quatf(angle: -s * lensTurn, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            part.simdPosition = SIMD3(s * lensX, lensY, lensZ)
            part.simdScale = SIMD3(repeating: scale)
            n.addChildNode(part)
        }
    }

    /// Frame arms from the outer edge of each lens back along the head.
    private static func temples(_ m: SCNMaterial, into n: SCNNode, radius: Float = 0.0045, from width: Float = 0.032) -> Void {
        for s: Float in [-1, 1] {
            let outer = SIMD3(s * (lensX + cos(lensTurn) * width), lensY + 0.006, lensZ + sin(lensTurn) * width)
            let path = [outer, SIMD3(s * 0.1, lensY + 0.008, -0.04), SIMD3(s * 0.103, lensY + 0.006, 0.0), SIMD3(s * 0.095, lensY + 0.0, 0.04)]
            n.addChildNode(Shapes.node(Shapes.tube(path, radii: Array(repeating: radius, count: path.count), sides: 6), m))
        }
    }

    private static func bridge(_ m: SCNMaterial, into n: SCNNode, radius: Float = 0.005, lift: Float = 0.012, halfGap: Float = 0.026, y: Float = 0) {
        let a = SIMD3(-lensX + cos(lensTurn) * halfGap, lensY + y, lensZ - sin(lensTurn) * halfGap)
        let b = SIMD3(lensX - cos(lensTurn) * halfGap, lensY + y, lensZ - sin(lensTurn) * halfGap)
        let mid = SIMD3(0, lensY + y + lift, lensZ - 0.02)
        n.addChildNode(Shapes.node(Shapes.tube(Shapes.curve(a, mid, b, 8), radii: Array(repeating: radius, count: 9), sides: 6), m))
    }

    static func eyes(_ id: String, animators: inout [CosmeticAnimator]) -> SCNNode? {
        let n = SCNNode()
        switch id {
        case "shades":
            let lensShape = trapezoidLens(0.066, 0.046)
            let black = Shapes.mat(c(0.05, 0.05, 0.06), rough: 0.35)
            let lensM = Shapes.mat(c(0.06, 0.07, 0.09), rough: 0.08, metal: 0.6)
            pair({ lensWithFrame(lensShape, frameWidth: 0.0065, lens: lensM, frame: black) }, into: n)
            bridge(black, into: n, radius: 0.005, lift: 0.004)
            temples(black, into: n, from: 0.034)

        case "nerd":
            let black = Shapes.mat(c(0.06, 0.05, 0.05), rough: 0.4)
            let glass = Shapes.glass(c(0.75, 0.9, 1.0), opacity: 0.28)
            pair({ lensWithFrame(Shapes.circle(0.028, 28), frameWidth: 0.009, lens: glass, frame: black, depth: 0.011) }, into: n)
            bridge(black, into: n, radius: 0.0065, lift: 0.006, halfGap: 0.036)
            temples(black, into: n, radius: 0.005, from: 0.036)
            let tape = Shapes.node(SCNBox(width: 0.018, height: 0.016, length: 0.016, chamferRadius: 0.003), Shapes.mat(c(0.97, 0.97, 0.95), rough: 0.9),
                                   at: SIMD3(0, lensY + 0.007, lensZ - 0.021))
            n.addChildNode(tape)

        case "threed":
            let card = Shapes.mat(c(0.97, 0.97, 0.96), rough: 0.9)
            let shape = Shapes.roundedRect(0.062, 0.042, 0.006)
            for (s, col) in [(Float(-1), c(1.0, 0.16, 0.18)), (Float(1), c(0.1, 0.8, 1.0))] {
                let part = lensWithFrame(shape, frameWidth: 0.008, lens: Shapes.glass(col, opacity: 0.72, rough: 0.2, metal: 0), frame: card, depth: 0.006)
                part.simdOrientation = simd_quatf(angle: -s * lensTurn, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
                part.simdPosition = SIMD3(s * lensX, lensY, lensZ)
                n.addChildNode(part)
            }
            bridge(card, into: n, radius: 0.006, lift: 0.004, halfGap: 0.034)
            temples(card, into: n, radius: 0.005, from: 0.036)

        case "heartglasses":
            let frame = Shapes.mat(c(0.92, 0.16, 0.42), rough: 0.35)
            let lens = Shapes.glass(c(1.0, 0.45, 0.7), opacity: 0.72, rough: 0.12, metal: 0.2)
            pair({ lensWithFrame(Shapes.heart(0.07), frameWidth: 0.006, lens: lens, frame: frame) }, into: n)
            bridge(frame, into: n, radius: 0.005, lift: 0.006, halfGap: 0.03)
            temples(frame, into: n, from: 0.034)

        case "starshades":
            let frame = Shapes.mat(c(1.0, 0.80, 0.18), rough: 0.3, metal: 0.4)
            let lens = Shapes.mat(c(0.08, 0.06, 0.12), rough: 0.1, metal: 0.6)
            pair({ lensWithFrame(Shapes.star(0.044, 0.022), frameWidth: 0.006, lens: lens, frame: frame) }, into: n)
            bridge(frame, into: n, radius: 0.005, lift: 0.006, halfGap: 0.03)
            temples(frame, into: n, from: 0.036)

        case "aviators":
            let gold = Shapes.mat(c(0.98, 0.78, 0.35), rough: 0.25, metal: 1.0)
            let grad = Patterns.cached("aviatorlens") {
                makeImage(width: 8, height: 64) { _, y in
                    let v = Float(y) / 63
                    return SIMD4(simd_mix(SIMD3<Float>(0.36, 0.22, 0.12), SIMD3(0.75, 0.55, 0.35), SIMD3(repeating: v)), 0.95 - 0.55 * v)
                }
            }
            let lens = Shapes.glass(.white, opacity: 1, rough: 0.05, metal: 0.4)
            lens.diffuse.contents = grad
            pair({ lensWithFrame(Shapes.teardrop(0.068, 0.054, inward: 1), frameWidth: 0.0035, lens: lens, frame: gold) }, into: n)
            bridge(gold, into: n, radius: 0.003, lift: 0.004, halfGap: 0.032, y: 0.012)
            bridge(gold, into: n, radius: 0.003, lift: -0.002, halfGap: 0.03, y: 0.0)
            temples(gold, into: n, radius: 0.003, from: 0.036)

        case "goggles":
            let black = Shapes.mat(c(0.08, 0.08, 0.09), rough: 0.6)
            let lens = Shapes.mat(c(1.0, 0.52, 0.1), rough: 0.18, metal: 0.45, glow: c(0.5, 0.22, 0.03))
            n.addChildNode(Shapes.node(wrapBand(from: -1.05, to: 1.05, y0: 0.008, y1: 0.068, grow: 0.022), lens))
            // Frame: top and bottom rims plus the ends.
            for y: Float in [0.006, 0.07] {
                n.addChildNode(Shapes.node(Shapes.tube(wrapPath(from: -1.1, to: 1.1, y: y, grow: 0.024), radii: Array(repeating: 0.007, count: 21), sides: 6), black))
            }
            // Strap all the way round.
            let strap = Patterns.cached("gogglestrap") {
                makeImage(width: 8, height: 16) { _, y in SIMD4(y > 5 && y < 10 ? SIMD3(0.2, 0.75, 0.95) : SIMD3(0.1, 0.1, 0.12), 1) }
            }
            let band = Shapes.lathe([SIMD2(headRadius(atY: 0.02) + 0.012, 0.018), SIMD2(headRadius(atY: 0.058) + 0.012, 0.058)], segments: 32, stretchZ: zStretch)
            n.addChildNode(Shapes.node(band, tex(strap, rough: 0.8)))

        case "monocle":
            let gold = Shapes.mat(c(0.98, 0.78, 0.35), rough: 0.25, metal: 1.0)
            let holder = SCNNode()
            holder.addChildNode(Shapes.node(Shapes.frame(outer: Shapes.circle(0.031, 32), inner: Shapes.circle(0.025, 32), depth: 0.006), gold))
            let glass = Shapes.node(Shapes.extrude(Shapes.circle(0.0255, 32), depth: 0.002), Shapes.glass(c(0.85, 0.95, 1.0), opacity: 0.3))
            holder.addChildNode(glass)
            holder.simdOrientation = simd_quatf(angle: -lensTurn, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            holder.simdPosition = SIMD3(lensX + 0.004, lensY, lensZ + 0.004)
            n.addChildNode(holder)
            let start = SIMD3(lensX + 0.012, lensY - 0.03, lensZ + 0.01)
            let chain = Shapes.curve(start, SIMD3(0.085, -0.09, -0.02), SIMD3(0.03, -0.1, 0.02), 14)
            n.addChildNode(Shapes.node(Shapes.tube(chain, radii: Array(repeating: 0.0022, count: 15), sides: 5), gold))

        case "pixel":
            let black = Shapes.mat(c(0.03, 0.03, 0.04), rough: 0.4)
            let white = Shapes.mat(c(1, 1, 1), rough: 0.4)
            // Classic 8-bit shades: a bar with two stepped lenses and a couple of white glints.
            let px: Float = 0.0105
            let rows = ["XXXXXXXXXXXXXXXXX",
                        "XWWXXXX...XWWXXXX",
                        "XWXXXXX...XWXXXXX",
                        ".XXXXX.....XXXXX.",
                        "..XXX.......XXX.."]
            let holder = SCNNode()
            var darkCells: [SIMD3<Float>] = [], lightCells: [SIMD3<Float>] = []
            for (r, line) in rows.enumerated() {
                for (k, ch) in line.enumerated() where ch != "." {
                    let p = SIMD3((Float(k) - Float(line.count - 1) / 2) * px, -Float(r) * px, 0)
                    if ch == "W" { lightCells.append(p) } else { darkCells.append(p) }
                }
            }
            holder.addChildNode(Shapes.node(Shapes.voxels(darkCells, size: SIMD3(px, px, 0.01)), black))
            holder.addChildNode(Shapes.node(Shapes.voxels(lightCells, size: SIMD3(px, px, 0.012)), white))
            holder.simdPosition = SIMD3(0, lensY + 0.02, lensZ - 0.012)
            n.addChildNode(holder)
            for s: Float in [-1, 1] {
                let path = [SIMD3(s * 0.088, lensY + 0.02, lensZ - 0.01), SIMD3(s * 0.1, lensY + 0.018, -0.04), SIMD3(s * 0.102, lensY + 0.012, 0.02)]
                n.addChildNode(Shapes.node(Shapes.tube(path, radii: [0.005, 0.005, 0.005], sides: 4), black))
            }

        case "visor":
            let glowM = Shapes.glow(c(0.25, 0.95, 1.0), 2.4)
            n.addChildNode(Shapes.node(wrapBand(from: -1.35, to: 1.35, y0: 0.022, y1: 0.05, grow: 0.018), glowM))
            let dark = Shapes.mat(c(0.12, 0.13, 0.16), rough: 0.3, metal: 0.8)
            for y: Float in [0.018, 0.054] {
                n.addChildNode(Shapes.node(Shapes.tube(wrapPath(from: -1.4, to: 1.4, y: y, grow: 0.019), radii: Array(repeating: 0.0045, count: 21), sides: 6), dark))
            }
            let band = Shapes.lathe([SIMD2(headRadius(atY: 0.022) + 0.012, 0.022), SIMD2(headRadius(atY: 0.05) + 0.012, 0.05)], segments: 32, stretchZ: zStretch)
            n.addChildNode(Shapes.node(band, dark))
            let m = glowM
            animators.append { _, _, t in m.diffuse.intensity = CGFloat(2.1 + 0.5 * sin(t * 3)) }

        default:
            return nil
        }
        n.name = "cosmetic"
        return n
    }

    /// Sunglasses lens: a little wider at the top.
    private static func trapezoidLens(_ w: Float, _ h: Float) -> [SIMD2<Float>] {
        Shapes.roundedRect(w, h, 0.013).map { p in SIMD2(p.x * (1 + 0.12 * (p.y / (h / 2))), p.y) }
    }

    /// A lens shape with a frame around it (built in XY facing +Z).
    private static func lensWithFrame(_ shape: [SIMD2<Float>], frameWidth: Float, lens: SCNMaterial, frame: SCNMaterial, depth: Float = 0.008) -> SCNNode {
        let n = SCNNode()
        n.addChildNode(Shapes.node(Shapes.extrude(shape, depth: 0.002), lens))
        n.addChildNode(Shapes.node(Shapes.frame(outer: Shapes.offset(shape, by: frameWidth), inner: shape, depth: depth), frame))
        return n
    }

    /// Points around the front of the head at height y (angle 0 = straight ahead), just outside the surface.
    private static func wrapPath(from a0: Float, to a1: Float, y: Float, grow: Float, count: Int = 20) -> [SIMD3<Float>] {
        (0...count).map { i in
            let a = a0 + (a1 - a0) * Float(i) / Float(count)
            let r = headRadius(atY: y) + grow
            return SIMD3(sin(a) * r, y, -cos(a) * r * zStretch)
        }
    }

    /// A curved strip hugging the front of the head (goggle lens, visor).
    private static func wrapBand(from a0: Float, to a1: Float, y0: Float, y1: Float, grow: Float) -> SCNGeometry {
        var m = MeshBuilder()
        let n = 24
        let white = SIMD3<Float>(1, 1, 1)
        for i in 0...n {
            let a = a0 + (a1 - a0) * Float(i) / Float(n)
            for y in [y0, y1] {
                let r = headRadius(atY: y) + grow
                let p = SIMD3(sin(a) * r, y, -cos(a) * r * zStretch)
                let nrm = simd_normalize(SIMD3(sin(a), 0.1, -cos(a)))
                m.vertex(p, nrm, white, uv: SIMD2(Float(i) / Float(n), y == y0 ? 0 : 1))
            }
        }
        for i in 0..<UInt32(n) {
            let a = i * 2, b = a + 1, c = a + 2, d = a + 3
            m.tri(a, c, b); m.tri(b, c, d)
        }
        let g = m.geometry()
        return g
    }

    // MARK: Neck (body space)

    /// The neck ring: just behind the head, where it meets the front of the body (the head itself reaches back to z ≈ -0.355).
    static let neckCenter = SIMD3<Float>(0, 0.01, -0.335)
    static let neckRadius = SIMD2<Float>(0.122, 0.1)

    /// An elliptical collar around the neck; the throat side leans forward a little.
    private static func collarPath(grow: Float = 0, count: Int = 32) -> [SIMD3<Float>] {
        (0...count).map { i in
            let a = Float(i) / Float(count) * 2 * .pi
            let y = neckCenter.y + sin(a) * (neckRadius.y + grow)
            return SIMD3(cos(a) * (neckRadius.x + grow), y, neckCenter.z + (y - neckCenter.y) * 0.18)
        }
    }

    static func neck(_ id: String, animators: inout [CosmeticAnimator]) -> SCNNode? {
        let n = SCNNode()
        switch id {
        case "bowtie":
            let dots = tex(Patterns.dots(SIMD3(0.82, 0.10, 0.14), SIMD3(0.98, 0.96, 0.94), count: 5), rough: 0.6, scale: (0.8, 0.8))
            let holder = SCNNode()
            for s: Float in [-1, 1] {
                let wing: [SIMD2<Float>] = [SIMD2(0.01, 0.016), SIMD2(0.085, 0.046), SIMD2(0.096, 0.0), SIMD2(0.085, -0.046), SIMD2(0.01, -0.016)]
                holder.addChildNode(Shapes.node(Shapes.extrude(wing.map { SIMD2($0.x * s, $0.y) }, depth: 0.026), dots))
            }
            holder.addChildNode(Shapes.node(SCNBox(width: 0.032, height: 0.036, length: 0.034, chamferRadius: 0.008), dots))
            holder.simdPosition = SIMD3(0, -0.05, -0.43)
            holder.simdOrientation = simd_quatf(angle: -0.45, axis: SIMD3(1, 0, 0))
            n.addChildNode(holder)

        case "bandana":
            let cloth = tex(Patterns.dots(SIMD3(0.80, 0.12, 0.12), SIMD3(0.98, 0.95, 0.9), count: 6), rough: 0.9, scale: (0.5, 0.5))
            cloth.isDoubleSided = true
            n.addChildNode(Shapes.node(Shapes.tube(collarPath(grow: 0.004), radii: Array(repeating: 0.016, count: 33), sides: 6), cloth))
            // The triangle hangs down under the throat.
            let tri: [SIMD2<Float>] = [SIMD2(-0.11, 0), SIMD2(0.11, 0), SIMD2(0, -0.13)]
            let flap = Shapes.node(Shapes.extrude(tri, depth: 0.008), cloth)
            flap.simdPosition = SIMD3(0, -0.07, -0.37)
            flap.simdOrientation = simd_quatf(angle: -0.55, axis: SIMD3(1, 0, 0))
            n.addChildNode(flap)
            // Knot on top.
            n.addChildNode(Shapes.node(Shapes.ball(0.026, segments: 8), cloth, at: SIMD3(0, neckCenter.y + neckRadius.y + 0.01, neckCenter.z + 0.03)))

        case "bell":
            let leather = Shapes.mat(c(0.78, 0.12, 0.14), rough: 0.6)
            n.addChildNode(Shapes.node(Shapes.tube(collarPath(), radii: Array(repeating: 0.016, count: 33), sides: 8), leather))
            let gold = Shapes.mat(c(1.0, 0.80, 0.30), rough: 0.2, metal: 1.0)
            let bell = Shapes.lathe([SIMD2(0.0, -0.028), SIMD2(0.038, -0.025), SIMD2(0.035, -0.01), SIMD2(0.027, 0.008), SIMD2(0.015, 0.02), SIMD2(0, 0.022)],
                                    segments: 20, capTop: false)
            let hang = SCNNode()
            hang.simdPosition = SIMD3(0, neckCenter.y - neckRadius.y - 0.004, neckCenter.z - 0.03)
            let b = Shapes.node(bell, gold, at: SIMD3(0, -0.03, 0))
            hang.addChildNode(b)
            hang.addChildNode(Shapes.node(Shapes.ball(0.009, segments: 6), gold, at: SIMD3(0, -0.006, 0)))
            n.addChildNode(hang)
            var phase: Float = 0
            animators.append { dt, speed, _ in
                phase += dt * (3 + speed * 0.2)
                hang.simdOrientation = simd_quatf(angle: sin(phase) * 0.25, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: 0.35 + 0.02 * min(speed, 30), axis: SIMD3(1, 0, 0))
            }

        case "scarf", "rainbowscarf":
            let rainbow = id == "rainbowscarf"
            let clothTex: CGImage = rainbow
                ? Patterns.cached("rainbowscarf") {
                    makeImage(width: 8, height: 96) { _, y in
                        let cols: [SIMD3<Float>] = [SIMD3(0.93, 0.22, 0.22), SIMD3(0.98, 0.56, 0.16), SIMD3(0.98, 0.86, 0.2),
                                                    SIMD3(0.3, 0.78, 0.35), SIMD3(0.22, 0.52, 0.95), SIMD3(0.55, 0.32, 0.88)]
                        return SIMD4(cols[(y / 8) % cols.count], 1)
                    }
                }
                : Patterns.cached("redscarf") {
                    makeImage(width: 8, height: 96) { _, y in
                        let stripe = y > 78 && (y / 4) % 2 == 0
                        return SIMD4(stripe ? SIMD3(0.98, 0.96, 0.92) : SIMD3(0.82, 0.12, 0.14), 1)
                    }
                }
            let cloth = tex(clothTex, rough: 0.85)
            cloth.isDoubleSided = true
            n.addChildNode(Shapes.node(Shapes.tube(collarPath(grow: 0.008), radii: Array(repeating: 0.024, count: 33), sides: 8), cloth))
            let top = SIMD3(0.025, neckCenter.y + neckRadius.y + 0.02, neckCenter.z + 0.03)
            n.addChildNode(Shapes.node(Shapes.ball(0.03, segments: 10), cloth, at: top))
            // Two long tails streaming back over the body, rebuilt each frame so they flutter.
            let tails = [SCNNode(), SCNNode()]
            for t in tails { n.addChildNode(t) }
            var phase: Float = 0
            let bases = [top + SIMD3(-0.012, 0.004, 0.01), top + SIMD3(0.018, -0.004, 0.012)]
            let lengths: [Float] = [0.66, 0.54]
            animators.append { dt, speed, _ in
                let s = clamp(speed / 25, 0, 1)
                phase += dt * (4 + 10 * s)
                for (i, node) in tails.enumerated() {
                    node.geometry = scarfTail(base: bases[i], length: lengths[i], width: 0.07 - Float(i) * 0.01, phase: phase + Float(i) * 1.7,
                                              stream: s)
                    node.geometry?.materials = [cloth]
                }
            }

        case "medal":
            let ribbon = Shapes.mat(c(0.16, 0.36, 0.82), rough: 0.8, doubleSided: true)
            let hangAt = SIMD3<Float>(0, neckCenter.y - neckRadius.y - 0.06, neckCenter.z - 0.05)
            for s: Float in [-1, 1] {
                let path = [SIMD3(s * (neckRadius.x + 0.006), neckCenter.y + 0.03, neckCenter.z + 0.01),
                            SIMD3(s * (neckRadius.x - 0.01), neckCenter.y - 0.05, neckCenter.z - 0.03),
                            hangAt + SIMD3(s * 0.012, 0.035, 0)]
                n.addChildNode(Shapes.node(Shapes.tube(Shapes.curve(path[0], path[1], path[2], 8), radii: Array(repeating: 0.013, count: 9), sides: 5), ribbon))
            }
            let gold = Shapes.mat(c(1.0, 0.80, 0.30), rough: 0.22, metal: 1.0)
            let disc = Shapes.node(Shapes.extrude(Shapes.circle(0.046, 28), depth: 0.01), gold, at: hangAt)
            disc.simdOrientation = simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            n.addChildNode(disc)
            let star = Shapes.node(Shapes.extrude(Shapes.star(0.027, 0.012), depth: 0.005), Shapes.mat(c(1.0, 0.93, 0.62), rough: 0.2, metal: 1.0))
            star.simdPosition = SIMD3(0, 0, 0.007)
            disc.addChildNode(star)

        case "lei":
            let colors = [c(1.0, 0.45, 0.65), c(0.99, 0.96, 0.9), c(0.72, 0.45, 0.95), c(1.0, 0.62, 0.22)]
            let path = collarPath(grow: 0.012, count: 14)
            for i in 0..<14 {
                let f = flower(0.032, colors[i % colors.count], c(1.0, 0.86, 0.3))
                f.simdPosition = path[i]
                // Petals face outward from the neck (and a little forward).
                let out = simd_normalize(SIMD3(path[i].x, path[i].y - neckCenter.y, 0))
                f.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(out + SIMD3(0, 0, -0.3)))
                n.addChildNode(f)
            }

        default:
            return nil
        }
        n.name = "cosmetic"
        return n
    }

    /// One scarf tail: a strip from `base` streaming backward (+Z) with a travelling wave. `stream` 0 hangs, 1 flies straight back.
    private static func scarfTail(base: SIMD3<Float>, length: Float, width: Float, phase: Float, stream: Float) -> SCNGeometry {
        var m = MeshBuilder()
        let segs = 10
        let white = SIMD3<Float>(1, 1, 1)
        var p = base
        var pts: [SIMD3<Float>] = []
        for i in 0...segs {
            let t = Float(i) / Float(segs)
            pts.append(p)
            // Direction: back and a little up when streaming, drooping when slow.
            let droop = (1 - stream) * 0.6
            var dir = simd_normalize(SIMD3(0, (t < 0.25 ? 0.32 : 0.1) - droop * t, 1))
            let wave = sin(phase - t * 7) * (0.18 + 0.5 * stream) * t
            dir += SIMD3(wave * 0.35, wave, 0)
            p += simd_normalize(dir) * (length / Float(segs))
        }
        for (i, q) in pts.enumerated() {
            let t = Float(i) / Float(segs)
            let fwd = simd_normalize(pts[min(i + 1, segs)] - pts[max(i - 1, 0)])
            var side = simd_normalize(simd_cross(fwd, SIMD3(0, 1, 0)))
            if !side.x.isFinite { side = SIMD3(1, 0, 0) }
            let w = width * (1 - 0.3 * t)
            let nrm = simd_normalize(simd_cross(side, fwd))
            m.vertex(q - side * w / 2, nrm, white, uv: SIMD2(0, t))
            m.vertex(q + side * w / 2, nrm, white, uv: SIMD2(1, t))
        }
        for i in 0..<UInt32(segs) {
            let a = i * 2, b = a + 1, c = a + 2, d = a + 3
            m.tri(a, c, b); m.tri(b, c, d)
        }
        return m.geometry()
    }
}
