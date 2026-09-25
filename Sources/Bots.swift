import SceneKit
import simd

/// Single-player fight settings (Play tab), saved between launches.
enum BotSettings {
    static let difficulties = ["Easy", "Normal", "Hard"]
    static var count: Int {
        get { clamp(UserDefaults.standard.object(forKey: "pvp.bots") as? Int ?? 3, 1, 5) }
        set { UserDefaults.standard.set(clamp(newValue, 1, 5), forKey: "pvp.bots") }
    }
    /// 0 easy, 1 normal, 2 hard.
    static var difficulty: Int {
        get { clamp(UserDefaults.standard.object(forKey: "pvp.difficulty") as? Int ?? 1, 0, 2) }
        set { UserDefaults.standard.set(clamp(newValue, 0, 2), forKey: "pvp.difficulty") }
    }
}

/// A computer-controlled bird for single-player fights. It flies with the same flight model as the player
/// (so it banks, stalls and dives the same way) and fights like a person would: attack runs at one bird,
/// shoot once it's lined up (not always accurately), then break away. It never tries to ram.
final class BotPilot {
    let id: Int
    let species: Species
    let weapon: WeaponKind
    let attack: Int
    let tuning: CombatTuning
    let flight = FlightModel()
    var fighter = Fighter()
    let avatar: OtherBird
    var knockouts = 0
    /// Seconds until a knocked-out bot comes back (0 = flying or out for good).
    var respawnIn: Float = 0
    private(set) var target: Int?
    private var retarget: Float = 0
    private var lockTime: Float = 0
    private var reaction: Float
    private var flapPhase: Float
    private var input = FlightInput()
    private var wingL = WingPose(), wingR = WingPose()
    private var rng: SplitMix64
    /// Skill 0…1: reaction time, accuracy and how often it breaks off to dodge.
    private let skill: Float
    private var evade: Float = 0
    private var evadeDir = SIMD3<Float>(1, 0, 0)
    private var goal = SIMD3<Float>(0, 0, 0)

    static let names = ["Beaky", "Sir Flaps", "Gustav", "Pip", "Captain Feathers", "Nimbus", "Squawk", "Talon"]

    init(id: Int, name: String, color: Int, species: Species, levels: Int, skill: Float, seed: UInt64) {
        self.id = id
        self.species = species
        self.skill = skill
        weapon = species.weapon
        let pts = BirdStat.allCases.map { min(species.base[$0.rawValue] + min(levels, species.maxLevel), StatRules.maxPoints) }
        attack = pts[BirdStat.attack.rawValue]
        tuning = CombatTuning(points: pts)
        flight.tuning = FlightTuning(points: pts)
        rng = SplitMix64(seed: seed)
        reaction = 1
        flapPhase = rng.float(0, 6)
        avatar = OtherBird(id: id, name: name, color: color, species: species.id, bot: true)
        reaction = nextReaction()
    }

    private func nextReaction() -> Float { rng.float(0.5, 1.1) * (1.5 - skill) }

    /// Start of a round.
    func place(_ p: SIMD3<Float>, yaw: Float) {
        flight.reset(at: p, yaw: yaw)
        flight.speed = 16
        fighter.newRound()
        respawnIn = 0
        knockouts = 0
        target = nil
        evade = 0
        syncAvatar()
    }

    /// Back in after a knock-out (lives are kept).
    func respawn(_ p: SIMD3<Float>, yaw: Float) {
        flight.reset(at: p, yaw: yaw)
        flight.speed = 16
        fighter.reset(shield: 3)
        target = nil
        evade = 0
        syncAvatar()
    }

    /// Hold still on the start grid (countdown).
    func hold(dt: Float) {
        flapPhase += dt * 2 * .pi * 0.4
        let e = 0.1 + 0.08 * sin(flapPhase)
        wingL = WingPose(elevation: e, bend: 0); wingR = wingL
        syncAvatar()
    }

