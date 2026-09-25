import SceneKit
import simd

enum HitKind { case lava, bullet, wall }

struct HazardHit {
    var impulse: SIMD3<Float>
    var coins: Int
    var kind: HitKind
}

/// World-specific systems layered on top of the base flight game. World 1 has none.
protocol WorldRuntime: AnyObject {
    var root: SCNNode { get }
    /// Warning text for the HUD ("Plane on your tail!").
    var threat: String? { get }
    /// Custom spawn (position, yaw), or nil to use the standard coastline search.
    func spawnPoint() -> (SIMD3<Float>, Float)?
    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit]
    /// Called after every physics sub-step; returns impact speed if the bird hit something.
    func constrain(_ flight: FlightModel) -> Float
    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float>
    func autopilot(_ flight: FlightModel) -> (roll: Float, pitch: Float)?
    func configure(_ rings: RingCourse)
}

extension WorldRuntime {
    func spawnPoint() -> (SIMD3<Float>, Float)? { nil }
    func constrain(_ flight: FlightModel) -> Float { 0 }
    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float> { cam }
    func autopilot(_ flight: FlightModel) -> (roll: Float, pitch: Float)? { nil }
}

/// Spacing between repeated penalties so one blast doesn't drain you.
private struct Cooldown {
    var t: Float = 0
    mutating func ready(_ dt: Float) -> Bool { t = max(0, t - dt); return t == 0 }
    mutating func trigger(_ s: Float) { t = s }
}

private func glowMaterial(_ c: NSColor, _ intensity: CGFloat = 1) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = c
    m.diffuse.intensity = intensity
    return m
}

// MARK: - Volcano

/// A lava geyser vent: rumbles and glows, then blasts lava into the air (Volcano).
final class LavaVent {
    let pos: SIMD3<Float>
    let node = SCNNode()
    let crater: SCNMaterial
    let spout = SCNParticleSystem()
    let smoke = SCNParticleSystem()
    var rng: SplitMix64
    enum State { case idle, warn, erupt }
    var state = State.idle
    var timer: Float

    init(pos: SIMD3<Float>, seed: UInt64) {
        self.pos = pos
        rng = SplitMix64(seed: seed)
        timer = rng.float(1, 7)
        crater = glowMaterial(NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 1), 0.6)
        let vent = SCNNode(geometry: SCNCone(topRadius: 2.4, bottomRadius: 6.5, height: 3.5))
        vent.geometry?.materials = [{ let m = SCNMaterial(); m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(srgbRed: 0.16, green: 0.13, blue: 0.13, alpha: 1); m.roughness.contents = 0.9; return m }()]
        vent.position = SCNVector3(0, 0.8, 0)
        node.addChildNode(vent)
        let mouth = SCNNode(geometry: SCNCylinder(radius: 2.3, height: 0.3))
        mouth.geometry?.materials = [crater]
        mouth.position = SCNVector3(0, 2.5, 0)
        node.addChildNode(mouth)

        let dot = makeImage(width: 32, height: 32) { x, y in
            let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
            return SIMD4(1, 1, 1, max(0, 1 - d))
        }
        spout.birthRate = 0
        spout.emitterShape = SCNSphere(radius: 1.6)
        spout.birthLocation = .volume
        spout.emittingDirection = SCNVector3(0, 1, 0)
        spout.spreadingAngle = 7
        spout.particleVelocity = 62
        spout.particleVelocityVariation = 14
        spout.particleLifeSpan = 1.5
        spout.particleSize = 2.2
        spout.particleSizeVariation = 1
        spout.acceleration = SCNVector3(0, -34, 0)
        spout.particleImage = dot
        spout.isLightingEnabled = false
        spout.blendMode = .alpha
        let col = CAKeyframeAnimation()
        col.values = [NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1), NSColor(srgbRed: 1, green: 0.4, blue: 0.08, alpha: 1),
                      NSColor(srgbRed: 0.35, green: 0.08, blue: 0.04, alpha: 0.9)]
        col.keyTimes = [0, 0.4, 1]
        spout.propertyControllers = [.color: SCNParticlePropertyController(animation: col)]
        let spoutNode = SCNNode()
        spoutNode.position = SCNVector3(0, 2.6, 0)
        spoutNode.addParticleSystem(spout)
        node.addChildNode(spoutNode)

        smoke.birthRate = 0
        smoke.emitterShape = SCNSphere(radius: 2)
        smoke.emittingDirection = SCNVector3(0, 1, 0)
        smoke.spreadingAngle = 25
        smoke.particleVelocity = 7
        smoke.particleLifeSpan = 2.5
        smoke.particleSize = 3
        smoke.particleSizeVariation = 1.5
        smoke.particleColor = NSColor(white: 0.25, alpha: 0.55)
        smoke.particleImage = dot
        smoke.isLightingEnabled = false
        smoke.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [0, 0.8, 0]
        fade.keyTimes = [0, 0.3, 1]
        smoke.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        spoutNode.addParticleSystem(smoke)
        node.simdPosition = pos
    }
}


