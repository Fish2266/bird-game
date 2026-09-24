import SceneKit
import AppKit
import simd

// MARK: - Image helpers

func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> SIMD4<Float>) -> CGImage {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let c = simd_clamp(pixel(x, y), SIMD4(repeating: 0), SIMD4(repeating: 1))
            let i = (y * width + x) * 4
            // premultiplied alpha
            data[i] = UInt8(c.x * c.w * 255); data[i + 1] = UInt8(c.y * c.w * 255)
            data[i + 2] = UInt8(c.z * c.w * 255); data[i + 3] = UInt8(c.w * 255)
        }
    }
    return data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

// MARK: - Sky

enum Sky {
    static let sunDir = simd_normalize(SIMD3<Float>(-0.55, 0.5, 0.62))
    static let horizon = SIMD3<Float>(0.80, 0.87, 0.95)
    static let zenith = SIMD3<Float>(0.24, 0.47, 0.86)

    static func color(_ d: SIMD3<Float>, _ v: WorldVisuals = .meadow) -> SIMD3<Float> {
        let y = d.y
        var c: SIMD3<Float>
        if y >= 0 {
            c = simd_mix(v.horizon, v.zenith, SIMD3(repeating: pow(y, 0.5)))
        } else {
            c = simd_mix(v.horizon, v.below, SIMD3(repeating: min(1, -y * 3)))
        }
        let cs = max(simd_dot(d, v.sunDir), 0)
        c += v.sunGlow * (pow(cs, 12) * 0.12 + pow(cs, 90) * 0.35 + pow(cs, 1800) * 3)
        return c
    }

    static let cachedFaces: [CGImage] = cubeFaces()

    /// Six cube faces (+X, -X, +Y, -Y, +Z, -Z).
    static func cubeFaces(size: Int = 256, _ look: WorldVisuals = .meadow) -> [CGImage] {
        let dirs: [(Float, Float) -> SIMD3<Float>] = [
            { u, v in SIMD3(1, -v, -u) }, { u, v in SIMD3(-1, -v, u) },
            { u, v in SIMD3(u, 1, v) }, { u, v in SIMD3(u, -1, -v) },
            { u, v in SIMD3(u, -v, 1) }, { u, v in SIMD3(-u, -v, -1) },
        ]
        return dirs.map { f in
            makeImage(width: size, height: size) { x, y in
                let u = (Float(x) + 0.5) / Float(size) * 2 - 1
                let v = (Float(y) + 0.5) / Float(size) * 2 - 1
                let c = color(simd_normalize(f(u, v)), look)
                return SIMD4(c, 1)
            }
        }
    }

    static var fogColor: NSColor { NSColor(srgbRed: CGFloat(horizon.x), green: CGFloat(horizon.y), blue: CGFloat(horizon.z), alpha: 1) }
}

// MARK: - Water

final class Water {
    let node: SCNNode
    private let tile: Float = 48
    private let size: Float = 9000

    init() {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.06, green: 0.25, blue: 0.34, alpha: 1)
        m.roughness.contents = 0.12
        m.metalness.contents = 0.0
        m.normal.contents = Water.normalMap()
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.mipFilter = .linear
        m.normal.maxAnisotropy = 8
        m.normal.intensity = 0.55
        let reps = CGFloat(size / tile)
        m.normal.contentsTransform = SCNMatrix4MakeScale(reps, reps, 1)
        m.transparency = 0.8
        m.blendMode = .alpha
        m.writesToDepthBuffer = true
        plane.materials = [m]
        node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.renderingOrder = 5
        node.castsShadow = false
    }

    /// Keep the plane under the camera, snapped so the wave texture stays fixed in the world.
    func follow(_ p: SIMD3<Float>) {
        let sx = (p.x / tile).rounded() * tile, sz = (p.z / tile).rounded() * tile
        node.simdPosition = SIMD3(sx, TerrainShape.waterLevel, sz)
    }

    private static func normalMap() -> CGImage {
        let n = 256
        var rng = SplitMix64(seed: 7)
        var waves: [(Float, Float, Float, Float)] = []
        for _ in 0..<14 {
            let kx = Float(Int(rng.float(-7, 7))), ky = Float(Int(rng.float(-7, 7)))
            if kx == 0 && ky == 0 { continue }
            waves.append((kx, ky, rng.float(0, 6.28), 1 / sqrt(kx * kx + ky * ky)))
        }
        func h(_ x: Float, _ y: Float) -> Float {
            var s: Float = 0
            for w in waves { s += sin(2 * .pi * (w.0 * x + w.1 * y) + w.2) * w.3 }
            return s
        }
        return makeImage(width: n, height: n) { x, y in
            let fx = Float(x) / Float(n), fy = Float(y) / Float(n), e: Float = 1 / Float(n)
            let dx = (h(fx + e, fy) - h(fx - e, fy)) * 0.9
            let dy = (h(fx, fy + e) - h(fx, fy - e)) * 0.9
            let nn = simd_normalize(SIMD3(-dx, -dy, 1))
            return SIMD4(nn * 0.5 + 0.5, 1)
        }
    }
}

