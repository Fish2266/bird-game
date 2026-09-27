import SceneKit
import simd

/// Sprites for particle trails, drawn once.
enum TrailSprites {
    private static func draw(_ size: Int = 64, _ body: @escaping (NSRect) -> Void) -> CGImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in body(r); return true }
        var rect = NSRect(x: 0, y: 0, width: size, height: size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    static let star: CGImage = draw { r in
        let p = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY)
        for i in 0..<8 {
            let a = CGFloat(i) / 8 * 2 * .pi + .pi / 2
            let rad: CGFloat = i % 2 == 0 ? 30 : 7
            let pt = NSPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        NSColor.white.setFill(); p.fill()
        NSGradient(starting: NSColor.white, ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: NSBezierPath(ovalIn: r.insetBy(dx: 18, dy: 18)), relativeCenterPosition: .zero)
    }

    static let heart: CGImage = draw { r in
        let pts = Shapes.heart(52)
        let p = NSBezierPath()
        for (i, v) in pts.enumerated() {
            let pt = NSPoint(x: r.midX + CGFloat(v.x), y: r.midY + CGFloat(v.y) - 2)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        NSColor.white.setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke(); p.lineWidth = 2; p.stroke()
    }

    static let bubble: CGImage = draw { r in
        let o = NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5))
        NSColor.white.withAlphaComponent(0.28).setFill(); o.fill()
        o.lineWidth = 5
        NSColor.white.setStroke(); o.stroke()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 17, y: r.maxY - 27, width: 12, height: 9)).fill()
    }

    static let leaf: CGImage = draw { r in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + 8, y: r.minY + 8))
        p.curve(to: NSPoint(x: r.maxX - 6, y: r.maxY - 6), controlPoint1: NSPoint(x: r.minX + 6, y: r.maxY - 10),
                controlPoint2: NSPoint(x: r.midX, y: r.maxY - 4))
        p.curve(to: NSPoint(x: r.minX + 8, y: r.minY + 8), controlPoint1: NSPoint(x: r.maxX - 4, y: r.midY),
                controlPoint2: NSPoint(x: r.maxX - 10, y: r.minY + 6))
        NSColor.white.setFill(); p.fill()
        let vein = NSBezierPath()
        vein.move(to: NSPoint(x: r.minX + 8, y: r.minY + 8)); vein.line(to: NSPoint(x: r.maxX - 12, y: r.maxY - 12))
        vein.lineWidth = 2
        NSColor(white: 0.55, alpha: 1).setStroke(); vein.stroke()
    }

    static let flake: CGImage = draw { r in
        let c = NSPoint(x: r.midX, y: r.midY)
        for (width, color) in [(CGFloat(7), NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.9)), (CGFloat(3.5), NSColor.white)] {
        color.setStroke()
        for k in 0..<6 {
            let a = CGFloat(k) / 6 * 2 * .pi
            let p = NSBezierPath()
            p.lineWidth = width; p.lineCapStyle = .round
            let tip = NSPoint(x: c.x + cos(a) * 27, y: c.y + sin(a) * 27)
            p.move(to: c); p.line(to: tip)
            for (d, l) in [(14, 8), (21, 6)] as [(CGFloat, CGFloat)] {
                let b = NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
                for s: CGFloat in [-1, 1] {
                    p.move(to: b)
                    p.line(to: NSPoint(x: b.x + cos(a + s * 0.8) * l, y: b.y + sin(a + s * 0.8) * l))
                }
            }
            p.stroke()
        }
        }
    }

    /// A bold pair of beamed quavers (♫), drawn as shapes so it stays readable when small.
    static let note: CGImage = draw { r in
        NSColor.white.setFill()
        let heads = [NSPoint(x: 17, y: 16), NSPoint(x: 45, y: 22)]
        for h in heads {
            let head = NSBezierPath(ovalIn: NSRect(x: h.x - 9, y: h.y - 6.5, width: 18, height: 13))
            var t = AffineTransform(translationByX: h.x, byY: h.y); t.rotate(byDegrees: -22); t.translate(x: -h.x, y: -h.y)
            head.transform(using: t)
            head.fill()
            NSBezierPath(rect: NSRect(x: h.x + 5, y: h.y, width: 5, height: 36)).fill()
        }
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: 22, y: 52)); beam.line(to: NSPoint(x: 55, y: 58))
        beam.line(to: NSPoint(x: 55, y: 48)); beam.line(to: NSPoint(x: 22, y: 42)); beam.close()
        beam.fill()
    }

    static let square: CGImage = draw { r in
        NSColor.white.setFill(); NSBezierPath(rect: r.insetBy(dx: 14, dy: 22)).fill()
    }

    static let puff: CGImage = makeImage(width: 64, height: 64) { x, y in
        let d = simd_length(SIMD2(Float(x) - 31.5, Float(y) - 31.5)) / 32
        let n = 0.85 + 0.15 * sin(Float(x) * 0.5) * cos(Float(y) * 0.43)
        return SIMD4(1, 1, 1, max(0, 1 - d * d) * n)
    }

    static let flame: CGImage = makeImage(width: 64, height: 64) { x, y in
        let u = (Float(x) - 31.5) / 32, v = (Float(y) - 31.5) / 32
        let d = simd_length(SIMD2(u, v * 0.8 + 0.1))
        return SIMD4(1, 1, 1, pow(max(0, 1 - d), 1.6))
    }

    static let dot: CGImage = Combat.dot
}

