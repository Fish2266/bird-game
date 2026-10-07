import SceneKit
import simd

/// Something solid in the city, for collisions and the camera.
enum CitySolid {
    case box(OBox)
    case cylinder(c: SIMD2<Float>, r: Float, y0: Float, y1: Float)
    case capsule(Capsule)

    /// Push that moves a sphere at `p` (radius `r`) out, or nil.
    func push(_ p: SIMD3<Float>, _ r: Float) -> SIMD3<Float>? {
        switch self {
        case .box(let b): return b.push(p, r)
        case .capsule(let c): return c.push(p, r)
        case .cylinder(let c, let rad, let y0, let y1):
            let d = SIMD2(p.x - c.x, p.z - c.y)
            let dl = simd_length(d)
            guard p.y > y0 - r, p.y < y1 + r, dl < rad + r else { return nil }
            let side = rad + r - dl
            let up = y1 + r - p.y, down = p.y - (y0 - r)
            if up < side && up < down { return SIMD3(0, up, 0) }
            if down < side { return SIMD3(0, -down, 0) }
            let n = dl > 1e-4 ? d / dl : SIMD2<Float>(1, 0)
            return SIMD3(n.x, 0, n.y) * side
        }
    }

    func contains(_ p: SIMD3<Float>, margin m: Float) -> Bool { push(p, m) != nil }
}

/// Skyline City: collisions with buildings, the clock for traffic lights, rings down the street canyons, plus the
/// living city (traffic, people, trains…) in CityLife.
final class CityRuntime: WorldRuntime {
    let root = SCNNode()
    private(set) var threat: String?
    let terrain: CityTerrain
    /// The city clock (traffic lights, cranes, billboards).
    private(set) var clock: Float = 0
    private var pendingHits: [HazardHit] = []
    private var notices: [String] = []
    private var penalty: Float = 0
    private var quiet = false
    private var autopilotTarget: Float = 120
    private var autopilotTimer: Float = 0
    private(set) var underground: Float = 0
    private var rewards: [WorldReward] = []
    private var found = Set<String>()
    let life: CityLife
    private let horizon = CityHorizon()

    init(terrain: CityTerrain) {
        self.terrain = terrain
        life = CityLife()
        root.addChildNode(life.root)
        root.addChildNode(horizon.node)
        CityShaders.setUnderground(0)
    }

    // MARK: Solids

    private struct SolidCache { var center: SIMD3<Float>; var solids: [CitySolid]; var used: Int }
    private var caches: [SolidCache] = []
    private var useCounter = 0
    private static let cacheRadius: Float = 70, cacheReuse: Float = 14

    /// Solids within about 55 m of `p` (cached; the moving ones — cranes — are added fresh).
    func solids(near p: SIMD3<Float>) -> [CitySolid] {
        useCounter += 1
        var list: [CitySolid]
        if let i = caches.firstIndex(where: { simd_distance($0.center, p) < CityRuntime.cacheReuse }) {
            caches[i].used = useCounter
            list = caches[i].solids
        } else {
            list = CityRuntime.staticSolids(near: p, radius: CityRuntime.cacheRadius)
            let entry = SolidCache(center: p, solids: list, used: useCounter)
            if caches.count < 8 { caches.append(entry) } else if let k = caches.indices.min(by: { caches[$0].used < caches[$1].used }) { caches[k] = entry }
        }
        // Crane jibs turn with the clock.
        for b in CityLayout.blocks(near: p.x, p.z, radius: 70) {
            guard let c = b.crane else { continue }
            let a = CityShaders.craneAngle(phase: c.phase, time: clock)
            let top = c.mast + SIMD3(0, c.height, 0)
            list.append(.capsule(Capsule(a: top + SIMD3(0, 2.6, 0), b: top + SIMD3(0, 2.6, 0) + jibDir(a) * c.jib, r: 1.3)))
            list.append(.capsule(Capsule(a: top + SIMD3(0, 2.4, 0), b: top + SIMD3(0, 2.4, 0) - jibDir(a) * 15, r: 1.4)))
        }
        list += life.solids(near: p)
        return list
    }