    /// Decide where to fly and whether to shoot. `claims` counts how many bots already chase each bird, so they
    /// spread out instead of all piling onto one. `orbs` are health orbs it can go for when hurt.
    func think(dt: Float, targets: [CombatTarget], claims: [Int: Int], orbs: [SIMD3<Float>], arena: Arena?,
               runtime: WorldRuntime?) -> Shot? {
        guard fighter.alive else { return nil }
        let p = flight.pos
        let fwd = flight.forward
        let others = targets.filter { $0.id != id }
        retarget -= dt
        if retarget <= 0 || !others.contains(where: { $0.id == target }) {
            retarget = rng.float(5, 9)
            target = others.min { a, b in
                simd_distance(a.pos, p) + Float(claims[a.id] ?? 0) * 160 < simd_distance(b.pos, p) + Float(claims[b.id] ?? 0) * 160
            }?.id
        }
        let t = others.first { $0.id == target }

        // Where to go: hurt → nearest orb; breaking away → off to the side and up; otherwise an attack run.
        evade = max(0, evade - dt)
        if fighter.health < 40, let orb = orbs.min(by: { simd_distance($0, p) < simd_distance($1, p) }), simd_distance(orb, p) < 300 {
            goal = orb
        } else if evade > 0 {
            goal = p + evadeDir * 80
        } else if let t {
            let d = simd_distance(t.pos, p)
            goal = t.pos + t.vel * 0.6 + SIMD3(0, 6, 0)
            if d < 30 {
                // Too close: peel off rather than crash into them.
                startEvade(away: t.pos)
            }
        } else if let arena {
            if simd_distance(goal, p) < 40 || goal == .zero {
                let a = rng.float(0, 2 * .pi), r = arena.radius * rng.float(0.1, 0.6)
                let x = arena.center.x + cos(a) * r, z = arena.center.z + sin(a) * r
                goal = SIMD3(x, TerrainShape.ground(x, z) + rng.float(35, 80), z)
            }
        }
        // Never fly into another bird.
        for o in others where simd_distance(o.pos, p) < 22 {
            let to = o.pos - p
            if simd_dot(simd_normalize(to), fwd) > 0.3 { startEvade(away: o.pos); break }
        }
        var to = goal - p
        if let arena, arena.distanceToWall(p) < 90 {
            let home = arena.center + SIMD3(0, 60, 0) - p
            to = simd_mix(to, home, SIMD3(repeating: smoothstep(90, 30, arena.distanceToWall(p))))
        }

        var roll: Float, pitch: Float
        if runtime is CaveRuntime, let steer = runtime?.autopilot(flight) {
            roll = steer.roll; pitch = steer.pitch
            if let t, simd_distance(t.pos, p) < 60, evade == 0 { roll = clamp(roll + bearing(fwd, to) * 0.6, -1, 1) }
        } else {
            let flatDist = max(simd_length(SIMD2(to.x, to.z)), 1)
            roll = clamp(bearing(fwd, to) * (1.0 + skill * 0.6), -1, 1)
            let wantPitch = atan2(to.y, flatDist)
            pitch = clamp((wantPitch - flight.pitch) * 2.2 + 0.15, -0.8, 1)
            // Stay off the ground.
            let ahead = p + fwd * 45
            let floor = max(TerrainShape.ground(ahead.x, ahead.z), TerrainShape.ground(p.x, p.z)) + 22
            if p.y < floor { pitch = max(pitch, 0.8); roll *= 0.4 }
        }

        let climbing = to.y > 10 || flight.speed < 17 || pitch > 0.5
        let dive = to.y < -35 && simd_length(to) > 90
        input.roll += (roll - input.roll) * approach(5, dt)
        input.pitch += (pitch - input.pitch) * approach(5, dt)
        input.tuck += ((dive ? 0.6 : 0) - input.tuck) * approach(4, dt)
        if climbing && !dive {
            flapPhase += dt * 2 * .pi * 1.7
            let down: Float = cos(flapPhase) < 0 ? 0.95 : 0
            input.flapL = down; input.flapR = down
        } else {
            flapPhase += dt * 2 * .pi * 0.3
            input.flapL = 0; input.flapR = 0
        }
        let e = climbing && !dive ? 0.25 + 0.75 * sin(flapPhase) : 0.05 + input.pitch * 0.3
        wingL = WingPose(elevation: e + input.roll * 0.4, bend: climbing ? -0.3 * cos(flapPhase) : 0)
        wingR = WingPose(elevation: e - input.roll * 0.4, bend: wingL.bend)

        // Shooting: only when lined up for a moment, and not every shot is on target.
        guard let t, evade == 0, fighter.cooldown <= 0 else { lockTime = 0; return nil }
        let spec = weapon.scaled(attack: attack)
        let d = simd_distance(t.pos, p)
        let ang = acos(clamp(simd_dot(fwd, (t.pos - p) / max(d, 1)), -1, 1))
        lockTime = d < spec.range * 0.7 && ang < 0.4 ? lockTime + dt : 0
        guard lockTime > reaction else { return nil }
        lockTime = 0
        reaction = nextReaction()
        fighter.cooldown = spec.cooldown * rng.float(1.25, 2.0) * (1.35 - skill * 0.5)
        if rng.float() < 0.45 { startEvade(away: t.pos) }
        var dir = Aim.lead(from: p, ownerVel: flight.velocity, spec: spec, target: t)
        var homingTarget: Int? = t.id
        if rng.float() > 0.45 + 0.3 * skill {
            // A miss: no homing and a bit off.
            homingTarget = nil
            let side = simd_normalize(simd_cross(dir, kUp))
            dir = simd_normalize(dir + side * rng.float(-0.25, 0.25) + kUp * rng.float(-0.12, 0.18))
        }
        return Shot(owner: id, weapon: weapon, attack: attack, origin: p + fwd * 0.8, dir: dir, ownerVel: flight.velocity,
                    target: homingTarget)
    }

