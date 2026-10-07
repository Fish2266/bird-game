import SceneKit
import simd

// The life of Dino Valley: herds grazing, drinking and wandering, T. rexes hunting them, fights that end with someone
// running for it, raptors and the odd tail swipe for birds that fly too low — and a director that makes sure the
// player gets to see the big stuff.

/// Something a dinosaur does with its body for a moment, layered over walking.
enum DinoAct {
    case none, roar, bite, snap, charge, tailSwing, rearUp, stagger, bellow, headButt, crouch

    var length: Float {
        switch self {
        case .none: return 0
        case .roar: return 2.4
        case .bite: return 1.3
        case .snap: return 0.75
        case .charge: return 2.0
        case .tailSwing: return 1.5
        case .rearUp: return 3.2
        case .stagger: return 1.0
        case .bellow: return 2.2
        case .headButt: return 1.4
        case .crouch: return 0.35
        }
    }

    /// When in the act (0…1) the blow lands.
    var strike: Float? {
        switch self {
        case .bite: return 0.52
        case .snap: return 0.5
        case .charge: return 0.7
        case .tailSwing: return 0.5
        case .rearUp: return 0.74
        case .headButt: return 0.55
        default: return nil
        }
    }
}

/// A sound a creature makes somewhere (the runtime turns it into gain and pan).
struct DinoCall {
    enum Kind { case roar, bellow, honk, grunt, shriek, screech, thud, stomp }
    var kind: Kind
    var at: SIMD3<Float>
    var pitch: Float
    var loud: Float
}

final class Dino {
    let sp: DinoSpecies
    let id: Int
    var kind: DinoKind { sp.kind }
    var pos: SIMD2<Float>
    var yaw: Float
    var speed: Float = 0
    let scale: Float
    var home: SIMD2<Float>
    let group: Int
    var leader: Bool
    var slot = SIMD2<Float>.zero

    var motion = DinoMotion()
    var pose: [simd_quatf] = []
    var mats: [simd_float4x4] = []
    var rootY: Float = 0
    var pitch: Float = 0
    var ground: Float = 0

    enum Mind { case graze, wander, drink, browse, alert, flee, hunt, fight, roam, chaseBird, rest }
    var mind: Mind = .graze
    var mindT: Float = 0
    var goal: SIMD2<Float>?
    var want: Float = 0
    /// Face this way (overrides heading for the goal) while fighting.
    var face: Float?
    var lookAt: SIMD3<Float>?

    var act: DinoAct = .none
    var actT: Float = 0
    var actSide: Float = 1
    var struck = false
    weak var foe: Dino?
    var fight: DinoFight?
    var morale: Float = 1
    var cooldown: Float = 0
    var nextMove: Float = 0
    var push = SIMD2<Float>.zero
    var probeT: Float = 0
    var stepPhase: Float = 0
    var distToPlayer: Float = 0
    var far = false
    var animSkip = 0
    /// Raptor leaps: height above the ground and vertical speed.
    var hop: Float = 0
    var hopV: Float = 0
    var hopVel = SIMD2<Float>.zero
    /// The last place it stood on dry, gentle ground (pushes and lunges never leave it in a river).
    var lastGood: SIMD2<Float>

    init(sp: DinoSpecies, id: Int, pos: SIMD2<Float>, yaw: Float, scale: Float, group: Int, leader: Bool) {
        self.sp = sp; self.id = id; self.pos = pos; self.yaw = yaw; self.scale = scale
        home = pos; self.group = group; self.leader = leader
        lastGood = pos
        motion.phase = Float(id % 7) / 7
        motion.time = Float(id) * 1.7
    }

    var forward: SIMD2<Float> { SIMD2(-sin(yaw), -cos(yaw)) }
    var position: SIMD3<Float> { SIMD3(pos.x, rootY, pos.y) }
    var busy: Bool { mind == .fight || mind == .flee || act != .none }

    /// World position of the snout, the tail tip, the head.
    var snout: SIMD3<Float> { sp.head >= 0 && mats.count > sp.head ? mats[sp.head].point(sp.snout) : position }
    var headPos: SIMD3<Float> { sp.head >= 0 && mats.count > sp.head ? mats[sp.head].origin : position }
    var tailTip: SIMD3<Float> {
        guard let t = sp.tail.last, mats.count > t else { return position }
        return mats[t].point(sp.tailTip)
    }

    func begin(_ a: DinoAct, side: Float = 1) {
        act = a; actT = 0; actSide = side; struck = false
    }

    /// Distance from a point to the nearest body capsule's surface (negative inside).
    func bodyDistance(_ p: SIMD3<Float>) -> Float {
        var best = Float.infinity
        guard mats.count == sp.rig.bones.count else { return simd_distance(p, position) - sp.length * scale * 0.3 }
        for c in sp.capsules {
            let m = mats[c.bone]
            let a = m.point(c.a), b = m.point(c.b)
            let ab = b - a
            let t = simd_clamp(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-5), 0, 1)
            best = min(best, simd_distance(p, a + ab * t) - c.r * scale)
        }
        return best
    }
}

/// Two dinosaurs going at it.
final class DinoFight {
    let a: Dino
    let b: Dino
    var t: Float = 0
    var over = false
    var winner: Dino?
    var announced = false
    var watched: Float = 0
    /// Rivals of one kind just shove until one backs off.
    let rivals: Bool
    init(_ a: Dino, _ b: Dino) { self.a = a; self.b = b; rivals = a.kind == b.kind }
    var center: SIMD2<Float> { (a.pos + b.pos) * 0.5 }
    var title: String { rivals ? "Two \(a.kind.plural) are locking horns" : "\(a.kind.name) vs \(b.kind.name)" }
}

final class DinoLife {
    let root = SCNNode()
    let terrain: DinoTerrain
    let mesh: DynamicMesh?
    private(set) var dinos: [Dino] = []
    private(set) var fights: [DinoFight] = []
    let pteros: PteroFlock
    private var cells: [ChunkKey: [Dino]] = [:]
    private var deadCells = Set<ChunkKey>()
    private var nextId = 0
    private var rng = SplitMix64(seed: 0xD1_70)
    static let cell: Float = 800
    var camera = SIMD3<Float>.zero
    private(set) var clock: Float = 0