    /// Direction of a crane jib for angle a: the shader rotates local (x, z) by a, and the jib points along local -z.
    @inline(__always) func jibDir(_ a: Float) -> SIMD3<Float> {
        // (x, z) = (0, -1) rotated: x' = c·0 - s·(-1) = s, z' = s·0 + c·(-1) = -c
        SIMD3(sin(a), 0, -cos(a))
    }

    static func staticSolids(near p: SIMD3<Float>, radius r: Float) -> [CitySolid] {
        var out: [CitySolid] = []
        func near(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
            let dx = max(lo.x - p.x, 0, p.x - hi.x), dz = max(lo.z - p.z, 0, p.z - hi.z)
            return dx * dx + dz * dz < r * r
        }
        for b in CityLayout.blocks(near: p.x, p.z, radius: r) {
            for bld in b.buildings {
                for part in bld.parts where near(part.lo - 4, part.hi + 4) {
                    switch part.shape {
                    case .box, .octagon:
                        out.append(.box(OBox(center: part.center, rot: simd_quatf(angle: part.yaw, axis: kUp), half: part.half)))
                    case .cylinder:
                        out.append(.cylinder(c: SIMD2(part.center.x, part.center.z), r: part.radius, y0: part.lo.y, y1: part.hi.y))
                    }
                }
                if let crown = bld.crown, let tp = bld.parts.last {
                    let ch: Float
                    switch crown { case .wedge(_, let h): ch = h; case .pyramid(let h): ch = h }
                    out.append(.box(OBox(center: SIMD3(tp.center.x, tp.hi.y + ch * 0.3, tp.center.z), rot: simd_quatf(angle: 0, axis: kUp),
                                         half: SIMD3(tp.half.x * 0.75, ch * 0.3, tp.half.z * 0.75))))
                }
                if let s = bld.spire, near(s.base - 2, s.base + 2) {
                    out.append(.capsule(Capsule(a: s.base, b: s.base + SIMD3(0, s.height, 0), r: max(0.9, s.height * 0.035))))
                }
                for item in bld.roof {
                    switch item {
                    case .waterTower(let c, let rr): out.append(.cylinder(c: SIMD2(c.x, c.z), r: rr, y0: c.y, y1: c.y + 10.6))
                    case .unit(let c, let h): out.append(.box(OBox(center: c + SIMD3(0, h.y, 0), rot: simd_quatf(angle: 0, axis: kUp), half: h)))
                    case .billboard(let c, let w, let yaw, _):
                        out.append(.box(OBox(center: c + SIMD3(0, 3 + w * 0.25, 0), rot: simd_quatf(angle: yaw, axis: kUp),
                                             half: SIMD3(w / 2 + 0.25, w * 0.25 + 0.25, 0.3))))
                    default: break
                    }
                }
            }
            for s in b.skybridges where near(s.lo, s.hi) {
                out.append(.box(OBox(center: (s.lo + s.hi) * 0.5, rot: simd_quatf(angle: 0, axis: kUp), half: (s.hi - s.lo) * 0.5)))
            }
            if let c = b.crane, near(c.mast - 3, c.mast + 3) {
                out.append(.box(OBox(center: c.mast + SIMD3(0, c.height / 2, 0), rot: simd_quatf(angle: 0, axis: kUp), half: SIMD3(1.3, c.height / 2 + 1.4, 1.3))))
            }
        }
        // The subway's platforms, columns, ledges and headwalls.
        for seg in CitySubway.segments(near: p.x, p.z, radius: r) { out += CitySubway.solids(seg) }
        // Bridges and the elevated railway.
        let G = CityLayout.pitch
        let i0 = Int(floor((p.x - r) / G)) - 1, i1 = Int(floor((p.x + r) / G)) + 1
        let j0 = Int(floor((p.z - r) / G)) - 1, j1 = Int(floor((p.z + r) / G)) + 1
        for j in j0...j1 {
            for i in i0...i1 {
                for alongX in [true, false] {
                    guard let e = CityLayout.edge(alongX: alongX, i, j), let br = e.bridge else { continue }
                    let a = e.start + e.dir * br.s0, z = e.start + e.dir * br.s1
                    let hw = e.line.halfWidth
                    let lo = SIMD3(min(a.x, z.x) - (alongX ? 0 : hw), br.deck - 1.6, min(a.y, z.y) - (alongX ? hw : 0))
                    let hi = SIMD3(max(a.x, z.x) + (alongX ? 0 : hw), br.deck, max(a.y, z.y) + (alongX ? hw : 0))
                    guard near(lo, hi) else { continue }
                    out.append(.box(OBox(center: (lo + hi) * 0.5, rot: simd_quatf(angle: 0, axis: kUp), half: (hi - lo) * 0.5)))
                    let span = br.s1 - br.s0
                    if e.line.avenue && span > 55 {
                        let towerH: Float = 42 + min(span, 110) * 0.15
                        let d3 = SIMD3(e.dir.x, 0, e.dir.y), side = SIMD3(-e.dir.y, 0, e.dir.x)
                        let A = SIMD3(a.x, br.deck, a.y), B = SIMD3(z.x, br.deck, z.y)
                        for tp in [A + d3 * 6, B - d3 * 6] {
                            for s: Float in [-1, 1] {
                                let leg = tp + side * (hw + 1.4) * s
                                out.append(.box(OBox(center: SIMD3(leg.x, br.deck + towerH / 2 - 4, leg.z), rot: simd_quatf(angle: 0, axis: kUp),
                                                     half: SIMD3(alongX ? 1.4 : 1.1, towerH / 2 + 4, alongX ? 1.1 : 1.4))))
                            }
                            out.append(.box(OBox(center: tp + SIMD3(0, towerH - 1.5, 0), rot: simd_quatf(angle: 0, axis: kUp),
                                                 half: alongX ? SIMD3(1.1, 1, hw + 2.4) : SIMD3(hw + 2.4, 1, 1.1))))
                            out.append(.box(OBox(center: tp + SIMD3(0, towerH * 0.55, 0), rot: simd_quatf(angle: 0, axis: kUp),
                                                 half: alongX ? SIMD3(1.1, 1, hw + 2.4) : SIMD3(hw + 2.4, 1, 1.1))))
                        }
                        // Main cables as a chain of capsules.
                        let t0 = A + d3 * 6, t1 = B - d3 * 6
                        for s: Float in [-1, 1] {
                            let o = side * (hw + 1.4) * s
                            var prev = t0 + o + SIMD3(0, towerH, 0)
                            for k in 1...8 {
                                let u = Float(k) / 8
                                var q = t0 + (t1 - t0) * u + o + SIMD3(0, towerH, 0)
                                q.y -= (towerH - 4) * 4 * u * (1 - u)
                                out.append(.capsule(Capsule(a: prev, b: q, r: 0.6)))
                                prev = q
                            }
                        }
                    }
                }
            }
        }
        for i in i0...i1 where CityLayout.lineX(i).el {
            let x = Float(i) * G
            guard abs(p.x - x) < r + 8 else { continue }
            var z = floor((p.z - r) / 25) * 25
            while z < p.z + r {
                let y = CityTerrain.trackY(x, z), y2 = CityTerrain.trackY(x, z + 25)
                out.append(.box(OBox(center: SIMD3(x, (y + y2) / 2 - 0.55, z + 12.5), rot: simd_quatf(angle: 0, axis: kUp), half: SIMD3(3.6, 0.7, 12.6))))
                let g = CityLayout.ground(x, z)
                out.append(.box(OBox(center: SIMD3(x, (g + y) / 2 - 0.7, z), rot: simd_quatf(angle: 0, axis: kUp), half: SIMD3(0.8, (y - g) / 2, 0.8))))
                z += 25
            }
        }
        return out
    }

