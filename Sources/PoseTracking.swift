import Foundation
import Vision
import QuartzCore
import simd

// MARK: - Raw pose from Vision

enum Joint: Int, CaseIterable {
    case nose, neck, lShoulder, rShoulder, lElbow, rElbow, lWrist, rWrist, lHip, rHip

    var vision: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .neck: return .neck
        case .lShoulder: return .leftShoulder
        case .rShoulder: return .rightShoulder
        case .lElbow: return .leftElbow
        case .rElbow: return .rightElbow
        case .lWrist: return .leftWrist
        case .rWrist: return .rightWrist
        case .lHip: return .leftHip
        case .rHip: return .rightHip
        }
    }
}

/// Keypoints in Vision's normalized image space (origin bottom-left, not mirrored).
struct RawPose {
    var time: Double
    var aspect: Float
    /// x, y, confidence per `Joint`.
    var points: [SIMD3<Float>] = Array(repeating: .zero, count: Joint.allCases.count)
    subscript(_ j: Joint) -> SIMD3<Float> {
        get { points[j.rawValue] }
        set { points[j.rawValue] = newValue }
    }
}

final class PoseTracker {
    private let request = VNDetectHumanBodyPoseRequest()
    private(set) var lastInferenceMs: Double = 0

    func detect(_ pb: CVPixelBuffer, time: Double, aspect: Float) -> RawPose? {
        let start = CACurrentMediaTime()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        lastInferenceMs = (CACurrentMediaTime() - start) * 1000
        guard let results = request.results, !results.isEmpty else { return nil }

        var best: RawPose?
        var bestScore: Float = 0
        for obs in results {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var pose = RawPose(time: time, aspect: aspect)
            for j in Joint.allCases {
                if let p = pts[j.vision], p.confidence > 0.1 {
                    pose[j] = SIMD3(Float(p.location.x), Float(p.location.y), p.confidence)
                }
            }
            // Pick the person closest to the camera (widest shoulders).
            let ls = pose[.lShoulder], rs = pose[.rShoulder]
            let width = abs(ls.x - rs.x) * aspect
            let score = (ls.z > 0.1 && rs.z > 0.1) ? width + 0.01 : 0.001 * (pose[.neck].z)
            if score > bestScore { bestScore = score; best = pose }
        }
        return best
    }
}

// MARK: - Interpreted control state

struct WingPose {
    /// Upper-arm elevation (rad): 0 = straight out, + = up.
    var elevation: Float = 0
    /// Forearm angle relative to upper arm (rad), + = bent up.
    var bend: Float = 0
}

struct ControlState {
    var tracking = false
    /// Tracking well enough to fly (at least one hand seen recently). Otherwise the bird autopilots.
    var ready = false
    var time: Double = 0
    /// -1…1, + = bank right.
    var roll: Float = 0
    /// -1…1, + = nose up.
    var pitch: Float = 0
    /// 0…1 wings folded against the body (dive).
    var tuck: Float = 0
    /// Downstroke power per wing, 0…~1.5.
    var flapL: Float = 0
    var flapR: Float = 0
    var wingL = WingPose()
    var wingR = WingPose()
    var calibrated = false
    var calibProgress: Float = 0
    var handsVisible = 0
    var flapCount = 0
    var hint = ""
}

/// Turns noisy 2D keypoints into smooth, low-latency flight controls.
///
/// Mapping (everything is in a mirror view: your left arm is on the left of the screen):
///  * Arm height difference / leaning  → bank (raise left arm = bank right, like a plane's wings)
///  * Average arm height               → pitch (arms up = climb, arms down = descend)
///  * Arms pinned down at your sides    → tuck & dive
///  * Fast downward arm strokes         → flap thrust (bigger, faster strokes = more power)
final class ArmInterpreter {
    private var fx = [OneEuroFilter](repeating: OneEuroFilter(minCutoff: 1.6, beta: 1.2), count: Joint.allCases.count)
    private var fy = [OneEuroFilter](repeating: OneEuroFilter(minCutoff: 1.6, beta: 1.2), count: Joint.allCases.count)
    private var lastSeen = [Double](repeating: -10, count: Joint.allCases.count)
    private var held = [SIMD2<Float>](repeating: .zero, count: Joint.allCases.count)

    private var lastTime: Double = 0
    private var lastTracked: Double = -10
    private var prevTheta: [Float?] = [nil, nil]
    private var omega: [Float] = [0, 0]
    private var rollElev: [Float] = [0, 0]
    private var pitchElev: [Float] = [0, 0]
    private var tuckElev: Float = 0
    private var flapActivity: Float = 0
    private var lastHandsSeen: Double = -10
    private var armLen: Float = 0
    private var flapArmed = true
    private var state = ControlState()

    // Calibration
    private var offsets: [Float] = [0, 0]
    private var tiltOffset: Float = 0
    private var calibStart: Double?
    private var calibSum: SIMD3<Float> = .zero
    private var calibN: Float = 0

    func recalibrate() {
        state.calibrated = false
        offsets = [0, 0]
        tiltOffset = 0
        calibStart = nil
    }