    // Out to the runtime each frame.
    var notices: [String] = []
    var calls: [DinoCall] = []
    var dust: [(SIMD3<Float>, Float)] = []
    var hits: [HazardHit] = []
    var quake: Float = 0
    var threat: String?
    var rewards: [WorldReward] = []

    // The director.
    private var sinceFight: Float = 35
    private var nextFightIn: Float = 40
    private var huntNoticeT: Float = 0
    private var sawFight = false
    private var underLongneck = false

    init(terrain: DinoTerrain) {
        self.terrain = terrain
        mesh = DynamicMesh(maxVertices: 200_000, maxTriangles: 300_000, material: WorldMaterials.vertexColor(rough: 0.78))
        pteros = PteroFlock(terrain: terrain)
        if let mesh {
            mesh.node.castsShadow = true
            root.addChildNode(mesh.node)
        }
    }

    // MARK: Spawning

    private func groupFor(_ i: Int, _ j: Int) -> (DinoKind, Int, SIMD2<Float>)? {
        var r = cellRNG(i, j, 0xD1_6E)
        let roll = r.float()
        let kind: DinoKind
        let count: Int
        switch roll {
        case ..<0.16: kind = .longneck; count = Int(r.float(2, 3.99))
        case ..<0.38: kind = .trike; count = Int(r.float(3, 5.99))
        case ..<0.54: kind = .para; count = Int(r.float(4, 7.99))
        case ..<0.65: kind = .stego; count = Int(r.float(1, 3.99))
        case ..<0.74: kind = .ankylo; count = Int(r.float(1, 2.99))
        case ..<0.82: kind = .raptor; count = Int(r.float(3, 5.99))
        case ..<0.94: kind = .rex; count = 1
        default: return nil
        }
        let c = DinoLife.cell
        for _ in 0..<14 {
            let x = (Float(i) + r.float(0.1, 0.9)) * c, z = (Float(j) + r.float(0.1, 0.9)) * c
            if terrain.walkable(x, z) { return (kind, count, SIMD2(x, z)) }
        }
        return nil
    }

    /// Where the herd in a cell lives (for choosing a spawn with something to see).
    func groupKind(near x: Float, _ z: Float) -> (DinoKind, SIMD2<Float>)? {
        let c = DinoLife.cell
        guard let (k, _, p) = groupFor(Int(floor(x / c)), Int(floor(z / c))) else { return nil }
        return (k, p)
    }

    @discardableResult
    private func spawn(_ kind: DinoKind, count: Int, at p: SIMD2<Float>, group: Int, seed: UInt64) -> [Dino] {
        let sp = DinoSpecies.all[kind]!
        var r = SplitMix64(seed: seed | 1)
        var out: [Dino] = []
        let yaw0 = r.float(0, 6.28)
        for k in 0..<count {
            var q = p
            if k > 0 {
                let a = r.float(0, 6.28), d = sp.length * r.float(0.7, 1.4)
                q += SIMD2(cos(a), sin(a)) * d
                if !terrain.walkable(q.x, q.y) { q = p + SIMD2(cos(a), sin(a)) * sp.length * 0.4 }
            }
            let d = Dino(sp: sp, id: nextId, pos: q, yaw: yaw0 + r.float(-0.6, 0.6), scale: r.float(sp.scaleRange.lowerBound, sp.scaleRange.upperBound),
                         group: group, leader: k == 0)
            nextId += 1
            d.slot = q - p
            d.mindT = r.float(2, 12)
            d.mind = kind == .rex ? .roam : (kind == .raptor ? .roam : .graze)
            d.ground = terrain.height(q.x, q.y)
            d.rootY = d.ground + sp.hip * d.scale
            dinos.append(d)
            out.append(d)
        }
        return out
    }

    private func manageCells(_ player: SIMD3<Float>) {
        let c = DinoLife.cell
        let ci = Int(floor(player.x / c)), cj = Int(floor(player.z / c))
        for dj in -3...3 {
            for di in -3...3 {
                let k = ChunkKey(x: ci + di, z: cj + dj)
                guard cells[k] == nil, !deadCells.contains(k) else { continue }
                let center = SIMD2((Float(k.x) + 0.5) * c, (Float(k.z) + 0.5) * c)
                guard simd_distance(center, SIMD2(player.x, player.z)) < 2100 else { continue }
                if let (kind, n, p) = groupFor(k.x, k.z) {
                    cells[k] = spawn(kind, count: n, at: p, group: k.x &* 7919 &+ k.z, seed: UInt64(bitPattern: Int64(k.x &* 92821 &+ k.z &* 68917)))
                } else {
                    cells[k] = []
                }
            }
        }
        // Let go of herds far behind (unless they're in the middle of something).
        for (k, list) in cells {
            let center = SIMD2((Float(k.x) + 0.5) * c, (Float(k.z) + 0.5) * c)
            guard simd_distance(center, SIMD2(player.x, player.z)) > 2700 else { continue }
            if list.contains(where: { $0.fight != nil }) { continue }
            let ids = Set(list.map(\.id))
            dinos.removeAll { ids.contains($0.id) }
            cells.removeValue(forKey: k)
        }
        // Visitors brought in by the director go away when far too.
        dinos.removeAll { $0.group < 0 && $0.fight == nil && $0.distToPlayer > 2700 }
    }

    // MARK: Update

    func update(dt: Float, player: FlightModel) {
        clock += dt
        notices.removeAll(keepingCapacity: true)
        calls.removeAll(keepingCapacity: true)
        dust.removeAll(keepingCapacity: true)
        hits.removeAll(keepingCapacity: true)
        quake = 0
        threat = nil
        let p = player.pos
        if Int(clock * 2) != Int((clock - dt) * 2) { manageCells(p) }
        for d in dinos {
            d.distToPlayer = simd_length(SIMD2(d.pos.x - p.x, d.pos.y - p.z))
        }
        director(dt, player)
        for f in fights { updateFight(f, dt) }
        fights.removeAll { f in
            if f.over { f.a.fight = nil; f.b.fight = nil }
            return f.over
        }
        for d in dinos { think(d, dt, player) }
        separate(dt)
        for d in dinos { move(d, dt) }
        birdHazards(dt, player)
        pteros.update(dt: dt, player: player, life: self)
        discoveries(dt, player)
        draw()
    }