// MARK: - Clouds (clusters of soft billboards, recycled around the player)

final class CloudField {
    let root = SCNNode()
    private var clouds: [SCNNode] = []
    private let range: Float = 1900
    private var rng = SplitMix64(seed: 4242)

    private let heights: ClosedRange<Float>

    init(count: Int = 34, heights: ClosedRange<Float> = 240...460, tint: SIMD3<Float>? = nil) {
        self.heights = heights
        let puffs = (0..<3).map { CloudField.puffMaterial(seed: UInt64($0), tint: tint) }
        for _ in 0..<count {
            let cloud = SCNNode()
            let n = Int(rng.float(5, 10))
            let length = rng.float(90, 220)
            for i in 0..<n {
                let t = Float(i) / Float(max(n - 1, 1)) - 0.5
                let r = rng.float(38, 75) * (1 - abs(t) * 0.8)
                let p = SCNPlane(width: CGFloat(r * 2), height: CGFloat(r * 2))
                p.materials = [puffs[Int(rng.float(0, 2.99))]]
                let pn = SCNNode(geometry: p)
                pn.simdPosition = SIMD3(t * length + rng.float(-15, 15), rng.float(-8, 18) + (0.5 - abs(t)) * 22, rng.float(-35, 35))
                let bc = SCNBillboardConstraint()
                bc.freeAxes = .all
                pn.constraints = [bc]
                pn.renderingOrder = 20
                pn.castsShadow = false
                cloud.addChildNode(pn)
            }
            cloud.simdPosition = SIMD3(rng.float(-range, range), rng.float(heights.lowerBound, heights.upperBound), rng.float(-range, range))
            cloud.eulerAngles.y = CGFloat(rng.float(0, 6.28))
            root.addChildNode(cloud)
            clouds.append(cloud)
        }
    }

    func update(center: SIMD3<Float>) {
        for c in clouds {
            var p = c.simdPosition
            var moved = false
            if p.x - center.x > range { p.x -= 2 * range; moved = true }
            if p.x - center.x < -range { p.x += 2 * range; moved = true }
            if p.z - center.z > range { p.z -= 2 * range; moved = true }
            if p.z - center.z < -range { p.z += 2 * range; moved = true }
            if moved { p.y = rng.float(heights.lowerBound, heights.upperBound); c.simdPosition = p }
        }
    }

    private static func puffMaterial(seed: UInt64, tint: SIMD3<Float>?) -> SCNMaterial {
        var rng = SplitMix64(seed: 100 + seed)
        var blobs: [(Float, Float, Float)] = []
        for _ in 0..<9 { blobs.append((rng.float(0.3, 0.7), rng.float(0.35, 0.65), rng.float(0.14, 0.26))) }
        let img = makeImage(width: 128, height: 128) { x, y in
            let u = Float(x) / 128, v = Float(y) / 128
            var a: Float = 0
            for b in blobs {
                let d = simd_length(SIMD2(u - b.0, v - b.1)) / b.2
                a += max(0, 1 - d * d)
            }
            a = min(1, a * 0.9)
            a *= smoothstep(0.5, 0.33, simd_length(SIMD2(u - 0.5, v - 0.5)))
            let shade = 1.0 - v * 0.28   // image y down: top brighter
            var c = SIMD3<Float>(shade, shade, min(1, shade + 0.03))
            if let tint { c *= tint }
            return SIMD4(c, a * 0.85)
        }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.diffuse.mipFilter = .linear
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return m
    }
}

// MARK: - Floating motes: static in the world, so they stream past and sell your speed.

