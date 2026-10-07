import SceneKit
import simd

/// Dino Valley's world systems: the dinosaurs (and bumping into them), rings that thread under the long necks, the
/// volcano's plume, dust from the fights, the jungle's sounds and the things worth finding.
final class DinoRuntime: WorldRuntime {
    let root = SCNNode()
    let terrain: DinoTerrain
    let life: DinoLife
    private(set) var threat: String?
    private var notices: [String] = []
    private var rewards: [WorldReward] = []
    private var pendingHits: [HazardHit] = []
    private var penalty: Float = 0
    private var quiet = false
    private var shake: Float = 0
    private var autopilotTimer: Float = 0
    private var autopilotTarget: Float = 60
    private let plume = SCNNode()
    private var plumeAt: SIMD4<Float>?
    /// Dust puffs: a few looping emitters switched on for a moment where something hits. (One-shot SceneKit particle
    /// systems added mid-game can balloon into screen-filling sheets; switching looping ones on and off is solid.)
    private var dustPool: [(node: SCNNode, ps: SCNParticleSystem, off: Float)] = []
    private var dustNext = 0
    private var clock: Float = 0
    private var foundCrater = false, foundEruption = false
    /// The volcano going off now and then (lava bombs and all).
    let eruption = DinoEruption()
    private var foundSkeleton = false, foundNest = false, foundFall = false
    private var nestsSeen = Set<Int64>()
    private var landmarkT: Float = 0
    private var nearSkeletons: [DinoSkeleton] = []
    private var nearNests: [DinoNest] = []
    private var nearFalls: [DinoWaterfall] = []
    private var fallSound: Float = 0
    /// Time spent on the creatures (tests read it).
    static var lifeTime: Double = 0
    static var lifeWorst: Double = 0
    private var lavaPenalty: Float = 0

    init(terrain: DinoTerrain) {
        self.terrain = terrain
        life = DinoLife(terrain: terrain)
        root.addChildNode(life.root)
        root.addChildNode(plume)
        root.addChildNode(eruption.root)
        for _ in 0..<8 {
            let n = SCNNode()
            n.simdPosition = SIMD3(0, -500, 0)
            let ps = DinoRuntime.dust()
            n.addParticleSystem(ps)
            dustPool.append((n, ps, 0))
            root.addChildNode(n)
        }
    }

    // MARK: Effects