    // MARK: WorldRuntime

    func configure(_ rings: RingCourse) {
        rings.generator = { [weak self] last, dir, first, rng in
            guard let self else { return RingSpec(center: last, normal: dir, radius: 7.5, dir: dir) }
            return self.nextRing(after: last, dir: dir, first: first, &rng)
        }
    }

    func spawnPoint() -> (SIMD3<Float>, Float)? {
        var best: (Int, Int)? = nil, bestScore: Float = -1e9
        for j in -14...14 where CityLayout.lineZ(j).avenue {
            for i in -14...14 where CityLayout.lineX(i).avenue && !CityLayout.lineX(i).el {
                guard CityLayout.nodeExists(i, j) else { continue }
                let p = CityLayout.nodePosition(i, j)
                let score = CityLayout.district(p.x, p.y) * 2 - simd_length(p) * 0.0004
                if score > bestScore { bestScore = score; best = (i, j) }
            }
        }
        let (i, j) = best ?? (0, 0)
        let p = CityLayout.nodePosition(i, j)
        // Head down the avenue toward the tallest part of downtown.
        var dir = SIMD2<Float>(0, -1), dirScore: Float = -1e9
        for d in [SIMD2<Float>(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] {
            let alongX = d.x != 0
            let next = alongX ? (d.x > 0 ? CityLayout.edge(alongX: true, i, j) : CityLayout.edge(alongX: true, i - 1, j))
                              : (d.y > 0 ? CityLayout.edge(alongX: false, i, j) : CityLayout.edge(alongX: false, i, j - 1))
            guard next != nil else { continue }
            var score: Float = 0
            for k in 1...4 { let q = p + d * Float(k) * 120; score += CityLayout.district(q.x, q.y) }
            if (alongX ? CityLayout.lineZ(j) : CityLayout.lineX(i)).avenue { score += 0.5 }
            if score > dirScore { dirScore = score; dir = d }
        }
        let start = p - dir * 40
        let y = CityLayout.ground(start.x, start.y) + 42
        return (SIMD3(start.x, y, start.y), atan2(-dir.x, -dir.y))
    }

    func update(dt: Float, time: Float, flight: FlightModel, sound: SoundEngine?) -> [HazardHit] {
        clock += dt
        // How far down in the subway are we? (Fades the light in and out at the stairs and tunnel mouths.)
        let p = flight.pos
        if CitySubway.nearLine(p.x, p.z), CitySubway.inside(p, shrink: 0) {
            underground = smoothstep(0.5, 6.5, CityLayout.ground(p.x, p.z) - p.y)
        } else {
            underground = 0
        }
        CityShaders.setTime(clock)
        horizon.follow(flight.pos)
        penalty = max(0, penalty - dt)
        life.update(dt: dt, clock: clock, player: flight, sound: sound, underground: underground)
        notices += life.drainNotices()
        // Warn about walls coming up fast.
        threat = nil
        let ahead = flight.pos + flight.forward * max(flight.speed * 1.1, 12)
        if flight.speed > 16 {
            for s in solids(near: flight.pos) where s.contains(ahead, margin: 1.5) {
                threat = "Pull up — building ahead!"
                break
            }
        }
        if let t = life.threat { threat = t }
        discoveries(flight)
        var hits = pendingHits
        hits += life.drainHits()
        pendingHits.removeAll()
        return hits
    }

    /// Things to find: under a bridge over the river, alongside the elevated train, past the helicopter, under the blimp.
    private func discoveries(_ flight: FlightModel) {
        let p = flight.pos
        func find(_ id: String, _ title: String, _ coins: Int) {
            guard !found.contains(id) else { return }
            found.insert(id)
            rewards.append(WorldReward(id: "city." + id, title: title, coins: coins, once: true))
        }
        let sky = life.sky
        if simd_distance(p, sky.heliPos) < 24 { find("heli", "You buzzed the helicopter!", 30) }
        let b = sky.blimpPos
        if simd_length(SIMD2(p.x - b.x, p.z - b.z)) < 18 && p.y < b.y - 6 && p.y > b.y - 45 { find("blimp", "You flew under the blimp!", 30) }
        if !found.contains("bridge") && p.y < CityLayout.quayTop + 2 {
            let G = CityLayout.pitch
            let i = Int((p.x / G).rounded()), j = Int((p.z / G).rounded())
            for (alongX, a, c) in [(true, Int(floor(p.x / G)), j), (false, i, Int(floor(p.z / G)))] {
                guard let e = CityLayout.edge(alongX: alongX, a, c), let br = e.bridge else { continue }
                let s = alongX ? p.x - e.start.x : p.z - e.start.y
                let across = alongX ? abs(p.z - e.start.y) : abs(p.x - e.start.x)
                if s > br.s0 && s < br.s1 && across < e.line.halfWidth && p.y < br.deck - 2 { find("bridge", "You flew under a bridge!", 30) }
            }
        }
        if !found.contains("el") {
            for t in life.transit.trains where t.speed > 8 {
                let front = t.cars[0].simdWorldPosition
                if simd_distance(front, p) < 14 && flight.forward.z * t.dir > 0.5 { find("el", "You raced the elevated train!", 30) }
            }
        }
    }

    func drainNotices() -> [String] { defer { notices.removeAll() }; return notices }
    func drainRewards() -> [WorldReward] {
        let r = rewards + life.drainRewards()
        rewards.removeAll()
        return r
    }
    func setCamera(_ p: SIMD3<Float>) { life.camera = p }

    func constrainQuietly(_ flight: FlightModel) {
        quiet = true
        _ = constrain(flight)
        quiet = false
    }

    /// Slide along walls, skid on roofs and bridge decks, bump off undersides — and underground, stay in the tunnels.
    func constrain(_ flight: FlightModel) -> Float {
        let r: Float = 0.9
        var impact: Float = 0
        var wallN = SIMD3<Float>(0, 0, 0)
        // Down in the subway, the tunnels, halls and stairwells are the only air there is.
        if CitySubway.nearLine(flight.pos.x, flight.pos.z), flight.pos.y < CityLayout.ground(flight.pos.x, flight.pos.z) - 0.4 {
            let airs = CitySubway.air(near: flight.pos)
            let shrink = SIMD3<Float>(r, 0.75, r)
            if !airs.isEmpty && !airs.contains(where: { $0.contains(flight.pos, shrink: shrink) }) {
                // Back inside — preferring a nudge that doesn't send the bird back the way it came, so a lip
                // (the roof at the end of a stair opening, the wall over a tunnel mouth) ducks you under it.
                var best = flight.pos
                var bestCost = Float.infinity
                let heading = flight.forward
                for a in airs {
                    let q = a.clamp(flight.pos, shrink: shrink)
                    let d = simd_distance(q, flight.pos)
                    let against = d > 1e-4 ? max(0, -simd_dot((q - flight.pos) / d, heading)) : 0
                    let cost = d + against * 1.6
                    if cost < bestCost { bestCost = cost; best = q }
                }
                let push = best - flight.pos
                flight.pos = best
                if simd_length(push) > 1e-4 {
                    let n = simd_normalize(push)
                    impact = max(impact, response(flight, n))
                    if abs(n.y) < 0.7 { wallN = n }
                }
            }
        }
        let list = solids(near: flight.pos)
        for _ in 0..<3 {
            var best: SIMD3<Float>?
            for s in list {
                if let v = s.push(flight.pos, r), simd_length_squared(v) > simd_length_squared(best ?? .zero) { best = v }
            }
            guard let push = best else { break }
            flight.pos += push
            let n = simd_normalize(push)
            impact = max(impact, response(flight, n))
            if abs(n.y) <= 0.7 { wallN = n }
        }
        if impact > 9 && penalty == 0 && !quiet {
            if underground > 0.5 { notices.append("Ouch — tight in here!") }
            pendingHits.append(HazardHit(impulse: wallN * 6, coins: 2, kind: .wall))
            penalty = 1.5
        }
        return impact
    }

    private func response(_ flight: FlightModel, _ n: SIMD3<Float>) -> Float { Collide.response(flight, n) }

    func constrainCamera(bird: SIMD3<Float>, cam: SIMD3<Float>) -> SIMD3<Float> {
        // Underground: never let the camera end up in the rock.
        if CitySubway.nearLine(bird.x, bird.z), bird.y < CityLayout.ground(bird.x, bird.z) - 0.2 {
            var last = bird
            for k in 1...14 {
                let q = bird + (cam - bird) * (Float(k) / 14)
                let below = q.y < CityLayout.ground(q.x, q.z) - 0.1
                if below && !CitySubway.inside(q, shrink: 0.35) { return bird + (last - bird) * 0.9 }
                last = q
            }
        }
        let list = solids(near: bird)
        let steps = 10
        var last = bird
        for k in 1...steps {
            let t = Float(k) / Float(steps)
            let p = bird + (cam - bird) * t
            if list.contains(where: { $0.contains(p, margin: 0.6) }) { return bird + (last - bird) * 0.85 }
            last = p
        }
        return cam
    }

    func autopilot(_ flight: FlightModel) -> (roll: Float, pitch: Float)? {
        // In a tunnel: follow it, mid-height, toward whichever end we're facing.
        if underground > 0.3, let seg = CitySubway.segments(near: flight.pos.x, flight.pos.z, radius: 1).first(where: { s in
            let (ss, l) = s.local(flight.pos); return ss >= -2 && ss <= CityLayout.pitch + 2 && abs(l) < CitySubway.hallHalf }) {
            let (sNow, _) = seg.local(flight.pos)
            let f = flight.forward
            let sign: Float = simd_dot(f, seg.axis) >= 0 ? 1 : -1
            let aheadS = sNow + sign * 14
            let target = seg.world(aheadS, 0, seg.floor(aheadS) + 4)
            let to = target - flight.pos
            let fwd = simd_normalize(SIMD2(f.x, f.z) + SIMD2(1e-4, 0))
            let t2 = SIMD2(to.x, to.z)
            let cross = fwd.x * t2.y - fwd.y * t2.x
            return (clamp(cross * 0.1, -0.9, 0.9), clamp(to.y / 6, -0.6, 0.6))
        }
        autopilotTimer -= 1.0 / 60
        if autopilotTimer <= 0 {
            autopilotTimer = 0.5
            autopilotTarget = max(autopilotTarget * 0.98, CityLayout.skyline(flight.pos.x, flight.pos.z, radius: 160) + 28)
        }
        let err = autopilotTarget - flight.pos.y
        return (0.32, clamp(err / 40, -0.4, 0.8))
    }

    /// Bots: aim over buildings in the way.
    func avoid(_ flight: FlightModel, goal: SIMD3<Float>) -> SIMD3<Float>? {
        let p = flight.pos
        var to = goal - p
        let dist = simd_length(to)
        guard dist > 1 else { return nil }
        to /= dist
        // Something tall between here and there? Go over it (above the goal, so once past it's a dive).
        let look = min(dist, 80)
        var highest: Float = -.infinity
        for k in 1...5 {
            let q = p + to * (look * Float(k) / 5)
            let roof = CityLayout.roofHeight(q.x, q.z)
            if q.y < roof + 5 { highest = max(highest, roof) }
        }
        guard highest > -.infinity else { return nil }
        return SIMD3(goal.x, max(goal.y, highest + 12), goal.z)
    }

    // MARK: Rings: down the street canyons

    private func nextRing(after last: SIMD3<Float>, dir: SIMD3<Float>, first: Bool, _ rng: inout SplitMix64) -> RingSpec {
        let G = CityLayout.pitch
        var d = SIMD2(dir.x, dir.z)
        if simd_length(d) < 0.1 { d = SIMD2(0, -1) }
        // Snap to the nearest street axis.
        d = abs(d.x) > abs(d.y) ? SIMD2(d.x > 0 ? 1 : -1, 0) : SIMD2(0, d.y > 0 ? 1 : -1)
        var p = SIMD2(last.x, last.z)
        // Ride the nearest street parallel to the heading.
        if d.x != 0 { p.y = (p.y / G).rounded() * G } else { p.x = (p.x / G).rounded() * G }
        let lineHere = d.x != 0 ? CityLayout.lineZ(Int((p.y / G).rounded())) : CityLayout.lineX(Int((p.x / G).rounded()))
        var spacing = first ? rng.float(100, 130) : rng.float(140, 195)
        // Turn at the next intersection now and then.
        let along = d.x != 0 ? p.x * d.x : p.y * d.y
        let nextNodeAlong = (floor(along / G) + 1) * G
        let toNode = nextNodeAlong - along
        var newDir = d
        var target: SIMD2<Float>
        var minClear: Float = 0
        if !first && toNode > 15 && toNode < spacing && rng.float() < 0.42 {
            let nodeP = p + d * toNode
            let ni = Int((nodeP.x / G).rounded()), nj = Int((nodeP.y / G).rounded())
            let left = SIMD2(d.y, -d.x), right = SIMD2(-d.y, d.x)
            var options: [SIMD2<Float>] = []
            for cand in [left, right] {
                let has = cand.x != 0 ? (cand.x > 0 ? CityLayout.edge(alongX: true, ni, nj) : CityLayout.edge(alongX: true, ni - 1, nj))
                                      : (cand.y > 0 ? CityLayout.edge(alongX: false, ni, nj) : CityLayout.edge(alongX: false, ni, nj - 1))
                if has != nil { options.append(cand) }
            }
            if let pick = options.isEmpty ? nil : options[Int(rng.float(0, Float(options.count) - 0.01))] {
                // The inside corner: can the bird cut across it?
                let corner = nodeP - d * 14 + pick * 14
                let cornerTop = CityLayout.roofHeight(corner.x, corner.y) - CityLayout.ground(nodeP.x, nodeP.y)
                let wide = lineHere.avenue && (pick.x != 0 ? CityLayout.lineZ(nj) : CityLayout.lineX(ni)).avenue
                if cornerTop < 70 || wide {
                    newDir = pick
                    minClear = wide ? 0 : cornerTop + 8
                    target = nodeP + pick * rng.float(45, 75)
                    return place(target, from: last, newDir: newDir, minClear: minClear, &rng)
                }
            }
        }
        spacing = min(spacing, 200)
        target = p + d * spacing
        return place(target, from: last, newDir: newDir, minClear: minClear, &rng)
    }

    private func place(_ t: SIMD2<Float>, from last: SIMD3<Float>, newDir: SIMD2<Float>, minClear: Float, _ rng: inout SplitMix64) -> RingSpec {
        let g = CityLayout.ground(t.x, t.y)
        var y: Float
        let line = newDir.x != 0 ? CityLayout.lineZ(Int((t.y / CityLayout.pitch).rounded())) : CityLayout.lineX(Int((t.x / CityLayout.pitch).rounded()))
        let r = rng.float()
        if r < 0.14 && line.avenue && !line.el { y = g + rng.float(7, 10) }          // low pass over the traffic
        else { y = g + rng.float(16, 46) }
        y = lerp(y, last.y, 0.35)
        y = max(y, g + minClear)
        if line.el && y < g + 24 && y > g + 9 { y = g + 25 }                    // clear of the elevated railway
        y = min(y, g + 160)
        // Never inside something.
        var c = SIMD3(t.x, y, t.y)
        for _ in 0..<12 where solids(near: c).contains(where: { $0.contains(c, margin: 8) }) { c.y += 6 }
        var n = c - last
        n.y *= 0.5
        n = simd_length(n) > 0.1 ? simd_normalize(n) : SIMD3(newDir.x, 0, newDir.y)
        return RingSpec(center: c, normal: n, radius: 7.5, dir: SIMD3(newDir.x, 0, newDir.y))
    }
}