/// A bird's trail: ribbons that stream off the wingtips / tail, or particles that pour out behind it.
/// In the game the effects live in world space (so they stay where you've been); in the menu preview
/// they're faked in the bird's own space, streaming straight back as if it were flying.
final class TrailFX {
    let kind: String
    /// World-space container for ribbons (the owner adds it next to the bird). Unused in preview mode.
    let root = SCNNode()
    private let preview: Bool
    private var ribbons: [Ribbon] = []
    private var emitters: [(system: SCNParticleSystem, rate: CGFloat)] = []
    private var time: Float = 0
    /// The bird's root node: trails are emitted from smoothed points that follow the wingtips / tail in its space,
    /// so a flapping wing leaves a gentle wave instead of a zig-zag.
    private let host: SCNNode
    private var proxies: [(anchor: SCNNode, node: SCNNode, primed: Bool)] = []

    private final class Ribbon {
        let anchor: SCNNode
        let width: Float
        let life: Float
        let billboard: Bool
        let node = SCNNode()
        let material: SCNMaterial
        var samples: [(p: SIMD3<Float>, side: SIMD3<Float>, t: Float)] = []
        init(anchor: SCNNode, width: Float, life: Float, billboard: Bool, material: SCNMaterial) {
            self.anchor = anchor; self.width = width; self.life = life; self.billboard = billboard; self.material = material
            node.castsShadow = false
            node.renderingOrder = 40
        }
    }

