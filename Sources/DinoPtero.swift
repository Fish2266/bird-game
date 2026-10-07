import SceneKit
import simd

/// Pteranodons wheeling over the valleys on outstretched wings, flapping to climb — and now and then folding up to
/// dive at a bird.
final class Ptero {
    var pos: SIMD3<Float>
    var vel: SIMD3<Float>
    var center: SIMD3<Float>
    var radius: Float
    var dir: Float
    var angle: Float
    let scale: Float
    var motion = DinoMotion()
    var pose: [simd_quatf] = []
    var mats: [simd_float4x4] = []
    enum Mode { case soar, dive, climb }
    var mode = Mode.soar
    var modeT: Float = 0
    var cooldown: Float
    var bank: Float = 0
    var yaw: Float = 0
    var pitch: Float = 0
    var closest: Float = .infinity
    var drift: SIMD3<Float>
    var callT: Float

    init(center: SIMD3<Float>, radius: Float, dir: Float, angle: Float, scale: Float, cooldown: Float, drift: SIMD3<Float>, callT: Float) {
        self.center = center; self.radius = radius; self.dir = dir; self.angle = angle; self.scale = scale
        self.cooldown = cooldown; self.drift = drift; self.callT = callT
        pos = center + SIMD3(cos(angle), 0, sin(angle)) * radius
        vel = SIMD3(-sin(angle), 0, cos(angle)) * dir * 13
    }
}

final class PteroFlock {
    let terrain: DinoTerrain
    private(set) var birds: [Ptero] = []
    private var rng = SplitMix64(seed: 0x9E_7E)
    private let sp = DinoSpecies.all[.ptero]!
    private(set) var threat: String?
    var wanted = 8

    init(terrain: DinoTerrain) { self.terrain = terrain }

    func update(dt: Float, player: FlightModel, life: DinoLife) {
        threat = nil
        let p = player.pos
        birds.removeAll { simd_distance(SIMD2($0.pos.x, $0.pos.z), SIMD2(p.x, p.z)) > 1800 }
        var tries = 0
        while birds.count < wanted && tries < 20 {
            tries += 1
            let a = rng.float(0, 6.28), r = rng.float(250, 1100)
            let c = SIMD2(p.x + cos(a) * r, p.z + sin(a) * r)
            let g = max(terrain.height(c.x, c.y), 0)
            let center = SIMD3(c.x, g + rng.float(60, 170), c.y)
            birds.append(Ptero(center: center, radius: rng.float(60, 150), dir: rng.float() < 0.5 ? -1 : 1, angle: rng.float(0, 6.28),
                               scale: rng.float(0.85, 1.15), cooldown: rng.float(8, 30),
                               drift: SIMD3(rng.float(-3, 3), 0, rng.float(-3, 3)), callT: rng.float(3, 20)))
        }
        for b in birds { fly(b, dt, player, life) }
    }

    private func fly(_ b: Ptero, _ dt: Float, _ player: FlightModel, _ life: DinoLife) {
        b.modeT += dt
        b.cooldown = max(0, b.cooldown - dt)
        b.motion.time += dt
        let p = player.pos
        let toBird = p - b.pos
        let dist = simd_length(toBird)
        var desired: SIMD3<Float>
        var agility: Float = 1.6
        var flap: Float = 0, fold: Float = 0
        switch b.mode {
        case .soar:
            b.angle += b.dir * dt * 13 / b.radius
            b.center += b.drift * dt
            let g = max(terrain.height(b.center.x, b.center.z), 0)
            b.center.y = max(b.center.y, g + 50)
            let target = b.center + SIMD3(cos(b.angle) * b.radius, sin(b.motion.time * 0.3 + b.radius) * 8, sin(b.angle) * b.radius)
            desired = simd_normalize(target - b.pos) * 13
            flap = desired.y > 1.5 ? 0.9 : (sin(b.motion.time * 0.7 + b.radius) > 0.85 ? 0.6 : 0)
            // A bird out in the open, not too high: worth a dive.
            let agl = p.y - max(terrain.height(p.x, p.z), 0)
            if dist < 90 && b.cooldown <= 0 && agl > 5 && p.y < b.pos.y + 25 && life.clock > 20 {
                b.mode = .dive; b.modeT = 0; b.closest = .infinity
                life.calls.append(DinoCall(kind: .screech, at: b.pos, pitch: 1, loud: 1))
            }
            b.callT -= dt
            if b.callT <= 0 {
                b.callT = rng.float(8, 25)
                if dist < 400 { life.calls.append(DinoCall(kind: .screech, at: b.pos, pitch: rng.float(0.9, 1.2), loud: 0.6)) }
            }
        case .dive:
            let lead = p + player.velocity * min(dist / 30, 0.6)
            desired = simd_normalize(lead - b.pos) * 28
            agility = 3
            fold = 0.65
            if dist < 70 { threat = "Pteranodon diving at you!" }
            if dist < 2.6 * b.scale {
                life.hits.append(HazardHit(impulse: simd_normalize(toBird + SIMD3(0, 0.5, 0)) * 12, coins: 3, kind: .wall))
                life.notices.append("A Pteranodon swooped on you!")
                b.mode = .climb; b.modeT = 0
            }
            b.closest = min(b.closest, dist)
            if b.modeT > 5 || (dist > b.closest + 12 && b.closest < 30) { b.mode = .climb; b.modeT = 0 }
        case .climb:
            var h = SIMD3(b.vel.x, 0, b.vel.z)
            if simd_length(h) < 1 { h = SIMD3(1, 0, 0) }
            desired = simd_normalize(h) * 14 + SIMD3(0, 7, 0)
            flap = 1
            if b.modeT > 3 {
                b.mode = .soar; b.modeT = 0; b.cooldown = rng.float(25, 45)
                b.center = b.pos - SIMD3(cos(b.angle), 0, sin(b.angle)) * b.radius
                b.center.y = b.pos.y
            }
        }
        let prevYaw = b.yaw
        b.vel += (desired - b.vel) * min(1, dt * agility)
        b.pos += b.vel * dt
        let g = max(terrain.height(b.pos.x, b.pos.z), 0)
        if b.pos.y < g + 7 { b.pos.y = g + 7; b.vel.y = max(b.vel.y, 2) }
        let hs = simd_length(SIMD2(b.vel.x, b.vel.z))
        b.yaw = atan2(-b.vel.x, -b.vel.z)
        b.pitch = atan2(b.vel.y, max(hs, 0.1)) * 0.8
        var turn = b.yaw - prevYaw
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        b.bank += (clamp(turn / max(dt, 1e-4) * 0.6, -0.9, 0.9) - b.bank) * min(1, dt * 3)
        b.motion.flap += (flap - b.motion.flap) * min(1, dt * 3)
        b.motion.fold += (fold - b.motion.fold) * min(1, dt * 4)
        b.motion.phase += dt * 1.5 * max(b.motion.flap, 0.05)
        if b.motion.phase > 1 { b.motion.phase -= 1 }
        b.motion.lookYaw = clamp(turn / max(dt, 1e-4) * 0.3, -0.5, 0.5)
    }

    func draw(into mesh: DynamicMesh, camera: SIMD3<Float>) {
        for b in birds {
            let d = simd_distance(b.pos, camera)
            guard d < 1600 else { continue }
            sp.pose(b.motion, into: &b.pose)
            let root = trs(b.pos, yawQuat(b.yaw) * rotX(b.pitch) * rotZ(-b.bank), b.scale)
            sp.rig.solve(root: root, pose: b.pose, into: &b.mats)
            sp.rig.draw(b.mats, into: mesh, far: d > 180)
        }
    }
}