func makeMotes(_ kind: MoteKind = .dust) -> SCNParticleSystem {
    if kind == .embers { return makeEmbers() }
    if kind == .fireflies { return makeFireflies() }
    let ps = SCNParticleSystem()
    ps.birthRate = 700
    ps.emitterShape = SCNBox(width: 70, height: 40, length: 70, chamferRadius: 0)
    ps.birthLocation = .volume
    ps.particleLifeSpan = 1.6
    ps.particleLifeSpanVariation = 0.5
    ps.particleSize = 0.05
    ps.particleSizeVariation = 0.03
    ps.particleVelocity = 0.2
    ps.particleColor = NSColor(white: 1, alpha: 0.55)
    ps.blendMode = .additive
    ps.isLightingEnabled = false
    ps.isAffectedByGravity = false
    ps.particleImage = makeImage(width: 32, height: 32) { x, y in
        let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
        return SIMD4(1, 1, 1, max(0, 1 - d) * max(0, 1 - d))
    }
    let fade = CAKeyframeAnimation()
    fade.values = [0, 1, 1, 0]
    fade.keyTimes = [0, 0.2, 0.7, 1]
    let ctrl = SCNParticlePropertyController(animation: fade)
    ps.propertyControllers = [.opacity: ctrl]
    return ps
}

private func softDot() -> CGImage {
    makeImage(width: 32, height: 32) { x, y in
        let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
        return SIMD4(1, 1, 1, max(0, 1 - d) * max(0, 1 - d))
    }
}

/// Glowing embers that drift upward (Volcano).
func makeEmbers() -> SCNParticleSystem {
    let ps = SCNParticleSystem()
    ps.birthRate = 260
    ps.emitterShape = SCNBox(width: 90, height: 50, length: 90, chamferRadius: 0)
    ps.birthLocation = .volume
    ps.particleLifeSpan = 2.5
    ps.particleLifeSpanVariation = 1
    ps.particleSize = 0.09
    ps.particleSizeVariation = 0.05
    ps.particleVelocity = 2.5
    ps.particleVelocityVariation = 1.5
    ps.emittingDirection = SCNVector3(0, 1, 0)
    ps.spreadingAngle = 40
    ps.particleColor = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 0.9)
    ps.blendMode = .additive
    ps.isLightingEnabled = false
    ps.particleImage = softDot()
    let fade = CAKeyframeAnimation()
    fade.values = [0, 1, 1, 0]
    fade.keyTimes = [0, 0.15, 0.6, 1]
    ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
    return ps
}

/// Slow blinking fireflies (Caves).
func makeFireflies() -> SCNParticleSystem {
    let ps = SCNParticleSystem()
    ps.birthRate = 45
    ps.emitterShape = SCNBox(width: 50, height: 16, length: 50, chamferRadius: 0)
    ps.birthLocation = .volume
    ps.particleLifeSpan = 4
    ps.particleLifeSpanVariation = 1.5
    ps.particleSize = 0.12
    ps.particleSizeVariation = 0.05
    ps.particleVelocity = 0.6
    ps.particleVelocityVariation = 0.4
    ps.spreadingAngle = 180
    ps.particleColor = NSColor(srgbRed: 0.85, green: 1.0, blue: 0.45, alpha: 1)
    ps.blendMode = .additive
    ps.isLightingEnabled = false
    ps.particleImage = softDot()
    let blink = CAKeyframeAnimation()
    blink.values = [0, 1, 0.2, 1, 0.3, 0]
    blink.keyTimes = [0, 0.15, 0.35, 0.55, 0.8, 1]
    ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: blink)]
    return ps
}

// MARK: - Lava

/// Glowing lava sea that follows the camera (Volcano's "water").
final class LavaSurface {
    let node: SCNNode
    private let tile: Float = 64
    private let size: Float = 7000
    private let material = SCNMaterial()

    init() {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        let tex = LavaSurface.texture()
        material.lightingModel = .constant
        material.diffuse.contents = tex
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        material.diffuse.intensity = 1.6
        let reps = CGFloat(size / tile)
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(reps, reps, 1)
        plane.materials = [material]
        node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.castsShadow = false
    }