final class VolcanoRuntime: WorldRuntime {
    let root = SCNNode()
    private(set) var threat: String?
    private let terrain: VolcanoTerrain
    private let cell: Float = 150
    private var geysers: [ChunkKey: LavaVent] = [:]
    private var penalty = Cooldown()
    private var lavaPenalty = Cooldown()

    init(terrain: VolcanoTerrain) { self.terrain = terrain }

    /// Test hook: make the geyser nearest to `p` erupt now; returns its vent position.
    func debugEruptNearest(to p: SIMD3<Float>) -> SIMD3<Float>? {
        guard let g = geysers.values.min(by: { simd_distance($0.pos, p) < simd_distance($1.pos, p) }) else { return nil }
        g.state = .warn; g.timer = 0.01
        return g.pos
    }
    var debugCount: Int { geysers.count }

    func configure(_ rings: RingCourse) {
        // Rings sit low, right over geysers, so you fly through the danger zone and have to time it.
        rings.generator = { [weak self] last, dir, first, rng in
            guard let self else { return RingSpec(center: last, normal: dir, radius: 7.5, dir: dir) }
            var d = simd_normalize(SIMD3(dir.x, 0, dir.z))
            if !d.x.isFinite { d = SIMD3(0, 0, -1) }
            let from = SIMD2(last.x, last.z)
            var best: (SIMD3<Float>, Float)?
            let ci = Int(floor(last.x / self.cell)), cj = Int(floor(last.z / self.cell))
            for dj in -3...3 {
                for di in -3...3 {
                    guard let (vent, _) = self.geyserPos(ci + di, cj + dj) else { continue }
                    let to = SIMD2(vent.x, vent.z) - from
                    let dist = simd_length(to)
                    guard dist > (first ? 90 : 120), dist < 330 else { continue }
                    let align = simd_dot(to / dist, SIMD2(d.x, d.z))
                    guard align > 0.45 else { continue }
                    let score = align * 2 - abs(dist - 190) / 120 + rng.float(0, 0.4)
                    if best == nil || score > best!.1 { best = (vent, score) }
                }
            }
            var c: SIMD3<Float>
            if let (vent, _) = best {
                c = vent + SIMD3(rng.float(-4, 4), rng.float(14, 34), rng.float(-4, 4))
            } else {
                let q = simd_quatf(angle: first ? 0 : rng.float(-0.5, 0.5), axis: kUp)
                c = last + q.act(d) * (first ? rng.float(110, 150) : rng.float(150, 210))
                c.y = TerrainShape.ground(c.x, c.z) + rng.float(12, 26)
            }
            // Never bury a ring in a hillside.
            c.y = max(c.y, TerrainShape.ground(c.x, c.z) + 9)
            var n = c - last
            n.y *= 0.5
            n = simd_length(n) > 0.1 ? simd_normalize(n) : d
            let flat = simd_normalize(SIMD3(c.x - last.x, 0, c.z - last.z))
            return RingSpec(center: c, normal: n, radius: 7.5, dir: flat.x.isFinite ? flat : d)
        }
    }