    // MARK: Minds

    private func think(_ d: Dino, _ dt: Float, _ player: FlightModel) {
        d.mindT -= dt
        d.cooldown = max(0, d.cooldown - dt)
        d.nextMove -= dt
        d.face = nil
        if d.fight != nil { return }
        switch d.mind {
        case .graze, .browse, .drink:
            d.want = 0
            if d.mindT <= 0 { pickNext(d) }
        case .wander, .roam:
            if let g = d.goal {
                let dist = simd_distance(g, d.pos)
                d.want = d.kind == .raptor ? d.sp.walk * 1.6 : d.sp.walk
                if dist < max(4, d.sp.length * 0.4) || d.mindT <= 0 { pickNext(d) }
            } else { pickNext(d) }
        case .alert:
            d.want = 0
            if d.mindT <= 0 { d.lookAt = nil; pickNext(d) }
        case .flee:
            d.want = d.sp.run
            if d.mindT <= 0 || (d.goal.map { simd_distance($0, d.pos) < 8 } ?? true) { d.mind = .graze; d.mindT = 6; d.goal = nil; d.morale = 1 }
        case .hunt:
            guard let prey = d.foe, dinos.contains(where: { $0 === prey }), d.mindT > 0 else { d.mind = .roam; d.foe = nil; d.cooldown = 30; pickNext(d); return }
            d.goal = prey.pos
            let dist = simd_distance(prey.pos, d.pos)
            d.want = dist > 220 ? d.sp.run * 0.72 : d.sp.run * 0.92
            d.lookAt = prey.position + SIMD3(0, prey.sp.hip, 0)
            let reach = (d.sp.length * d.scale + prey.sp.length * prey.scale) * 0.36
            if dist < reach + 4 { startFight(d, prey) }
            // Prey that notices runs or squares up.
            if dist < 60 && prey.mind != .fight && prey.mind != .flee {
                if prey.kind == .para || prey.kind == .raptor || prey.kind == .longneck && prey.scale < 0.95 {
                    flee(prey, from: d.pos, for: 14)
                } else if prey.act == .none {
                    prey.mind = .alert; prey.mindT = 3; prey.lookAt = d.position; prey.begin(.bellow); call(prey, .bellow)
                }
            }
        case .chaseBird:
            d.want = d.sp.run
            if d.mindT <= 0 { d.mind = .roam; d.cooldown = 6; pickNext(d) }
        case .rest:
            d.want = 0
            if d.mindT <= 0 { pickNext(d) }
        case .fight:
            break
        }
        // Herd members drift after their leader.
        if !d.leader, d.mind == .wander || d.mind == .graze, let lead = leader(of: d), lead.mind != .flee {
            let target = lead.pos + rotate(d.slot, lead.yaw)
            if simd_distance(target, d.pos) > d.sp.length * 1.2 {
                d.mind = .wander; d.goal = target; d.mindT = max(d.mindT, 3)
            }
        }
    }

    private func leader(of d: Dino) -> Dino? {
        dinos.first { $0.group == d.group && $0.leader && $0 !== d }
    }

    private func rotate(_ v: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
        SIMD2(v.x * cos(a) + v.y * sin(a), -v.x * sin(a) + v.y * cos(a))
    }

    /// Something to do next: graze, wander a little, drink at the river, stretch up into the trees, roar…
    private func pickNext(_ d: Dino) {
        d.lookAt = nil
        let r = rng.float()
        switch d.kind {
        case .rex:
            if r < 0.15 { d.mind = .rest; d.mindT = rng.float(4, 9); if rng.float() < 0.5 { d.begin(.roar); call(d, .roar) } }
            else { d.mind = .roam; d.mindT = rng.float(20, 40); d.goal = walkableNear(d.home, 520) ?? d.home }
        case .raptor:
            if d.leader || leader(of: d) == nil {
                d.mind = .roam; d.mindT = rng.float(10, 22); d.goal = walkableNear(d.home, 380) ?? d.home
            } else {
                d.mind = .wander; d.mindT = 4
            }
        default:
            if d.leader || leader(of: d) == nil {
                if r < 0.45 {
                    d.mind = d.kind == .longneck && rng.float() < 0.45 ? .browse : .graze
                    d.mindT = rng.float(8, 22)
                } else if r < 0.6, let w = waterNear(d.pos) {
                    d.mind = .wander; d.goal = w; d.mindT = 40
                } else {
                    d.mind = .wander; d.mindT = rng.float(12, 30)
                    d.goal = walkableNear(d.home, 260) ?? d.home
                }
                if rng.float() < 0.12 { d.begin(.bellow); call(d, d.kind == .para ? .honk : .bellow) }
            } else {
                d.mind = r < 0.7 ? (d.kind == .longneck && rng.float() < 0.4 ? .browse : .graze) : .wander
                d.mindT = rng.float(5, 14)
                if d.mind == .wander { d.goal = d.pos + SIMD2(rng.float(-20, 20), rng.float(-20, 20)) }
            }
        }
    }

    private func walkableNear(_ c: SIMD2<Float>, _ r: Float) -> SIMD2<Float>? {
        for _ in 0..<8 {
            let a = rng.float(0, 6.28), d = rng.float(r * 0.2, r)
            let q = c + SIMD2(cos(a), sin(a)) * d
            if terrain.walkable(q.x, q.y) { return q }
        }
        return nil
    }

    /// A spot on the river bank nearby, to drink.
    private func waterNear(_ p: SIMD2<Float>) -> SIMD2<Float>? {
        for _ in 0..<10 {
            let a = rng.float(0, 6.28), d = rng.float(20, 160)
            let q = p + SIMD2(cos(a), sin(a)) * d
            let h = terrain.height(q.x, q.y)
            if h > 1.8 && h < 3.2 { return q }
        }
        return nil
    }

