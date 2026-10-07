import SceneKit
import simd

/// Now and then the volcano blows: a boom you feel, a fountain of glowing spatter over the crater, a dark ash column,
/// and lava bombs arcing far out over the flanks — smoking as they fly, smouldering where they land. It goes off soon
/// after you first come near, and every minute or two while you stay.
final class DinoEruption {
    final class Bomb {
        let node: SCNNode
        let trail = SCNParticleSystem()
        let material = SCNMaterial()
        var pos = SIMD3<Float>.zero, vel = SIMD3<Float>.zero
        var r: Float = 1.5
        /// 0 waiting, 1 flying, 2 smouldering where it came down.
        var state = 0
        var t: Float = 0
        var spin = SIMD3<Float>(0, 1, 0)

        init() {
            let s = SCNSphere(radius: 1)
            s.segmentCount = 10
            material.lightingModel = .constant
            s.materials = [material]
            node = SCNNode(geometry: s)
            node.isHidden = true
            trail.birthRate = 0
            trail.emitterShape = SCNSphere(radius: 0.7)
            trail.birthLocation = .volume
            trail.particleVelocity = 1.2
            trail.spreadingAngle = 180
            trail.particleLifeSpan = 3.4
            trail.particleLifeSpanVariation = 1
            trail.particleSize = 3.2
            trail.particleSizeVariation = 1
            trail.particleImage = TrailSprites.puff
            trail.particleColor = NSColor(srgbRed: 0.2, green: 0.18, blue: 0.17, alpha: 0.75)
            trail.blendMode = .alpha
            trail.isLightingEnabled = false
            trail.acceleration = SCNVector3(0, 0.6, 0)
            let grow = CAKeyframeAnimation(); grow.values = [0.5, 1.6, 3.4]; grow.keyTimes = [0, 0.3, 1]
            let fade = CAKeyframeAnimation(); fade.values = [0.85, 0.5, 0]; fade.keyTimes = [0, 0.45, 1]
            trail.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
            node.addParticleSystem(trail)
        }

        /// Glowing orange when thrown, dulling to a dark crust as it cools.
        func heat(_ h: Float) {
            let hot = SIMD3<Float>(1, 0.52, 0.12), warm = SIMD3<Float>(0.55, 0.1, 0.03), cold = SIMD3<Float>(0.13, 0.1, 0.09)
            let c = h > 0.5 ? simd_mix(warm, hot, SIMD3(repeating: (h - 0.5) * 2)) : simd_mix(cold, warm, SIMD3(repeating: h * 2))
            material.diffuse.contents = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
    }

    let root = SCNNode()
    private(set) var bombs: [Bomb] = []
    private let crater = SCNNode()
    private let spatter = SCNParticleSystem(), ash = SCNParticleSystem()
    private var at: SIMD4<Float>?
    private var floorY: Float = 0
    /// Seconds of the eruption still to go (0 when quiet).
    private(set) var left: Float = 0
    private var launches: [Float] = []
    private var clock: Float = 0
    private var next: Float = 60
    private var primed = false
    private var rng = SplitMix64(seed: 0xE2_0B)
    /// This frame: it just blew / just finished; where bombs came down (and how big they were).
    private(set) var blew = false, ended = false
    private(set) var landings: [(SIMD3<Float>, Float)] = []
    /// The bird's closest approach to the crater during this eruption, and whether a bomb got it.
    private(set) var closest: Float = .infinity
    var birdHit = false