    private func geyserPos(_ i: Int, _ j: Int) -> (SIMD3<Float>, UInt64)? {
        var rng = cellRNG(i, j, 0x6E75)
        guard rng.float() < 0.38 else { return nil }
        let x = (Float(i) + rng.float(0.2, 0.8)) * cell, z = (Float(j) + rng.float(0.2, 0.8)) * cell
        let h = terrain.height(x, z)
        guard h < 220 else { return nil }
        return (SIMD3(x, max(h, 0) - 0.5, z), rng.next())
    }

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        var hits: [HazardHit] = []
        let p = flight.pos
        let ci = Int(floor(p.x / cell)), cj = Int(floor(p.z / cell))
        let r = 4
        // Keep geysers alive around the bird.
        for dj in -r...r {
            for di in -r...r where di * di + dj * dj <= r * r {
                let k = ChunkKey(x: ci + di, z: cj + dj)
                if geysers[k] == nil, let (pos, seed) = geyserPos(k.x, k.z) {
                    let g = LavaVent(pos: pos, seed: seed)
                    root.addChildNode(g.node)
                    geysers[k] = g
                }
            }
        }
        for (k, g) in geysers where (k.x - ci) * (k.x - ci) + (k.z - cj) * (k.z - cj) > (r + 2) * (r + 2) {
            g.node.removeFromParentNode()
            geysers.removeValue(forKey: k)
        }

        var rumble: Float = 0
        threat = nil
        let canHit = penalty.ready(dt)
        for g in geysers.values {
            g.timer -= dt
            let flat = simd_length(SIMD2(p.x - g.pos.x, p.z - g.pos.z))
            let dist = simd_distance(p, g.pos)
            switch g.state {
            case .idle:
                g.crater.diffuse.intensity = 0.6
                if g.timer <= 0 { g.state = .warn; g.timer = 1.6; g.smoke.birthRate = 35 }
            case .warn:
                g.crater.diffuse.intensity = 0.8 + 2.2 * CGFloat(abs(sin(time * 14)))
                rumble += smoothstep(260, 30, dist)
                if flat < 45 && p.y < g.pos.y + 90 { threat = "Geyser about to blow!" }
                if g.timer <= 0 {
                    g.state = .erupt; g.timer = 2.4
                    g.spout.birthRate = 420; g.smoke.birthRate = 0
                    sound?.eruption(smoothstep(400, 20, dist))
                }
            case .erupt:
                g.crater.diffuse.intensity = 3
                rumble += smoothstep(300, 30, dist) * 1.3
                if flat < 9.5 && p.y > g.pos.y - 2 && p.y < g.pos.y + 82 && canHit {
                    var out = SIMD3(p.x - g.pos.x, 0, p.z - g.pos.z)
                    out = simd_length(out) > 0.1 ? simd_normalize(out) : SIMD3(1, 0, 0)
                    hits.append(HazardHit(impulse: out * 13 + SIMD3(0, 15, 0), coins: 5, kind: .lava))
                    penalty.trigger(1.2)
                }
                if g.timer <= 0 { g.state = .idle; g.timer = g.rng.float(2.5, 7); g.spout.birthRate = 0 }
            }
        }
        sound?.setRumble(min(rumble, 1))

        // Hot air over the lava lakes: free lift if you dare fly low over it.
        let overLava = terrain.height(p.x, p.z) < 0
        flight.externalLift = overLava ? 3.4 * smoothstep(170, 30, p.y) : 0

        // Touching the lava burns.
        if lavaPenalty.ready(dt) && overLava && p.y < TerrainShape.waterLevel + 1.4 {
            hits.append(HazardHit(impulse: SIMD3(0, 17, 0) + flight.forward * 4, coins: 5, kind: .lava))
            lavaPenalty.trigger(1.5)
        }
        return hits
    }
}

// MARK: - Caves

final class CaveRuntime: WorldRuntime {
    let root = SCNNode()
    private(set) var threat: String?
    private let terrain: CaveTerrain
    private let lantern = SCNNode()
    private var pendingHits: [HazardHit] = []
    private var penalty = Cooldown()
    private var lastDt: Float = 1.0 / 60
    private var quiet = false

    /// Wall collisions for birds other than the player (bots): no penalties or sounds.
    func constrainQuietly(_ flight: FlightModel) {
        quiet = true
        _ = constrain(flight)
        quiet = false
    }