    func flee(_ d: Dino, from threat: SIMD2<Float>, for t: Float) {
        var away = d.pos - threat
        if simd_length(away) < 0.1 { away = d.forward }
        away = simd_normalize(away)
        d.mind = .flee; d.mindT = t
        d.goal = walkableNear(d.pos + away * 140, 60) ?? d.pos + away * 120
        d.lookAt = nil
        if d.act == .none && rng.float() < 0.6 { call(d, d.kind == .para ? .honk : .bellow) }
    }

    // MARK: Moving

    private func angleTo(_ d: Dino, _ g: SIMD2<Float>) -> Float { atan2(-(g.x - d.pos.x), -(g.y - d.pos.y)) }

    @inline(__always) private func wrap(_ a: Float) -> Float {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    private func move(_ d: Dino, _ dt: Float) {
        // Heading.
        var desired = d.yaw
        if let f = d.face { desired = f } else if let g = d.goal, d.want > 0.05 { desired = angleTo(d, g) }
        // Keep out of cliffs and deep water: look ahead now and then.
        d.probeT -= dt
        if d.probeT <= 0 && d.speed > 0.3 {
            d.probeT = 0.5
            let ahead = d.pos + d.forward * (d.sp.length * d.scale * 0.5 + d.speed * 1.6)
            let wade = d.kind == .longneck
            let h = terrain.height(ahead.x, ahead.y)
            if !terrain.walkable(ahead.x, ahead.y) && !(wade && h > -2.5 && h < 4) {
                // Turn back toward home.
                d.goal = walkableNear(d.home, 200) ?? d.home
                if d.mind == .flee { d.goal = walkableNear(d.pos - d.forward * 60, 40) ?? d.home }
            }
        }
        let turnRate = d.sp.turn * (1 + 0.6 * smoothstep(d.sp.walk, d.sp.run, d.speed)) * (d.mind == .fight ? 1.4 : 1)
        let delta = wrap(desired - d.yaw)
        let turn = clamp(delta, -turnRate * dt, turnRate * dt)
        d.yaw = wrap(d.yaw + turn)
        d.motion.turning = turn / max(dt, 1e-4)
        // Speed: slow down to turn sharply.
        var want = d.want
        if abs(delta) > 0.9 { want = min(want, d.sp.walk * 0.6) }
        let accel = d.sp.run * 0.45, brake = d.sp.run * 0.9
        d.speed += clamp(want - d.speed, -brake * dt, accel * dt)
        d.speed = max(0, d.speed)
        let step = d.forward * d.speed * dt + d.push * dt
        d.push *= max(0, 1 - 3 * dt)
        if simd_length_squared(step) > 1e-8 {
            let next = d.pos + step
            let gNext = terrain.height(next.x, next.y)
            let deep: Float = d.kind == .longneck ? -3.2 : -0.6
            let climb = (gNext - d.ground) / max(simd_length(step), 0.01)
            if (gNext < deep && gNext < d.ground) || (climb > 0.9 && d.hop == 0) {
                // Blocked: stop and find somewhere else to go.
                d.speed *= 0.5
                d.push = .zero
                if d.probeT > 0.1 { d.probeT = 0 }
                if d.fight == nil, d.mind != .hunt { d.goal = walkableNear(d.home, 160) ?? d.home }
            } else {
                d.pos = next
            }
        }
        // Raptor leaps.
        if d.hop > 0 || d.hopV > 0 {
            d.hopV -= 22 * dt
            d.hop += d.hopV * dt
            d.pos += d.hopVel * dt
            if d.hop <= 0 { d.hop = 0; d.hopV = 0; d.hopVel = .zero; dust.append((d.position, 0.6)) }
        }
        d.motion.speed = d.speed
        d.motion.step(d.sp, dt: dt, scale: d.scale)
        animate(d, dt)
        // Stand on the ground, tilted with the slope.
        let half = d.sp.length * d.scale * 0.22
        let f = d.forward * half
        var gC = terrain.height(d.pos.x, d.pos.y)
        if gC < (d.kind == .longneck ? -3.2 : -0.6) && d.hop == 0 {
            d.pos = d.lastGood
            gC = terrain.height(d.pos.x, d.pos.y)
        } else if d.hop == 0 {
            d.lastGood = d.pos
        }
        let gF = terrain.height(d.pos.x + f.x, d.pos.y + f.y), gB = terrain.height(d.pos.x - f.x, d.pos.y - f.y)
        d.ground = gC
        let slope = clamp(atan2(gF - gB, 2 * half), -0.32, 0.32)
        d.pitch += (slope - d.pitch) * min(1, dt * 4)
        let base = d.kind == .longneck ? gC : max(gC, -0.5)
        d.rootY = base + (d.sp.hip - d.motion.bob(d.sp)) * d.scale * (1 - 0.18 * d.motion.crouch) + d.hop
        // Footfalls: big ones you can hear (and feel).
        if d.kind == .longneck || d.kind == .rex, d.distToPlayer < 260, d.speed > 0.4 {
            let steps: Float = 2
            let s = floor(d.motion.phase * steps)
            if s != d.stepPhase {
                d.stepPhase = s
                let near = smoothstep(260, 30, d.distToPlayer)
                calls.append(DinoCall(kind: .thud, at: d.position, pitch: d.kind == .longneck ? 0.7 : 1, loud: near * (d.kind == .longneck ? 1 : 0.7)))
                if d.distToPlayer < 90 { quake = max(quake, near * (d.kind == .longneck ? 0.18 : 0.1) * (1 + smoothstep(d.sp.walk, d.sp.run, d.speed))) }
            }
        }
    }

    /// Fold the current act and mind into the body's motion.
    private func animate(_ d: Dino, _ dt: Float) {
        var m = d.motion
        // Resting values for this frame (eased toward).
        var neck: Float = 0, jaw: Float = 0, lunge: Float = 0, rear: Float = 0, crouch: Float = 0, shake: Float = 0, swing: Float = 0
        switch d.mind {
        case .graze: neck = -0.85 + 0.15 * sin(m.time * 0.7 + Float(d.id)); jaw = max(0, sin(m.time * 4)) * 0.15
        case .drink: neck = -1
        case .browse: neck = 0.9 + 0.1 * sin(m.time * 0.5); jaw = max(0, sin(m.time * 3)) * 0.2
        case .alert: neck = 0.4
        case .hunt: neck = -0.15
        case .fight: neck = d.kind == .trike ? -0.35 : 0.1
        default: break
        }
        if d.act != .none {
            d.actT += dt
            let u = d.actT / d.act.length
            let bell = sin(.pi * clamp(u, 0, 1))
            switch d.act {
            case .roar, .bellow:
                neck = 0.75 * bell; jaw = smoothstep(0.05, 0.25, u) * smoothstep(1, 0.75, u); shake = d.act == .roar ? 0.35 * bell : 0.1 * bell
            case .bite, .snap:
                let wind = smoothstep(0, 0.35, u) * smoothstep(0.52, 0.4, u)
                let strike = smoothstep(0.35, 0.5, u) * smoothstep(1, 0.6, u)
                neck = 0.35 * wind - 0.1 * strike; jaw = max(wind, 0) * 0.95 + (u < 0.52 ? 0 : 0); lunge = strike
                if u > 0.52 { jaw = 0.1 * smoothstep(1, 0.6, u) }
            case .charge:
                crouch = 0.7 * bell; neck = -0.55 * bell; lunge = smoothstep(0.55, 0.72, u) * smoothstep(1, 0.8, u)
            case .tailSwing:
                swing = d.actSide * sin(.pi * clamp(u * 1.15, 0, 1)) * 1.1
            case .rearUp:
                rear = smoothstep(0, 0.45, u) * smoothstep(0.78, 0.66, u); neck = 0.6 * rear; jaw = 0.4 * rear
            case .stagger:
                shake = 0.6 * bell; neck = 0.25 * bell; jaw = 0.5 * bell
            case .headButt:
                crouch = 0.5 * bell; neck = -0.6 * bell; lunge = smoothstep(0.4, 0.55, u) * smoothstep(1, 0.7, u)
            case .crouch:
                crouch = bell
            case .none: break
            }
            if u >= 1 { d.act = .none; d.actT = 0 }
        }
        let k = min(1, dt * 5)
        m.neck += (neck - m.neck) * k
        m.jaw += (jaw - m.jaw) * min(1, dt * 12)
        m.lunge += (lunge - m.lunge) * min(1, dt * 14)
        m.rear += (rear - m.rear) * min(1, dt * 6)
        m.crouch += (crouch - m.crouch) * min(1, dt * 8)
        m.shake += (shake - m.shake) * min(1, dt * 10)
        m.tailSwing += (swing - m.tailSwing) * min(1, dt * 9)
        // Look at whatever it's watching.
        var ly: Float = 0, lp: Float = 0
        if let t = d.lookAt {
            let to = SIMD2(t.x - d.pos.x, t.z - d.pos.y)
            ly = clamp(wrap(atan2(-to.x, -to.y) - d.yaw), -1.1, 1.1)
            lp = clamp(atan2(t.y - d.headPos.y, max(simd_length(to), 1)), -0.6, 0.8)
        } else {
            ly = sin(m.time * 0.23 + Float(d.id)) * 0.35
        }
        m.lookYaw += (ly - m.lookYaw) * min(1, dt * 3)
        m.lookPitch += (lp - m.lookPitch) * min(1, dt * 3)
        d.motion = m
    }

    /// Keep bodies from walking through each other.
    private func separate(_ dt: Float) {
        let n = dinos.count
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            let a = dinos[i]
            for j in (i + 1)..<n {
                let b = dinos[j]
                let d = b.pos - a.pos
                let r = (a.sp.length * a.scale + b.sp.length * b.scale) * 0.26
                let l2 = simd_length_squared(d)
                guard l2 < r * r, l2 > 1e-4 else { continue }
                let l = sqrt(l2)
                let push = d / l * (r - l) * min(1, dt * 3)
                let wa = b.sp.length / (a.sp.length + b.sp.length)
                a.pos -= push * wa
                b.pos += push * (1 - wa)
            }
        }
    }

