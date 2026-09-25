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

/// Flies toward a point with plain stick inputs (tests only): bank toward it, pitch to match its height,
/// flap when slow or climbing.
func steerToward(_ g: Game, _ p: SIMD3<Float>, phase: inout Float, dt: Float) -> FlightInput {
    var i = FlightInput()
    let (d, bearing, above) = g.pointer(to: p)
    i.roll = clamp(bearing * 2.2, -1, 1)
    let wantPitch = atan2(above, max(d, 1))
    i.pitch = clamp((wantPitch - g.flight.pitch) * 3 + 0.1, -1, 1)
    let ground = TerrainShape.ground(g.flight.pos.x, g.flight.pos.z)
    if g.flight.pos.y - ground < 4 { i.pitch = max(i.pitch, 0.6) }
    phase += dt * 2 * .pi * 1.7
    if g.flight.speed < 22 || above > 6 { let down: Float = cos(phase) < 0 ? 0.95 : 0; i.flapL = down; i.flapR = down }
    return i
}

enum RenderTest {
    /// `--render-test <dir> [seconds] [bird] [world] [mode]`: fly offscreen and save frames + a telemetry log.
    /// Free roam uses the scripted arm-flapping demo; races fly the course; fights fly at the nearest bot.
    static func run(outDir: String, seconds: Double, species: String = "gull", world: WorldID = .meadow, mode: GameMode = .freeRoam) {
        let shared = SharedControls()
        let sp = Catalog.species(species)
        let game = Game(controls: shared, world: world, mode: mode, species: sp, points: sp.base, terrainRadius: 5)
        game.synchronousTerrain = true
        var phaseT: Float = 0
        if mode.isRace, let track = game.track {
            print(String(format: "course: %.0f m, %d gates, %d obstacles, %d boosts, start %@", track.length, track.gates.count,
                         track.obstacles.count, track.boosts.count, "\(track.start)"))
            game.debugSteer = { g in
                let s = min(g.progressS + 45, track.length)
                let target = g.nextGate < track.gates.count && simd_distance(track.gates[g.nextGate].center, g.flight.pos) < 60
                    ? track.gates[g.nextGate].center : track.point(atArc: s)
                return steerToward(g, target, phase: &phaseT, dt: 1.0 / 60)
            }
        } else if mode == .pvp {
            game.debugSteer = { g in
                guard let b = g.bots.filter({ $0.fighter.alive }).min(by: { simd_distance($0.flight.pos, g.flight.pos) < simd_distance($1.flight.pos, g.flight.pos) })
                else { return nil }
                if g.fighter.cooldown <= 0 { g.keys.attack = true }
                return steerToward(g, b.flight.pos, phase: &phaseT, dt: 1.0 / 60)
            }
            game.onKnockout = { n in print("  knocked out \(n)") }
        }
        game.onMatchOver = { o in
            print("MATCH OVER: place \(o.place)/\(o.of) time \(o.time.map { raceClock($0) } ?? "-") gates \(o.gates) missed \(o.missed) KOs \(o.knockouts) hits \(o.hits)")
            for s in o.standings { print("   \(s.place). \(s.name) \(s.note) KOs \(s.knockouts)") }
        }
        game.onNotice = { print("  notice: \($0)") }
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
            // Callbacks are posted to the main queue; drain it so they print.
            RunLoop.main.run(until: Date())
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
                if mode == .freeRoam {
                    print(String(format: "t=%5.2f %-17@ ctl roll=%+.2f pitch=%+.2f tuck=%.2f flap=%.2f/%.2f cal=%d | pos y=%6.1f spd=%5.1f pitch=%+.2f roll=%+.2f yaw=%+.2f",
                                 t, phase as NSString, c.roll, c.pitch, c.tuck, c.flapL, c.flapR, c.calibrated ? 1 : 0,
                                 f.pos.y, f.speed, f.pitch, f.roll, f.yaw))
                    nextLog += 0.5
                } else {
                    let s = game.stats
                    print(String(format: "t=%5.1f %@ spd=%5.1f alt=%5.1f agl=%5.1f | %@ time=%@ pen=%.0f prog=%.0f off=%.1f hp=%.0f left=%d/%d proj=%d %@",
                                 t, "\(s.phase)", f.speed, f.pos.y, s.agl, s.gateLabel, raceClock(s.raceTime), s.penalty, game.progressS,
                                 s.offCourse, s.health, s.fightersLeft, s.fighters, game.combat.activeCount, s.threat ?? ""))
                    nextLog += 2
                }
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
        if mode == .pvp, let b = game.bots.first {
            // Close-up of a bot: nametag, health bar and the show-location glow (also through a hill).
            b.avatar.updateVisuals(camera: b.flight.pos, dt: 0.1, showLocation: true, showHealth: true)
            let f = b.flight.forward
            for (name, off) in [("bot.png", -f * 7 + SIMD3(2, 2, 0)), ("bot-far.png", -f * 90 + SIMD3(0, 25, 0))] {
                game.cameraNode.simdPosition = b.flight.pos + off
                game.cameraNode.simdLook(at: b.flight.pos, up: kUp, localFront: SIMD3(0, 0, -1))
                game.cameraNode.camera?.fieldOfView = 50
                b.avatar.updateVisuals(camera: game.cameraNode.simdPosition, dt: 0.016, showLocation: true, showHealth: true)
                let img = renderer.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
                }
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

enum NetTest {
    /// `--net-test`: host + two guests in one process over real Bonjour / TCP. Checks discovery, joining, lobby
    /// sync, state relay, events, match commands, invites and kicking. Prints PASS/FAIL per step.
    static func run() {
        var failures = 0
        // Ghost files round-trip.
        var run = GhostRun(); run.bird = "phoenix"; run.splits = [10.5, 21.25]
        for k in 0..<30 { run.record(pos: SIMD3(Float(k), 2, 3), rot: simd_quatf(angle: Float(k) * 0.1, axis: kUp), wings: SIMD3(0.1, 0.2, 0)) }
        if let back = GhostRun(data: run.encoded()), back.bird == "phoenix", back.splits == run.splits, back.samples == run.samples,
           let p = back.pose(at: 1.55), abs(p.0.x - 15.5) < 0.01 {
            print("PASS  ghost save/load round trip")
        } else { failures += 1; print("FAIL  ghost save/load round trip") }
        func wait(_ what: String, _ timeout: Double = 10, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let ok = cond()
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(what)")
        }
        let host = LANSession(); host.name = "Hosty"; host.color = 5
        let guest = LANSession(); guest.name = "Guesty"; guest.color = 2; guest.bird = "falcon"
        let other = LANSession(); other.name = "Invitee"; other.color = 7
        var hostEvents: [GameEvent] = []
        host.onEvent = { _, e in hostEvents.append(e) }
        var guestMatch: [MatchCommand] = []
        guest.onMatch = { guestMatch.append($0) }
        var ended: String?
        guest.onEnded = { ended = $0 }
        var invite: Invite?
        other.onInvite = { invite = $0 }

        host.goOnline(); guest.goOnline(); other.goOnline()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.host(mode: .ringRace, world: "volcano", rules: MatchRules(collisions: true, pvp: false, showLocation: true))
        wait("guest discovers the hosted game") { guest.games.contains { $0.hostName == "Hosty" } }
        wait("host sees the others online") { host.nearby.count >= 2 }
        if let g = guest.games.first(where: { $0.hostName == "Hosty" }) {
            print("      found: \(g.hostName) · \(g.mode.title) · \(g.world) · \(g.players) player(s)")
            guest.join(g)
        }
        wait("guest joined with id 2 and sees both players") { guest.role == .joined && guest.localId == 2 && guest.lobby.players.count == 2 }
        print("      guest status: \(guest.status) role \(guest.role) host status: \(host.status)")
        wait("host lobby lists the guest (falcon)") { host.lobby.players.contains { $0.name == "Guesty" && $0.bird == "falcon" } }
        print("      guest lobby: mode \(guest.lobby.mode.rawValue), world \(guest.lobby.world), pvp \(guest.lobby.rules.pvp)")

        // States both ways
        func st(_ id: Int, _ x: Float) -> NetState {
            NetState(id: id, p: SIMD3(x, 50, 0), q: simd_quatf(angle: 0, axis: kUp).vector, v: SIMD3(0, 0, -20),
                     w: SIMD4(0.1, 0.1, 0, 0), hp: 100, flags: NetState.alive, bird: "gull")
        }
        var gotAtGuest: [NetState] = [], gotAtHost: [NetState] = []
        wait("guest receives the host's flight state") {
            host.send(state: st(1, 11)); guest.send(state: st(99, 22))
            gotAtGuest += guest.drain().states; gotAtHost += host.drain().states
            return gotAtGuest.contains { $0.id == 1 && $0.p.x == 11 }
        }
        wait("host receives the guest's state (id forced to 2)") {
            guest.send(state: st(99, 22)); gotAtHost += host.drain().states
            return gotAtHost.contains { $0.id == 2 && $0.p.x == 22 }
        }
        // Events
        guest.send(event: .finished(id: 2, time: 99.5))
        wait("host gets the guest's finish event") { hostEvents.contains { if case .finished(2, _) = $0 { return true }; return false } }
        var guestEvents: [GameEvent] = []
        let shot = Shot(owner: 1, weapon: .missiles, attack: 7, origin: .zero, dir: SIMD3(0, 0, -1), ownerVel: .zero, target: 2)
        host.send(event: .fire(shot))
        wait("guest gets the host's attack") { guestEvents += guest.drain().events; return guestEvents.contains { if case .fire = $0 { return true }; return false } }
        // Director + match commands
        let director = MatchDirector()
        let start = director.start(mode: .ringRace, players: host.lobby.players)
        host.broadcast(start)
        wait("guest gets the round start") { guestMatch.contains { if case .start = $0 { return true }; return false } }
        _ = director.handle(.finished(id: 1, time: 101.2))
        // (fights end on .eliminated, races on .finished)
        if let res = director.handle(.finished(id: 2, time: 99.5)), case .results(_, let standings) = res {
            print("PASS  director ends the race when everyone finishes: " + standings.map { "\($0.place). \($0.name) \($0.time.map(raceClock) ?? "-")" }.joined(separator: ", "))
            host.broadcast(res)
        } else { failures += 1; print("FAIL  director results") }
        wait("guest gets the results") { guestMatch.contains { if case .results = $0 { return true }; return false } }
        // Rules change
        host.updateLobby(rules: MatchRules(collisions: false, pvp: true, showLocation: false))
        wait("guest sees new host settings") { guest.lobby.rules.pvp && !guest.lobby.rules.collisions }
        // Invite
        if let p = host.nearby.first(where: { $0.name == "Invitee" }) { host.invite(p) }
        wait("invitee gets an invite from Hosty") { invite?.from == "Hosty" }
        // Kick
        host.kick(2)
        wait("kicked guest is told and leaves") { ended != nil && guest.role == .idle }
        print("      guest was told: \(ended ?? "-")")
        wait("host lobby drops the guest") { host.lobby.players.count == 1 }
        host.leave(); guest.leave(); other.leave()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}

enum Gallery {
    /// `--gallery <dir> [world]`: pictures of every race gate, obstacle type and (volcano) geyser, for checking looks.
    static func run(dir: String, only: WorldID?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 960, height: 600)
        func save(_ r: SCNRenderer, _ t: Double, _ name: String) {
            let img = r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        for world in [WorldID.meadow, .volcano, .caves, .dogfight] where only == nil || only == world {
            for mode in [GameMode.ringRace, .speedRace] {
                let g = Game(controls: SharedControls(), world: world, mode: mode, terrainRadius: 5)
                g.synchronousTerrain = true
                let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                r.scene = g.scene
                r.pointOfView = g.cameraNode
                guard let track = g.track else { continue }
                var t = 0.0
                func shoot(_ target: SIMD3<Float>, from: SIMD3<Float>, _ name: String, frames: Int = 40) {
                    g.flight.reset(at: target + SIMD3(0, 400, 0), yaw: 0)
                    g.bird.node.isHidden = true
                    for _ in 0..<frames {
                        g.update(time: t)
                        g.terrain.update(center: target, synchronous: true)
                        g.cameraNode.simdPosition = from
                        g.cameraNode.simdLook(at: target, up: kUp, localFront: SIMD3(0, 0, -1))
                        g.cameraNode.camera?.fieldOfView = 60
                        _ = r.snapshot(atTime: t, with: CGSize(width: 64, height: 40), antialiasingMode: .none)
                        t += 1.0 / 30
                    }
                    save(r, t, "\(world.rawValue)-\(mode.rawValue)-\(name)")
                }
                func view(atArc s: Float, back: Float = 55, side: Float = 12, up: Float = 8) -> SIMD3<Float> {
                    let p = track.point(atArc: max(0, s - back))
                    let f = PathFrame(p, track.tangent(at: max(0, s - back)))
                    var v = f.at(side, 0, up)
                    if world == .caves { v = f.at(0, 0, 2) }
                    return v
                }
                shoot(track.point(atArc: 0), from: view(atArc: 0, back: 40), "start")
                if let gate = track.gates.first { shoot(gate.center, from: view(atArc: gate.s), "gate") }
                var seen = Set<String>()
                for o in track.obstacles {
                    let kind = "\(type(of: o))"
                    guard !seen.contains(kind) else { continue }
                    seen.insert(kind)
                    var hint = 0
                    let s = track.nearest(o.center, hint: &hint).s
                    var h2 = track.index(atArc: s)
                    let s2 = track.nearest(o.center, hint: &h2).s
                    shoot(o.center, from: view(atArc: s2, back: 70, side: 18, up: 12), kind, frames: 90)
                }
            }
            if world == .volcano {
                // A free-roam geyser erupting, for comparison.
                let g = Game(controls: SharedControls(), world: .volcano, terrainRadius: 5)
                g.synchronousTerrain = true
                let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                r.scene = g.scene; r.pointOfView = g.cameraNode
                var t = 0.0
                for _ in 0..<30 { g.update(time: t); t += 1.0 / 30 }
                if let v = g.runtime as? VolcanoRuntime, let vent = v.debugEruptNearest(to: g.flight.pos) {
                    for _ in 0..<110 {
                        g.update(time: t)
                        g.cameraNode.simdPosition = vent + SIMD3(70, 30, 70)
                        g.cameraNode.simdLook(at: vent + SIMD3(0, 30, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                        _ = r.snapshot(atTime: t, with: CGSize(width: 64, height: 40), antialiasingMode: .none)
                        t += 1.0 / 30
                    }
                    save(r, t, "volcano-freeRoam-geyser")
                }
            }
            print("gallery: \(world.rawValue) done")
        }
    }
}

enum PvPSim {
    /// `--pvp-sim [bird] [world] [seconds] [pilot]`: a headless fight against the bots with a human-like pilot
    /// (`demo` = the scripted arm-flapping player shooting now and then, `chase` = flies at the nearest bot).
    static func run(bird: String, world: WorldID, seconds: Double, pilot: String) {
        let shared = SharedControls()
        let sp = Catalog.species(bird)
        let g = Game(controls: shared, world: world, mode: .pvp, species: sp, points: sp.base, terrainRadius: 3)
        g.synchronousTerrain = true
        var events: [String] = []
        var t = 0.0
        g.debugEvent = { events.append(String(format: "%5.1f %@", t, $0)) }
        var over: MatchOutcome?
        g.onMatchOver = { over = $0 }
        g.onNotice = { n in events.append(String(format: "%5.1f notice: %@", t, n)) }
        let interp = ArmInterpreter()
        var demo = DemoPoseSource()
        var phase: Float = 0
        var nextShot = 1.5
        var rng = SplitMix64(seed: 5)
        if pilot == "chase" {
            g.debugSteer = { g in
                guard let b = g.bots.filter({ $0.fighter.alive }).min(by: { simd_distance($0.flight.pos, g.flight.pos) < simd_distance($1.flight.pos, g.flight.pos) }) else { return nil }
                return steerToward(g, b.flight.pos + SIMD3(0, 8, 0), phase: &phase, dt: 1.0 / 60)
            }
        }
        var maxKnock: Float = 0, lowTime: Float = 0, lastLog = -1.0
        while t < seconds {
            RunLoop.main.run(until: Date())
            if pilot != "chase", Int(t * 30) != Int((t - 1.0 / 60) * 30) {
                let (_, raw) = demo.pose(at: t)
                shared.publish(interp.process(raw, time: t), pose: raw)
            }
            if t > nextShot { g.keys.attack = true; nextShot = t + Double(rng.float(1.5, 3.5)) }
            g.update(time: t)
            maxKnock = max(maxKnock, simd_length(g.flight.knockVel))
            if g.flight.pos.y - TerrainShape.ground(g.flight.pos.x, g.flight.pos.z) < 3 { lowTime += 1.0 / 60 }
            if t - lastLog >= 5 {
                lastLog = t
                let bots = g.bots.map { b in String(format: "%@ hp%3.0f agl%4.0f d%4.0f", b.avatar.name.prefix(6) as CVarArg, b.fighter.health,
                    b.flight.pos.y - TerrainShape.ground(b.flight.pos.x, b.flight.pos.z), simd_distance(b.flight.pos, g.flight.pos)) }
                print(String(format: "t=%5.1f %@ me hp%3.0f spd%4.0f knock%4.1f | ", t, "\(g.phase)", g.fighter.health, g.flight.speed,
                             simd_length(g.flight.knockVel)) + bots.joined(separator: " | "))
            }
            t += 1.0 / 60
            if over != nil && t > (Double(g.fightClock) + 3) { break }
        }
        let hits = events.filter { $0.contains("hit from") }.count
        let rams = events.filter { $0.contains("collision") }.count
        print("--- events (first 40)")
        events.prefix(40).forEach { print($0) }
        print(String(format: "SUMMARY %@ vs bots: fight lasted %.0f s, hits taken %d, collisions %d, max knock %.0f m/s, %.0f s near ground",
                     sp.name, g.fightClock, hits, rams, maxKnock, lowTime))
        if let o = over { print("result: place \(o.place)/\(o.of), KOs \(o.knockouts), hits landed \(o.hits)") } else { print("no result yet") }
    }
}

enum ScenarioTest {
    /// `--scenario-test`: headless checks of race and fight flows that are easy to break.
    static func run() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        var t = 0.0
        func step(_ g: Game, _ secs: Double) {
            let end = t + secs
            while t < end { g.update(time: t); t += 1.0 / 60; RunLoop.main.run(until: Date()) }
        }
        let sp = Catalog.species("falcon")

        // --- Race: finish, ghost, splits, restart
        var phase: Float = 0
        let g = Game(controls: SharedControls(), world: .meadow, mode: .ringRace, species: sp, points: sp.base, terrainRadius: 3)
        g.synchronousTerrain = true
        let track = g.track!
        g.debugSteer = { g in
            let target = g.nextGate < track.gates.count && simd_distance(track.gates[g.nextGate].center, g.flight.pos) < 60
                ? track.gates[g.nextGate].center : track.point(atArc: min(g.progressS + 45, track.length))
            return steerToward(g, target, phase: &phase, dt: 1.0 / 60)
        }
        var outcome: MatchOutcome?
        g.onMatchOver = { outcome = $0 }
        step(g, 1)
        check(g.phase == .countdown, "race starts with a countdown")
        step(g, 2.5)
        check(g.phase == .running, "GO after 3 s")
        // Single-player pause freezes the clock.
        let c0 = g.clock
        g.paused = true; step(g, 2); g.paused = false
        check(abs(g.clock - c0) < 0.05, "single-player pause freezes the race clock")
        step(g, 230)
        check(outcome != nil, "race finishes")
        if let o = outcome {
            check(o.medals.count == 3 && o.medals[0] < o.medals[1] && o.medals[1] < o.medals[2], "medal targets gold < silver < bronze: \(o.medals.map { raceClock($0) })")
            check((o.ghost?.samples.count ?? 0) > 100 && (o.ghost?.splits.count ?? 0) == 16, "ghost recorded with 16 splits")
            print("      time \(raceClock(o.time ?? 0)) → medal: \(o.time.flatMap { Medal.of($0, o.medals)?.name } ?? "none")")
            g.setBest(time: o.time, run: o.ghost)
        }
        g.restartMatch()
        check(g.ghost != nil && g.phase == .countdown && g.nextGate == 0, "race again: countdown with ghost")
        step(g, 3.5)
        step(g, 30)
        check(g.splitText != nil || g.nextGate > 0, "splits compare against the best run")
        // Off course: teleport far away and wait.
        let before = g.lastSafeS
        g.debugSteer = { _ in FlightInput() }
        g.place(at: track.point(atArc: g.progressS) + SIMD3(300, 60, 0), yaw: 0, speed: 20)
        step(g, 4)
        check(simd_distance(g.flight.pos, track.point(atArc: before)) < 40, "straying off course puts you back at the last gate")

        // --- Multiplayer-style pause keeps the clock running (no network needed).
        let m = Game(controls: SharedControls(), world: .meadow, mode: .speedRace, multiplayer: true, species: sp, points: sp.base, terrainRadius: 2)
        m.startMatch(id: 1, countdown: 1, slot: 0)
        m.paused = true
        step(m, 3)
        check(m.phase == .running && m.clock > 1.5, "LAN pause: countdown and race clock keep going (\(String(format: "%.1f", m.clock)) s)")

        // --- Fight: lives, elimination, spectating, orbs, time limit
        let f = Game(controls: SharedControls(), world: .meadow, mode: .pvp, species: sp, points: sp.base, terrainRadius: 2)
        var fightOut: MatchOutcome?
        f.onMatchOver = { fightOut = $0 }
        step(f, 3.5)
        check(f.phase == .running && f.bots.count == BotSettings.count, "fight running with \(f.bots.count) bots")
        func lethal() { f.fighter.shield = 0; f.applyToMe(HitReport(from: 100, to: 1, damage: 500, impulse: .zero, source: .shot)) }
        lethal()
        check(f.fighter.lives == 2 && f.respawnIn > 0, "knocked out: 2 lives left, respawning")
        step(f, 3.5)
        check(f.fighter.alive && f.participating, "back in after 3 s")
        // Orbs heal.
        f.fighter.health = 40
        if let orb = f.orbs?.active.first {
            f.place(at: orb, yaw: 0, speed: 1)
            step(f, 0.1)
            check(f.fighter.health >= 70, "health orb heals (\(Int(f.fighter.health)))")
        }
        lethal(); step(f, 3.5); lethal()
        check(f.fighter.eliminated && !f.participating && f.spectating != nil, "out of lives: spectating")
        if f.bots.filter({ !$0.fighter.eliminated }).count > 1 {
            let first = f.spectating
            f.keys.right = true; step(f, 0.05); f.keys.right = false; step(f, 0.05)
            check(f.spectating != first, "→ switches who you watch")
        }
        f.fightClock = Game.fightLimit - 0.5
        step(f, 1)
        check(fightOut != nil, "fight ends at the time limit")
        if let o = fightOut {
            check(o.place == o.of, "you place last after being eliminated first (\(o.place)/\(o.of))")
            print("      standings: " + o.standings.map { "\($0.place). \($0.name)" }.joined(separator: ", "))
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}

enum PerfTest {
    /// `--perf-test [bird] [seconds]`: frame times (simulation + a real render at 1280×800, 4× MSAA) in a fight while
    /// everyone attacks nonstop, compared with plain free flight.
    static func run(bird: String, seconds: Double) {
        let sp = Catalog.species(bird)
        let device = MTLCreateSystemDefaultDevice()
        func measure(_ label: String, _ mode: GameMode, attack: Bool) {
            let g = Game(controls: SharedControls(), world: .meadow, mode: mode, species: sp, points: sp.base, terrainRadius: 4)
            g.synchronousTerrain = true
            let r = SCNRenderer(device: device, options: nil)
            r.scene = g.scene
            r.pointOfView = g.cameraNode
            var phase: Float = 0
            if mode == .pvp {
                g.debugSteer = { g in
                    guard let b = g.bots.filter({ $0.fighter.alive }).min(by: { simd_distance($0.flight.pos, g.flight.pos) < simd_distance($1.flight.pos, g.flight.pos) })
                    else { return nil }
                    return steerToward(g, b.flight.pos, phase: &phase, dt: 1.0 / 60)
                }
            }
            var t = 0.0
            // Warm up (terrain, shaders).
            for _ in 0..<120 { g.update(time: t); _ = r.snapshot(atTime: t, with: CGSize(width: 320, height: 200), antialiasingMode: .none); t += 1.0 / 60 }
            // From here on, terrain streams in the background like in the real game.
            g.synchronousTerrain = false
            var times: [Double] = [], maxProj = 0
            let frames = Int(seconds * 60)
            for _ in 0..<frames {
                if attack { g.keys.attack = true; g.fighter.shield = 99; g.fighter.health = Fighter.maxHealth }
                let t0 = CACurrentMediaTime()
                let before = g.combat.activeCount
                g.update(time: t)
                let t1 = CACurrentMediaTime()
                _ = r.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
                let t2 = CACurrentMediaTime()
                times.append((t2 - t0) * 1000)
                if (t2 - t0) * 1000 > 18 && ProcessInfo.processInfo.environment["PERF_VERBOSE"] != nil {
                    print(String(format: "   spike at %.2f s: update %.1f ms, render %.1f ms, projectiles %d→%d", t, (t1 - t0) * 1000,
                                 (t2 - t1) * 1000, before, g.combat.activeCount))
                }
                maxProj = max(maxProj, g.combat.activeCount)
                t += 1.0 / 60
            }
            let sorted = times.sorted()
            let avg = times.reduce(0, +) / Double(times.count)
            print(String(format: "%-28@ avg %5.1f ms   p95 %5.1f   worst %5.1f   frames over 33 ms: %d   max projectiles %d",
                         label as NSString, avg, sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, times.filter { $0 > 33 }.count, maxProj))
        }
        measure("free flight", .freeRoam, attack: false)
        measure("fight, \(sp.name) attacking", .pvp, attack: true)
    }
}