    private func startEvade(away from: SIMD3<Float>) {
        guard evade == 0 else { return }
        evade = rng.float(1.5, 3) * (0.6 + skill * 0.6)
        var away = flight.pos - from
        away.y = 0
        let side = simd_normalize(simd_cross(flight.forward, kUp)) * (rng.float() < 0.5 ? -1 : 1)
        evadeDir = simd_normalize((simd_length(away) > 0.1 ? simd_normalize(away) : side) + side + SIMD3(0, 0.35, 0))
    }

    /// Signed horizontal angle from `fwd` to `to` (+ = to the right).
    private func bearing(_ fwd: SIMD3<Float>, _ to: SIMD3<Float>) -> Float {
        let f = SIMD2(fwd.x, fwd.z), d = SIMD2(to.x, to.z)
        guard simd_length(f) > 1e-3, simd_length(d) > 1e-3 else { return 0 }
        let a = simd_normalize(f), b = simd_normalize(d)
        return atan2(a.x * b.y - a.y * b.x, simd_dot(a, b))
    }

    func step(dt: Float, runtime: WorldRuntime?, arena: Arena?) {
        if fighter.alive {
            var remaining = dt
            while remaining > 0 {
                let h = min(remaining, 1.0 / 60.0)
                _ = flight.step(h, input)
                (runtime as? CaveRuntime)?.constrainQuietly(flight)
                remaining -= h
            }
            if let arena, let push = arena.constrain(flight) { flight.nudge(push * 8 * tuning.knockTaken) }
        } else {
            // Knocked out: drop.
            flight.pos.y -= dt * 12
        }
        syncAvatar()
    }

    private func syncAvatar() {
        avatar.setPose(pos: flight.pos, rot: flight.orientation, vel: flight.velocity,
                       wings: SIMD4(wingL.elevation, wingR.elevation, wingL.bend, input.tuck))
        avatar.hp = fighter.health
        var f = fighter.alive ? NetState.alive : 0
        if fighter.burnTime > 0 { f |= NetState.burning }
        if fighter.eliminated && !fighter.alive { f |= NetState.spectator }
        avatar.flags = f
    }

    /// Returns true if this hit knocked the bot out.
    func apply(_ h: HitReport, now: Float) -> Bool {
        guard fighter.alive, fighter.shield <= 0 else { return false }
        flight.nudge(h.impulse * tuning.knockTaken * fighter.knockScale(now: now))
        // Getting shot makes it want to dodge.
        if h.source == .shot && rng.float() < 0.5 { startEvade(away: flight.pos - simd_normalize(h.impulse + SIMD3(0, 0.01, 0)) * 10) }
        return fighter.take(h, now: now)
    }
}