    // MARK: Fights

    private func startFight(_ a: Dino, _ b: Dino) {
        guard a.fight == nil, b.fight == nil else { return }
        if b.kind == .para || b.kind == .raptor {
            // Too quick to stand and fight: it bolts, and the rex roars after it.
            flee(b, from: a.pos, for: 16)
            a.mind = .rest; a.mindT = 4; a.foe = nil; a.cooldown = 40
            a.begin(.roar); call(a, .roar)
            return
        }
        let f = DinoFight(a, b)
        a.fight = f; b.fight = f
        a.mind = .fight; b.mind = .fight
        a.foe = b; b.foe = a
        a.morale = 1; b.morale = b.kind == .longneck ? 1.4 : 1
        a.nextMove = 0.8; b.nextMove = 1.6
        fights.append(f)
        a.begin(.roar); call(a, a.kind == .rex ? .roar : .bellow)
        sinceFight = 0
    }

    private func updateFight(_ f: DinoFight, _ dt: Float) {
        let a = f.a, b = f.b
        f.t += dt
        guard dinos.contains(where: { $0 === a }), dinos.contains(where: { $0 === b }) else { f.over = true; return }
        let d = b.pos - a.pos
        let dist = max(simd_length(d), 0.01)
        let dir = d / dist
        let reach = (a.sp.length * a.scale + b.sp.length * b.scale) * 0.34
        let toB = atan2(-dir.x, -dir.y), toA = atan2(dir.x, dir.y)
        // The aggressor faces in; the defender squares up horns-first, or turns its weapon of a tail to the threat.
        a.face = toB
        switch b.kind {
        case .stego, .ankylo: b.face = wrap(toA + .pi + 0.55 * b.actSide)
        default: b.face = toA
        }
        a.lookAt = b.position + SIMD3(0, b.sp.hip * b.scale, 0)
        b.lookAt = a.position + SIMD3(0, a.sp.hip * a.scale, 0)
        // Close in, back off, circle.
        let circle = SIMD2(-dir.y, dir.x) * sin(f.t * 0.4) * 0.8
        a.want = dist > reach + 2 ? a.sp.walk * 1.4 : (dist < reach - 1.5 ? 0 : 0.4)
        a.goal = b.pos + circle * 10
        if dist < reach - 1.5 { a.push -= dir * 1.5 * dt * 10 }
        b.want = dist < reach - 2 ? 0.5 : 0
        b.goal = b.pos - dir * 6
        // Moves.
        func choose(_ x: Dino, _ other: Dino) {
            guard x.act == .none, x.nextMove <= 0 else { return }
            let r = rng.float()
            let close = simd_distance(x.pos, other.pos) < reach + 2.5
            switch x.kind {
            case .rex:
                if r < 0.62 && close { x.begin(.bite) } else if r < 0.85 { x.begin(.roar); call(x, .roar) } else { x.begin(.snap) }
                x.nextMove = rng.float(0.8, 2.2)
            case .trike:
                if f.rivals || r < 0.55 { x.begin(f.rivals ? .headButt : .charge); call(x, .grunt) } else { x.begin(.bellow); call(x, .bellow) }
                x.nextMove = rng.float(1.2, 2.6)
            case .stego, .ankylo:
                if r < 0.75 { x.begin(.tailSwing, side: rng.float() < 0.5 ? -1 : 1); call(x, .grunt) } else { x.begin(.bellow); call(x, .bellow) }
                x.nextMove = rng.float(0.9, 2.2)
            case .longneck:
                if r < 0.5 { x.begin(.rearUp); call(x, .bellow) } else { x.begin(.tailSwing, side: rng.float() < 0.5 ? -1 : 1) }
                x.nextMove = rng.float(1.5, 3.5)
            default:
                x.nextMove = 2
            }
        }
        choose(a, b)
        choose(b, a)
        // Lunges carry the body forward.
        for (x, other) in [(a, b), (b, a)] where x.act == .bite || x.act == .charge || x.act == .headButt {
            let u = x.actT / x.act.length
            if u > 0.35 && u < 0.6 {
                let to = simd_normalize(other.pos - x.pos)
                x.pos += to * (x.act == .charge ? 7 : 4) * dt
            }
        }
        resolve(a, against: b, f)
        resolve(b, against: a, f)
        // Done?
        let loser: Dino? = a.morale <= 0 ? a : (b.morale <= 0 ? b : nil)
        if let l = loser {
            let w = l === a ? b : a
            f.winner = w
            f.over = true
            for x in [a, b] { x.mind = .graze; x.mindT = 4; x.face = nil; x.lookAt = nil; x.foe = nil; x.cooldown = 45 }
            flee(l, from: w.pos, for: f.rivals ? 6 : 16)
            w.mind = .alert; w.mindT = 4; w.lookAt = l.position
            w.begin(w.kind == .rex ? .roar : .bellow); call(w, w.kind == .rex ? .roar : .bellow)
            if f.announced && l.distToPlayer < 1400 {
                if f.rivals { notices.append("The \(l.kind.name) backed down.") }
                else if l.kind == .rex { notices.append("The \(w.kind.name) drove the T. rex off!") }
                else { notices.append("The \(w.kind.name) won — the \(l.kind.name) is running for it!") }
            }
        } else if f.t > (f.rivals ? 22 : 40) {
            // Neither gives in: they go their separate ways.
            f.over = true
            for x in [a, b] { x.mind = .graze; x.mindT = 6; x.face = nil; x.lookAt = nil; x.foe = nil; x.cooldown = 40 }
            flee(a, from: b.pos, for: 8)
            if f.announced && a.distToPlayer < 1400 { notices.append("The \(a.kind.name) gave up.") }
        }
    }