    func process(_ raw: RawPose?, time t: Double) -> ControlState {
        let dt = Float(clamp(t - lastTime, 1.0 / 120.0, 0.2))
        lastTime = t
        state.time = t

        // Update filtered joints (mirror-space, aspect-corrected: y in 0…1, x in 0…aspect).
        var pos = [SIMD2<Float>?](repeating: nil, count: Joint.allCases.count)
        if let raw {
            for j in Joint.allCases {
                let p = raw[j]
                let i = j.rawValue
                let minConf: Float = (j == .lElbow || j == .rElbow || j == .lWrist || j == .rWrist) ? 0.3 : 0.2
                if p.z >= minConf {
                    if t - lastSeen[i] > 0.5 { fx[i].reset(); fy[i].reset() }
                    let mx = (1 - p.x) * raw.aspect
                    let v = SIMD2(fx[i].filter(mx, t: t), fy[i].filter(p.y, t: t))
                    held[i] = v
                    lastSeen[i] = t
                    pos[i] = v
                } else if t - lastSeen[i] < 0.25 {
                    pos[i] = held[i]   // bridge short dropouts
                }
            }
        }

        var lS = pos[Joint.lShoulder.rawValue], rS = pos[Joint.rShoulder.rawValue]
        guard let ls0 = lS, let rs0 = rS, simd_distance(ls0, rs0) > 0.02 else {
            return decay(dt: dt, t: t)
        }
        lastTracked = t

        // Mirror space: the person's left arm should be on the left. Swap if Vision disagrees.
        var lE = pos[Joint.lElbow.rawValue], rE = pos[Joint.rElbow.rawValue]
        var lW = pos[Joint.lWrist.rawValue], rW = pos[Joint.rWrist.rawValue]
        if ls0.x > rs0.x {
            swap(&lS, &rS); swap(&lE, &rE); swap(&lW, &rW)
        }
        let S = [lS!, rS!]
        let E = [lE, rE]
        let W = [lW, rW]
        let out: [Float] = [-1, 1]  // outward x direction per arm in mirror space
        let sw = simd_distance(S[0], S[1])

        if armLen == 0 { armLen = sw * 1.6 }
        armLen = max(armLen - dt * 0.02 * armLen, sw * 1.1)

        var theta: [Float] = [0, 0]
        var upper: [Float] = [0, 0]
        var bend: [Float] = [0, 0]
        var reach: [Float] = [0, 0]
        var valid = [false, false]
        var hands = 0
        for a in 0..<2 {
            func ang(_ v: SIMD2<Float>) -> Float { atan2(v.y, v.x * out[a]) }
            if let e = E[a] {
                let u = e - S[a]
                upper[a] = ang(u)
                valid[a] = true
                if let w = W[a] {
                    hands += 1
                    let f = w - e
                    let whole = w - S[a]
                    theta[a] = ang(whole)
                    bend[a] = wrapAngle(ang(f) - upper[a])
                    armLen = max(armLen, min(simd_length(u) + simd_length(f), sw * 2.6))
                    reach[a] = whole.x * out[a] / armLen
                } else {
                    // Wrist out of frame: the upper arm alone is a good proxy.
                    theta[a] = upper[a]
                    bend[a] = 0
                    reach[a] = u.x * out[a] / (armLen * 0.5)
                }
            } else if let w = W[a] {
                hands += 1
                theta[a] = ang(w - S[a]); upper[a] = theta[a]; valid[a] = true
                reach[a] = (w - S[a]).x * out[a] / armLen
            }
        }
        state.handsVisible = hands
        // An arm we can't see at all copies the other one so it doesn't fight the controls.
        if !valid[0] && valid[1] { theta[0] = theta[1]; upper[0] = upper[1]; reach[0] = reach[1] }
        if !valid[1] && valid[0] { theta[1] = theta[0]; upper[1] = upper[0]; reach[1] = reach[0] }
        if !valid[0] && !valid[1] { return decay(dt: dt, t: t) }

        let tilt = atan2(S[1].y - S[0].y, S[1].x - S[0].x)

        // --- Flap detection: angular velocity of each arm.
        var power: [Float] = [0, 0]
        for a in 0..<2 {
            if let p = prevTheta[a] {
                let raw = wrapAngle(theta[a] - p) / dt
                omega[a] += approach(22, dt) * (raw - omega[a])
            }
            prevTheta[a] = theta[a]
            // Downstroke faster than ~45°/s starts producing thrust; ~250°/s is a strong flap.
            power[a] = clamp((-omega[a] - 0.8) / 3.6, 0, 1.6)
        }
        let meanPower = (power[0] + power[1]) * 0.5
        if meanPower > 0.3 && flapArmed { state.flapCount += 1; flapArmed = false }
        if (omega[0] + omega[1]) * 0.5 > 0.5 { flapArmed = true }

        // --- Calibration: hold both arms out roughly level and still for a second.
        let calm = abs(omega[0]) < 1.0 && abs(omega[1]) < 1.0
        let tpose = abs(theta[0]) < 0.45 && abs(theta[1]) < 0.45 && reach[0] > 0.55 && reach[1] > 0.55 && hands == 2
        if !state.calibrated {
            if tpose && calm {
                if calibStart == nil { calibStart = t; calibSum = .zero; calibN = 0 }
                calibSum += SIMD3(theta[0], theta[1], tilt)
                calibN += 1
                state.calibProgress = Float(min((t - calibStart!) / 1.0, 1))
                if state.calibProgress >= 1 {
                    let m = calibSum / calibN
                    offsets = [clamp(m.x, -0.3, 0.3), clamp(m.y, -0.3, 0.3)]
                    tiltOffset = clamp(m.z, -0.25, 0.25)
                    state.calibrated = true
                    Log.write(String(format: "calibrated offsets %.3f %.3f tilt %.3f", offsets[0], offsets[1], tiltOffset))
                }
            } else {
                calibStart = nil
                state.calibProgress = max(0, state.calibProgress - dt * 2)
            }
        }

        let elev = [theta[0] - offsets[0], theta[1] - offsets[1]]

        // --- Bank: fast-ish filter so turns feel immediate but flap asymmetry noise is removed.
        for a in 0..<2 {
            rollElev[a] += approach(12, dt) * (elev[a] - rollElev[a])
            pitchElev[a] += approach(2.6, dt) * (elev[a] - pitchElev[a])
        }
        let lean = -(wrapAngle(tilt - tiltOffset))
        // With arms hanging down the angle difference is meaningless; steer by leaning instead.
        let armsDown = smoothstep(-0.9, -1.3, (rollElev[0] + rollElev[1]) * 0.5)
        var roll = (rollElev[0] - rollElev[1]) / 1.15 * (1 - armsDown) + lean / 0.5 * (0.5 + armsDown * 0.6)
        // Small dead zone so a slightly uneven T-pose flies straight.
        roll = abs(roll) < 0.06 ? 0 : roll - (roll > 0 ? 0.06 : -0.06)
        roll = clamp(roll * 1.06, -1, 1)

        // --- Pitch from average arm height (with a small dead zone around level).
        // While flapping, arm height swings every stroke; ignore it for pitch (flapping climbs anyway).
        flapActivity += ((meanPower > 0.08 ? 1 : 0) - flapActivity) * approach(meanPower > 0.08 ? 8 : 1.2, dt)
        let mean = (pitchElev[0] + pitchElev[1]) * 0.5 * (1 - smoothstep(0.1, 0.6, flapActivity))
        let dz: Float = 0.1
        let shaped = mean > dz ? mean - dz : (mean < -dz ? mean + dz : 0)
        let pitch = clamp(shaped / 0.55, -1, 1)

        // --- Tuck: arms pinned down along the body.
        let fastMean = (elev[0] + elev[1]) * 0.5
        tuckElev += approach(8, dt) * (fastMean - tuckElev)
        let meanReach = (reach[0] + reach[1]) * 0.5
        let tuck = hands > 0 ? smoothstep(-0.85, -1.2, tuckElev) * smoothstep(0.6, 0.3, meanReach) : 0

        if hands > 0 { lastHandsSeen = t }
        state.tracking = true
        state.ready = t - lastHandsSeen < 0.8
        state.roll = roll
        state.pitch = pitch * (1 - tuck)
        state.tuck = tuck
        state.flapL = power[0] * (1 - tuck)
        state.flapR = power[1] * (1 - tuck)
        state.wingL = WingPose(elevation: upper[0] - offsets[0], bend: bend[0])
        state.wingR = WingPose(elevation: upper[1] - offsets[1], bend: bend[1])

        if !state.ready {
            state.hint = "Step back so your hands are in view"
        } else if hands < 2 && tuck < 0.5 {
            state.hint = hands == 0 ? "Step back so your hands are in view" : "Step back so both hands are in view"
        } else if !state.calibrated {
            state.hint = "Hold your arms out like wings to calibrate"
        } else {
            state.hint = ""
        }
        return state
    }

    private func decay(dt: Float, t: Double) -> ControlState {
        let k = approach(4, dt)
        state.roll -= state.roll * k
        state.pitch -= state.pitch * k
        state.tuck -= state.tuck * k
        state.flapL = 0
        state.flapR = 0
        prevTheta = [nil, nil]
        omega = [0, 0]
        state.handsVisible = 0
        if t - lastTracked > 0.4 {
            state.tracking = false
            state.ready = false
            state.hint = "I can't see you — step in front of the camera"
        }
        return state
    }
}

/// Thread-safe mailbox between the camera/vision thread and the render loop.
final class SharedControls {
    private let lock = NSLock()
    private var _control = ControlState()
    private var _pose: RawPose?
    private var _mirrorAspect: Float = 4.0 / 3.0

    func publish(_ c: ControlState, pose: RawPose?) {
        lock.lock(); _control = c; _pose = pose; lock.unlock()
    }
    var control: ControlState { lock.lock(); defer { lock.unlock() }; return _control }
    var pose: RawPose? { lock.lock(); defer { lock.unlock() }; return _pose }
}
