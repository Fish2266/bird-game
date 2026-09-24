import SceneKit
import AppKit
import simd

/// Synthesizes Vision-style keypoints for a scripted "player" so the whole
/// pose → controls → flight pipeline can be exercised without a camera.
struct DemoPoseSource {
    var aspect: Float = 1760.0 / 1328.0
    var rng = SplitMix64(seed: 99)

    /// Returns (phase name, raw pose) for time t.
    mutating func pose(at t: Double) -> (String, RawPose) {
        let cycle = t.truncatingRemainder(dividingBy: 22)
        var eL: Float = 0, eR: Float = 0, bendL: Float = 0, bendR: Float = 0
        var reachScale: Float = 1
        var name = ""
        switch cycle {
        case ..<2.5:
            name = "t-pose"
            eL = 0.03; eR = -0.02
        case ..<7:
            name = "flap"
            let ph = Float(cycle - 2.5) * 2 * .pi * 1.3
            eL = 0.25 + 0.85 * sin(ph); eR = eL
            bendL = -0.35 * cos(ph); bendR = bendL
        case ..<10:
            name = "bank right"
            eL = 0.5; eR = -0.5
        case ..<13:
            name = "tuck dive"
            eL = -1.45; eR = -1.45; reachScale = 0.2
        case ..<16:
            name = "pull up"
            eL = 0.6; eR = 0.6
        case ..<19.5:
            name = "bank left + flap"
            let ph = Float(cycle - 16) * 2 * .pi * 1.2
            eL = -0.35 + 0.6 * sin(ph); eR = 0.35 + 0.6 * sin(ph)
        default:
            name = "glide"
            eL = -0.05; eR = -0.05
        }
        var p = RawPose(time: t, aspect: aspect)
        let sw: Float = 0.17, l1: Float = 0.15, l2: Float = 0.14
        let cy: Float = 0.6
        // Raw (unmirrored) image: the person's left side appears on the image's right (+x).
        func put(_ j: Joint, _ x: Float, _ y: Float) {
            p[j] = SIMD3(x / aspect + 0.5 + rng.float(-0.002, 0.002), y + rng.float(-0.002, 0.002), 0.9)
        }
        put(.neck, 0, cy + 0.02)
        put(.nose, 0, cy + 0.12)
        put(.lHip, sw * 0.35, cy - 0.3)
        put(.rHip, -sw * 0.35, cy - 0.3)
        for (side, e, b) in [(Float(1), eL, bendL), (Float(-1), eR, bendR)] {
            let sx = side * sw / 2
            let ex = sx + side * cos(e) * l1 * reachScale, ey = cy + sin(e) * l1
            let fa = e + b
            let wx = ex + side * cos(fa) * l2 * reachScale, wy = ey + sin(fa) * l2
            if side > 0 {
                put(.lShoulder, sx, cy); put(.lElbow, ex, ey); put(.lWrist, wx, wy)
            } else {
                put(.rShoulder, sx, cy); put(.rElbow, ex, ey); put(.rWrist, wx, wy)
            }
        }
        return (name, p)
    }
}