    /// When an attack reaches its moment, see if it lands.
    private func resolve(_ x: Dino, against y: Dino, _ f: DinoFight) {
        guard let s = x.act.strike, !x.struck, x.actT / x.act.length >= s else { return }
        x.struck = true
        var weapon: SIMD3<Float>
        var reach: Float
        var harm: Float
        switch x.act {
        case .bite, .snap: weapon = x.snout; reach = 1.4 * x.scale; harm = 0.3
        case .charge, .headButt: weapon = x.snout + SIMD3(0, 0.6, 0); reach = 1.6 * x.scale; harm = f.rivals ? 0.22 : 0.34
        case .tailSwing: weapon = x.tailTip; reach = 2.2 * x.scale; harm = x.kind == .ankylo ? 0.42 : 0.36
        case .rearUp:
            let front = x.sp.legs.filter(\.front).map { x.mats.count > $0.toes ? x.mats[$0.toes].origin : x.position }
            weapon = front.isEmpty ? x.position : front.reduce(.zero, +) / Float(front.count); reach = 4.5; harm = 0.4
            dust.append((weapon, 1.6)); calls.append(DinoCall(kind: .stomp, at: weapon, pitch: 0.8, loud: 1))
            quake = max(quake, smoothstep(300, 40, x.distToPlayer) * 0.5)
        default: return
        }
        let gap = y.bodyDistance(weapon)
        guard gap < reach else { return }
        // A hit: the victim reels back, loses heart; dust flies.
        y.begin(.stagger)
        let away = simd_normalize(y.pos - x.pos + SIMD2(0.001, 0))
        y.push += away * (x.act == .charge ? 6 : 4)
        y.morale -= harm * rng.float(0.8, 1.2)
        x.morale = min(1.4, x.morale + 0.05)
        dust.append((weapon, 1.1))
        calls.append(DinoCall(kind: .thud, at: weapon, pitch: 1.2, loud: 1))
        call(y, y.kind == .rex ? .roar : .bellow, pitch: 1.15)
        quake = max(quake, smoothstep(240, 30, x.distToPlayer) * 0.35)
    }

    /// The bird flew into it: it notices.
    func bumped(_ d: Dino, by p: SIMD3<Float>) {
        guard d.act == .none else { return }
        d.lookAt = p
        if d.fight == nil && d.mind != .flee && d.mind != .hunt { d.mind = .alert; d.mindT = 2.5 }
        d.begin(d.kind == .rex ? .roar : .bellow)
        call(d, d.kind == .rex ? .roar : .bellow)
    }