    init(terrain: CaveTerrain) {
        self.terrain = terrain
        let light = SCNLight()
        light.type = .omni
        light.color = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.62, alpha: 1)
        light.intensity = 1000
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = 90
        light.attenuationFalloffExponent = 1.4
        light.categoryBitMask = 2      // lights the cave walls, not the bird
        lantern.light = light
        root.addChildNode(lantern)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.color = NSColor(srgbRed: 0.35, green: 0.55, blue: 0.58, alpha: 1)
        amb.light?.intensity = 360
        root.addChildNode(amb)
    }

    func configure(_ rings: RingCourse) {
        rings.generator = { [terrain] last, dir, first, rng in
            var p = SIMD2(last.x, last.z)
            var d = SIMD2(dir.x, dir.z)
            if simd_length(d) < 0.1 { d = SIMD2(0, -1) }
            d = simd_normalize(d)
            let dist = first ? rng.float(45, 60) : rng.float(55, 85)
            var travelled: Float = 0
            while travelled < dist {
                d = terrain.tangent(p.x, p.y, prefer: d)
                p = terrain.recenter(p + d * 4)
                travelled += 4
            }
            let s = terrain.sample(p.x, p.y)
            let c = SIMD3(p.x, (s.floor + s.ceiling) * 0.5, p.y)
            var n = c - last
            if simd_length(n) < 0.1 { n = SIMD3(d.x, 0, d.y) }
            n = simd_normalize(n)
            let g = simd_length(terrain.gradient(p.x, p.y))
            let halfWidth = g > 1e-6 ? s.w / g : 20
            let radius = clamp(min(halfWidth * 0.6, (s.ceiling - s.floor) * 0.38), 3.2, 7.5)
            return RingSpec(center: c, normal: n, radius: radius, dir: SIMD3(d.x, 0, d.y))
        }
    }

    func spawnPoint() -> (SIMD3<Float>, Float)? {
        var best = SIMD2<Float>(0, 0), bestScore: Float = -1e9
        for j in stride(from: -600, through: 600, by: 24) {
            for i in stride(from: -600, through: 600, by: 24) {
                let x = Float(i), z = Float(j)
                let s = terrain.sample(x, z)
                guard s.open > 0.9 else { continue }
                let score = s.wide * 2 + (s.ceiling - s.floor) * 0.02 - simd_length(SIMD2(x, z)) * 0.0005
                if score > bestScore { bestScore = score; best = SIMD2(x, z) }
            }
        }
        best = terrain.recenter(best)
        let s = terrain.sample(best.x, best.y)
        let t = terrain.tangent(best.x, best.y, prefer: SIMD2(0, -1))
        return (SIMD3(best.x, (s.floor + s.ceiling) * 0.5, best.y), atan2(-t.x, -t.y))
    }

    /// Keep the bird inside the tunnel: slide along walls, bump off the ceiling.
    func constrain(_ flight: FlightModel) -> Float {
        var impact: Float = 0
        var p = flight.pos
        var s = terrain.sample(p.x, p.z)
        if s.ceiling - s.floor < 3 || s.open < 0.02 {
            let g = terrain.gradient(p.x, p.z)
            if simd_length(g) > 1e-7 {
                let inward = simd_normalize(-g * (s.n > 0 ? 1 : -1))
                let f = flight.forward
                let flat = SIMD2(f.x, f.z)
                let into = max(0, -simd_dot(flat, inward)) * flight.speed
                impact = into
                for _ in 0..<8 {
                    p.x += inward.x * 0.8; p.z += inward.y * 0.8
                    s = terrain.sample(p.x, p.z)
                    if s.ceiling - s.floor >= 3.5 && s.open > 0.05 { break }
                }
                // Turn to slide along the wall.
                var slide = flat - inward * min(0, simd_dot(flat, inward)) * 1.3
                if simd_length(slide) < 0.05 { slide = terrain.tangent(p.x, p.z, prefer: flat) }
                slide = simd_normalize(slide)
                flight.yaw = atan2(-slide.x, -slide.y)
                flight.speed *= into > 6 ? 0.8 : 0.96
            }
        }
        let top = s.ceiling - 1.2
        if p.y > top {
            impact = max(impact, max(0, flight.forward.y * flight.speed))
            p.y = top
            flight.pitch = min(flight.pitch, -0.12)
        }
        let bottom = s.floor + 0.9
        if p.y < bottom { p.y = bottom }
        flight.pos = p
        if impact > 9 && penalty.t == 0 && !quiet {
            pendingHits.append(HazardHit(impulse: .zero, coins: 2, kind: .wall))
            penalty.trigger(1.5)
        }
        return impact
    }

    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float> {
        func inside(_ c: SIMD3<Float>) -> Bool {
            let s = terrain.sample(c.x, c.z)
            return s.open > 0.25 && c.y > s.floor + 1.2 && c.y < s.ceiling - 1.2
        }
        for t in stride(from: Float(1), through: 0.15, by: -0.12) {
            let c = bird + (cam - bird) * t
            if inside(c) { return c }
        }
        return bird + (cam - bird) * 0.15
    }

    func autopilot(_ flight: FlightModel) -> (roll: Float, pitch: Float)? {
        let p = flight.pos
        let f = flight.forward
        let ahead = SIMD2(p.x, p.z) + simd_normalize(SIMD2(f.x, f.z)) * 12
        let target = terrain.recenter(ahead)
        let to = target - SIMD2(p.x, p.z)
        let fwd = simd_normalize(SIMD2(f.x, f.z))
        let cross = fwd.x * to.y - fwd.y * to.x
        let s = terrain.sample(target.x, target.y)
        let err = (s.floor + s.ceiling) * 0.5 - p.y
        return (clamp(cross * 0.12, -0.9, 0.9), clamp(err / 8, -0.6, 0.6))
    }

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        _ = penalty.ready(dt)
        lastDt = dt
        lantern.simdPosition = flight.pos + SIMD3(0, 0.3, 0) + flight.forward * 5
        let ahead = flight.pos + flight.forward * 30
        let s = terrain.sample(ahead.x, ahead.z)
        threat = (s.ceiling - s.floor < 9 && s.open > 0) ? "Tight squeeze ahead" : nil
        let hits = pendingHits
        pendingHits.removeAll()
        return hits
    }
}