enum RenderTest {
    /// `--render-test <dir> [seconds]`: fly the scripted demo offscreen and save frames + a telemetry log.
    static func run(outDir: String, seconds: Double, species: String = "gull", world: WorldID = .meadow) {
        let shared = SharedControls()
        let game = Game(controls: shared, world: world, terrainRadius: 5)
        game.synchronousTerrain = true
        let sp = Catalog.species(species)
        game.setSpecies(sp.look, tuning: FlightTuning(points: sp.base))
        var maxSpeed: Float = 0, yawAt10: Float = 0
        let interp = ArmInterpreter()
        var demo = DemoPoseSource()
        let device = MTLCreateSystemDefaultDevice()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = game.scene
        renderer.pointOfView = game.cameraNode
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let fps = 60.0
        var t = 0.0
        var nextPose = 0.0
        var nextShot = 1.0
        var nextLog = 0.0
        var phase = ""
        let start = CACurrentMediaTime()
        while t < seconds {
            if t >= nextPose {
                let (name, raw) = demo.pose(at: t)
                phase = name
                let c = interp.process(raw, time: t)
                shared.publish(c, pose: raw)
                nextPose += 1.0 / 30.0
            }
            game.update(time: t)
            maxSpeed = max(maxSpeed, game.flight.speed)
            if abs(t - 10) < 0.009 { yawAt10 = game.flight.yaw }
            if t >= nextLog {
                let c = shared.control
                let f = game.flight
                print(String(format: "t=%5.2f %-17@ ctl roll=%+.2f pitch=%+.2f tuck=%.2f flap=%.2f/%.2f cal=%d | pos y=%6.1f spd=%5.1f pitch=%+.2f roll=%+.2f yaw=%+.2f",
                             t, phase as NSString, c.roll, c.pitch, c.tuck, c.flapL, c.flapR, c.calibrated ? 1 : 0,
                             f.pos.y, f.speed, f.pitch, f.roll, f.yaw))
                nextLog += 0.5
            }
            if t >= nextShot {
                let img = renderer.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
                let path = "\(outDir)/frame_\(String(format: "%05.1f", t)).png"
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                nextShot += 2.0
            }
            t += 1.0 / fps
        }
        game.onHit = { c in print(String(format: "  t=%.1f hit! -%d coins", t, c)) }
        if game.runtime is VolcanoRuntime {
            for r in game.rings.rings {
                print(String(format: "ring %.0f m above ground", r.center.y - TerrainShape.ground(r.center.x, r.center.z)))
            }
        }
        if let v = game.runtime as? VolcanoRuntime, let vent = v.debugEruptNearest(to: game.flight.pos) {
            print("geysers nearby: \(v.debugCount); filming the one at \(vent)")
            // Let it warn and erupt, rendering every frame so the particles build up.
            for k in 0..<100 {
                let tk = t + Double(k) / 60
                game.update(time: tk)
                game.cameraNode.simdPosition = vent + SIMD3(60, 25, 60)
                game.cameraNode.simdLook(at: vent + SIMD3(0, 35, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                _ = renderer.snapshot(atTime: tk, with: CGSize(width: 320, height: 200), antialiasingMode: .none)
            }
            let img = renderer.snapshot(atTime: t + 100.0 / 60, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(outDir)/geyser.png"))
            }
        }
        if let d = game.runtime as? DogfightRuntime {
            print("shots fired: \(d.shotsFired)")
            if let plane = d.debugNearestPlane(to: game.flight.pos) {
                let me = game.flight.pos
                game.cameraNode.simdPosition = me + simd_normalize(plane - me) * -6 + SIMD3(0, 2, 0)
                game.cameraNode.simdLook(at: plane, up: kUp, localFront: SIMD3(0, 0, -1))
                game.cameraNode.camera?.fieldOfView = 30
                let img = renderer.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/plane.png"))
                }
                print("nearest plane \(Int(simd_distance(plane, me))) m away")
            }
        }
        print(String(format: "%@: top speed %.0f km/h, heading change after 3s bank %.0f°, final alt %.0f m",
                     sp.name as NSString, maxSpeed * 3.6, -yawAt10 * 57.3, game.flight.pos.y))
        print(String(format: "simulated %.1fs in %.1fs wall, chunks=%d score=%d", seconds, CACurrentMediaTime() - start, game.terrain.loadedCount, game.rings.score))
    }
}

enum AudioTest {
    /// `--audio-test <file.wav>`: render a scripted flight through the synth, write a WAV and print a
    /// loudness / frequency-band table so the mix can be checked without listening.
    static func run(path: String) {
        let sr: Float = 48000
        let synth = BirdSynth(sampleRate: sr)
        let seconds: Float = 17
        let n = Int(seconds * sr)
        var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
        let blk = 256
        var elevPrev: Float = 0
        var chimed = false, splashed = false
        var phases: [(Float, String)] = []
        func phase(_ t: Float) -> String {
            switch t {
            case ..<2: return "glide 15 m/s"
            case ..<5: return "flapping"
            case ..<8: return "banked turn 25 m/s"
            case ..<12: return "tucked dive"
            case ..<13.5: return "pull up"
            case ..<15: return "stall"
            default: return "splash"
            }
        }
        var i = 0
        while i < n {
            let t = Float(i) / sr, dt = Float(blk) / sr
            var speed: Float = 15, tuck: Float = 0, stall: Float = 0, roll: Float = 0, ground: Float = 0
            var elev: Float = 0.05
            switch t {
            case ..<2: break
            case ..<5: speed = 16 + (t - 2) * 1.3; elev = 0.25 + 0.85 * sin((t - 2) * 2 * .pi * 1.3)
            case ..<8: speed = 25; roll = 0.9
            case ..<12: speed = 20 + (t - 8) / 4 * 65; tuck = 1
            case ..<13.5: speed = 85 - (t - 12) / 1.5 * 45; ground = 0.8
            case ..<15: speed = 8; stall = 1; elev = 0.3
            default: speed = 12; ground = 1
            }
            let vel = (elev - elevPrev) / dt
            elevPrev = elev
            synth.airspeed = speed; synth.tuck = tuck; synth.stall = stall; synth.roll = roll; synth.ground = ground
            synth.wingDown = (max(0, -vel), max(0, -vel)); synth.wingUp = (max(0, vel), max(0, vel))
            if t > 6 && !chimed { synth.chime(); chimed = true }
            if t > 15.2 && !splashed { synth.impact(9, water: true); splashed = true }
            let m = min(blk, n - i)
            L.withUnsafeMutableBufferPointer { lb in
                R.withUnsafeMutableBufferPointer { rb in synth.render(lb.baseAddress! + i, rb.baseAddress! + i, m) }
            }
            i += m
            if phases.last?.1 != phase(t) { phases.append((t, phase(t))) }
        }

        // WAV (16-bit stereo)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
        for k in 0..<n {
            u16(UInt16(bitPattern: Int16(clamp(L[k], -1, 1) * 32767)))
            u16(UInt16(bitPattern: Int16(clamp(R[k], -1, 1) * 32767)))
        }
        try? data.write(to: URL(fileURLWithPath: path))

        // Band analysis with the same filters the synth uses.
        let bands: [Float] = [50, 120, 300, 700, 1500, 3000, 6000]
        var filters = bands.map { f -> SVFProbe in var s = SVFProbe(); s.set(f, q: 1.4, sr: sr); return s }
        let seg = Int(sr / 2)
        print("  t   phase                 peak   rms dB |" + bands.map { String(format: "%6.0f", $0) }.joined() + "  (band dB)")
        var s0 = 0
        while s0 < n {
            let s1 = min(n, s0 + seg)
            var peak: Float = 0, sum: Float = 0
            var be = [Float](repeating: 0, count: bands.count)
            for k in s0..<s1 {
                let x = (L[k] + R[k]) * 0.5
                peak = max(peak, abs(L[k]), abs(R[k])); sum += x * x
                for b in 0..<bands.count { let y = filters[b].bp(x); be[b] += y * y }
            }
            let cnt = Float(s1 - s0)
            let db = { (e: Float) -> String in String(format: "%6.0f", 10 * log10(max(e / cnt, 1e-10))) }
            let t = Float(s0) / sr
            print(String(format: "%5.1f %-20@ %5.2f %6.1f |", t, phase(t) as NSString, peak, 10 * log10(max(sum / cnt, 1e-10)))
                  + be.map(db).joined())
            s0 = s1
        }
    }
}

/// Minimal SVF for offline analysis.
struct SVFProbe {
    var ic1: Float = 0, ic2: Float = 0, a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1
    mutating func set(_ fc: Float, q: Float, sr: Float) {
        let g = tan(Float.pi * fc / sr); k = 1 / q
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    mutating func bp(_ v0: Float) -> Float {
        let v3 = v0 - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
        return v1 * k
    }
}

enum WorldShots {
    /// `--world-shots <dir>`: fly each world briefly and save a framed portrait screenshot for the shop.
    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 560, height: 800)
        for id in [WorldID.meadow, .volcano, .caves, .dogfight] {
            let game = Game(controls: SharedControls(), world: id, terrainRadius: 6)
            game.synchronousTerrain = true
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = game.scene
            renderer.pointOfView = game.cameraNode
            var t = 0.0
            func step(_ frames: Int, compose: (() -> Void)? = nil, render: Bool = false) {
                for _ in 0..<frames {
                    game.update(time: t)
                    compose?()
                    if render { _ = renderer.snapshot(atTime: t, with: CGSize(width: 140, height: 200), antialiasingMode: .none) }
                    t += 1.0 / 60
                }
            }
            step(id == .dogfight ? 420 : 200)   // autopilot flies a little (planes need time to close in)

            let bird = { game.flight.pos }
            let fwd = { () -> SIMD3<Float> in let f = game.flight.forward; return simd_normalize(SIMD3(f.x, 0, f.z)) }
            var compose: () -> Void = {
                let f = fwd(), right = simd_normalize(simd_cross(f, kUp))
                let cam = bird() - f * 7 + right * 1.2 + SIMD3(0, 2.6, 0)
                game.cameraNode.simdPosition = cam
                game.cameraNode.simdLook(at: bird() + f * 28 - SIMD3(0, 3, 0), up: kUp, localFront: SIMD3(0, 0, -1))
            }
            if let v = game.runtime as? VolcanoRuntime, let vent = v.debugEruptNearest(to: bird() + fwd() * 150) {
                // Put the bird ~85 m from the erupting geyser, heading for it.
                var dir = simd_normalize(SIMD3(vent.x - bird().x, 0, vent.z - bird().z))
                if !dir.x.isFinite { dir = SIMD3(0, 0, -1) }
                var start = vent - dir * 85
                start.y = max(TerrainShape.ground(start.x, start.z) + 18, vent.y + 22)
                game.flight.reset(at: start, yaw: atan2(-dir.x, -dir.z))
                _ = v.debugEruptNearest(to: vent)
                compose = {
                    let toVent = simd_normalize(SIMD3(vent.x - bird().x, 0, vent.z - bird().z))
                    game.cameraNode.simdPosition = bird() - toVent * 9 + SIMD3(0, 3, 0)
                    game.cameraNode.simdLook(at: vent + SIMD3(0, 30, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                }
            }
            if let d = game.runtime as? DogfightRuntime {
                compose = {
                    guard let plane = d.debugNearestPlane(to: bird()) else { return }
                    let dir = simd_normalize(plane - bird())
                    game.cameraNode.simdPosition = bird() - dir * 7 + SIMD3(0, 1.6, 0)
                    game.cameraNode.simdLook(at: (bird() + plane) * 0.5, up: kUp, localFront: SIMD3(0, 0, -1))
                }
            }
            if id == .caves, let cave = game.terrain.terrain as? CaveTerrain {
                // Start inside a medium-sized tunnel (walls in view) facing along it.
                var best = SIMD2<Float>(bird().x, bird().z), bestScore: Float = -1e9
                for j in stride(from: -500, through: 500, by: 20) {
                    for i in stride(from: -500, through: 500, by: 20) {
                        let x = bird().x + Float(i), z = bird().z + Float(j)
                        let sm = cave.sample(x, z)
                        guard sm.open > 0.9 else { continue }
                        let room = sm.ceiling - sm.floor
                        let score = -abs(room - 22) - abs(sm.wide - 0.25) * 20
                        if score > bestScore { bestScore = score; best = SIMD2(x, z) }
                    }
                }
                best = cave.recenter(best)
                let sm = cave.sample(best.x, best.y)
                let t = cave.tangent(best.x, best.y, prefer: SIMD2(0, -1))
                game.flight.reset(at: SIMD3(best.x, (sm.floor + sm.ceiling) * 0.5, best.y), yaw: atan2(-t.x, -t.y))
                game.flight.speed = 14
                step(90)
                compose = {
                    let f = game.flight.forward
                    let flat = simd_normalize(SIMD3(f.x, 0, f.z))
                    let cam = game.runtime!.constrainCamera(bird: bird(), cam: bird() - flat * 7 + SIMD3(0, 2.2, 0))
                    game.cameraNode.simdPosition = cam
                    game.cameraNode.simdLook(at: bird() + flat * 30 + SIMD3(0, 1, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                }
            }
            game.cameraNode.camera?.fieldOfView = 62
            if id == .caves { game.cameraNode.camera?.exposureOffset = 1.1 }
            step(100, compose: compose, render: true)
            let img = renderer.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(id.rawValue).png"))
            }
            print("saved \(id.rawValue)")
        }
    }
}