    /// `wingTips` = [left, right]; `body` is the bird's root node (preview mode draws in its space).
    init?(kind: String, wingTips anchors: [SCNNode], tail tailAnchor: SCNNode, body: SCNNode, preview: Bool) {
        self.kind = kind
        self.preview = preview
        host = body
        root.castsShadow = false
        var made: [ObjectIdentifier: SCNNode] = [:]
        var list: [(anchor: SCNNode, node: SCNNode, primed: Bool)] = []
        func proxy(_ a: SCNNode) -> SCNNode {
            if let n = made[ObjectIdentifier(a)] { return n }
            let n = SCNNode()
            body.addChildNode(n)
            made[ObjectIdentifier(a)] = n
            list.append((a, n, false))
            return n
        }
        let wingTips = anchors.map(proxy)
        let tail = proxy(tailAnchor)
        defer { proxies = list }
        switch kind {
        case "contrails":
            for t in wingTips { addRibbon(t, width: 0.11, life: 1.5, billboard: true, texture: TrailFX.ribbonTexture("white"), additive: false) }
        case "neon":
            addRibbon(wingTips[0], width: 0.16, life: 1.3, billboard: true, texture: TrailFX.ribbonTexture("magenta"), additive: true, intensity: 2)
            addRibbon(wingTips[1], width: 0.16, life: 1.3, billboard: true, texture: TrailFX.ribbonTexture("cyan"), additive: true, intensity: 2)
        case "rainbow":
            addRibbon(tail, width: 0.66, life: 1.4, billboard: true, texture: TrailFX.ribbonTexture("rainbow"), additive: false, intensity: 1.15)
        case "sparkles":
            for t in wingTips {
                addParticles(t, rate: 55) { ps in
                    ps.particleImage = TrailSprites.star
                    ps.particleColor = NSColor(srgbRed: 1, green: 0.86, blue: 0.4, alpha: 1)
                    ps.particleColorVariation = SCNVector4(0.03, 0.2, 0, 0)
                    ps.particleSize = 0.17; ps.particleSizeVariation = 0.08
                    ps.particleLifeSpan = 0.9; ps.particleLifeSpanVariation = 0.3
                    ps.blendMode = .additive
                    ps.particleVelocity = 0.4; ps.spreadingAngle = 180
                    ps.particleAngularVelocity = 90; ps.particleAngularVelocityVariation = 120
                    ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 0.3, 1, 0], [0, 0.15, 0.45, 0.7, 1])]
                }
            }
        case "stardust":
            addRibbon(tail, width: 0.32, life: 1.6, billboard: true, texture: TrailFX.ribbonTexture("violet"), additive: true, intensity: 1)
            for t in wingTips + [tail] {
                addParticles(t, rate: 40) { ps in
                    ps.particleImage = TrailSprites.star
                    ps.particleColor = NSColor(srgbRed: 0.75, green: 0.8, blue: 1, alpha: 1)
                    ps.particleColorVariation = SCNVector4(0.12, 0.3, 0, 0)
                    ps.particleSize = 0.13; ps.particleSizeVariation = 0.07
                    ps.particleLifeSpan = 2.2; ps.particleLifeSpanVariation = 0.6
                    ps.blendMode = .additive
                    ps.particleVelocity = 0.35; ps.spreadingAngle = 180
                    ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 0.4, 1, 0.3, 0], [0, 0.1, 0.3, 0.5, 0.75, 1])]
                }
            }
        case "bubbles":
            for t in [tail] + wingTips {
            addParticles(t, rate: t === tail ? 20 : 12) { ps in
                ps.particleImage = TrailSprites.bubble
                ps.particleColor = NSColor(srgbRed: 0.75, green: 0.93, blue: 1, alpha: 1)
                ps.particleColorVariation = SCNVector4(0.12, 0.3, 0, 0)
                ps.particleSize = 0.34; ps.particleSizeVariation = 0.14
                ps.particleLifeSpan = 1.9; ps.particleLifeSpanVariation = 0.5
                ps.blendMode = .alpha
                ps.particleVelocity = 0.7; ps.particleVelocityVariation = 0.3
                ps.emittingDirection = SCNVector3(0, 1, 0); ps.spreadingAngle = 70
                ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 1, 0], [0, 0.1, 0.8, 1]),
                                          .size: TrailFX.keys([0.6, 1, 1.3], [0, 0.2, 1])]
            }
            }
        case "hearts":
            for t in [tail] + wingTips {
            addParticles(t, rate: t === tail ? 9 : 6) { ps in
                ps.particleImage = TrailSprites.heart
                ps.particleColor = NSColor(srgbRed: 1, green: 0.22, blue: 0.48, alpha: 1)
                ps.particleColorVariation = SCNVector4(0.03, 0.2, 0.05, 0)
                ps.particleSize = 0.44; ps.particleSizeVariation = 0.1
                ps.particleLifeSpan = 1.5; ps.particleLifeSpanVariation = 0.4
                ps.blendMode = .alpha
                ps.particleVelocity = 0.9; ps.emittingDirection = SCNVector3(0, 1, 0); ps.spreadingAngle = 45
                ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 1, 0], [0, 0.1, 0.7, 1]),
                                          .size: TrailFX.keys([0.5, 1.15, 0.9, 1.1, 0.9], [0, 0.2, 0.45, 0.7, 1])]
            }
            }
        case "leaves":
            for t in wingTips {
                addParticles(t, rate: 13) { ps in
                    ps.particleImage = TrailSprites.leaf
                    ps.particleColor = NSColor(srgbRed: 0.98, green: 0.38, blue: 0.04, alpha: 1)
                    ps.particleColorVariation = SCNVector4(0.07, 0, 0.12, 0)
                    ps.particleSize = 0.4; ps.particleSizeVariation = 0.1
                    ps.particleLifeSpan = 2.0; ps.particleLifeSpanVariation = 0.5
                    ps.blendMode = .alpha
                    ps.particleVelocity = 0.6; ps.spreadingAngle = 180
                    ps.particleAngularVelocity = 200; ps.particleAngularVelocityVariation = 160
                    ps.isAffectedByGravity = false
                    ps.acceleration = SCNVector3(0, -2.2, 0)
                    ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 1, 0], [0, 0.1, 0.8, 1])]
                }
            }
        case "snow":
            for t in wingTips {
                addParticles(t, rate: 22) { ps in
                    ps.particleImage = TrailSprites.flake
                    ps.particleColor = NSColor(srgbRed: 0.95, green: 0.98, blue: 1, alpha: 1)
                    ps.particleSize = 0.32; ps.particleSizeVariation = 0.1
                    ps.particleLifeSpan = 2.2; ps.particleLifeSpanVariation = 0.5
                    ps.blendMode = .alpha
                    ps.particleVelocity = 0.4; ps.spreadingAngle = 180
                    ps.particleAngularVelocity = 40; ps.particleAngularVelocityVariation = 60
                    ps.acceleration = SCNVector3(0, -0.9, 0)
                    ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 1, 0], [0, 0.1, 0.8, 1])]
                }
            }
        case "notes":
            for t in [tail] + wingTips {
            addParticles(t, rate: t === tail ? 6 : 5) { ps in
                ps.particleImage = TrailSprites.note
                ps.particleColor = NSColor(srgbRed: 0.95, green: 0.25, blue: 0.4, alpha: 1)
                ps.particleColorVariation = SCNVector4(1, 0.05, 0, 0)
                ps.particleSize = 0.54; ps.particleSizeVariation = 0.1
                ps.particleLifeSpan = 1.7; ps.particleLifeSpanVariation = 0.4
                ps.blendMode = .alpha
                ps.particleVelocity = 1.0; ps.emittingDirection = SCNVector3(0, 1, 0); ps.spreadingAngle = 50
                ps.particleAngleVariation = 25
                ps.propertyControllers = [.opacity: TrailFX.keys([0, 1, 1, 0], [0, 0.1, 0.75, 1])]
            }
            }
        case "confetti":
            addParticles(tail, rate: 70) { ps in
                ps.particleImage = TrailSprites.square
                ps.particleColor = NSColor(srgbRed: 1, green: 0.25, blue: 0.3, alpha: 1)
                ps.particleColorVariation = SCNVector4(1, 0.2, 0.05, 0)
                ps.particleSize = 0.17; ps.particleSizeVariation = 0.05
                ps.particleLifeSpan = 1.8; ps.particleLifeSpanVariation = 0.5
                ps.blendMode = .alpha
                ps.particleVelocity = 1.6; ps.particleVelocityVariation = 0.6; ps.spreadingAngle = 120
                ps.emittingDirection = SCNVector3(0, 1, 0)
                ps.particleAngularVelocity = 400; ps.particleAngularVelocityVariation = 300
                ps.acceleration = SCNVector3(0, -3.2, 0)
                ps.propertyControllers = [.opacity: TrailFX.keys([1, 1, 0], [0, 0.75, 1])]
            }
        case "smoke":
            let colors = [NSColor(srgbRed: 0.95, green: 0.2, blue: 0.2, alpha: 1), NSColor(white: 0.97, alpha: 1),
                          NSColor(srgbRed: 0.2, green: 0.4, blue: 0.95, alpha: 1)]
            for (anchor, col) in zip([wingTips[0], tail, wingTips[1]], colors) {
                addParticles(anchor, rate: 90) { ps in
                    ps.particleImage = TrailSprites.puff
                    ps.particleColor = col
                    ps.particleSize = 0.55; ps.particleSizeVariation = 0.12
                    ps.particleLifeSpan = 1.9; ps.particleLifeSpanVariation = 0.3
                    ps.blendMode = .alpha
                    ps.particleVelocity = 0.25; ps.spreadingAngle = 180
                    ps.particleAngleVariation = 180
                    ps.propertyControllers = [.opacity: TrailFX.keys([0, 0.75, 0.5, 0], [0, 0.06, 0.5, 1]),
                                              .size: TrailFX.keys([0.7, 1.3, 3.2], [0, 0.25, 1])]
                }
            }
        case "fire":
            for t in wingTips {
                addParticles(t, rate: 150) { ps in
                    ps.particleImage = TrailSprites.flame
                    ps.particleColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.15, alpha: 1)
                    ps.particleSize = 0.26; ps.particleSizeVariation = 0.08
                    ps.particleLifeSpan = 0.38; ps.particleLifeSpanVariation = 0.12
                    ps.blendMode = .additive
                    ps.particleVelocity = 0.6; ps.spreadingAngle = 180
                    ps.acceleration = SCNVector3(0, 2, 0)
                    ps.particleIntensity = 1.6
                    let col = CAKeyframeAnimation()
                    col.values = [NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1), NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1),
                                  NSColor(srgbRed: 0.8, green: 0.15, blue: 0.05, alpha: 1)]
                    col.keyTimes = [0, 0.35, 1]
                    ps.propertyControllers = [.color: SCNParticlePropertyController(animation: col),
                                              .opacity: TrailFX.keys([0.9, 0.8, 0], [0, 0.5, 1]),
                                              .size: TrailFX.keys([1, 0.8, 0.3], [0, 0.4, 1])]
                }
                addParticles(t, rate: 18) { ps in
                    ps.particleImage = TrailSprites.dot
                    ps.particleColor = NSColor(srgbRed: 1, green: 0.7, blue: 0.3, alpha: 1)
                    ps.particleSize = 0.05; ps.particleSizeVariation = 0.02
                    ps.particleLifeSpan = 1.1; ps.particleLifeSpanVariation = 0.4
                    ps.blendMode = .additive
                    ps.particleVelocity = 1.2; ps.spreadingAngle = 180
                    ps.acceleration = SCNVector3(0, 1.5, 0)
                    ps.propertyControllers = [.opacity: TrailFX.keys([1, 1, 0], [0, 0.6, 1])]
                }
            }
        default:
            return nil
        }
    }

    private static func keys(_ values: [Double], _ times: [Double]) -> SCNParticlePropertyController {
        let a = CAKeyframeAnimation()
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = times.map { NSNumber(value: $0) }
        return SCNParticlePropertyController(animation: a)
    }

    private func addRibbon(_ anchor: SCNNode, width: Float, life: Float, billboard: Bool, texture: CGImage, additive: Bool, intensity: CGFloat = 1) {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = texture
        m.diffuse.intensity = intensity
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = additive ? .add : .alpha
        let r = Ribbon(anchor: anchor, width: width, life: life, billboard: billboard, material: m)
        ribbons.append(r)
        root.addChildNode(r.node)
    }

    private func addParticles(_ anchor: SCNNode, rate: CGFloat, _ configure: (SCNParticleSystem) -> Void) {
        let ps = SCNParticleSystem()
        ps.birthRate = 0
        ps.emitterShape = SCNSphere(radius: 0.03)
        ps.birthLocation = .volume
        ps.isLightingEnabled = false
        ps.isAffectedByGravity = false
        configure(ps)
        if preview {
            // Pretend to fly: particles stream straight back from the bird.
            ps.isLocal = true
            ps.emittingDirection = SCNVector3(0, 0.15, 1)
            ps.particleVelocity += 3.2
            ps.spreadingAngle = min(ps.spreadingAngle, 25)
        }
        anchor.addParticleSystem(ps)
        emitters.append((ps, rate))
    }

    /// Horizontal texture profile across the ribbon (u), fading out along its length (v = age).
    private static func ribbonTexture(_ style: String) -> CGImage {
        Patterns.cached("ribbon-\(style)") {
            makeImage(width: 64, height: 64) { x, y in
                let u = (Float(x) + 0.5) / 64, v = (Float(y) + 0.5) / 64
                let edge = smoothstep(0, 0.22, min(u, 1 - u))
                let fade = pow(1 - v, 1.4) * smoothstep(0, 0.04, v + 0.02)
                switch style {
                case "rainbow":
                    let cols: [SIMD3<Float>] = [SIMD3(0.93, 0.2, 0.22), SIMD3(0.98, 0.55, 0.14), SIMD3(0.98, 0.88, 0.2),
                                                SIMD3(0.28, 0.78, 0.33), SIMD3(0.2, 0.5, 0.95), SIMD3(0.56, 0.3, 0.88)]
                    let band = min(Int(u * 6), 5)
                    return SIMD4(cols[band], fade * smoothstep(0, 0.06, min(u, 1 - u)) * 0.95)
                case "magenta", "cyan", "violet":
                    let base: SIMD3<Float> = style == "magenta" ? SIMD3(1, 0.2, 0.8) : style == "cyan" ? SIMD3(0.2, 0.9, 1) : SIMD3(0.55, 0.4, 1)
                    let core = smoothstep(0.32, 0.5, 1 - abs(u - 0.5) * 2 * 0.5 - 0.25)
                    let c = simd_mix(base, SIMD3(1, 1, 1), SIMD3(repeating: core * 0.7))
                    return SIMD4(c * fade * (0.35 + 0.65 * edge), 1)
                default:
                    return SIMD4(1, 1, 1, fade * edge * 0.6)
                }
            }
        }
    }

    // MARK: Per frame

    /// `speed` in m/s; `emitting` false stops new trail (paused, knocked out, hidden). `camera` orients billboard ribbons.
    func update(dt: Float, speed: Float, camera: SIMD3<Float>, emitting: Bool) {
        time += dt
        let k = approach(4.5, dt)
        for i in proxies.indices {
            let target = host.simdConvertPosition(.zero, from: proxies[i].anchor)
            let n = proxies[i].node
            if !proxies[i].primed || dt <= 0 { n.simdPosition = target; proxies[i].primed = dt > 0 }
            else { n.simdPosition += (target - n.simdPosition) * k }
        }
        let flow = emitting ? CGFloat(clamp((speed - 6) / 16, 0, 1)) : 0
        for (ps, rate) in emitters { ps.birthRate = rate * (preview ? 1 : flow) }
        for r in ribbons { updateRibbon(r, speed: speed, camera: camera, emitting: emitting) }
    }

    /// Forget the trail behind (after a teleport).
    func reset() { for r in ribbons { r.samples.removeAll(); r.node.geometry = nil } }

    private func updateRibbon(_ r: Ribbon, speed: Float, camera: SIMD3<Float>, emitting: Bool) {
        if preview {
            // Fake flight: a gently waving ribbon straight back from the anchor, in the bird's space.
            let parent = root.parent ?? root
            let a = parent.simdConvertPosition(.zero, from: r.anchor)
            var pts: [(SIMD3<Float>, SIMD3<Float>)] = []
            let n = 24
            for i in 0...n {
                let t = Float(i) / Float(n)
                let p = a + SIMD3(sin(time * 3 - t * 5) * 0.06 * t, sin(time * 2.3 - t * 4) * 0.05 * t, t * 2.4)
                pts.append((p, SIMD3(1, 0, 0)))
            }
            r.node.geometry = ribbonGeometry(pts.map { ($0.0, $0.1) }, ages: (0...n).map { Float($0) / Float(n) }, width: r.width,
                                             billboardFrom: r.billboard ? parent.simdConvertPosition(camera, from: nil) : nil)
            r.node.geometry?.materials = [r.material]
            return
        }
        let p = r.anchor.simdWorldPosition
        // A jump (respawn, teleport) starts a fresh trail.
        if let last = r.samples.last, simd_distance(last.p, p) > 25 { r.samples.removeAll() }
        let side = simd_normalize(r.anchor.simdWorldTransform.columns.0.xyz_)
        if emitting && speed > 4 {
            if let last = r.samples.last, simd_distance(last.p, p) < 0.05 {
                r.samples[r.samples.count - 1] = (p, side, time)
            } else {
                r.samples.append((p, side, time))
            }
        }
        r.samples.removeAll { time - $0.t > r.life }
        guard r.samples.count >= 2 else { r.node.geometry = nil; return }
        let ordered = r.samples.reversed()
        r.node.geometry = ribbonGeometry(ordered.map { ($0.p, $0.side) }, ages: ordered.map { (time - $0.t) / r.life }, width: r.width,
                                         billboardFrom: r.billboard ? camera : nil)
        r.node.geometry?.materials = [r.material]
    }

    /// A strip through `points` (newest first). Billboard strips turn to face `billboardFrom`; flat ones use each point's side vector.
    private func ribbonGeometry(_ points: [(SIMD3<Float>, SIMD3<Float>)], ages: [Float], width: Float, billboardFrom: SIMD3<Float>?) -> SCNGeometry {
        let n = points.count
        var pos: [Float] = [], uv: [Float] = [], nrm: [Float] = []
        pos.reserveCapacity(n * 6); uv.reserveCapacity(n * 4); nrm.reserveCapacity(n * 6)
        for i in 0..<n {
            let p = points[i].0
            let tangent = simd_normalize(points[min(i + 1, n - 1)].0 - points[max(i - 1, 0)].0)
            var side = points[i].1
            if let cam = billboardFrom {
                let toCam = cam - p
                let s = simd_cross(tangent, toCam)
                if simd_length(s) > 1e-5 { side = simd_normalize(s) }
            }
            if !side.x.isFinite { side = SIMD3(1, 0, 0) }
            // Starts thin at the anchor, full width a moment later.
            let w = width * (0.35 + 0.65 * smoothstep(0, 0.08, ages[i])) * 0.5
            let a = p - side * w, b = p + side * w
            pos += [a.x, a.y, a.z, b.x, b.y, b.z]
            let v = min(ages[i], 0.999)
            uv += [0, v, 1, v]
            let up = simd_normalize(simd_cross(side, tangent))
            nrm += [up.x, up.y, up.z, up.x, up.y, up.z]
        }
        var idx: [UInt32] = []
        idx.reserveCapacity((n - 1) * 6)
        for i in 0..<UInt32(n - 1) {
            let a = i * 2, b = a + 1, c = a + 2, d = a + 3
            idx += [a, c, b, b, c, d]
        }
        func src(_ a: [Float], _ s: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
            let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: s, vectorCount: a.count / comps, usesFloatComponents: true,
                                     componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
        }
        let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                    primitiveCount: idx.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: [src(pos, .vertex, 3), src(nrm, .normal, 3), src(uv, .texcoord, 2)], elements: [el])
    }
}

extension SIMD4 where Scalar == Float {
    var xyz_: SIMD3<Float> { SIMD3(x, y, z) }
}