    private func call(_ d: Dino, _ k: DinoCall.Kind, pitch: Float = 1) {
        guard d.distToPlayer < 1600 else { return }
        var kind = k
        if d.kind == .para && k == .bellow { kind = .honk }
        if d.kind == .raptor { kind = .shriek }
        let p = pitch * (d.kind == .longneck ? 0.6 : d.kind == .rex ? 1 : d.kind == .raptor ? 1.6 : 1.1) / d.scale
        calls.append(DinoCall(kind: kind, at: d.headPos, pitch: p, loud: 1))
    }

    // MARK: The director

    /// Makes sure something big happens where the player can see it every minute or so: a hunt, and a fight.
    private func director(_ dt: Float, _ player: FlightModel) {
        sinceFight += dt
        huntNoticeT -= dt
        let p = SIMD2(player.pos.x, player.pos.z)
        // Tell the player about fights near them (once each).
        for f in fights where !f.announced && simd_distance(f.center, p) < 1100 {
            f.announced = true
            notices.append("Dino fight! \(f.title) — \(where_(f.center, player))")
        }
        guard fights.isEmpty || !fights.contains(where: { simd_distance($0.center, p) < 1300 }) else { return }
        guard sinceFight > nextFightIn else { return }
        guard !dinos.contains(where: { $0.mind == .hunt && $0.distToPlayer < 1300 }) else { return }
        nextFightIn = rng.float(50, 85)
        sinceFight = nextFightIn * 0.5
        // A hunter close by, or one walking in from over the hill.
        var hunter = dinos.filter { $0.kind == .rex && $0.fight == nil && $0.cooldown <= 0 && $0.distToPlayer < 1100 }
            .min { $0.distToPlayer < $1.distToPlayer }
        let preyKinds: Set<DinoKind> = [.trike, .stego, .ankylo, .longneck, .para]
        // Armoured, horned and spiked prey make the best fights.
        func weight(_ k: DinoKind) -> Float {
            switch k { case .trike: return 0.55; case .stego: return 0.65; case .ankylo: return 0.7; case .longneck: return 1.25; default: return 1 }
        }
        func preyNear(_ q: SIMD2<Float>, within r: Float) -> Dino? {
            dinos.filter { preyKinds.contains($0.kind) && $0.fight == nil && $0.mind != .flee && simd_distance($0.pos, q) < r && $0.distToPlayer < 900 }
                .sorted { simd_distance($0.pos, q) * weight($0.kind) < simd_distance($1.pos, q) * weight($1.kind) }
                .prefix(4).first { reachable(q, $0.pos) }
        }
        // Only a hunter with prey close by will do; otherwise bring one in.
        if let h = hunter, preyNear(h.pos, within: 320) == nil { hunter = nil }
        if hunter == nil, let prey = preyNear(p, within: 700) {
            // Bring a rex in from 150–280 m off, out of the player's way.
            for _ in 0..<16 {
                let a = rng.float(0, 6.28), r = rng.float(150, 280)
                let q = prey.pos + SIMD2(cos(a), sin(a)) * r
                if terrain.walkable(q.x, q.y), simd_distance(q, p) > 160, reachable(q, prey.pos) {
                    let rex = spawn(.rex, count: 1, at: q, group: -1 - nextId, seed: rng.next())[0]
                    rex.yaw = atan2(-(prey.pos.x - q.x), -(prey.pos.y - q.y))
                    hunter = rex
                    break
                }
            }
        }
        if let h = hunter {
            // Rivals instead, now and then, when there's a herd of trikes about.
            if rng.float() < 0.25, let t = dinos.first(where: { $0.kind == .trike && $0.fight == nil && $0.distToPlayer < 700 }),
               let t2 = dinos.first(where: { $0.kind == .trike && $0 !== t && $0.group == t.group && $0.fight == nil }) {
                t.mind = .hunt; t.foe = t2; t.mindT = 30
                return
            }
            guard let prey = preyNear(h.pos, within: 320) else { return }
            h.mind = .hunt; h.foe = prey; h.mindT = 40 + simd_distance(prey.pos, h.pos) / 4
            if huntNoticeT <= 0 && h.distToPlayer < 1200 {
                huntNoticeT = 30
                notices.append("A T. rex is on the hunt — \(where_(h.pos, player))")
            }
        } else if let t = dinos.first(where: { $0.kind == .trike && $0.fight == nil && $0.distToPlayer < 900 }),
                  let t2 = dinos.first(where: { $0.kind == .trike && $0 !== t && $0.group == t.group && $0.fight == nil }) {
            // No predator about: two trikes settle who's boss.
            t.mind = .hunt; t.foe = t2; t.mindT = 30
        }
    }

    /// Can something walk straight from a to b (no river or cliff in the way)?
    func reachable(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        let d = simd_distance(a, b)
        let n = max(2, Int(d / 14))
        var last = terrain.height(a.x, a.y)
        for k in 1...n {
            let q = a + (b - a) * (Float(k) / Float(n))
            let h = terrain.height(q.x, q.y)
            if h < -0.5 || abs(h - last) > 9 { return false }
            last = h
        }
        return true
    }

    /// "ahead", "to your left"… for a place relative to the bird.
    func where_(_ q: SIMD2<Float>, _ player: FlightModel) -> String {
        let to = q - SIMD2(player.pos.x, player.pos.z)
        let f = SIMD2(player.forward.x, player.forward.z)
        guard simd_length(to) > 1, simd_length(f) > 0.01 else { return "right below you" }
        let a = atan2(f.x * to.y - f.y * to.x, simd_dot(f, to))
        let dist = simd_length(to)
        let far = dist > 450 ? " in the distance" : ""
        if abs(a) < 0.6 { return "dead ahead" + far }
        if abs(a) > 2.4 { return "behind you" + far }
        return (a > 0 ? "to your right" : "to your left") + far
    }

    // MARK: The bird

