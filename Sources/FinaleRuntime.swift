import SceneKit
import simd

/// The Finale's world systems: the castle (and bumping into it), the crowds and the fireworks, the music drifting
/// from the castle and the cheering, rings that loop round the towers and sometimes run in through the gate. No
/// hazards: it's a celebration. The cutscene (FinaleCutscene) borrows the crowds and the castle while it plays.
final class FinaleRuntime: WorldRuntime {
    let root = SCNNode()
    let terrain: FinaleTerrain
    let castle: SCNNode
    let fireworks = FinaleFireworks()
    let life: FinaleLife
    private(set) var threat: String?
    private var notices: [String] = []
    private var rewards: [WorldReward] = []
    private var shake: Float = 0
    private var quiet = false
    private var autopilotTimer: Float = 0
    private var autopilotTarget: Float = 110
    private var clock: Float = 0
    /// While the cutscene plays it moves the guest of honour and the camera itself.
    var cutsceneActive = false
    private var ringStep = 0
    private var camera = SIMD3<Float>.zero

    init(terrain: FinaleTerrain) {
        self.terrain = terrain
        castle = FinaleCastle.build()
        life = FinaleLife(fireworks: fireworks)
        root.addChildNode(castle)
        root.addChildNode(life.root)
        root.addChildNode(fireworks.root)
    }

    // MARK: Start, rings

    func spawnPoint() -> (SIMD3<Float>, Float)? {
        // South of the castle over the road, looking at the gate and the towers.
        (SIMD3(0, 96, 340), 0)
    }

    func configure(_ rings: RingCourse) {
        // Round and round the castle at all heights; now and then a run in through the gate, over the courtyard and up
        // past the Sky Tower.
        rings.generator = { [weak self] last, dir, first, rng in
            guard let self else { return RingSpec(center: last, normal: dir, radius: 7.5, dir: dir) }
            let L = FinaleLayout.self
            self.ringStep += 1
            let flat = SIMD2(last.x, last.z)
            // The gate run: when the last ring was out front, south of the gate.
            if !first && flat.y > 180 && abs(flat.x) < 160 && rng.float() < 0.5 {
                let c = SIMD3<Float>(0, L.ground + 6.5, L.gateZ + 22)
                return RingSpec(center: c, normal: SIMD3(0, 0, -1), radius: 4.6, dir: SIMD3(0, 0, -1))
            }
            if abs(flat.x) < 2 && abs(flat.y - (L.gateZ + 22)) < 2 {
                return RingSpec(center: SIMD3(0, L.ground + 18, 40), normal: simd_normalize(SIMD3(0, 0.3, -1)), radius: 7, dir: SIMD3(0, 0, -1))
            }
            if abs(flat.x) < 2 && abs(flat.y - 40) < 2 {
                let c = SIMD3<Float>(-34, L.ground + 70, -100)
                return RingSpec(center: c, normal: simd_normalize(c - last), radius: 7.5, dir: simd_normalize(SIMD3(c.x - last.x, 0, c.z - last.z)))
            }
            // Otherwise the next step round, counterclockwise, at a new radius and height.
            var ang = atan2(flat.y, flat.x)
            ang += rng.float(0.3, 0.55)
            let r = first ? rng.float(240, 300) : rng.float(170, 380)
            var c = SIMD3(cos(ang) * r, 0, sin(ang) * r)
            let g = max(self.terrain.height(c.x, c.z), 0)
            c.y = g + rng.float(22, 70)
            if r < 200 { c.y = max(c.y, L.ground + L.towerHeight + 26) }
            var n = c - last
            n.y *= 0.5
            n = simd_length(n) > 0.1 ? simd_normalize(n) : dir
            let fl = simd_normalize(SIMD3(c.x - last.x, 0, c.z - last.z))
            return RingSpec(center: c, normal: n, radius: 7.5, dir: fl.x.isFinite ? fl : dir)
        }
    }