    func follow(_ p: SIMD3<Float>, time: Float) {
        let sx = (p.x / tile).rounded() * tile, sz = (p.z / tile).rounded() * tile
        node.simdPosition = SIMD3(sx, TerrainShape.waterLevel, sz)
        // Slow crawl of the crust.
        let reps = CGFloat(size / tile)
        var m = SCNMatrix4MakeScale(reps, reps, 1)
        m = SCNMatrix4Translate(m, CGFloat(time * 0.02), CGFloat(time * 0.013), 0)
        material.diffuse.contentsTransform = m
    }

    private static func texture() -> CGImage {
        let n = 256
        var rng = SplitMix64(seed: 666)
        func blurred(_ r: Int, _ passes: Int) -> [Float] {
            var a = (0..<(n * n)).map { _ in rng.float() }
            var b = a
            for _ in 0..<passes {
                for y in 0..<n { for x in 0..<n { var s: Float = 0; for k in -r...r { s += a[y * n + (x + k + n) % n] }; b[y * n + x] = s / Float(2 * r + 1) } }
                for y in 0..<n { for x in 0..<n { var s: Float = 0; for k in -r...r { s += b[((y + k + n) % n) * n + x] }; a[y * n + x] = s / Float(2 * r + 1) } }
            }
            let lo = a.min()!, hi = a.max()!
            return a.map { ($0 - lo) / (hi - lo) }
        }
        let big = blurred(10, 2), mid = blurred(3, 2)
        return makeImage(width: n, height: n) { x, y in
            let i = y * n + x
            let v = big[i] * 0.65 + mid[i] * 0.35
            // Bright cracks where the noise is mid-valued, dark crust elsewhere.
            let crack = 1 - min(1, abs(v - 0.5) * 7)
            let hot = SIMD3<Float>(1.0, 0.55, 0.12), crust = SIMD3<Float>(0.25, 0.06, 0.03), warm = SIMD3<Float>(0.75, 0.20, 0.05)
            var c = simd_mix(crust, warm, SIMD3(repeating: smoothstep(0.2, 0.8, v)))
            c = simd_mix(c, hot, SIMD3(repeating: crack))
            return SIMD4(c, 1)
        }
    }
}

// MARK: - Ring course

/// Where to put a ring (from a world's own course generator).
struct RingSpec {
    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var radius: Float
    /// Horizontal direction the course continues in.
    var dir: SIMD3<Float>
}

/// Height/spacing rules for the standard open-sky course (World 1 uses the defaults).
struct RingCourseParams {
    var firstDistance: ClosedRange<Float> = 110...150
    var spacing: ClosedRange<Float> = 150...230
    var yawJitter: Float = 0.6
    var climb: ClosedRange<Float> = -45...35
    var minAboveGround: ClosedRange<Float> = 28...45
    var maxAboveGround: Float = 180
    /// Side-to-side drift of the rings (m); 0 = still.
    var sway: Float = 0
}

final class RingCourse {
    struct Ring {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
        var node: SCNNode
        var radius: Float
        var base: SIMD3<Float>
        var phase: Float
    }
    let root = SCNNode()
    private(set) var rings: [Ring] = []
    private(set) var score = 0
    private var rng = SplitMix64(seed: 777)
    private let radius: Float = 7.5
    private let activeMat: SCNMaterial
    private let idleMat: SCNMaterial
    var params = RingCourseParams()
    /// Optional world-specific course (caves follow the tunnels).
    var generator: ((SIMD3<Float>, SIMD3<Float>, Bool, inout SplitMix64) -> RingSpec)?

