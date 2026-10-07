import SceneKit
import simd

/// The Wild West's world systems: the steam train and the life on the plateau (WestLife), bumping into buildings,
/// trestles and trains, the old mine underground, rings that dive into the canyon, sounds and things to find.
final class WestRuntime: WorldRuntime {
    let root = SCNNode()
    let terrain: WestTerrain
    let life: WestLife
    private(set) var threat: String?
    private(set) var underground: Float = 0
    private var notices: [String] = []
    private var rewards: [WorldReward] = []
    private var pendingHits: [HazardHit] = []
    private var penalty: Float = 0
    private var quiet = false
    private var shake: Float = 0
    private var autopilotTimer: Float = 0
    private var autopilotTarget: Float = 220
    private var clock: Float = 0
    // Things found.
    private var saloonEntry: (id: Int64, t: Float, front: Bool)?
    private var found = Set<String>()
    private var mineEntry: (Int, Float)?

    init(terrain: WestTerrain) {
        self.terrain = terrain
        life = WestLife(terrain: terrain)
        root.addChildNode(life.root)
        CityShaders.setUnderground(0)
    }

    // MARK: Start, rings

    func spawnPoint() -> (SIMD3<Float>, Float)? {
        // Over the west end of the nearest town's main street, looking down it toward the church.
        guard let t = WestLayout.towns(near: .zero, radius: 4500).min(by: { simd_length($0.center) < simd_length($1.center) }) else { return nil }
        let p = SIMD3(t.center.x - WestLayout.streetHalfLength - 70, t.ground + 34, t.center.y)
        return (p, -.pi / 2)
    }

    func configure(_ rings: RingCourse) {
        rings.generator = { [weak self] last, dir, first, rng in
            guard let self else { return RingSpec(center: last, normal: dir, radius: 7.5, dir: dir) }
            var d = simd_normalize(SIMD3(dir.x, 0, dir.z))
            if !d.x.isFinite { d = SIMD3(0, 0, -1) }
            let rim = WestLayout.rim
            let dist = first ? rng.float(110, 150) : rng.float(150, 200)
            var best: (SIMD3<Float>, Float, Float)?
            for k in -6...6 {
                let a = Float(k) * 0.14 + rng.float(-0.04, 0.04)
                let nd = simd_quatf(angle: a, axis: kUp).act(d)
                var hmax: Float = -1e9
                for s in 1...6 {
                    let q = last + nd * (dist * Float(s) / 6)
                    hmax = max(hmax, self.terrain.height(q.x, q.z))
                }
                let c = last + nd * dist
                let g = max(self.terrain.height(c.x, c.z), 0)
                // Down in the canyon is best; never through the wall in front.
                let score = -g * 0.025 - max(0, hmax - (last.y - 8)) * 0.25 - abs(a) * 0.6 + rng.float(0, 0.3)
                if best == nil || score > best!.1 { best = (c, score, hmax) }
            }
            var c = best!.0
            let g = max(self.terrain.height(c.x, c.z), 0)
            if g < rim - 60 {
                // Inside the canyon: between the walls, below the rim.
                c.y = min(g + rng.float(24, 70), rim - 18)
            } else {
                c.y = g + rng.float(14, 30)
            }
            c.y = max(c.y, best!.2 + 8, g + 10)
            // Now and then down a town's main street, or under a trestle.
            if !first && rng.float() < 0.3 {
                if let t = WestLayout.towns(near: SIMD2(c.x, c.z), radius: 420).first {
                    let s = SIMD3(t.center.x + rng.float(-60, 60), t.ground + 7, t.center.y)
                    if simd_dot(simd_normalize(s - last), d) > 0.3 && simd_distance(s, last) < 320 { c = s }
                }
            }
            var n = c - last
            n.y *= 0.5
            n = simd_length(n) > 0.1 ? simd_normalize(n) : d
            let flat = simd_normalize(SIMD3(c.x - last.x, 0, c.z - last.z))
            return RingSpec(center: c, normal: n, radius: 7.5, dir: flat.x.isFinite ? flat : d)
        }
    }

