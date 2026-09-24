import SceneKit
import simd

/// A few gulls that try to hold formation slots beside the player. Dive hard and they fall
/// behind; they catch up (or re-join from ahead) when you ease off.
final class Flock {
    private struct Member {
        let bird: BirdNode
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        let slot: SIMD3<Float>
        var phase: Float
        var flapping: Float = 0
        var roll: Float = 0
    }
    let root = SCNNode()
    private var members: [Member] = []
    private var rng = SplitMix64(seed: 31337)

    init(count: Int = 5) {
        let slots: [SIMD3<Float>] = [SIMD3(-11, 1.5, -2), SIMD3(13, 3, 4), SIMD3(-24, 5, 10),
                                     SIMD3(27, -1, 14), SIMD3(-38, 8, 22), SIMD3(40, 6, 28)]
        for i in 0..<min(count, slots.count) {
            let b = BirdNode()
            b.node.simdScale = SIMD3(repeating: 0.9)
            root.addChildNode(b.node)
            members.append(Member(bird: b, pos: .zero, vel: .zero, slot: slots[i], phase: Float(i) * 1.7))
        }
    }

    func reset(around p: SIMD3<Float>, yaw: Float, speed: Float) {
        let q = simd_quatf(angle: yaw, axis: kUp)
        for i in members.indices {
            members[i].pos = p + q.act(members[i].slot)
            members[i].vel = q.act(SIMD3(0, 0, -speed))
        }
    }

    func update(dt: Float, player: FlightModel) {
        let q = simd_quatf(angle: player.yaw, axis: kUp)
        let pv = player.velocity
        for i in members.indices {
            var m = members[i]
            let wobble = SIMD3(sin(m.phase * 0.37) * 3, sin(m.phase * 0.23) * 2, 0)
            var target = player.pos + q.act(m.slot + wobble)
            let ground = TerrainShape.ground(target.x, target.z)
            target.y = max(target.y, ground + 8)
            let toTarget = target - m.pos
            let dist = simd_length(toTarget)
            if dist > 450 {
                // Lost them: rejoin from ahead.
                m.pos = player.pos + q.act(SIMD3(m.slot.x * 2, m.slot.y + 10, -160))
                m.vel = pv
            }
            // Spring toward the slot, matching the player's velocity.
            let maxSpeed = max(simd_length(pv) * 1.25 + 6, 14)
            var desired = pv + toTarget * 0.9
            if simd_length(desired) > maxSpeed { desired = simd_normalize(desired) * maxSpeed }
            let steer = (desired - m.vel)
            m.vel += steer * approach(2.2, dt)
            m.pos += m.vel * dt

            // Visuals: bank into turns, flap when climbing or catching up.
            let speed = max(simd_length(m.vel), 1)
            let fwd = m.vel / speed
            let lateral = simd_dot(steer, simd_cross(fwd, kUp))
            m.roll += (clamp(lateral * 0.08, -1, 1) - m.roll) * approach(3, dt)
            let wantsFlap: Float = (steer.y > 1.5 || simd_dot(steer, fwd) > 3) ? 1 : 0
            m.flapping += (wantsFlap - m.flapping) * approach(3, dt)
            m.phase += dt * (m.flapping > 0.3 ? 2 * .pi * 2.1 : 0.8)
            let e = m.flapping > 0.3 ? 0.2 + 0.75 * sin(m.phase) : 0.05 + 0.05 * sin(m.phase)
            let yaw = atan2(-fwd.x, -fwd.z)
            let pitch = asin(clamp(fwd.y, -1, 1))
            m.bird.node.simdPosition = m.pos
            m.bird.node.simdOrientation = simd_quatf(angle: yaw, axis: kUp) *
                simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -m.roll, axis: SIMD3(0, 0, 1))
            m.bird.pose(left: WingPose(elevation: e, bend: m.flapping > 0.3 ? -0.3 * cos(m.phase) : 0),
                        right: WingPose(elevation: e, bend: m.flapping > 0.3 ? -0.3 * cos(m.phase) : 0),
                        fold: 0, pitchIn: 0, rollIn: m.roll, dt: dt)
            members[i] = m
        }
    }
}