    private func birdHazards(_ dt: Float, _ player: FlightModel) {
        let p = player.pos
        let agl = p.y - terrain.height(p.x, p.z)
        for d in dinos where d.distToPlayer < 60 && d.fight == nil {
            switch d.kind {
            case .rex:
                // Fly near its head and it'll watch you… and snap.
                let hp = d.headPos
                let dist = simd_distance(hp, p)
                if dist < 22 {
                    d.lookAt = p
                    if dist < 18 { threat = "Watch out — T. rex!" }
                    if dist < 10.5 && d.act == .none && d.cooldown <= 0 {
                        d.begin(.snap); d.cooldown = 1.6; call(d, .roar, pitch: 1.2)
                        d.face = atan2(-(p.x - d.pos.x), -(p.z - d.pos.y))
                    }
                }
                if d.act == .snap && !d.struck && d.actT / d.act.length >= 0.5 {
                    d.struck = true
                    if simd_distance(d.snout, p) < 3.4 * d.scale {
                        let away = simd_normalize(p - d.snout + SIMD3(0, 0.3, 0))
                        hits.append(HazardHit(impulse: away * 16 + SIMD3(0, 6, 0), coins: 4, kind: .wall))
                        notices.append("CHOMP! The T. rex nearly had you.")
                        quake = max(quake, 0.5)
                    }
                }
            case .raptor:
                // Low birds get jumped.
                if agl < 7, d.distToPlayer < 24, d.hop == 0, d.cooldown <= 0, d.mind != .flee {
                    d.mind = .chaseBird; d.mindT = 4
                    d.goal = SIMD2(p.x, p.z) + SIMD2(player.forward.x, player.forward.z) * 4
                    d.lookAt = p
                    threat = threat ?? "Raptors below!"
                    if d.distToPlayer < 9 {
                        // Leap at it.
                        let lead = p + player.velocity * 0.45
                        let to = SIMD2(lead.x - d.pos.x, lead.z - d.pos.y)
                        d.hopV = clamp(sqrt(2 * 22 * max(1, lead.y - d.ground - d.sp.hip * 0.5)), 6, 13)
                        d.hop = 0.01
                        d.hopVel = to / max(d.hopV / 22 * 2, 0.4)
                        d.cooldown = 5
                        d.begin(.snap)
                        call(d, .shriek)
                    }
                }
                if d.hop > 0.5, simd_distance(d.snout, p) < 1.9 {
                    hits.append(HazardHit(impulse: simd_normalize(p - d.position + SIMD3(0, 1, 0)) * 11, coins: 2, kind: .wall))
                    notices.append("A raptor jumped you!")
                    d.hopVel *= 0.3
                }
            case .stego, .ankylo:
                // Too close to that tail.
                let tip = d.tailTip
                if simd_distance(tip, p) < 7.5 && agl < 9 && d.act == .none && d.cooldown <= 0 {
                    let side = SIMD2(cos(d.yaw), -sin(d.yaw))
                    let rel = SIMD2(p.x - d.pos.x, p.z - d.pos.y)
                    d.begin(.tailSwing, side: simd_dot(rel, side) > 0 ? -1 : 1)
                    d.cooldown = 3
                    call(d, .grunt)
                }
                if d.act == .tailSwing && !d.struck && d.actT / d.act.length >= 0.5 {
                    d.struck = true
                    if simd_distance(d.tailTip, p) < 2.8 * d.scale {
                        hits.append(HazardHit(impulse: simd_normalize(p - d.position + SIMD3(0, 2, 0)) * 15, coins: 3, kind: .wall))
                        notices.append("Thwack! Mind the tail.")
                        quake = max(quake, 0.4)
                    }
                }
            default:
                // Herbivores look up at a low bird; parasaurolophus honk and trot off.
                if agl < 14 && d.distToPlayer < 30 && d.mind != .alert && d.mind != .flee && d.act == .none {
                    d.mind = .alert; d.mindT = 3; d.lookAt = p
                    if d.kind == .para && rng.float() < 0.5 { call(d, .honk); flee(d, from: SIMD2(p.x, p.z), for: 5) }
                }
            }
        }
    }

    // MARK: Rewards

    private func discoveries(_ dt: Float, _ player: FlightModel) {
        let p = player.pos
        if !sawFight {
            for f in fights where simd_distance(f.center, SIMD2(p.x, p.z)) < 220 {
                f.watched += dt
                if f.watched > 3 {
                    sawFight = true
                    rewards.append(WorldReward(id: "dino.fight", title: "You saw a dinosaur fight!", coins: 40, once: true))
                }
            }
        }
        if !underLongneck {
            for d in dinos where d.kind == .longneck && d.distToPlayer < 30 {
                // Under the belly or the neck, between the legs.
                let body = d.position
                let agl = p.y - d.ground
                if agl > 0.5 && p.y < body.y - 1.2 && d.bodyDistance(p) < 3 {
                    underLongneck = true
                    rewards.append(WorldReward(id: "dino.under", title: "You flew under a Brachiosaurus!", coins: 30, once: true))
                }
            }
        }
    }

    // MARK: Drawing

    private func draw() {
        guard let mesh else { return }
        mesh.begin()
        let cam = camera
        for d in dinos {
            let dc = simd_distance(SIMD3(d.pos.x, d.rootY, d.pos.y), cam)
            guard dc < 2300 else { d.mats.removeAll(keepingCapacity: true); continue }
            d.far = dc > 260
            // Distant ones can pose less often.
            d.animSkip += 1
            if d.far && dc > 900 && d.animSkip % 3 != 0 && !d.mats.isEmpty {
                d.sp.rig.draw(d.mats, into: mesh, far: true)
                continue
            }
            d.sp.pose(d.motion, into: &d.pose)
            let root = trs(SIMD3(d.pos.x, d.rootY, d.pos.y), yawQuat(d.yaw) * rotX(d.pitch + d.motion.rear * 0.55), d.scale)
            d.sp.rig.solve(root: root, pose: d.pose, into: &d.mats)
            d.sp.rig.draw(d.mats, into: mesh, far: d.far)
        }
        pteros.draw(into: mesh, camera: cam)
        mesh.end()
    }
}