    init() {
        func mat(_ glow: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 1)
            m.metalness.contents = 0.6
            m.roughness.contents = 0.3
            m.emission.contents = NSColor(srgbRed: 1 * glow, green: 0.62 * glow, blue: 0.12 * glow, alpha: 1)
            return m
        }
        activeMat = mat(1.0)
        idleMat = mat(0.35)
    }

    var next: Ring? { rings.first }

    func reset(from p: SIMD3<Float>, heading: SIMD3<Float>) {
        for r in rings { r.node.removeFromParentNode() }
        rings.removeAll()
        var last = p
        var dir = simd_normalize(SIMD3(heading.x, 0, heading.z))
        if !dir.x.isFinite { dir = SIMD3(0, 0, -1) }
        if generator == nil { last += dir * 40 }
        for _ in 0..<4 { (last, dir) = spawn(after: last, dir: dir, first: rings.isEmpty) }
        refreshMaterials()
    }

    @discardableResult
    private func spawn(after last: SIMD3<Float>, dir: SIMD3<Float>, first: Bool) -> (SIMD3<Float>, SIMD3<Float>) {
        let spec: RingSpec
        if let generator {
            spec = generator(last, dir, first, &rng)
        } else {
            let p = params
            let yawJitter = first ? 0 : rng.float(-p.yawJitter, p.yawJitter)
            let q = simd_quatf(angle: yawJitter, axis: kUp)
            let d = q.act(dir)
            let dist = first ? rng.float(p.firstDistance.lowerBound, p.firstDistance.upperBound)
                             : rng.float(p.spacing.lowerBound, p.spacing.upperBound)
            var c = last + d * dist
            let ground = max(TerrainShape.height(c.x, c.z), TerrainShape.waterLevel)
            let want = last.y + rng.float(p.climb.lowerBound, p.climb.upperBound)
            c.y = max(want, ground + rng.float(p.minAboveGround.lowerBound, p.minAboveGround.upperBound))
            c.y = min(c.y, ground + p.maxAboveGround)
            let n = simd_normalize(c - last)
            spec = RingSpec(center: c, normal: n, radius: radius, dir: simd_normalize(SIMD3(d.x, 0, d.z)))
        }

        let torus = SCNTorus(ringRadius: CGFloat(spec.radius), pipeRadius: CGFloat(0.55 * min(1, spec.radius / radius + 0.2)))
        torus.ringSegmentCount = 48
        torus.pipeSegmentCount = 12
        let node = SCNNode(geometry: torus)
        node.simdPosition = spec.center
        // Torus axis is +Y; rotate it to face the approach direction.
        node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: spec.normal)
        node.castsShadow = false
        root.addChildNode(node)
        rings.append(Ring(center: spec.center, normal: spec.normal, node: node, radius: spec.radius,
                          base: spec.center, phase: params.sway > 0 ? rng.float(0, 6.28) : 0))
        return (spec.center, spec.dir)
    }

    private func refreshMaterials() {
        for (i, r) in rings.enumerated() { r.node.geometry?.materials = [i == 0 ? activeMat : idleMat] }
    }

    /// Returns the number of rings skipped (0 = the next one) when the bird flew through a ring
    /// this step, or nil if it didn't.
    func update(prev: SIMD3<Float>, now: SIMD3<Float>, time: Float) -> Int? {
        if let r = rings.first {
            r.node.simdScale = SIMD3(repeating: 1 + 0.06 * sin(time * 6))
        }
        if params.sway > 0 {
            for i in rings.indices {
                let n = rings[i].normal
                let side = simd_normalize(SIMD3(-n.z, 0, n.x))
                let c = rings[i].base + side * params.sway * sin(time * 0.6 + rings[i].phase)
                    + SIMD3(0, params.sway * 0.4 * sin(time * 0.45 + rings[i].phase * 1.7), 0)
                rings[i].center = c
                rings[i].node.simdPosition = c
            }
        }
        var hitIndex: Int?
        for (i, r) in rings.enumerated() {
            let a = simd_dot(prev - r.center, r.normal), b = simd_dot(now - r.center, r.normal)
            guard (a < 0) != (b < 0) else { continue }
            let hit = prev + (now - prev) * (a / (a - b))
            if simd_distance(hit, r.center) < r.radius + 1.2 { hitIndex = i; break }
        }
        guard let k = hitIndex else {
            // Far off course? Rebuild the course ahead of the bird.
            if let r = rings.first, simd_distance(now, r.center) > 1100 { reset(from: now, heading: now - prev) }
            return nil
        }
        score += 1
        for (i, r) in rings.prefix(k + 1).enumerated() {
            let node = r.node
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            if i == k { node.simdScale = SIMD3(repeating: 1.8) }
            node.opacity = 0
            SCNTransaction.completionBlock = { node.removeFromParentNode() }
            SCNTransaction.commit()
        }
        let passed = rings[k]
        rings.removeFirst(k + 1)
        var last = rings.last?.base ?? passed.base
        var dir: SIMD3<Float>
        if rings.count >= 2 {
            let p = rings[rings.count - 2].base
            dir = simd_normalize(SIMD3(last.x - p.x, 0, last.z - p.z))
        } else {
            dir = simd_normalize(SIMD3(passed.normal.x, 0, passed.normal.z))
        }
        while rings.count < 4 { (last, dir) = spawn(after: last, dir: dir, first: false) }
        refreshMaterials()
        return k
    }
}