// MARK: - Dogfight

final class DogfightRuntime: WorldRuntime {
    let root = SCNNode()
    private(set) var threat: String?
    private var planes: [Plane] = []
    private var bullets: [Bullet] = []
    private var bulletPool: [SCNNode] = []
    private var rng = SplitMix64(seed: 1914)
    private var penalty = Cooldown()
    private var elapsed: Float = 0
    private(set) var shotsFired = 0
    /// Where shots came from relative to the bird: front, side, back (test stats).
    private(set) var shotDirs = [0, 0, 0]
    /// Test hook: position of the nearest plane.
    func debugNearestPlane(to p: SIMD3<Float>) -> SIMD3<Float>? { planes.min { simd_distance($0.pos, p) < simd_distance($1.pos, p) }?.pos }

    private final class Plane {
        let model: BiplaneNode
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        var bank: Float = 0
        var breakaway: Float = 0
        var breakDir = SIMD3<Float>(1, 0, 0)
        var cooldown: Float
        var burst = 0
        var burstTimer: Float = 0
        var lockOn: Float = 0
        /// Attack setup: fly to a point ahead of / beside the player first, so most passes come from
        /// the front or side where you can see the plane. nil = attacking.
        var setup: (yaw: Float, dist: Float, height: Float)?
        var setupTimer: Float = 0
        init(model: BiplaneNode, pos: SIMD3<Float>, vel: SIMD3<Float>, cooldown: Float) {
            self.model = model; self.pos = pos; self.vel = vel; self.cooldown = cooldown
        }
    }

    private struct Bullet {
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        var life: Float
        var node: SCNNode
        var whizzed = false
    }

    init() {}

    func configure(_ rings: RingCourse) {
        rings.params.minAboveGround = 55...100
        rings.params.maxAboveGround = 260
        rings.params.spacing = 170...250
        rings.params.sway = 7
    }