    init() {
        for _ in 0..<14 {
            let b = Bomb()
            bombs.append(b)
            root.addChildNode(b.node)
        }
        root.addChildNode(crater)
        spatter.birthRate = 0
        spatter.emitterShape = SCNSphere(radius: 12)
        spatter.birthLocation = .volume
        spatter.emittingDirection = SCNVector3(0, 1, 0)
        spatter.spreadingAngle = 24
        spatter.particleVelocity = 52
        spatter.particleVelocityVariation = 22
        spatter.acceleration = SCNVector3(0, -9.8, 0)
        spatter.particleLifeSpan = 5
        spatter.particleLifeSpanVariation = 1.5
        spatter.particleSize = 4.6
        spatter.particleSizeVariation = 2
        spatter.particleImage = TrailSprites.puff
        spatter.particleColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.16, alpha: 1)
        spatter.blendMode = .additive
        spatter.isLightingEnabled = false
        let cool = CAKeyframeAnimation()
        cool.values = [NSColor(srgbRed: 1, green: 0.75, blue: 0.3, alpha: 1), NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 1),
                       NSColor(srgbRed: 0.6, green: 0.12, blue: 0.04, alpha: 1)]
        cool.keyTimes = [0, 0.4, 1]
        let fadeS = CAKeyframeAnimation(); fadeS.values = [1, 0.9, 0]; fadeS.keyTimes = [0, 0.7, 1]
        spatter.propertyControllers = [.color: SCNParticlePropertyController(animation: cool), .opacity: SCNParticlePropertyController(animation: fadeS)]
        crater.addParticleSystem(spatter)
        // A column of ash boiling up hundreds of metres, glowing orange at its foot, spreading as it slows.
        ash.birthRate = 0
        ash.emitterShape = SCNSphere(radius: 20)
        ash.birthLocation = .volume
        ash.emittingDirection = SCNVector3(0, 1, 0)
        ash.spreadingAngle = 9
        ash.particleVelocity = 44
        ash.particleVelocityVariation = 10
        ash.acceleration = SCNVector3(1.8, -1.2, 0.7)
        ash.particleLifeSpan = 18
        ash.particleLifeSpanVariation = 4
        ash.particleSize = 40
        ash.particleSizeVariation = 12
        ash.particleImage = TrailSprites.puff
        ash.particleColor = NSColor.white
        ash.blendMode = .alpha
        ash.isLightingEnabled = false
        let grow = CAKeyframeAnimation(); grow.values = [0.5, 1.8, 4.0]; grow.keyTimes = [0, 0.3, 1]
        let fade = CAKeyframeAnimation(); fade.values = [0, 0.95, 0.75, 0]; fade.keyTimes = [0, 0.05, 0.6, 1]
        let tint = CAKeyframeAnimation()
        tint.values = [NSColor(srgbRed: 0.55, green: 0.3, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.25, green: 0.21, blue: 0.19, alpha: 1),
                       NSColor(srgbRed: 0.21, green: 0.19, blue: 0.18, alpha: 1)]
        tint.keyTimes = [0, 0.05, 1]
        ash.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade),
                                   .color: SCNParticlePropertyController(animation: tint)]
        crater.addParticleSystem(ash)
    }

    /// Tests and the tour: blow now.
    func debugErupt() { next = 0; primed = true }

    /// `volcano` nil (none near): no eruptions, but bombs already thrown still come down.
    func update(_ dt: Float, volcano: SIMD4<Float>?, floor: Float, bird: SIMD3<Float>, terrain: DinoTerrain) {
        clock += dt
        blew = false; ended = false
        landings.removeAll(keepingCapacity: true)
        if let v = volcano { cycle(dt, v, floor, bird) }
        updateBombs(dt, terrain)
    }

    private func cycle(_ dt: Float, _ v: SIMD4<Float>, _ floor: Float, _ bird: SIMD3<Float>) {
        if at != v {
            at = v; floorY = floor; primed = false
            crater.simdPosition = SIMD3(v.x, floor + 6, v.y)
        }
        let d = simd_length(SIMD2(bird.x - v.x, bird.z - v.y))
        if left <= 0 {
            // It only counts down while you're around to see it, and goes off soon after you first come near.
            if d < v.z * 3 { next -= dt }
            if !primed && d < v.z * 1.6 { primed = true; next = min(next, 7) }
            if next <= 0 { erupt(v, bird) }
        } else {
            left -= dt
            closest = min(closest, d)
            let u = 9 - left
            spatter.birthRate = CGFloat(u < 3.5 ? 300 : max(0, 300 * (1 - (u - 3.5) / 2.5)))
            ash.birthRate = CGFloat(u < 6 ? 40 : max(0, 40 * (1 - (u - 6) / 3)))
            while let first = launches.first, u >= first {
                launches.removeFirst()
                launch(v, bird)
            }
            if left <= 0 {
                left = 0; ended = true
                spatter.birthRate = 0; ash.birthRate = 0
                next = rng.float(55, 100)
            }
        }
    }

    /// The bombs: thrown, falling, smouldering.
    private func updateBombs(_ dt: Float, _ terrain: DinoTerrain) {
        for b in bombs where b.state != 0 {
            b.t += dt
            if b.state == 1 {
                b.vel.y -= 9.8 * dt
                b.vel *= 1 - 0.015 * dt
                b.pos += b.vel * dt
                b.node.simdPosition = b.pos
                b.node.simdOrientation = simd_quatf(angle: b.t * 2.4, axis: b.spin)
                let g = terrain.height(b.pos.x, b.pos.z)
                if b.t > 1, b.pos.y < max(g, 0) + b.r * 0.35 {
                    if g < 0 {
                        // Into the river: gone in a hiss.
                        b.state = 0; b.node.isHidden = true; b.trail.birthRate = 0
                        landings.append((SIMD3(b.pos.x, 0, b.pos.z), b.r * 0.6))
                        continue
                    }
                    b.state = 2; b.t = 0
                    b.pos.y = g + b.r * 0.25
                    b.node.simdPosition = b.pos
                    b.trail.birthRate = 9
                    landings.append((b.pos, b.r))
                }
            } else {
                b.heat(max(0, 1 - b.t / 10))
                b.trail.birthRate = CGFloat(max(0, 9 - b.t * 0.9))
                if b.t > 14 {
                    b.state = 0; b.node.isHidden = true; b.trail.birthRate = 0
                }
            }
        }
    }

    private func erupt(_ v: SIMD4<Float>, _ bird: SIMD3<Float>) {
        left = 9
        blew = true
        birdHit = false
        closest = simd_length(SIMD2(bird.x - v.x, bird.z - v.y))
        let n = Int(rng.float(10, 14.99))
        launches = (0..<n).map { _ in rng.float(0, 4.2) }.sorted()
    }

    private func launch(_ v: SIMD4<Float>, _ bird: SIMD3<Float>) {
        guard let b = bombs.first(where: { $0.state == 0 }) ?? bombs.min(by: { $0.t > $1.t }) else { return }
        // Most fly anywhere; some come your way, to keep you honest.
        var a = rng.float(0, 2 * .pi)
        let toBird = SIMD2(bird.x - v.x, bird.z - v.y)
        if simd_length(toBird) < v.z * 1.8 && rng.float() < 0.35 { a = atan2(toBird.y, toBird.x) + rng.float(-0.35, 0.35) }
        let dir = SIMD3(cos(a), 0, sin(a))
        b.pos = SIMD3(v.x, floorY + 8, v.y) + dir * rng.float(0, 9)
        b.vel = dir * rng.float(10, 44) + SIMD3(0, rng.float(48, 80), 0)
        b.r = rng.float(1.4, 3.0)
        b.node.scale = SCNVector3(b.r, b.r * 0.85, b.r)
        b.spin = simd_normalize(SIMD3(rng.float(-1, 1), rng.float(-1, 1), rng.float(-1, 1)) + SIMD3(0, 0.01, 0))
        b.state = 1; b.t = 0
        b.heat(1)
        b.trail.birthRate = 46
        b.node.simdPosition = b.pos
        b.node.isHidden = false
    }
}
