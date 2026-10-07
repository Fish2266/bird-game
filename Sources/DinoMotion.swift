import simd

/// What a dinosaur's body is doing this frame; turned into bone rotations by `pose`.
struct DinoMotion {
    /// Gait cycle, 0…1.
    var phase: Float = 0
    var speed: Float = 0
    /// Yaw rate, rad/s (+ = turning left).
    var turning: Float = 0
    /// Head turned (+ left) and raised, relative to the body.
    var lookYaw: Float = 0
    var lookPitch: Float = 0
    /// −1 head down grazing … 0 at rest … 1 reaching up / roaring.
    var neck: Float = 0
    /// 0…1 mouth open.
    var jaw: Float = 0
    /// −1…1 tail lashed to one side.
    var tailSwing: Float = 0
    /// 0…1 striking forward and down with the head.
    var lunge: Float = 0
    /// 0…1 up on the hind legs.
    var rear: Float = 0
    /// 0…1 low and ready (charging, about to pounce).
    var crouch: Float = 0
    /// Head shake (roaring, flinching).
    var shake: Float = 0
    var time: Float = 0
    /// Pterosaurs: 0 gliding … 1 flapping hard; wing fold 0…1.
    var flap: Float = 0
    var fold: Float = 0

    /// Advance the gait for the current speed.
    mutating func step(_ sp: DinoSpecies, dt: Float, scale: Float) {
        time += dt
        guard sp.walk > 0 else { return }
        let run = smoothstep(sp.walk, sp.run, speed)
        // A stride covers more ground when running; cycle rate follows speed.
        let strideLen = sp.hip * scale * (1.5 + 1.3 * run) * (sp.biped ? 1.15 : 1)
        phase += dt * max(speed, 0) / max(strideLen, 0.3)
        if phase > 1 { phase -= floor(phase) }
    }

    /// Height the body bobs down by (bipeds twice a stride), in metres before scaling.
    func bob(_ sp: DinoSpecies) -> Float {
        guard sp.walk > 0 else { return 0 }
        let moving = smoothstep(0.05, sp.walk * 0.6, speed)
        let k: Float = sp.biped ? 4 : 4
        return sp.bob * moving * (0.5 - 0.5 * cos(phase * .pi * k)) * (1 + smoothstep(sp.walk, sp.run, speed))
    }
}

extension DinoSpecies {
    /// Bone rotations for a motion state.
    func pose(_ m: DinoMotion, into q: inout [simd_quatf]) {
        let n = rig.bones.count
        let id = simd_quatf(angle: 0, axis: kUp)
        if q.count != n { q = [simd_quatf](repeating: id, count: n) } else { for i in 0..<n { q[i] = id } }
        if kind == .ptero || kind == .vulture { poseFlyer(m, into: &q); return }
        let moving = smoothstep(0.05, walk * 0.6, m.speed)
        let runK = smoothstep(walk, run, m.speed)
        let A = stride * (0.55 + 0.55 * runK) * moving
        let duty = lerp(0.62, 0.42, runK)
        for l in legs {
            var psi = m.phase + l.phase
            psi -= floor(psi)
            var swing: Float, lift: Float
            if psi < duty {
                swing = A * (1 - 2 * psi / duty); lift = 0
            } else {
                let u = (psi - duty) / (1 - duty)
                swing = A * (-1 + 2 * smoothstep(0, 1, u)); lift = sin(.pi * u)
            }
            lift *= moving
            let rearT: Float = l.front ? -0.55 * m.rear : 0.3 * m.rear
            let crouchT: Float = m.crouch * (l.front ? -0.1 : 0.35)
            let thigh = swing + rearT + crouchT
            let shin = l.knee * (lift * (0.55 + 0.4 * runK) + (l.front ? 1.1 * m.rear : 0) + m.crouch * 0.6)
            let foot = -l.knee * (lift * 0.45 + m.crouch * 0.3) * (biped ? 1 : 0.5)
            q[l.thigh] = rotX(thigh)
            q[l.shin] = rotX(shin)
            q[l.foot] = rotX(foot)
            // Keep the toes flat (curling a little as they leave the ground).
            q[l.toes] = rotX(-(thigh + shin + foot) + lift * 0.35 * (biped ? -1 : 0))
        }
        // Neck: grazing / reaching, looking, lunging, and a counter-sway with the stride.
        let reach = m.neck < 0 ? -m.neck * neckDown : m.neck * neckUp
        let sway = sin(m.phase * 2 * .pi) * 0.05 * moving
        let neckPitch = reach + m.lookPitch * 0.6 - m.lunge * 0.35 + sin(m.time * 0.9) * 0.02
        let neckYaw = m.lookYaw * 0.7 - sway
        let nn = Float(max(neck.count, 1))
        for b in neck { q[b] = rotY(neckYaw / nn) * rotX(neckPitch / nn) }
        if head >= 0 {
            let shake = m.shake * sin(m.time * 23) * 0.25
            q[head] = rotY(m.lookYaw * 0.3 + shake) * rotX(m.lookPitch * 0.4 - m.lunge * 0.25 + m.neck * 0.1 * (m.neck > 0 ? 1 : 0))
        }
        if jaw >= 0 { q[jaw] = rotX(-m.jaw * jawOpen) }
        // Tail: a lazy wave, swinging out wide on turns, held higher at a run, lashing when it's a weapon.
        let tn = Float(max(tail.count, 1))
        for (k, b) in tail.enumerated() {
            let kk = Float(k)
            let wave = sin(m.time * (1.3 + runK) - kk * 0.75) * (0.05 + 0.03 * moving) * (1 + kk * 0.25)
            let turnYaw = -m.turning * 0.22 * (1 + kk * 0.3) / tn
            let lash = m.tailSwing * (0.32 + kk * 0.05)
            let lift = -0.05 * runK - 0.08 * m.rear + (biped ? 0 : 0.02)
            q[b] = rotY(wave + turnYaw + lash) * rotX(lift)
        }
        // Little arms paddle along.
        for (k, b) in arms.enumerated() where k % 2 == 0 {
            q[b] = rotX(sin((m.phase + Float(k) * 0.25) * 2 * .pi) * 0.12 * moving + m.lunge * 0.4)
        }
        // The front of the body sways with the steps.
        if chest >= 0 && !biped { q[chest] = rotZ(sin(m.phase * 2 * .pi) * 0.025 * moving) }
    }

    /// Pteranodons: wings beat (or hold steady for a glide), fold in a dive, the head looks where it's going.
    private func poseFlyer(_ m: DinoMotion, into q: inout [simd_quatf]) {
        guard wings.count == 4 else { return }
        let beat = sin(m.phase * 2 * .pi)
        let flapA = 0.75 * m.flap
        let dihedral: Float = 0.1
        for (k, s) in [(0, Float(-1)), (2, Float(1))] {
            let up = (beat * flapA + dihedral) * s
            q[wings[k]] = rotZ(-up) * rotY(m.fold * 0.9 * s)
            // The outer wing lags the beat and folds back.
            q[wings[k + 1]] = rotZ(-(cos(m.phase * 2 * .pi) * flapA * 0.45) * s) * rotY(m.fold * 1.4 * s)
        }
        if head >= 0 { q[head] = rotY(m.lookYaw * 0.5) * rotX(m.lookPitch * 0.5) }
        for b in neck { q[b] = rotY(m.lookYaw * 0.4) }
    }
}