    private func spawnPlane(near p: SIMD3<Float>, forward f: SIMD3<Float>, index: Int) -> Plane {
        let livery = BiplaneNode.liveries[index % BiplaneNode.liveries.count]
        let model = BiplaneNode(livery: livery)
        root.addChildNode(model.node)
        let flat = simd_normalize(SIMD3(f.x, 0, f.z))
        let side = SIMD3(-flat.z, 0, flat.x) * (rng.float() < 0.5 ? -1 : 1)
        let pos = p + flat * rng.float(300, 480) + side * rng.float(100, 250) + SIMD3(0, rng.float(25, 70), 0)
        let vel = simd_normalize(p - pos) * 40
        let plane = Plane(model: model, pos: pos, vel: vel, cooldown: rng.float(2, 5))
        plane.setup = (rng.float(-1.2, 1.2), rng.float(260, 340), rng.float(10, 35))
        plane.setupTimer = 9
        return plane
    }

    private func bulletNode() -> SCNNode {
        if let n = bulletPool.popLast() { n.isHidden = false; return n }
        let g = SCNBox(width: 0.14, height: 0.14, length: 2.2, chamferRadius: 0.05)
        g.materials = [glowMaterial(NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 1), 2.5)]
        let n = SCNNode(geometry: g)
        n.castsShadow = false
        root.addChildNode(n)
        return n
    }

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        var hits: [HazardHit] = []
        elapsed += dt
        let me = flight.pos
        let myVel = flight.velocity
        let myFwd = flight.forward
        let right = simd_normalize(simd_cross(myFwd, kUp))

        // Two planes to start, a third joins after a while.
        let wanted = elapsed > 25 ? 3 : 2
        while planes.count < wanted { planes.append(spawnPlane(near: me, forward: myFwd, index: planes.count)) }

        threat = nil
        var engines: [(Float, Float, Float)] = []
        for p in planes {
            let to = me - p.pos
            let dist = simd_length(to)
            if dist > 1400 {   // lost us: come back around from ahead
                let fresh = spawnPlane(near: me, forward: myFwd, index: 0)
                p.pos = fresh.pos; p.vel = fresh.vel
                fresh.model.node.removeFromParentNode()
                continue
            }
            // Steering: set up an attack run (usually ahead or to the side), turn in, fire, peel off.
            var desired: SIMD3<Float>
            let myFlat = simd_normalize(SIMD3(myFwd.x, 0, myFwd.z))
            if p.breakaway > 0 {
                p.breakaway -= dt
                desired = p.breakDir
                if p.breakaway <= 0 {
                    // Next run: 75% from the front / sides, 25% straight from wherever (often behind).
                    p.setup = rng.float() < 0.75 ? (rng.float(-1.2, 1.2), rng.float(260, 340), rng.float(10, 35)) : nil
                    p.setupTimer = 9
                }
            } else if let s = p.setup {
                let wp = me + simd_quatf(angle: s.yaw, axis: kUp).act(myFlat) * s.dist + SIMD3(0, s.height, 0)
                desired = simd_normalize(wp - p.pos)
                p.setupTimer -= dt
                if simd_distance(wp, p.pos) < 70 || p.setupTimer <= 0 { p.setup = nil }
            } else {
                let lead = me + myVel * min(dist / 170, 1.5)
                desired = simd_normalize(lead - p.pos)
                // Peel off when close or once we've flown past the bird.
                if dist < 45 || (dist < 150 && simd_dot(simd_normalize(p.vel), to / max(dist, 1)) < -0.2) {
                    p.breakaway = rng.float(2.5, 3.5)
                    let side = simd_normalize(simd_cross(simd_normalize(p.vel), kUp)) * (rng.float() < 0.5 ? -1 : 1)
                    p.breakDir = simd_normalize(side + SIMD3(0, 0.35, 0) + simd_normalize(p.vel) * 0.5)
                }
            }
            let ground = TerrainShape.ground(p.pos.x, p.pos.z)
            if p.pos.y < ground + 40 { desired.y = max(desired.y, 0.45); desired = simd_normalize(desired) }
            let speed: Float = p.breakaway > 0 || p.setup != nil ? 48 : 40
            let cur = simd_normalize(p.vel)
            let maxTurn: Float = 0.9 * dt
            let ang = acos(clamp(simd_dot(cur, desired), -1, 1))
            var newDir = desired
            if ang > maxTurn {
                let axis = simd_cross(cur, desired)
                if simd_length(axis) > 1e-5 { newDir = simd_quatf(angle: maxTurn, axis: simd_normalize(axis)).act(cur) }
            }
            let turnSign = simd_dot(simd_cross(cur, newDir), kUp)
            p.bank += (clamp(-turnSign / max(dt, 1e-3) * 1.4, -1.1, 1.1) - p.bank) * approach(3, dt)
            p.vel = newDir * speed
            p.pos += p.vel * dt
            let yaw = atan2(-newDir.x, -newDir.z)
            let pitch = asin(clamp(newDir.y, -1, 1))
            p.model.node.simdPosition = p.pos
            p.model.node.simdOrientation = simd_quatf(angle: yaw, axis: kUp) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) *
                simd_quatf(angle: -p.bank, axis: SIMD3(0, 0, 1))

            // Guns: fire bursts when lined up.
            p.cooldown -= dt
            let aim = simd_dot(newDir, to / max(dist, 1))
            // Hold the aim for a moment before firing — that's the player's window to dodge.
            p.lockOn = (aim > 0.97 && dist < 260 && p.breakaway <= 0 && p.setup == nil) ? p.lockOn + dt : 0
            if p.burst == 0 && p.cooldown <= 0 && p.lockOn > 1.0 {
                p.burst = 6; p.burstTimer = 0
            }
            if p.burst > 0 {
                p.burstTimer -= dt
                if p.burstTimer <= 0 {
                    p.burst -= 1
                    p.burstTimer = 0.09
                    let spread = SIMD3(rng.float(-1, 1), rng.float(-1, 1), rng.float(-1, 1)) * 0.026
                    let dir = simd_normalize(simd_normalize(me + myVel * (dist / 180) - p.pos) + spread)
                    bullets.append(Bullet(pos: p.pos + newDir * 3, vel: dir * 180 + p.vel * 0.3, life: 2, node: bulletNode()))
                    shotsFired += 1
                    let rel = simd_dot(simd_normalize(SIMD3(myFwd.x, 0, myFwd.z)), simd_normalize(p.pos - me))
                    shotDirs[rel > 0.5 ? 0 : (rel < -0.5 ? 2 : 1)] += 1
                    let pan = clamp(simd_dot(simd_normalize(p.pos - me), right), -1, 1)
                    sound?.gunshot(gain: smoothstep(500, 30, dist), pan: pan)
                    if p.burst == 0 { p.cooldown = rng.float(7, 12); p.lockOn = 0 }
                }
            }
            if dist < 300 && (p.lockOn > 0.2 || p.burst > 0) {
                let rel = -to / max(dist, 1)
                let ahead = simd_dot(myFlat, rel), side = simd_dot(right, rel)
                if ahead < -0.5 { threat = "Plane on your tail!" }
                else if ahead > 0.5 { threat = "Plane ahead!" }
                else { threat = side > 0 ? "Plane on your right!" : "Plane on your left!" }
            }
            let closing = simd_dot(p.vel - myVel, simd_normalize(to))
            let pan = clamp(simd_dot(simd_normalize(p.pos - me), right), -1, 1)
            engines.append((95 * (1 + closing / 340), smoothstep(700, 40, dist), pan))
        }
        sound?.setEngines(engines)

        // Bullets
        let canHit = penalty.ready(dt)
        var hitThisFrame = false
        for i in bullets.indices.reversed() {
            var b = bullets[i]
            let prev = b.pos
            b.pos += b.vel * dt
            b.life -= dt
            b.node.simdPosition = b.pos
            b.node.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(b.vel))
            // Closest approach of this step's segment to the bird.
            let seg = b.pos - prev
            let t = clamp(simd_dot(me - prev, seg) / max(simd_length_squared(seg), 1e-4), 0, 1)
            let d = simd_distance(prev + seg * t, me)
            if d < 1.4 && canHit && !hitThisFrame {
                hits.append(HazardHit(impulse: simd_normalize(b.vel) * 17 + SIMD3(0, 6, 0), coins: 3, kind: .bullet))
                penalty.trigger(2.5)
                hitThisFrame = true
                b.life = 0
            } else if d < 7 && !b.whizzed {
                b.whizzed = true
                sound?.whiz(gain: smoothstep(7, 1.5, d))
            }
            if b.life <= 0 {
                b.node.isHidden = true
                bulletPool.append(b.node)
                bullets.remove(at: i)
            } else {
                bullets[i] = b
            }
        }
        return hits
    }
}
