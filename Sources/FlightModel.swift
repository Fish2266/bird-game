import simd

struct FlightInput {
    var roll: Float = 0      // -1…1 (+ = right)
    var pitch: Float = 0     // -1…1 (+ = nose up)
    var tuck: Float = 0      // 0…1
    var flapL: Float = 0     // downstroke power per wing
    var flapR: Float = 0
}

struct FlightEvents {
    var groundImpact: Float = 0   // m/s into the ground this step
    var waterSkim = false
}

/// Arcade-physical bird flight: energy is traded between height and speed (dive to go fast,
/// climb to slow down), wings stall when too slow, banking turns like a real glider and
/// flapping adds thrust and lift.
final class FlightModel {
    var pos = SIMD3<Float>(0, 150, 0)
    var yaw: Float = 0
    var pitch: Float = -0.05
    var roll: Float = 0
    var speed: Float = 17
    private(set) var verticalBoost: Float = 0
    private(set) var stalled: Float = 0
    private(set) var thrustNow: Float = 0
    /// Flap power averaged over ~half a second (strokes are pulses; this is the "effort").
    private(set) var flapEffort: Float = 0
    /// Hazard knockback velocity that fades out (always zero in World 1).
    private(set) var knockVel = SIMD3<Float>.zero
    /// 0…1 wing wobble after being hit.
    private(set) var wobble: Float = 0
    private var wobblePhase: Float = 0
    /// Extra upward air (thermals over lava, etc.), m/s.
    var externalLift: Float = 0

    var tuning = FlightTuning()
    static let g: Float = 9.81
    static let cruisePitch: Float = -0.07

    var orientation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) *
            simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) *
            simd_quatf(angle: -roll, axis: SIMD3(0, 0, 1))
    }
    var forward: SIMD3<Float> { orientation.act(SIMD3(0, 0, -1)) }
    var velocity: SIMD3<Float> { forward * speed + SIMD3(0, verticalBoost, 0) }

    func reset(at p: SIMD3<Float>, yaw y: Float) {
        pos = p; yaw = y; pitch = -0.05; roll = 0; speed = 17; verticalBoost = 0
        knockVel = .zero; wobble = 0; externalLift = 0
    }

    /// Shove the bird (lava blast, bullet, wall) — it tumbles a little and loses some speed.
    func knock(_ impulse: SIMD3<Float>) {
        knockVel += impulse
        wobble = 1
        speed *= 0.85
    }

    /// A gentler shove for fights: wobble in proportion to the hit and no lost speed, so you keep control.
    func nudge(_ impulse: SIMD3<Float>) {
        knockVel += impulse
        wobble = max(wobble, min(simd_length(impulse) / 30, 0.7))
    }

    func step(_ dt: Float, _ input: FlightInput) -> FlightEvents {
        var ev = FlightEvents()
        let g = Self.g
        let flap = (input.flapL + input.flapR) * 0.5
        let spread = 1 - input.tuck
        flapEffort += (flap - flapEffort) * approach(2.2, dt)

        // --- Roll: fast response, stronger when fast. Asymmetric flapping rolls you too.
        let t = tuning
        var rollTarget = input.roll * t.maxBank + (input.flapL - input.flapR) * 0.25
        if wobble > 0.001 {
            wobblePhase += dt * 17
            rollTarget += sin(wobblePhase) * wobble * 1.1
            wobble = max(0, wobble - dt * 0.9)
        }
        rollTarget = clamp(rollTarget, -t.maxBank - 0.15, t.maxBank + 0.15)
        roll += (rollTarget - roll) * approach((4.2 + min(speed, 40) * 0.04) * t.rollRate, dt)

        // --- Coordinated turn: yaw rate from bank angle.
        let v = max(speed, 7)
        let turn = -g * tan(clamp(roll, -1.3, 1.3)) / v
        yaw += clamp(turn, -2.2, 2.2) * dt * 1.15 * t.turn

        // --- Pitch target from arm height, tuck and flapping.
        var pTarget = Self.cruisePitch * t.bankPenalty + input.pitch * (input.pitch > 0 ? 0.7 : 0.6)
        pTarget -= input.tuck * 1.25
        pTarget += min(flapEffort * 1.6, 1) * 0.55 * t.flapLift
        // Steep banks cost lift unless you flap.
        pTarget -= (1 / max(cos(roll), 0.35) - 1) * 0.12 * (1 - min(flapEffort * 1.5, 1)) * t.bankPenalty
        // Stall: below this speed the nose drops no matter what.
        let stallSpeed: Float = 8.5 - t.stallDrop - min(flapEffort * 1.5, 1.2) * 4.5
        stalled = smoothstep(stallSpeed + 1.5, stallSpeed - 2, speed) * spread
        if stalled > 0 { pTarget = lerp(pTarget, min(pTarget, -0.55), stalled) }
        // Thin air above ~700 m.
        if pos.y > 700 { pTarget = min(pTarget, lerp(0.6, -0.2, smoothstep(700, 900, pos.y))) }
        pTarget = clamp(pTarget, -1.45, 1.1)
        let pitchRate: Float = input.tuck > 0.3 ? 3.2 : 2.6
        pitch += (pTarget - pitch) * approach(pitchRate, dt)

        // --- Speed: gravity along the flight path, drag, flap thrust.
        let cd = 0.0011 * t.diveDrag + 0.0026 * spread * t.glideDrag + max(0, input.pitch - 0.85) * 0.01
        let thrust = flap * 13 * t.thrust * clamp(1.15 - speed / (55 * t.thrust), 0.15, 1)
        thrustNow = thrust
        let accel = -g * sin(pitch) - cd * speed * speed + thrust + t.diveAccel * input.tuck
        speed = clamp(speed + accel * dt, 3, t.maxSpeed)

        // --- Extra direct lift from flapping (lets you climb out of a slow hover).
        let lowSpeed = smoothstep(18, 6, speed)
        verticalBoost += (flapEffort * 6 * lowSpeed - verticalBoost) * approach(3, dt)
        verticalBoost -= stalled * 2.5 * dt

        if knockVel == .zero && externalLift == 0 {
            pos += velocity * dt
        } else {
            pos += (velocity + knockVel + SIMD3(0, externalLift, 0)) * dt
            knockVel -= knockVel * approach(2.4, dt)
            if simd_length_squared(knockVel) < 0.01 { knockVel = .zero }
        }

        // --- Ground & water: forgiving skid instead of a crash.
        let ground = max(TerrainShape.height(pos.x, pos.z), TerrainShape.waterLevel)
        let clearance: Float = 0.9
        if pos.y < ground + clearance {
            let into = max(0, -velocity.y)
            pos.y = ground + clearance
            if pitch < 0.08 {
                ev.groundImpact = into
                pitch = max(pitch, 0.12)
                speed *= into > 6 ? 0.75 : 0.985
            }
            verticalBoost = max(verticalBoost, 0)
            ev.waterSkim = TerrainShape.height(pos.x, pos.z) < TerrainShape.waterLevel
        }
        return ev
    }
}