    private static let softDot: CGImage = makeImage(width: 64, height: 64) { x, y in
        let d = simd_length(SIMD2(Float(x) - 31.5, Float(y) - 31.5)) / 32
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, a * a * (3 - 2 * a))
    }

    private static func smoke() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 5
        s.emitterShape = SCNSphere(radius: 22)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0.15, 1, 0.08)
        s.spreadingAngle = 16
        s.particleVelocity = 13
        s.particleVelocityVariation = 4
        s.particleLifeSpan = 24
        s.particleLifeSpanVariation = 5
        s.particleSize = 36
        s.particleSizeVariation = 10
        s.acceleration = SCNVector3(2.2, 0.8, 0.9)
        s.particleImage = softDot
        s.particleColor = NSColor(srgbRed: 0.36, green: 0.34, blue: 0.33, alpha: 0.6)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        s.sortingMode = .distance
        let grow = CAKeyframeAnimation()
        grow.values = [0.5, 1.5, 3.0]
        grow.keyTimes = [0, 0.35, 1]
        let fade = CAKeyframeAnimation()
        fade.values = [0, 0.75, 0.5, 0]
        fade.keyTimes = [0, 0.08, 0.6, 1]
        s.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
        s.warmupDuration = 30
        return s
    }

    private static func dust() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 0
        s.emitterShape = SCNSphere(radius: 1.5)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 75
        s.particleVelocity = 6
        s.particleVelocityVariation = 3
        s.particleLifeSpan = 2.6
        s.particleLifeSpanVariation = 0.8
        s.particleSize = 2.2
        s.particleSizeVariation = 0.8
        s.acceleration = SCNVector3(0, -0.6, 0)
        s.dampingFactor = 0.6
        s.particleImage = softDot
        s.particleColor = NSColor(srgbRed: 0.62, green: 0.56, blue: 0.42, alpha: 0.7)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        let grow = CAKeyframeAnimation()
        grow.values = [0.6, 2.2]
        grow.keyTimes = [0, 1]
        let fade = CAKeyframeAnimation()
        fade.values = [0.8, 0.5, 0]
        fade.keyTimes = [0, 0.5, 1]
        s.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
        return s
    }

    /// Test hook: a dust burst somewhere.
    func debugBurst(_ p: SIMD3<Float>, _ size: Float) { burst(p, size) }

    private static let dustColor = NSColor(srgbRed: 0.62, green: 0.56, blue: 0.42, alpha: 0.7)
    private static let ashColor = NSColor(srgbRed: 0.24, green: 0.22, blue: 0.21, alpha: 0.8)

    private func burst(_ p: SIMD3<Float>, _ size: Float, ash: Bool = false) {
        let k = dustNext
        dustNext = (dustNext + 1) % dustPool.count
        dustPool[k].node.simdPosition = SIMD3(p.x, max(terrain.height(p.x, p.z), 0) + 0.6, p.z)
        dustPool[k].ps.particleSize = CGFloat(2.2 * size)
        dustPool[k].ps.particleColor = ash ? DinoRuntime.ashColor : DinoRuntime.dustColor
        dustPool[k].ps.birthRate = CGFloat(160 + 140 * size)
        dustPool[k].off = clock + 0.18
    }

    private func settleDust() {
        for k in dustPool.indices where dustPool[k].off > 0 && clock >= dustPool[k].off {
            dustPool[k].ps.birthRate = 0
            dustPool[k].off = 0
        }
    }

    // MARK: Start, rings

    func spawnPoint() -> (SIMD3<Float>, Float)? {
        // Near the middle of the valley system, facing a herd of Brachiosaurus across a meadow.
        let c = DinoLife.cell
        var herd: SIMD2<Float>?
        search: for r in 0..<8 {
            for j in -r...r {
                for i in -r...r where max(abs(i), abs(j)) == r {
                    if let (k, p) = life.groupKind(near: (Float(i) + 0.5) * c, (Float(j) + 0.5) * c), k == .longneck { herd = p; break search }
                }
            }
        }
        guard let h = herd else { return nil }
        var best: (SIMD2<Float>, Float)?
        for k in 0..<36 {
            let a = Float(k) / 36 * 2 * .pi
            let s = h + SIMD2(cos(a), sin(a)) * 190
            let hs = terrain.height(s.x, s.y)
            guard hs > 1 && hs < 30 else { continue }
            var hmax: Float = -1e9
            for q in 1...8 {
                let t = s + (h - s) * (Float(q) / 8)
                hmax = max(hmax, terrain.height(t.x, t.y))
            }
            // A clear view across low ground, and room behind to have come from.
            let behind = terrain.height(s.x + cos(a) * 120, s.y + sin(a) * 120)
            let score = -hmax - max(0, behind - 30) * 0.5
            if best == nil || score > best!.1 { best = (s, score) }
        }
        guard let (s, _) = best else { return nil }
        let y = max(terrain.height(s.x, s.y), 0) + 36
        return (SIMD3(s.x, y, s.y), atan2(-(h.x - s.x), -(h.y - s.y)))
    }

    func configure(_ rings: RingCourse) {
        // Down the valleys, low over the meadows and the river — and now and then right under a Brachiosaurus's neck.
        rings.generator = { [weak self] last, dir, first, rng in
            guard let self else { return RingSpec(center: last, normal: dir, radius: 7.5, dir: dir) }
            var d = simd_normalize(SIMD3(dir.x, 0, dir.z))
            if !d.x.isFinite { d = SIMD3(0, 0, -1) }
            var best: (SIMD3<Float>, Float, Float)?
            let dist = first ? rng.float(110, 150) : rng.float(150, 195)
            for k in -6...6 {
                let a = Float(k) * 0.13 + rng.float(-0.04, 0.04)
                let nd = simd_quatf(angle: a, axis: kUp).act(d)
                var hmax: Float = -1e9
                for s in 1...6 {
                    let q = last + nd * (dist * Float(s) / 6)
                    hmax = max(hmax, self.terrain.height(q.x, q.z))
                }
                let c = last + nd * dist
                let g = max(self.terrain.height(c.x, c.z), 0)
                let score = -g * 0.04 - max(0, hmax - (last.y - 6)) * 0.25 - abs(a) * 0.7 + rng.float(0, 0.3)
                if best == nil || score > best!.1 { best = (c, score, hmax) }
            }
            var c = best!.0
            let g = max(self.terrain.height(c.x, c.z), 0)
            c.y = g + rng.float(13, 30)
            c.y = max(c.y, best!.2 + 9)
            if !first && rng.float() < 0.35 {
                // Under a long neck, if one's grazing roughly ahead.
                let ahead = self.life.dinos.filter { n in
                    guard n.kind == .longneck, n.sp.neck.count > 2, n.mats.count == n.sp.rig.bones.count else { return false }
                    let to = SIMD3(n.pos.x - last.x, 0, n.pos.y - last.z)
                    let l = simd_length(to)
                    return l > 90 && l < 260 && simd_dot(to / l, d) > 0.55
                }.min { simd_distance($0.position, c) < simd_distance($1.position, c) }
                if let n = ahead {
                    let mid = n.mats[n.sp.neck[2]].origin
                    let under = (mid.y - n.ground) * 0.45
                    if under > 6 { c = SIMD3(mid.x, n.ground + under, mid.z) }
                }
            }
            var nrm = c - last
            nrm.y *= 0.5
            nrm = simd_length(nrm) > 0.1 ? simd_normalize(nrm) : d
            let flat = simd_normalize(SIMD3(c.x - last.x, 0, c.z - last.z))
            return RingSpec(center: c, normal: nrm, radius: 7.5, dir: flat.x.isFinite ? flat : d)
        }
    }

    // MARK: Update

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        clock += dt
        penalty = max(0, penalty - dt)
        lavaPenalty = max(0, lavaPenalty - dt)
        let t0 = CACurrentMediaTime()
        life.update(dt: dt, player: flight)
        DinoRuntime.lifeTime += CACurrentMediaTime() - t0
        DinoRuntime.lifeWorst = max(DinoRuntime.lifeWorst, CACurrentMediaTime() - t0)
        notices += life.notices
        rewards += life.rewards
        life.rewards.removeAll()
        threat = life.threat ?? life.pteros.threat
        shake = max(shake, life.quake)
        settleDust()
        for (p, s) in life.dust { burst(p, s) }
        if let sound { mix(sound, flight) }
        var hits = life.hits + pendingHits
        pendingHits.removeAll()
        landmarks(dt, flight)
        // The volcano: its plume, a rumble as you get close, hot air over the crater, and the crater itself.
        flight.externalLift = 0
        if let v = terrain.nearestVolcano(flight.pos.x, flight.pos.z) {
            let floorY = terrain.craterFloor(v)
            if plumeAt != v {
                // Start a fresh plume (warmed up in place) over this volcano.
                plumeAt = v
                plume.removeAllParticleSystems()
                plume.simdPosition = SIMD3(v.x, floorY + 26, v.y)
                plume.addParticleSystem(DinoRuntime.smoke())
            }
            let d = simd_length(SIMD2(flight.pos.x - v.x, flight.pos.z - v.y))
            eruption.update(dt, volcano: v, floor: floorY, bird: flight.pos, terrain: terrain)
            erupting(v, d, flight, sound, &hits)
            sound?.setRumble(smoothstep(v.z * 1.2, v.z * 0.12, d) * 0.55 + (eruption.left > 0 ? 0.45 * smoothstep(v.z * 3, v.z * 0.2, d) : 0))
            if d < v.z * 0.14 { flight.externalLift = 3.6 * smoothstep(floorY + 220, floorY + 10, flight.pos.y) }
            if !foundCrater && d < v.z * 0.12 && flight.pos.y < floorY + v.w * 0.13 + 6 {
                foundCrater = true
                rewards.append(WorldReward(id: "dino.crater", title: "You flew into the volcano!", coins: 50, once: true))
            }
            if d < v.z * 0.075 && flight.pos.y < floorY + 3.2 && lavaPenalty == 0 {
                hits.append(HazardHit(impulse: SIMD3(0, 17, 0) + flight.forward * 4, coins: 5, kind: .lava))
                lavaPenalty = 1.5
                notices.append("Ouch — lava!")
            }
        } else {
            eruption.update(dt, volcano: nil, floor: 0, bird: flight.pos, terrain: terrain)
        }
        return hits
    }

    /// The eruption's effects on the bird and the valley: the boom, the shake, bombs coming down, the herds running.
    private func erupting(_ v: SIMD4<Float>, _ d: Float, _ flight: FlightModel, _ sound: SoundEngine?, _ hits: inout [HazardHit]) {
        let e = eruption
        let vc = SIMD2(v.x, v.y)
        if e.blew {
            let g = smoothstep(v.z * 3.2, v.z * 0.3, d)
            sound?.eruption(max(0.3, g))
            shake = max(shake, 0.25 + 0.75 * g)
            if d < v.z * 2.8 { notices.append("The volcano is erupting!") }
            for dino in life.dinos where dino.fight == nil && simd_distance(dino.pos, vc) < v.z * 1.5 { life.flee(dino, from: vc, for: 12) }
        }
        if e.left > 0 && threat == nil && d < v.z * 1.3 { threat = "Lava bombs!" }
        for (q, size) in e.landings {
            burst(q, size * 0.9, ash: true)
            let dd = simd_distance(q, flight.pos)
            if dd < 140 {
                shake = max(shake, 0.45 * smoothstep(140, 10, dd))
                let right = SIMD3(cos(flight.yaw), 0, -sin(flight.yaw))
                sound?.dinoCall(.thud, gain: smoothstep(320, 10, dd), pan: dd > 1 ? clamp(simd_dot((q - flight.pos) / dd, right), -1, 1) : 0, pitch: 0.6)
            }
        }
        if lavaPenalty == 0 {
            for b in e.bombs where b.state == 1 && simd_distance(b.pos, flight.pos) < b.r + 1.4 {
                var away = flight.pos - b.pos
                away = simd_length(away) > 0.1 ? simd_normalize(away) : kUp
                hits.append(HazardHit(impulse: away * 14 + SIMD3(0, 8, 0), coins: 5, kind: .lava))
                lavaPenalty = 1.5
                e.birdHit = true
                notices.append("Ouch — lava bomb!")
                break
            }
        }
        if e.ended && !foundEruption && !e.birdHit && e.closest < v.z * 0.5 {
            foundEruption = true
            rewards.append(WorldReward(id: "dino.eruption", title: "You braved the eruption!", coins: 50, once: true))
        }
    }

    /// Skeletons to fly through, nests to find, waterfalls to fly through (and hear).
    private func landmarks(_ dt: Float, _ flight: FlightModel) {
        let p = flight.pos
        landmarkT -= dt
        if landmarkT <= 0 {
            landmarkT = 0.5
            nearSkeletons = DinoLandmarks.skeletons(near: p, terrain).filter { simd_distance($0.center, p) < 400 }
            nearNests = DinoLandmarks.nests(near: p, terrain).filter { simd_distance($0.pos, p) < 300 }
            nearFalls = DinoLandmarks.waterfalls(near: p, terrain)
        }
        let g = terrain.height(p.x, p.z)
        for s in nearSkeletons where !foundSkeleton && s.inside(p, ground: g) {
            foundSkeleton = true
            rewards.append(WorldReward(id: "dino.skeleton", title: "You flew through a giant skeleton!", coins: 40, once: true))
        }
        for n in nearNests where simd_length(SIMD2(p.x - n.pos.x, p.z - n.pos.z)) < 7 && p.y - n.pos.y < 10 && !nestsSeen.contains(n.id) {
            nestsSeen.insert(n.id)
            if !foundNest {
                foundNest = true
                rewards.append(WorldReward(id: "dino.nest", title: "You found a dinosaur nest!", coins: 40, once: true))
            } else {
                rewards.append(WorldReward(id: "dino.nest.more", title: "Another nest", coins: 5, once: false))
            }
        }
        var fall: Float = 0
        for w in nearFalls {
            let d = min(simd_distance(p, w.foot), simd_distance(p, (w.lip + w.foot) * 0.5))
            fall = max(fall, smoothstep(260, 20, d))
            if !foundFall && w.contains(p) {
                foundFall = true
                rewards.append(WorldReward(id: "dino.waterfall", title: "You flew through a waterfall!", coins: 30, once: true))
            }
        }
        fallSound = fall
    }

    /// Creature calls, footfalls and the jungle, mixed for where the bird is.
    private func mix(_ sound: SoundEngine, _ flight: FlightModel) {
        let ear = life.camera == .zero ? flight.pos : life.camera
        let right = SIMD3(cos(flight.yaw), 0, -sin(flight.yaw))
        for c in life.calls {
            let to = c.at - ear
            let d = simd_length(to)
            let range: Float = c.kind == .thud || c.kind == .stomp ? 320 : (c.kind == .roar || c.kind == .bellow ? 1500 : 700)
            let g = c.loud * pow(smoothstep(range, 0, d), 1.6)
            guard g > 0.02 else { continue }
            let pan = d > 1 ? clamp(simd_dot(to / d, right), -1, 1) : 0
            sound.dinoCall(c.kind, gain: g, pan: pan, pitch: c.pitch)
        }
        // Insects and birdsong down in the valleys; the river when you're over it.
        let g = terrain.height(flight.pos.x, flight.pos.z)
        let low = smoothstep(220, 40, flight.pos.y - max(g, 0))
        let water = max(smoothstep(4, -1, g) * smoothstep(60, 5, flight.pos.y), fallSound * 1.3)
        sound.setJungle(low * 0.8 + 0.2, water: water)
    }

    func drainNotices() -> [String] { defer { notices.removeAll() }; return notices }
    func drainRewards() -> [WorldReward] { defer { rewards.removeAll() }; return rewards }
    func drainShake() -> Float { defer { shake = 0 }; return shake }
    func setCamera(_ p: SIMD3<Float>) { life.camera = p }

    // MARK: Collisions

    func constrainQuietly(_ flight: FlightModel) {
        quiet = true
        _ = constrain(flight)
        quiet = false
    }

    /// Dinosaurs are solid: bounce off bodies, necks, legs and tails.
    func constrain(_ flight: FlightModel) -> Float {
        let r: Float = 0.9
        var impact: Float = 0
        var wallN = SIMD3<Float>(0, 0, 0)
        let p0 = flight.pos
        for d in life.dinos where d.mats.count == d.sp.rig.bones.count {
            let reach = d.sp.length * d.scale * 0.75 + 4
            guard abs(d.pos.x - p0.x) < reach, abs(d.pos.y - p0.z) < reach else { continue }
            for c in d.sp.capsules {
                let m = d.mats[c.bone]
                guard let push = Collide.capsule(flight.pos, r, a: m.point(c.a), b: m.point(c.b), radius: c.r * d.scale) else { continue }
                flight.pos += push
                let n = simd_normalize(push)
                impact = max(impact, Collide.response(flight, n))
                if abs(n.y) <= 0.7 { wallN = n }
                if !quiet { life.bumped(d, by: flight.pos) }
            }
        }
        // Fossil skeletons are solid too.
        for s in nearSkeletons where simd_distance(s.center, flight.pos) < 70 {
            for c in s.caps {
                guard let push = c.push(flight.pos, r) else { continue }
                flight.pos += push
                let n = simd_normalize(push)
                impact = max(impact, Collide.response(flight, n))
                if abs(n.y) <= 0.7 { wallN = n }
            }
        }
        if impact > 9 && penalty == 0 && !quiet {
            notices.append("Bonk! That's a dinosaur.")
            pendingHits.append(HazardHit(impulse: wallN * 6, coins: 2, kind: .wall))
            penalty = 1.5
        }
        return impact
    }

    func autopilot(_ flight: FlightModel) -> (roll: Float, pitch: Float)? {
        autopilotTimer -= 1.0 / 60
        if autopilotTimer <= 0 {
            autopilotTimer = 0.5
            var high: Float = 0
            let f = simd_normalize(SIMD3(flight.forward.x, 0, flight.forward.z) + SIMD3(1e-4, 0, 0))
            for k in 0...6 {
                let q = flight.pos + f * Float(k) * 45
                high = max(high, terrain.height(q.x, q.z))
            }
            autopilotTarget = max(autopilotTarget * 0.98, high + 32)
        }
        let err = autopilotTarget - flight.pos.y
        return (0.28, clamp(err / 40, -0.4, 0.8))
    }

    /// Bots: go over cliffs and dinosaurs in the way rather than into them.
    func avoid(_ flight: FlightModel, goal: SIMD3<Float>) -> SIMD3<Float>? {
        let p = flight.pos
        var to = goal - p
        let dist = simd_length(to)
        guard dist > 1 else { return nil }
        to /= dist
        let look = min(dist, 110)
        var highest: Float = -.infinity
        for k in 1...6 {
            let q = p + to * (look * Float(k) / 6)
            highest = max(highest, terrain.height(q.x, q.z))
        }
        for d in life.dinos where d.kind == .longneck || d.kind == .rex {
            let q = SIMD2(d.pos.x - p.x, d.pos.y - p.z)
            let along = simd_dot(q, SIMD2(to.x, to.z))
            guard along > 0, along < look else { continue }
            let off = simd_length(q - SIMD2(to.x, to.z) * along)
            if off < d.sp.length * d.scale * 0.4 { highest = max(highest, d.ground + d.sp.headHeight * d.scale) }
        }
        guard highest > p.y - 10 else { return nil }
        return SIMD3(goal.x, max(goal.y, highest + 18), goal.z)
    }
}