    // MARK: Update

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        clock += dt
        if !cutsceneActive { life.honoree = flight.pos }
        life.camera = camera == .zero ? flight.pos : camera
        life.update(dt: dt, sound: sound)
        fireworks.update(dt: dt, around: SIMD3(0, FinaleLayout.ground, -30))
        if let sound {
            let ear = camera == .zero ? flight.pos : camera
            let d = simd_length(SIMD2(ear.x, ear.z))
            if !cutsceneActive { sound.setFinaleMusic(smoothstep(900, 120, d) * 0.7) }
            sound.setCrowd(cheer: life.roar)
            let right = SIMD3(cos(flight.yaw), 0, -sin(flight.yaw))
            for b in fireworks.bursts {
                let to = b - ear
                let dist = simd_length(to)
                sound.firework(gain: smoothstep(1400, 60, dist), pan: dist > 1 ? clamp(simd_dot(to / dist, right), -1, 1) : 0, delay: dist / 343)
            }
        }
        return []
    }

    func drainNotices() -> [String] { defer { notices.removeAll() }; return notices }
    func drainRewards() -> [WorldReward] { defer { rewards.removeAll() }; return rewards }
    func drainShake() -> Float { defer { shake = 0 }; return shake }
    func setCamera(_ p: SIMD3<Float>) { camera = p }

    // MARK: Collisions

    func constrainQuietly(_ flight: FlightModel) {
        quiet = true
        _ = constrain(flight)
        quiet = false
    }

    func constrain(_ flight: FlightModel) -> Float {
        let p0 = flight.pos
        guard simd_length(SIMD2(p0.x, p0.z + 20)) < 190, p0.y < FinaleLayout.ground + 140 else { return 0 }
        let r: Float = 0.9
        var impact: Float = 0
        for s in FinaleCastle.solids {
            let v: SIMD3<Float>?
            switch s {
            case .box(let b): v = b.push(flight.pos, r)
            case .capsule(let c): v = c.push(flight.pos, r)
            }
            guard let v else { continue }
            flight.pos += v
            impact = max(impact, Collide.response(flight, simd_normalize(v)))
        }
        if impact > 9 && !quiet { shake = max(shake, min(impact / 30, 0.6)) }
        return impact
    }

    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float> {
        guard simd_length(SIMD2(bird.x, bird.z + 20)) < 200, bird.y < FinaleLayout.ground + 140 else { return cam }
        var last = bird
        for k in 1...10 {
            let q = bird + (cam - bird) * (Float(k) / 10)
            let blocked = FinaleCastle.solids.contains { s in
                switch s {
                case .box(let b): return b.push(q, 0.35) != nil
                case .capsule(let c): return c.push(q, 0.35) != nil
                }
            }
            if blocked { return bird + (last - bird) * 0.85 }
            last = q
        }
        return cam
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
                if simd_length(SIMD2(q.x, q.z + 20)) < 160 { high = max(high, FinaleLayout.ground + FinaleLayout.skyTowerHeight + 20) }
            }
            autopilotTarget = max(autopilotTarget * 0.98, high + 34)
        }
        return (0.25, clamp((autopilotTarget - flight.pos.y) / 40, -0.4, 0.8))
    }

    /// Bots: over the castle rather than into it.
    func avoid(_ flight: FlightModel, goal: SIMD3<Float>) -> SIMD3<Float>? {
        let p = flight.pos
        var to = goal - p
        let dist = simd_length(to)
        guard dist > 1 else { return nil }
        to /= dist
        let look = min(dist, 120)
        var highest: Float = -.infinity
        for k in 1...6 {
            let q = p + to * (look * Float(k) / 6)
            highest = max(highest, terrain.height(q.x, q.z))
            if simd_length(SIMD2(q.x, q.z + 20)) < 150 { highest = max(highest, FinaleLayout.ground + 60) }
            if simd_length(SIMD2(q.x - FinaleLayout.skyTower.x, q.z - FinaleLayout.skyTower.y)) < 20 {
                highest = max(highest, FinaleLayout.ground + FinaleLayout.skyTowerHeight + 30)
            }
        }
        guard highest > p.y - 10 else { return nil }
        return SIMD3(goal.x, max(goal.y, highest + 16), goal.z)
    }
}