    // MARK: Update

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        clock += dt
        penalty = max(0, penalty - dt)
        let p = flight.pos
        // Down in the mine?
        if WestMine.floorUnder(p, terrain) != nil && p.y < terrain.height(p.x, p.z) - 1 {
            underground = smoothstep(0.5, 6, terrain.height(p.x, p.z) - p.y)
        } else {
            underground = 0
        }
        life.update(dt: dt, player: flight, sound: sound, underground: underground)
        notices += life.notices
        rewards += life.rewards
        life.rewards.removeAll()
        threat = life.threat
        shake = max(shake, life.quake)
        discoveries(flight)
        var hits = life.hits + pendingHits
        pendingHits.removeAll()
        // Dust devils lift and spin you.
        flight.externalLift = life.devilLift
        if life.devilKick != .zero && penalty == 0 {
            hits.append(HazardHit(impulse: life.devilKick, coins: 2, kind: .wall))
            penalty = 1.2
        }
        return hits
    }

    private func discoveries(_ flight: FlightModel) {
        let p = flight.pos
        // The saloon: in one door and out the other.
        for t in WestLayout.towns(near: SIMD2(p.x, p.z), radius: 140) {
            guard let s = WestTown.plan(t).saloon else { continue }
            let mid = (s.lo.x + s.hi.x) / 2
            guard abs(p.x - mid) < WestTown.doorHalf + 0.3, p.y > s.lo.y, p.y < s.lo.y + WestTown.doorHeight + 0.3 else { continue }
            let id = (Int64(t.line) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: t.index)))
            let nearFront = abs(p.z - s.frontZ) < 1.5, nearBack = abs(p.z - (s.facing > 0 ? s.lo.z : s.hi.z)) < 1.5
            if nearFront || nearBack {
                if let e = saloonEntry, e.id == id, e.front != nearFront, clock - e.t < 4 {
                    if !found.contains("saloon") {
                        found.insert("saloon")
                        rewards.append(WorldReward(id: "west.saloon", title: "You flew through the saloon!", coins: 50, once: true))
                    }
                    notices.append("Yee-haw! Straight through the saloon.")
                    saloonEntry = nil
                } else if saloonEntry?.id != id || saloonEntry?.front != nearFront {
                    saloonEntry = (id, clock, nearFront)
                }
            }
        }
        // The mine: from one end to the other.
        for (k, m) in WestMine.near(p.x, p.z, terrain).enumerated() {
            let (s, l) = m.local(p)
            guard abs(l) < WestMineTunnel.halfWidth, p.y > m.floorY, p.y < m.floorY + WestMineTunnel.height else { continue }
            let end = s < 2 ? 0 : (s > m.length - 2 ? 1 : -1)
            guard end >= 0 else { continue }
            if let e = mineEntry, e.0 != end, clock - e.1 < 15 {
                if !found.contains("mine") {
                    found.insert("mine")
                    rewards.append(WorldReward(id: "west.mine", title: "You flew through the old mine!", coins: 50, once: true))
                }
                mineEntry = nil
            } else if mineEntry?.0 != end {
                mineEntry = (end, clock)
            }
            _ = k
        }
        // Under a trestle, between the bents.
        if !found.contains("trestle") {
            let (k, dl) = WestLayout.nearestLine(p.z)
            if dl < 3, let b = WestRail.bents(line: k, from: p.x - 10, to: p.x + 10, terrain).first, p.y < b.deck - 4, p.y > b.ground + 3 {
                found.insert("trestle")
                rewards.append(WorldReward(id: "west.trestle", title: "You flew under the trestle!", coins: 30, once: true))
            }
        }
        // Under a trestle just as the train thunders across it.
        if !found.contains("trestle.train"), let tr = life.train {
            let (k, dl) = WestLayout.nearestLine(p.z)
            if k == tr.line && dl < 10, let b = WestRail.bents(line: k, from: p.x - 10, to: p.x + 10, terrain).first, p.y < b.deck - 4, p.y > b.ground + 2,
               tr.cars.contains(where: { abs($0.node.simdPosition.x - p.x) < $0.length / 2 + 3 }) {
                found.insert("trestle.train")
                rewards.append(WorldReward(id: "west.trestle.train", title: "The train thundered right over you!", coins: 40, once: true))
                shake = max(shake, 0.45)
            }
        }
        // Skimming the river at the bottom of the canyon.
        if !found.contains("river") && terrain.height(p.x, p.z) < -0.5 && p.y < 2.5 {
            found.insert("river")
            rewards.append(WorldReward(id: "west.river", title: "You skimmed the river at the bottom of the canyon!", coins: 30, once: true))
        }
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

    func constrain(_ flight: FlightModel) -> Float {
        let r: Float = 0.9
        var impact: Float = 0
        var wallN = SIMD3<Float>(0, 0, 0)
        func push(_ v: SIMD3<Float>) {
            flight.pos += v
            let n = simd_normalize(v)
            impact = max(impact, Collide.response(flight, n))
            if abs(n.y) <= 0.7 { wallN = n }
        }
        // In the mine, the tunnel is the only air.
        let p0 = flight.pos
        if p0.y < terrain.height(p0.x, p0.z) - 0.4 {
            let airs = WestMine.near(p0.x, p0.z, terrain).filter { m in
                let (s, l) = m.local(p0); return s > -8 && s < m.length + 8 && abs(l) < 9
            }.map(\.air)
            let shrink = SIMD3<Float>(r, 0.75, r)
            if !airs.isEmpty && !airs.contains(where: { $0.contains(flight.pos, shrink: shrink) }) {
                var best = flight.pos, bestD = Float.infinity
                for a in airs {
                    let q = a.clamp(flight.pos, shrink: shrink)
                    let d = simd_distance(q, flight.pos)
                    if d < bestD { bestD = d; best = q }
                }
                if simd_length(best - flight.pos) > 1e-4 { push(best - flight.pos) }
            }
        }
        // Buildings, the saloon's walls (not its doors), porch roofs, fixtures, trestles, the train.
        for s in solids(near: flight.pos) {
            switch s {
            case .box(let b): if let v = b.push(flight.pos, r) { push(v) }
            case .capsule(let c): if let v = c.push(flight.pos, r) { push(v) }
            }
        }
        for b in life.trainBoxes(near: flight.pos) {
            if let v = b.push(flight.pos, r) {
                push(v)
                if !quiet && penalty == 0 { notices.append("Ouch — that's a train!") }
            }
        }
        if impact > 9 && penalty == 0 && !quiet {
            pendingHits.append(HazardHit(impulse: wallN * 6, coins: 2, kind: .wall))
            penalty = 1.5
        }
        return impact
    }

    enum Solid { case box(OBox), capsule(Capsule) }

    private var solidCache: (key: SIMD2<Int32>, list: [Solid])?

    /// Everything solid within ~60 m.
    func solids(near p: SIMD3<Float>) -> [Solid] {
        let key = SIMD2(Int32(floor(p.x / 20)), Int32(floor(p.z / 20)))
        if let c = solidCache, c.key == key { return c.list }
        var out: [Solid] = []
        let id = simd_quatf(angle: 0, axis: kUp)
        func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) { out.append(.box(OBox(center: (lo + hi) / 2, rot: id, half: (hi - lo) / 2))) }
        for t in WestLayout.towns(near: SIMD2(p.x, p.z), radius: 80) {
            let plan = WestTown.plan(t)
            for b in plan.buildings {
                let f = b.facing
                if b.kind == .saloon {
                    // Walls with doorways, the ceiling under the upstairs, the bar, the piano.
                    let g = b.lo.y, mid = (b.lo.x + b.hi.x) / 2, door = WestTown.doorHalf, top = g + WestTown.doorHeight
                    for z in [b.lo.z, b.hi.z] {
                        box(SIMD3(b.lo.x, g, z - 0.3), SIMD3(mid - door, b.hi.y, z + 0.3))
                        box(SIMD3(mid + door, g, z - 0.3), SIMD3(b.hi.x, b.hi.y, z + 0.3))
                        box(SIMD3(mid - door, top, z - 0.3), SIMD3(mid + door, b.hi.y, z + 0.3))
                    }
                    box(SIMD3(b.lo.x - 0.3, g, b.lo.z), SIMD3(b.lo.x + 0.3, b.hi.y, b.hi.z))
                    box(SIMD3(b.hi.x - 0.3, g, b.lo.z), SIMD3(b.hi.x + 0.3, b.hi.y, b.hi.z))
                    box(SIMD3(b.lo.x, g + 5.5, b.lo.z), SIMD3(b.hi.x, b.hi.y + (b.hi.x - b.lo.x) * 0.28, b.hi.z))
                    box(SIMD3(b.lo.x + 2.0, g, b.lo.z + 3.8), SIMD3(b.lo.x + 3.4, g + 1.35, b.hi.z - 3.8))
                    box(SIMD3(b.hi.x - 1.9, g, b.lo.z + 7), SIMD3(b.hi.x - 0.2, g + 1.5, b.lo.z + 9.2))
                } else {
                    let ridge = b.hi.y + (b.hi.x - b.lo.x) * (b.kind == .church ? 0 : 0.28)
                    box(b.lo, SIMD3(b.hi.x, max(ridge, b.hi.y), b.hi.z))
                }
                if b.kind == .church {
                    let tower = SIMD3(b.lo.x + 2.4, b.lo.y, (b.lo.z + b.hi.z) / 2)
                    box(tower + SIMD3(-2.3, 0, -2.3), tower + SIMD3(2.3, b.hi.y - b.lo.y + 10, 2.3))
                    out.append(.capsule(Capsule(a: tower + SIMD3(0, b.hi.y - b.lo.y + 10, 0), b: tower + SIMD3(0, b.hi.y - b.lo.y + 18, 0), r: 1.2)))
                } else if b.kind != .station {
                    // The false front, the porch roof and its posts.
                    let fz = b.frontZ
                    box(SIMD3(b.lo.x - 0.3, b.hi.y, min(fz, fz - f * 0.4)), SIMD3(b.hi.x + 0.3, b.frontTop, max(fz, fz - f * 0.4)))
                    let porchY = b.kind == .saloon ? b.lo.y + 4.6 : b.lo.y + 3.3
                    let walk = fz + f * 3.2
                    box(SIMD3(b.lo.x - 0.5, porchY, min(fz, walk)), SIMD3(b.hi.x + 0.5, porchY + (b.kind == .saloon ? 1.3 : 0.25), max(fz, walk)))
                } else {
                    box(SIMD3(b.lo.x - 1, b.hi.y, b.lo.z - 4.6), SIMD3(b.hi.x + 1, b.hi.y + 2.8, b.hi.z + 1))
                }
            }
            let w = plan.waterTower
            out.append(.capsule(Capsule(a: w + SIMD3(0, 9, 0), b: w + SIMD3(0, 15, 0), r: 3.6)))
            for (sx, sz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                out.append(.capsule(Capsule(a: w + SIMD3(sx * 2.6, 0, sz * 2.6), b: w + SIMD3(sx * 2.0, 9, sz * 2.0), r: 0.3)))
            }
            let wp = plan.windpump
            out.append(.capsule(Capsule(a: wp, b: wp + SIMD3(0, 11, 0), r: 1.3)))
            out.append(.capsule(Capsule(a: wp + SIMD3(0, 11, -0.3), b: wp + SIMD3(0, 11, -0.3), r: 2.4)))
        }
        let tr = WestRail.solids(near: p, radius: 60, terrain)
        out += tr.caps.map { .capsule($0) }
        out += tr.boxes.map { .box($0) }
        solidCache = (key, out)
        return out
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
            autopilotTarget = max(autopilotTarget * 0.98, high + 34)
        }
        return (0.28, clamp((autopilotTarget - flight.pos.y) / 40, -0.4, 0.8))
    }

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
            if let (t, _) = WestLayout.townBlend(q.x, q.z) { highest = max(highest, t.ground + 16) }
        }
        guard highest > p.y - 10 else { return nil }
        return SIMD3(goal.x, max(goal.y, highest + 18), goal.z)
    }

    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float> {
        // Inside the saloon or the mine, keep the camera inside too.
        guard bird.y < terrain.height(bird.x, bird.z) + 6 else { return cam }
        var last = bird
        let list = solids(near: bird)
        for k in 1...10 {
            let q = bird + (cam - bird) * (Float(k) / 10)
            let below = q.y < terrain.height(q.x, q.z) - 0.2 && WestMine.floorUnder(q, terrain) == nil
            let blocked = list.contains { s in
                switch s {
                case .box(let b): return b.push(q, 0.3) != nil
                case .capsule(let c): return c.push(q, 0.3) != nil
                }
            }
            if below || blocked { return bird + (last - bird) * 0.85 }
            last = q
        }
        return cam
    }
}
