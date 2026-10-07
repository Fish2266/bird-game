import SceneKit
import AppKit
import simd
import Network

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
    // (Not while diving at something well below: flapping there just holds the bird up.)
    if (g.flight.speed < 22 && above > -4) || above > 6 { let down: Float = cos(phase) < 0 ? 0.95 : 0; i.flapL = down; i.flapR = down }
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
        let scene = ProcessInfo.processInfo.environment["AUDIO_SCENE"] ?? ""
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
            if scene == "city" {
                // The city around the flight: traffic all along, voices early, the el, the chopper, a siren, horns.
                synth.cityTraffic = 0.6
                synth.cityCrowd = t < 6 ? 0.6 : 0
                synth.cityTrain = t > 6 && t < 10 ? 0.8 : 0
                synth.cityHeli = t > 8 && t < 14 ? 0.8 : 0
                synth.sirenGain = t > 10 && t < 16 ? 0.7 : 0
                func once(_ at: Float, _ f: () -> Void) { if t >= at && t - dt < at { f() } }
                once(2) { synth.shutter() }
                once(3) { synth.horn(gain: 1, pan: -0.5) }
                once(3.3) { synth.horn(gain: 0.8, pan: 0.4) }
                once(5) { synth.flutter() }
                once(7) { synth.trainHorn() }
            }
            let m = min(blk, n - i)
            L.withUnsafeMutableBufferPointer { lb in
                R.withUnsafeMutableBufferPointer { rb in synth.render(lb.baseAddress! + i, rb.baseAddress! + i, m) }
            }
            i += m
            if phases.last?.1 != phase(t) { phases.append((t, phase(t))) }
        }

        writeWAV(L, R, sr: sr, path: path)
        bandTable(L, R, sr: sr, phases: phases, phase: phase)
    }

    /// 16-bit stereo WAV.
    static func writeWAV(_ L: [Float], _ R: [Float], sr: Float, path: String) {
        let n = L.count
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
    }

    private static func bandTable(_ L: [Float], _ R: [Float], sr: Float, phases: [(Float, String)], phase: (Float) -> String) {
        let n = L.count

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
        let only = ProcessInfo.processInfo.environment["SHOT_WORLDS"]?.split(separator: ",").compactMap { WorldID(rawValue: String($0)) }
        for id in only ?? [WorldID.meadow, .volcano, .caves, .dogfight, .city, .dino, .west, .finale] {
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
            if [WorldID.city, .dino, .west, .finale].contains(id) {
                // Clean pictures: no rings, and the bird flying straight and level (not circling on autopilot).
                game.rings.root.isHidden = true
                game.debugSteer = { g in
                    var i = FlightInput()
                    i.pitch = clamp(-g.flight.pitch * 2.5, -1, 1)
                    i.roll = clamp(-g.flight.roll * 2, -1, 1)
                    return i
                }
            }
            if id == .city {
                // Down an avenue between the towers, from the spawn.
                let (p, yaw) = game.spawn
                game.flight.reset(at: p - SIMD3<Float>(0, 12, 0), yaw: yaw)
                game.flight.speed = 16
                step(20)
            }
            // A Brachiosaurus out in the open (no trees between it and the camera).
            let openNeck: Dino? = (game.runtime as? DinoRuntime).flatMap { rt in
                guard let t = game.terrain.terrain as? DinoTerrain else { return nil }
                let standing: [Dino.Mind] = [.graze, .wander, .roam, .rest, .alert]
                return rt.life.dinos.filter { $0.kind == .longneck && standing.contains($0.mind) && simd_distance($0.position, bird()) < 700 }.min { a, b in
                    func cover(_ d: Dino) -> Float {
                        var f: Float = 0
                        for k in 0..<8 {
                            let ang = Float(k) / 8 * 2 * .pi
                            f += t.forest(d.pos.x + cos(ang) * 35, d.pos.y + sin(ang) * 35)
                        }
                        return f + t.forest(d.pos.x, d.pos.y) * 2
                    }
                    return cover(a) < cover(b)
                }
            }
            if id == .dino, let neck = openNeck, let t = game.terrain.terrain as? DinoTerrain {
                // Coming in toward a Brachiosaurus from the clearest side.
                var to = SIMD3<Float>(0, 0, -1), bestCover = Float.infinity
                for k in 0..<12 {
                    let ang = Float(k) / 12 * 2 * .pi
                    let d = SIMD3<Float>(cos(ang), 0, sin(ang))
                    var c: Float = 0
                    for r: Float in [12, 24, 36, 48, 60] { c += max(0, t.forest(neck.position.x - d.x * r, neck.position.z - d.z * r)) }
                    if c < bestCover { bestCover = c; to = d }
                }
                var start = neck.position - to * 75
                start.y = max(TerrainShape.ground(start.x, start.z), neck.ground) + 32
                game.flight.reset(at: start, yaw: atan2(-to.x, -to.z))
                game.flight.speed = 14
                step(10)
                compose = {
                    let target = neck.position + SIMD3<Float>(0, neck.sp.hip * neck.scale * 1.1, 0)
                    let dir = simd_normalize(SIMD3(target.x - bird().x, 0, target.z - bird().z))
                    game.cameraNode.simdPosition = bird() - dir * 9 + SIMD3<Float>(0, 4, 0)
                    game.cameraNode.simdLook(at: target, up: kUp, localFront: SIMD3<Float>(0, 0, -1))
                }
            }
            if id == .west, let t = game.terrain.terrain as? WestTerrain {
                // Down in the great canyon, flying along it between the layered walls.
                let sp = game.spawn.0
                var river: SIMD3<Float>?
                search: for r in stride(from: Float(0), to: 4000, by: 40) {
                    for k in 0..<max(1, Int(r / 30)) {
                        let a = Float(k) / Float(max(1, Int(r / 30))) * 2 * .pi
                        let q = sp + SIMD3<Float>(cos(a), 0, sin(a)) * r
                        if WestLayout.canyonDistances(q.x, q.z).0 < 20 && t.height(q.x, q.z) < 0 { river = SIMD3(q.x, 0, q.z); break search }
                    }
                }
                if let rv = river {
                    let e: Float = 4
                    let f0 = WestLayout.fields(rv.x, rv.z).0
                    var across = SIMD3<Float>(WestLayout.fields(rv.x + e, rv.z).0 - f0, 0, WestLayout.fields(rv.x, rv.z + e).0 - f0)
                    across = simd_length(across) > 1e-9 ? simd_normalize(across) : SIMD3<Float>(1, 0, 0)
                    let along = SIMD3<Float>(-across.z, 0, across.x)
                    game.terrain.update(center: rv, synchronous: true)
                    game.flight.reset(at: rv + SIMD3<Float>(0, 95, 0), yaw: atan2(-along.x, -along.z))
                    game.flight.speed = 16
                    step(10)
                    compose = {
                        let f = fwd()
                        game.cameraNode.simdPosition = bird() - f * 9 + SIMD3<Float>(0, 2.4, 0)
                        game.cameraNode.simdLook(at: bird() + f * 60 - SIMD3<Float>(0, 14, 0), up: kUp, localFront: SIMD3<Float>(0, 0, -1))
                    }
                }
            }
            if id == .finale {
                // Flying in to the castle from the south: the walls and towers ahead, the Sky Tower behind them.
                let gy = FinaleLayout.ground
                let target = SIMD3<Float>(0, gy + 34, -50)
                game.flight.reset(at: SIMD3<Float>(-10, gy + 30, 235), yaw: 0)
                game.flight.speed = 14
                step(10)
                compose = {
                    let dir = simd_normalize(SIMD3(target.x - bird().x, 0, target.z - bird().z))
                    game.cameraNode.simdPosition = bird() - dir * 8 + SIMD3<Float>(1.2, 2.4, 0)
                    game.cameraNode.simdLook(at: target, up: kUp, localFront: SIMD3<Float>(0, 0, -1))
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
        let guest = LANSession(); guest.name = "Guesty"; guest.color = 2; guest.bird = "falcon"; guest.fit = "h=tophat,t=rainbow"
        let other = LANSession(); other.name = "Invitee"; other.color = 7
        let third = LANSession(); third.name = "Thirdy"; third.color = 4
        var hostEvents: [(Int, GameEvent)] = []
        host.onEvent = { hostEvents.append(($0, $1)) }
        var guestMatch: [MatchCommand] = []
        guest.onMatch = { guestMatch.append($0) }
        var ended: String?
        guest.onEnded = { ended = $0 }
        var invite: Invite?
        other.onInvite = { invite = $0 }

        // A 0.2 game on the network (older protocol): shown, but marked as needing the same version.
        var oldTXT = NWTXTRecord()
        for (k, v) in ["n": "Oldie", "c": "1", "i": "OLD00000", "v": "3", "h": "1", "g": "1", "m": "freeRoam", "w": "meadow", "p": "1"] { oldTXT[k] = v }
        let oldParams = NWParameters.tcp; oldParams.requiredInterfaceType = .loopback
        let oldHost = try? NWListener(using: oldParams)
        oldHost?.service = NWListener.Service(name: "Oldie · OLD00000", type: LANSession.serviceType, domain: nil, txtRecord: oldTXT)
        oldHost?.newConnectionHandler = { $0.cancel() }
        oldHost?.start(queue: .main)
        // A 0.2.1 game (protocol 4, which sent its app version).
        var v021 = NWTXTRecord()
        for (k, v) in ["n": "Olivia", "c": "3", "i": "OLD00021", "v": "4", "a": "0.2.1", "h": "1", "g": "1", "m": "ringRace", "w": "volcano", "p": "2"] { v021[k] = v }
        let v021Host = try? NWListener(using: oldParams)
        v021Host?.service = NWListener.Service(name: "Olivia · OLD00021", type: LANSession.serviceType, domain: nil, txtRecord: v021)
        v021Host?.newConnectionHandler = { $0.cancel() }
        v021Host?.start(queue: .main)

        host.goOnline()
        wait("host listens on the fixed port \(LANSession.port)") { host.listeningPort == LANSession.port }
        guest.goOnline(); other.goOnline(); third.goOnline()
        wait("other copies on the same Mac fall back to other ports") { [guest, other, third].allSatisfy { ($0.listeningPort ?? LANSession.port) != LANSession.port } }
        host.host(mode: .ringRace, world: "volcano", rules: MatchRules(collisions: true, pvp: false, showLocation: true))
        wait("guest discovers the hosted game") { guest.games.contains { $0.hostName == "Hosty" && $0.otherVersion == nil } }
        wait("guest sees the 0.2 game marked as a different version") { guest.games.contains { $0.hostName == "Oldie" && $0.otherVersion == "0.2" } }
        wait("guest sees a 0.2.1 game marked as a different version") { guest.games.contains { $0.hostName == "Olivia" && $0.otherVersion == "0.2.1" } }
        if let old = guest.games.first(where: { $0.hostName == "Oldie" }) {
            guest.join(old)
            print("      trying to join it: \(guest.status)")
            if guest.role != .idle { failures += 1; print("FAIL  joining a different version is refused") }
        }
        wait("host sees the others online") { host.nearby.filter { $0.otherVersion == nil }.count >= 3 }
        if let g = guest.games.first(where: { $0.hostName == "Hosty" }) {
            print("      found: \(g.hostName) · \(g.mode.title) · \(g.world) · \(g.players) player(s)")
            guest.join(g)
        }
        wait("guest joined with id 2 and sees both players") { guest.role == .joined && guest.localId == 2 && guest.lobby.players.count == 2 }
        wait("host lobby lists the guest (falcon)") { host.lobby.players.contains { $0.name == "Guesty" && $0.bird == "falcon" } }
        wait("the guest's outfit (top hat, rainbow trail) reaches the host") { host.lobby.players.contains { $0.name == "Guesty" && $0.fit == "h=tophat,t=rainbow" } }
        wait("the host's advertised player count updates without restarting") { third.games.first { $0.hostName == "Hosty" }?.players == 2 }
        // Join by typing the address.
        print("      host addresses: \(host.addresses)")
        third.join(address: "127.0.0.1:\(LANSession.port)")
        wait("third player joins by address (127.0.0.1)") { third.role == .joined && third.lobby.players.count == 3 }
        if LANSession.endpoint("hello world") != nil || LANSession.endpoint("192.168.1.23") == nil || LANSession.endpoint("mac.local:1234") == nil {
            failures += 1; print("FAIL  address parsing")
        } else { print("PASS  address parsing") }

        // States: each one reaches the others exactly once, in order.
        func st(_ id: Int, _ x: Float, _ t: Double = 0) -> NetState {
            NetState(id: id, p: SIMD3(x, 50, 0), q: simd_quatf(angle: 0, axis: kUp).vector, v: SIMD3(0, 0, -20),
                     w: SIMD4(0.1, 0.1, 0, 0), hp: 100, flags: NetState.alive, bird: "gull", t: t)
        }
        _ = guest.drain(); _ = third.drain(); _ = host.drain()
        for k in 0..<30 { guest.send(state: st(99, Float(k), Double(k) / 30)); host.send(state: st(1, 100 + Float(k))) }
        var atThird: [NetState] = [], atGuest: [NetState] = [], atHost: [NetState] = []
        wait("third gets all 30 of the guest's states, once each, in order") {
            atThird += third.drain().states; atGuest += guest.drain().states; atHost += host.drain().states
            let g = atThird.filter { $0.id == 2 }.map(\.p.x)
            return g == (0..<30).map(Float.init)
        }
        wait("guest gets the host's states and never its own") {
            atGuest += guest.drain().states
            return atGuest.filter { $0.id == 1 }.count == 30 && !atGuest.contains { $0.id == 2 }
        }
        wait("host gets the guest's states (id forced to 2)") { atHost += host.drain().states; return atHost.filter { $0.id == 2 }.count == 30 }
        // Events
        guest.send(event: .finished(id: 1, time: 99.5))
        wait("host gets the guest's finish, credited to the guest even if it claims another id") {
            hostEvents.contains { if $0.0 == 2, case .finished(2, _) = $0.1 { return true }; return false }
        }
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
        _ = director.handle(.finished(id: 3, time: 120))
        if let res = director.handle(.finished(id: 2, time: 99.5)), case .results(_, let standings) = res {
            print("PASS  director ends the race when everyone finishes: " + standings.map { "\($0.place). \($0.name) \($0.time.map(raceClock) ?? "-")" }.joined(separator: ", "))
            host.broadcast(res)
        } else { failures += 1; print("FAIL  director results") }
        wait("guest gets the results") { guestMatch.contains { if case .results = $0 { return true }; return false } }
        // Rules change
        host.updateLobby(rules: MatchRules(collisions: false, pvp: true, showLocation: false))
        wait("guest sees new host settings") { guest.lobby.rules.pvp && !guest.lobby.rules.collisions }
        // Chat
        host.say("  hi\nall  ")
        wait("everyone gets the host's chat (one line, trimmed)") {
            guest.chat.contains { $0.id == 1 && $0.name == "Hosty" && $0.text == "hi all" } && third.chat.contains { $0.text == "hi all" }
        }
        guest.say(String(repeating: "x", count: 500))
        wait("a guest's message reaches the host and others, at most \(ChatLine.maxLength) characters") {
            host.chat.contains { $0.id == 2 && $0.name == "Guesty" && $0.text.count == ChatLine.maxLength }
                && third.chat.contains { $0.name == "Guesty" }
        }
        if guest.chat.filter({ $0.name == "Guesty" }).count != 1 || guest.say("   ") {
            failures += 1; print("FAIL  own message shown once; blank ones not sent")
        } else { print("PASS  own message shown once; blank ones not sent") }
        for k in 0..<12 { third.say("spam \(k)") }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let spam = host.chat.filter { $0.name == "Thirdy" }.count
        if spam == 6 { print("PASS  spam guard lets 6 of 12 quick messages through") } else { failures += 1; print("FAIL  spam guard (\(spam) got through)") }
        // Quiet lobby: heartbeats keep everyone connected.
        RunLoop.main.run(until: Date().addingTimeInterval(LANSession.timeout + 2))
        wait("still connected after \(Int(LANSession.timeout + 2)) s with nothing to say") { guest.role == .joined && third.role == .joined && host.lobby.players.count == 3 }
        // Invite: listed in the host's TXT record alone (like a player whose firewall turns away the direct kind)…
        host.debugNoDirectInvites = true
        if let p = host.nearby.first(where: { $0.name == "Invitee" }) { host.invite(p) }
        wait("invitee gets an invite from Hosty through the TXT record alone") { invite?.from == "Hosty" }
        host.debugNoDirectInvites = false
        // …and sent directly, which is all a 0.3 game understands.
        let old03 = DirectInviteCatcher(name: "Oldy", instance: "OLD00030")
        wait("host sees a 0.3 game online") { host.nearby.contains { $0.name == "Oldy" } }
        if let p = host.nearby.first(where: { $0.name == "Oldy" }) { host.invite(p) }
        wait("the 0.3 game gets the direct invite") { old03.invites.contains("Hosty") }
        old03.stop()
        if let inv = invite { other.accept(inv) }
        wait("invitee accepts and joins") { other.role == .joined && host.lobby.players.count == 4 }
        other.leave()
        wait("leaving frees the slot") { host.lobby.players.count == 3 && other.role == .idle }
        // A player whose Mac goes to sleep (no goodbye): the host notices within the timeout.
        if let g = other.games.first(where: { $0.hostName == "Hosty" }) { other.join(g) }
        wait("invitee joins again") { other.role == .joined && host.lobby.players.count == 4 }
        other.debugGoSilent()
        let silentAt = Date()
        wait("host drops a player who went silent", LANSession.timeout + 5) { host.lobby.players.count == 3 }
        print(String(format: "      dropped after %.1f s", Date().timeIntervalSince(silentAt)))
        // Kick
        host.kick(2)
        wait("kicked guest is told and leaves") { ended != nil && guest.role == .idle }
        print("      guest was told: \(ended ?? "-")")
        wait("host lobby drops the guest") { host.lobby.players.count == 2 }
        if let g = guest.games.first(where: { $0.hostName == "Hosty" }) { guest.join(g) }
        wait("a kicked player can't rejoin") { guest.role == .idle && guest.status.contains("removed") }
        print("      rejoin said: \(guest.status)")
        // Host leaves: everyone is told.
        var thirdEnded: String?
        third.onEnded = { thirdEnded = $0 }
        host.leave()
        wait("when the host stops, players are told") { third.role == .idle && thirdEnded != nil }
        print("      third was told: \(thirdEnded ?? "-")")
        guest.leave(); third.leave()
        oldHost?.cancel()
        v021Host?.cancel()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}

/// Test stand-in for Bird Game 0.3 on the network: advertises itself as a player and records direct invites
/// (the only kind 0.3 understands).
final class DirectInviteCatcher {
    private(set) var invites: [String] = []
    private let listener: NWListener?
    private var conns: [Conn] = []

    init(name: String, instance: String) {
        var t = NWTXTRecord()
        for (k, v) in ["n": name, "c": "4", "i": instance, "v": String(LANProtocol.version), "a": "0.3", "h": "0", "g": "0"] { t[k] = v }
        listener = try? NWListener(using: LANProtocol.parameters())
        listener?.service = NWListener.Service(name: "\(name) · \(instance)", type: LANProtocol.serviceType, domain: nil, txtRecord: t)
        listener?.newConnectionHandler = { [weak self] nc in
            let c = Conn(nc)
            c.onMessage = { w in if case .invite(let from, _, _) = w { self?.invites.append(from) } }
            self?.conns.append(c)
            c.start(on: .main)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        conns.forEach { $0.close() }
    }
}

/// Test stand-in for a game joining straight over TCP on loopback (to try other versions and a full game).
final class RawJoiner {
    private(set) var reply: Wire?
    private let conn: Conn

    init(instance: String, version: Int = LANProtocol.version) {
        conn = Conn(NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LANProtocol.port)!),
                                 using: LANProtocol.parameters()))
        conn.onMessage = { [weak self] w in if self?.reply == nil { self?.reply = w } }
        conn.start(on: .main)
        conn.send(.hello(Hello(name: "Raw", color: 0, bird: "gull", version: version, instance: instance)))
    }

    var welcomed: Bool { if case .welcome? = reply { return true }; return false }
    var rejection: String? { if case .reject(let why)? = reply { return why }; return nil }
    func close() { conn.close() }
}

enum ServerTest {
    /// `--server-test`: Bird Server's engine (a host that doesn't play) and copies of the game in one process over real
    /// Bonjour / TCP. Checks that games find and join it like a Mac host, its relay, rounds, chat, invites (TXT and
    /// direct), removing players, other versions, a full game and stopping. Prints PASS/FAIL per step.
    static func run() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        func wait(_ what: String, _ timeout: Double = 10, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(cond(), what)
        }
        func results(_ list: [MatchCommand]) -> [Standing]? {
            for m in list.reversed() { if case .results(_, let st) = m { return st } }
            return nil
        }

        // The invite list in the TXT record.
        check(LANProtocol.inviteList(["AAAA1111", "BBBB2222"]) == "AAAA1111,BBBB2222"
              && LANProtocol.invited(in: "AAAA1111,BBBB2222") == ["AAAA1111", "BBBB2222"] && LANProtocol.invited(in: nil).isEmpty,
              "invite list round trip")
        let long = LANProtocol.inviteList((0..<40).map { String(format: "ID%06d", $0) })
        check(long.count + 3 <= 250 && long.hasSuffix("ID000039") && !long.hasPrefix("ID000000"),
              "a long invite list keeps the newest and fits in one TXT entry")

        let server = LANServer()
        server.name = "Phoney"
        server.color = 6
        var serverChat: [ChatLine] = []
        server.onChat = { serverChat.append($0) }
        let a = LANSession(); a.name = "Alice"; a.color = 1; a.bird = "falcon"
        let b = LANSession(); b.name = "Bob"; b.color = 2; b.bird = "owl"
        let c = LANSession(); c.name = "Cara"; c.color = 3
        var aMatch: [MatchCommand] = [], bMatch: [MatchCommand] = []
        a.onMatch = { aMatch.append($0) }
        b.onMatch = { bMatch.append($0) }
        var aEnded: String?, bEnded: String?
        a.onEnded = { aEnded = $0 }
        b.onEnded = { bEnded = $0 }
        var cInvite: Invite?
        c.onInvite = { cInvite = $0 }
        let old03 = DirectInviteCatcher(name: "Olde", instance: "OLD00030")

        server.start(mode: .ringRace, world: "volcano", rules: MatchRules(collisions: true, pvp: false, showLocation: true))
        wait("server listens on the fixed port \(LANProtocol.port)") { server.port == LANProtocol.port }
        a.goOnline(); b.goOnline(); c.goOnline()
        wait("games find the server's game: Phoney's, Ring Race on Volcano, nobody in it yet") {
            a.games.contains { $0.hostName == "Phoney" && $0.mode == .ringRace && $0.world == "volcano" && $0.players == 0 && $0.otherVersion == nil }
        }
        wait("the server shows up as a server, not a player to invite") { a.nearby.contains { $0.name == "Phoney" && $0.server && $0.inGame } }
        wait("the server sees the games on the network to invite (not itself)") {
            Set(server.nearby.map(\.name)).isSuperset(of: ["Alice", "Bob", "Cara", "Olde"]) && !server.nearby.contains { $0.id == server.instance }
        }

        // Joining
        if let g = a.games.first(where: { $0.hostName == "Phoney" }) { a.join(g) }
        wait("Alice joins with id 2; the lobby has only her (the server doesn't play)") {
            a.role == .joined && a.localId == 2 && a.lobby.players.map(\.name) == ["Alice"] && a.lobby.hostName == "Phoney"
        }
        wait("the server lists Alice (falcon)") { server.players.map(\.name) == ["Alice"] && server.players.first?.bird == "falcon" }
        b.join(address: "127.0.0.1:\(LANProtocol.port)")
        wait("Bob joins by address with id 3") { b.role == .joined && b.localId == 3 && b.lobby.players.count == 2 && a.lobby.players.count == 2 }
        wait("the advertised player count follows") { c.games.first { $0.hostName == "Phoney" }?.players == 2 }
        wait("players in the game leave the invite list") { !server.nearby.contains { $0.name == "Alice" || $0.name == "Bob" } }
        wait("the server's chat notes who joined") { server.chat.filter(\.system).map(\.text) == ["Alice joined", "Bob joined"] }

        // Flight states: relayed once each, in order, never back to the sender.
        func st(_ x: Float, _ t: Double, bird: String = "falcon", fit: String = "", flags: Int = NetState.alive) -> NetState {
            NetState(id: 99, p: SIMD3(x, 50, 0), q: simd_quatf(angle: 0, axis: kUp).vector, v: SIMD3(0, 0, -20),
                     w: SIMD4(0.1, 0.1, 0, 0), hp: 80, flags: flags, bird: bird, progress: 2.5, t: t, fit: fit)
        }
        _ = a.drain(); _ = b.drain()
        for k in 0..<30 { a.send(state: st(Float(k), Double(k) / 30)) }
        var atB: [NetState] = []
        wait("Bob gets all 30 of Alice's states, once each, in order, as id 2") {
            atB += b.drain().states
            return atB.filter { $0.id == 2 }.map(\.p.x) == (0..<30).map(Float.init) && !atB.contains { $0.id == 99 }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(a.drain().states.isEmpty, "Alice never gets her own states back")
        wait("the server shows Alice flying (80 health, race progress)") {
            server.players.first { $0.id == 2 }.map { $0.hp == 80 && $0.progress == 2.5 && $0.has(NetState.alive) } ?? false
        }
        b.send(state: st(0, 1, bird: "phoenix", fit: "h=crown,t=fire", flags: NetState.alive | NetState.paused))
        wait("a new bird or outfit reaches everyone's lobby") { a.lobby.players.contains { $0.name == "Bob" && $0.bird == "phoenix" && $0.fit == "h=crown,t=fire" } }
        wait("the server shows Bob paused") { server.players.first { $0.id == 3 }?.has(NetState.paused) == true }

        // Events: relayed to the others, credited to the sender.
        let shot = Shot(owner: 7, weapon: .missiles, attack: 7, origin: .zero, dir: SIMD3(0, 0, -1), ownerVel: .zero, target: 3)
        a.send(event: .fire(shot))
        var bEvents: [GameEvent] = []
        wait("Bob sees Alice's attack, credited to Alice") {
            bEvents += b.drain().events
            return bEvents.contains { if case .fire(let s) = $0 { return s.owner == 2 }; return false }
        }

        // A race: start, finishes, results, back to warm-up.
        server.startRound()
        wait("everyone gets the round start, with a grid slot each") {
            [aMatch, bMatch].allSatisfy { $0.contains { if case .start(_, _, let slots) = $0 { return Set(slots.keys) == [2, 3] }; return false } }
        }
        wait("the lobby says a round is under way") { a.lobby.running && server.lobby.running && server.roundStarted != nil }
        a.send(event: .finished(id: 3, time: 88.25))
        wait("the server credits a finish to whoever sent it") {
            server.players.first { $0.id == 2 }?.finishTime == 88.25 && server.players.first { $0.id == 3 }?.finishTime == nil
        }
        b.send(event: .finished(id: 3, time: 91.5))
        wait("when everyone has finished, everyone gets the results: Alice, then Bob") {
            results(aMatch)?.map(\.name) == ["Alice", "Bob"] && results(bMatch)?.first?.time == 88.25
        }
        check(server.results?.map(\.name) == ["Alice", "Bob"] && !server.lobby.running, "the server shows the results and the round is over")
        wait("everyone goes back to warm-up 14 s later", 20) { aMatch.contains { if case .warmup = $0 { return true }; return false } }
        aMatch = []
        server.startRound()
        wait("a second round starts") { aMatch.contains { if case .start(2, _, _) = $0 { return true }; return false } }
        server.endRound()
        wait("End round sends the results straight away (nobody finished)") {
            results(aMatch).map { $0.count == 2 && $0.allSatisfy { $0.time == nil && $0.note == "Did not finish" } } ?? false
        }

        // Mode, map and rules.
        server.play(.pvp, on: "caves")
        wait("everyone switches to PvP Fight on Glow Caves") { a.lobby.mode == .pvp && a.lobby.world == "caves" && b.lobby.mode == .pvp && b.lobby.world == "caves" }
        wait("the advertised mode and map follow") { c.games.first { $0.hostName == "Phoney" }.map { $0.mode == .pvp && $0.world == "caves" } ?? false }
        server.setRules(MatchRules(collisions: false, pvp: true, showLocation: false))
        wait("everyone gets the new rules") { a.lobby.rules == MatchRules(collisions: false, pvp: true, showLocation: false) && !b.lobby.rules.collisions }
        aMatch = []
        server.startRound()
        wait("a fight starts") { aMatch.contains { if case .start = $0 { return true }; return false } }
        b.send(event: .died(victim: 3, killer: 2))
        b.send(event: .eliminated(id: 3))
        wait("the fight ends when one bird is left: Alice first with a knock-out, then Bob") {
            results(aMatch).map { $0.map(\.name) == ["Alice", "Bob"] && $0[0].knockouts == 1 } ?? false
        }

        // Chat
        server.say("  welcome\nall  ")
        wait("everyone gets the server's message from Phoney, as one trimmed line") {
            a.chat.contains { $0.id == 1 && $0.name == "Phoney" && $0.color == 6 && $0.text == "welcome all" } && b.chat.contains { $0.text == "welcome all" }
        }
        a.say("hi phone")
        wait("a player's message reaches the server and the others") {
            serverChat.contains { $0.name == "Alice" && $0.text == "hi phone" } && b.chat.contains { $0.name == "Alice" && $0.text == "hi phone" }
        }
        for k in 0..<12 { b.say("spam \(k)") }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let spam = serverChat.filter { $0.name == "Bob" }.count
        check(spam == 6, "spam guard lets 6 of 12 quick messages through (\(spam) did)")

        // Invites: the TXT record alone reaches a game (like a Mac whose firewall turns away direct invites)…
        server.debugNoDirectInvites = true
        if let p = server.nearby.first(where: { $0.name == "Cara" }) { server.invite(p.id) }
        wait("Cara gets an invite from Phoney through the TXT record alone") { cInvite?.from == "Phoney" && cInvite?.color == 6 }
        check(server.nearby.first { $0.name == "Cara" }?.invited == true, "the invite list shows Cara as invited")
        if let inv = cInvite { c.accept(inv) }
        wait("Cara accepts and joins") { c.role == .joined && server.players.count == 3 }
        // …and a 0.3 game gets the direct kind.
        server.debugNoDirectInvites = false
        if let p = server.nearby.first(where: { $0.name == "Olde" }) { server.invite(p.id) }
        wait("a 0.3 game gets the direct invite") { old03.invites.contains("Phoney") }

        // Heartbeats keep a quiet game together; a player who goes silent is dropped.
        RunLoop.main.run(until: Date().addingTimeInterval(LANProtocol.timeout + 2))
        wait("still connected after \(Int(LANProtocol.timeout + 2)) s with nothing to say") {
            [a, b, c].allSatisfy { $0.role == .joined } && server.players.count == 3
        }
        c.debugGoSilent()
        let silentAt = Date()
        wait("the server drops a player who went silent", LANProtocol.timeout + 5) { server.players.count == 2 }
        print(String(format: "      dropped after %.1f s", Date().timeIntervalSince(silentAt)))
        wait("the chat notes that Cara left") { server.chat.last?.text == "Cara left" }

        // Removing a player, and letting them back.
        server.kick(3)
        wait("removed Bob is told and leaves") { b.role == .idle && bEnded == "The host removed you from the game." }
        wait("the server lists Bob under removed players") { server.removed.map(\.name) == ["Bob"] && server.players.count == 1 }
        if let g = b.games.first(where: { $0.hostName == "Phoney" }) { b.join(g) }
        wait("a removed player can't rejoin") { b.role == .idle && b.status.contains("removed") }
        if let r = server.removed.first { server.allowBack(r.id) }
        wait("allowing Bob back empties the list") { server.removed.isEmpty }
        if let g = b.games.first(where: { $0.hostName == "Phoney" }) { b.join(g) }
        wait("once allowed back, Bob can join again") { b.role == .joined && server.players.count == 2 }

        // Other versions and a full game.
        let wrong = RawJoiner(instance: "RAW00004", version: LANProtocol.version - 1)
        wait("a game on another LAN version is turned away") { wrong.rejection?.contains("same version") == true }
        var raws: [RawJoiner] = []
        for k in 0..<6 { raws.append(RawJoiner(instance: "RAW0010\(k)")) }
        wait("the server takes \(LANProtocol.maxPlayers) players") { raws.allSatisfy(\.welcomed) && server.players.count == LANProtocol.maxPlayers }
        let ninth = RawJoiner(instance: "RAW00200")
        wait("a ninth player is told the game is full") { ninth.rejection == "That game is full." }
        raws.forEach { $0.close() }
        wrong.close()
        ninth.close()
        wait("players who disconnect leave the lobby") { server.players.count == 2 && a.lobby.players.count == 2 }

        // Stopping: everyone is told, and the game leaves the network.
        server.stop()
        wait("when the server stops, everyone is told the game is over") { a.role == .idle && aEnded == "The host ended the game." && b.role == .idle }
        wait("the game disappears from the network") { !a.games.contains { $0.hostName == "Phoney" } }
        old03.stop()
        a.leave(); b.leave()
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
        for world in WorldID.allCases where only == nil || only == world {
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
                    // Between buildings: stay on the street's centre line.
                    if world == .city { v = f.at(0, 0, 5) }
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
                    for _ in 0..<62 {
                        g.update(time: t)
                        g.cameraNode.simdPosition = vent + SIMD3(90, 25, 90)
                        g.cameraNode.simdLook(at: vent + SIMD3(0, 36, 0), up: kUp, localFront: SIMD3(0, 0, -1))
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
            var target = g.nextGate < track.gates.count && simd_distance(track.gates[g.nextGate].center, g.flight.pos) < 60
                ? track.gates[g.nextGate].center : track.point(atArc: min(g.progressS + 45, track.length))
            // Follow dips (down to a barn door) closer in than the turns.
            target.y = min(target.y, track.point(atArc: min(g.progressS + 18, track.length)).y)
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

        // --- Speed-race checkpoints: the next one pulses in place (its node used to sit at the world's origin, so the
        // pulse swung the hoop back and forth by ~5% of its distance from there: tens of metres on the Dogfight course).
        let sr = Game(controls: SharedControls(), world: .dogfight, mode: .speedRace, species: sp, points: sp.base, terrainRadius: 3)
        sr.synchronousTerrain = true
        step(sr, 4.5)
        if let st = sr.track, st.gates.indices.contains(sr.nextGate) {
            let gate = st.gates[sr.nextGate]
            var worst: Float = 0
            for _ in 0..<90 {
                step(sr, 1.0 / 60)
                let b = gate.node.boundingSphere.center
                let world = gate.node.simdConvertPosition(SIMD3(Float(b.x), Float(b.y), Float(b.z)), to: nil)
                worst = max(worst, simd_distance(world, gate.center))
            }
            check(worst < 0.5, String(format: "the next checkpoint pulses in place (%.0f m from the origin, moved %.2f m)",
                                       simd_length(gate.center), worst))
        } else {
            check(false, "speed race has checkpoints")
        }

        // --- Test codes: unlock every cosmetic, then reset everything (which takes them all away again).
        let key = "progress.scenario-codes"
        UserDefaults.standard.removeObject(forKey: key)
        let p = Progress(key: key)
        let buyable = CosmeticCatalog.all.filter { !CosmeticCatalog.isFree($0) }
        check(p.unlockAllCosmetics() == buyable.count && buyable.allSatisfy(p.ownsCosmetic), "the code unlocks all \(buyable.count) cosmetics")
        check(p.unlockAllCosmetics() == 0, "…and again does nothing")
        p.wear(CosmeticCatalog.item("crown", .hat), slot: .hat)
        p.wear(CosmeticCatalog.item("stardust", .trail), slot: .trail)
        check(p.outfit.code.contains("crown") && p.outfit.code.contains("stardust"), "unlocked things can be worn (\(p.outfit.code))")
        p.grant(500)
        p.resetAll()
        check(p.coins == 0 && p.cosmeticsOwned == 0 && p.outfit == Outfit() && !buyable.contains(where: p.ownsCosmetic),
              "reset takes every cosmetic away and undresses the bird")
        check(Progress(key: key).cosmeticsOwned == 0, "…and it stays reset after a restart")
        UserDefaults.standard.removeObject(forKey: key)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}

enum PerfTest {
    /// `--perf-test [bird] [seconds]`: frame times (simulation + a real render at 1280×800, 4× MSAA) in a fight while
    /// everyone attacks nonstop, compared with plain free flight.
    static func run(bird: String, seconds: Double) {
        let sp = Catalog.species(bird)
        let device = MTLCreateSystemDefaultDevice()
        let heavy = Outfit(code: "h=crown,e=visor,n=rainbowscarf,t=stardust,p=galaxy")
        func measure(_ label: String, _ mode: GameMode, attack: Bool, dressed: Bool = false, world: WorldID = .meadow) {
            let g = Game(controls: SharedControls(), world: world, mode: mode, species: sp, points: sp.base,
                         outfit: dressed ? heavy : Outfit(), terrainRadius: 4)
            g.synchronousTerrain = true
            func dress() {
                // Everyone in their fanciest clothes, each with a different trail.
                let trails = ["rainbow", "fire", "neon", "confetti", "smoke", "hearts"]
                for (i, b) in g.bots.enumerated() {
                    b.avatar.setLook(species: b.avatar.speciesId, outfit: "h=tophat,e=aviators,n=scarf,t=\(trails[i % trails.count]),p=chrome")
                }
            }
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
            let verbose = ProcessInfo.processInfo.environment["PERF_VERBOSE"] != nil
            if verbose {
                g.debugEvent = { e in if !e.hasPrefix("hit from") { print(String(format: "     %.2f %@", t, e)) } }
                g.onNotice = { e in print(String(format: "     %.2f notice: %@", t, e)) }
                g.onKnockout = { e in print(String(format: "     %.2f KO %@", t, e)) }
            }
            var chunks = g.terrain.loadedCount
            // Like the app: compile the world's (and the attacks') shaders up front.
            for o in g.warmupObjects() { _ = r.prepare(o, shouldAbortBlock: nil) }
            // Warm up (terrain, shaders).
            for k in 0..<120 {
                if k == 60 && dressed { dress() }
                g.update(time: t); _ = r.snapshot(atTime: t, with: CGSize(width: 320, height: 200), antialiasingMode: .none); t += 1.0 / 60
            }
            // From here on, terrain streams in the background like in the real game.
            g.synchronousTerrain = false
            if let hide = ProcessInfo.processInfo.environment["PERF_HIDE"] {
                // Experiments: hide a kind of node to see what the frame costs.
                g.scene.rootNode.enumerateHierarchy { n, _ in
                    guard let m = n.geometry?.firstMaterial else { return }
                    let facade = m === CityShaders.facade, glow = m === CityShaders.signals
                    if hide.contains("facade") && facade { n.isHidden = true }
                    if hide.contains("glow") && glow { n.isHidden = true }
                    if hide.contains("terrain") && n.parent === g.terrain.root { n.geometry = nil }
                    if hide.contains("props") && !facade && !glow && n.parent?.parent === g.terrain.root { n.isHidden = true }
                }
                if hide.contains("shadow") { g.sun.light?.castsShadow = false }
                if hide.contains("life"), let rt = g.runtime as? CityRuntime { rt.life.root.isHidden = true }
            }
            var times: [Double] = [], maxProj = 0
            var simTotal: Double = 0
            let frames = Int(seconds * 60)
            for _ in 0..<frames {
                if attack { g.keys.attack = true; g.fighter.shield = 99; g.fighter.health = Fighter.maxHealth }
                if verbose { RunLoop.main.run(until: Date()) }
                let t0 = CACurrentMediaTime()
                let before = g.combat.activeCount
                g.update(time: t)
                let t1 = CACurrentMediaTime()
                _ = r.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
                let t2 = CACurrentMediaTime()
                times.append((t2 - t0) * 1000)
                simTotal += (t1 - t0) * 1000
                if (t2 - t0) * 1000 > 18 && ProcessInfo.processInfo.environment["PERF_VERBOSE"] != nil {
                    print(String(format: "   spike at %.2f s: update %.1f ms, render %.1f ms, projectiles %d→%d", t, (t1 - t0) * 1000,
                                 (t2 - t1) * 1000, before, g.combat.activeCount))
                }
                maxProj = max(maxProj, g.combat.activeCount)
                if verbose && g.terrain.loadedCount != chunks {
                    print(String(format: "     %.2f terrain chunks %d -> %d", t, chunks, g.terrain.loadedCount))
                    chunks = g.terrain.loadedCount
                }
                t += 1.0 / 60
            }
            let sorted = times.sorted()
            let avg = times.reduce(0, +) / Double(times.count)
            print(String(format: "%-30@ avg %5.1f ms (sim %4.1f)   p95 %5.1f   worst %5.1f   frames over 33 ms: %d   max projectiles %d",
                         label as NSString, avg, simTotal / Double(times.count), sorted[Int(Double(sorted.count) * 0.95)], sorted.last!,
                         times.filter { $0 > 33 }.count, maxProj))
        }
        if let name = ProcessInfo.processInfo.environment["PERF_WORLD"], let w = WorldID(rawValue: name) {
            measure("\(name) free flight", .freeRoam, attack: false, world: w)
            BotSettings.count = 5
            measure("\(name) fight, 5 dressed", .pvp, attack: true, dressed: true, world: w)
            return
        }
        measure("free flight", .freeRoam, attack: false)
        measure("free flight, dressed up", .freeRoam, attack: false, dressed: true)
        measure("fight, \(sp.name) attacking", .pvp, attack: true)
        let bots = BotSettings.count
        BotSettings.count = 5
        measure("fight, 5 bots, all dressed", .pvp, attack: true, dressed: true)
        measure("caves fight, 5 dressed", .pvp, attack: true, dressed: true, world: .caves)
        measure("volcano free flight, dressed", .freeRoam, attack: false, dressed: true, world: .volcano)
        measure("city free flight", .freeRoam, attack: false, world: .city)
        measure("city fight, 5 dressed", .pvp, attack: true, dressed: true, world: .city)
        BotSettings.count = bots
    }
}

enum EconomySim {
    /// `--economy-sim [minutes]`: how fast coins come in. A ring-chasing autopilot flies free roam in every world, then every
    /// race course and a fight, and prints coins per minute (the autopilot is better than a person flapping, so treat these
    /// as an upper bound).
    static func run(minutes: Double) {
        func luckBonus(_ sp: Species) -> Float { 0.6 + 0.08 * Float(sp.base[BirdStat.luck.rawValue]) }
        func perRing(_ sp: Species) -> Float { (5 * luckBonus(sp)).rounded() }
        print("FREE ROAM (\(Int(minutes)) min each, autopilot chasing rings)")
        let only = ProcessInfo.processInfo.environment["ECON_WORLDS"].map { Set($0.split(separator: ",").compactMap { WorldID(rawValue: String($0)) }) }
        for world in WorldID.allCases where only == nil || only!.contains(world) {
            for bird in ["gull", "phoenix"] {
                let sp = Catalog.species(bird)
                let g = Game(controls: SharedControls(), world: world, mode: .freeRoam, species: sp, points: sp.base, terrainRadius: 3)
                g.synchronousTerrain = true
                var phase: Float = 0
                g.debugSteer = { g in
                    guard let r = g.rings.next else { return nil }
                    if let cave = g.runtime as? CaveRuntime, let s = cave.autopilot(g.flight) {
                        // Caves: follow the tunnel, aiming at the ring once it's close.
                        var i = steerToward(g, r.center, phase: &phase, dt: 1.0 / 60)
                        if simd_distance(r.center, g.flight.pos) > 25 { i.roll = s.roll; i.pitch = s.pitch }
                        return i
                    }
                    return steerToward(g, r.center, phase: &phase, dt: 1.0 / 60)
                }
                var coins: Float = 0, rings = 0, lost = 0, bestStreak = 0
                let w = WorldCatalog.info(world.rawValue)
                g.onRing = { streak in
                    rings += 1
                    bestStreak = max(bestStreak, streak)
                    let bonus: Float = w.isChallenge ? w.ringMultiplier * (1 + 0.25 * Float(min(max(streak - 1, 0), 8))) : 1
                    coins += (perRing(sp) * bonus).rounded()
                }
                g.onHit = { lost += $0 }
                var t = 0.0
                while t < minutes * 60 {
                    g.update(time: t)
                    t += 1.0 / 60
                    if Int(t * 60) % 30 == 0 { RunLoop.main.run(until: Date()) }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                print(String(format: "  %-9@ %-8@ rings/min %5.1f  coins/min %6.1f  (lost %d)  best streak %d",
                             world.rawValue as NSString, bird as NSString, Float(rings) / Float(minutes),
                             (coins - Float(lost)) / Float(minutes), lost, bestStreak))
            }
        }
        print("RACES (gull, autopilot)")
        for world in WorldID.allCases where only == nil || only!.contains(world) {
            for mode in [GameMode.ringRace, .speedRace] {
                let sp = Catalog.species("gull")
                let g = Game(controls: SharedControls(), world: world, mode: mode, species: sp, points: sp.base, terrainRadius: 3)
                g.synchronousTerrain = true
                let track = g.track!
                var phase: Float = 0
                g.debugSteer = { g in
                    var target = g.nextGate < track.gates.count && simd_distance(track.gates[g.nextGate].center, g.flight.pos) < 60
                        ? track.gates[g.nextGate].center : track.point(atArc: min(g.progressS + 45, track.length))
                    // Follow dips (down to a barn door) closer in than the turns.
                    target.y = min(target.y, track.point(atArc: min(g.progressS + 18, track.length)).y)
                    return steerToward(g, target, phase: &phase, dt: 1.0 / 60)
                }
                var out: MatchOutcome?
                g.onMatchOver = { out = $0 }
                var t = 0.0
                while out == nil && t < 600 {
                    g.update(time: t)
                    t += 1.0 / 60
                    if Int(t * 60) % 30 == 0 { RunLoop.main.run(until: Date()) }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                guard let o = out, let time = o.time else { print("  \(world.rawValue) \(mode.rawValue): did not finish"); continue }
                let medal = Medal.of(time, o.medals)
                let base = o.gates * 3 + 25 + (medal?.coins ?? 0)
                let firstTime = o.gates * 3 + 25 + 15 + (medal?.coins ?? 0) * 2
                print(String(format: "  %-9@ %-10@ %@ (%@)  missed %d  coins %d (first medal %d)  ≈ %.0f coins/min",
                             world.rawValue as NSString, mode.rawValue as NSString, raceClock(time), medal?.name ?? "no medal",
                             o.missed, base, firstTime, Double(base) / ((time + 12) / 60)))
            }
        }
    }
}

enum CosmeticGallery {
    /// `--cosmetic-gallery <dir> [slot or item id]`: every cosmetic on every playable bird, from a close 3/4 front view and
    /// the in-game chase camera (trails: from the side and the chase camera after a short curving flight).
    static func run(dir: String, filter: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // GALLERY_BIRDS=owl,gull limits the birds.
        let only = ProcessInfo.processInfo.environment["GALLERY_BIRDS"]?.split(separator: ",").map(String.init)
        let birds = Catalog.playable.filter { only?.contains($0.id) ?? true }
        let cell = CGSize(width: 360, height: 270)
        let device = MTLCreateSystemDefaultDevice()
        if filter == "combos" { combos(dir: dir, cell: cell, device: device); return }
        var items = CosmeticCatalog.all
        if let f = filter { items = items.filter { $0.slot.rawValue == f || $0.id == f } }
        for item in items {
            let rows = item.slot == .trail ? 2 : 3
            var shots: [[NSImage]] = Array(repeating: [], count: rows)
            for sp in birds {
                var outfit = Outfit()
                outfit[item.slot] = item.id
                let views = render(sp, outfit: outfit, trail: item.slot == .trail, size: cell, device: device)
                for r in 0..<rows { shots[r].append(views[r]) }
            }
            let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(birds.count), height: cell.height * CGFloat(rows) + 30), flipped: false) { r in
                NSColor(white: 0.12, alpha: 1).setFill(); r.fill()
                for row in 0..<rows {
                    for (i, img) in shots[row].enumerated() {
                        img.draw(in: NSRect(x: CGFloat(i) * cell.width, y: CGFloat(rows - 1 - row) * cell.height, width: cell.width, height: cell.height))
                    }
                }
                let label = "\(item.name) (\(item.slot.rawValue), \(item.rarity.name))   " + birds.map(\.name).joined(separator: " · ")
                (label as NSString).draw(at: NSPoint(x: 8, y: cell.height * CGFloat(rows) + 8),
                                         withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 14)])
                return true
            }
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(item.slot.rawValue)-\(item.id).png"))
            }
            print("rendered \(item.slot.rawValue) \(item.id)")
        }
    }

    /// Whole outfits (hat + glasses + neck + paint) on the birds, to catch items that clash.
    static func combos(dir: String, cell: CGSize, device: MTLDevice?) {
        let outfits: [(String, Outfit)] = [
            ("beanie+shades+scarf", Outfit(code: "h=beanie,e=shades,n=scarf")),
            ("cap+aviators+bandana", Outfit(code: "h=cap,e=aviators,n=bandana")),
            ("viking+goggles+medal", Outfit(code: "h=viking,e=goggles,n=medal")),
            ("crown+monocle+bowtie", Outfit(code: "h=crown,e=monocle,n=bowtie,p=chrome")),
            ("explorer+nerd+bell", Outfit(code: "h=explorer,e=nerd,n=bell,p=robin")),
            ("chef+heartglasses+lei", Outfit(code: "h=chef,e=heartglasses,n=lei,p=candy")),
            ("grad+pixel+rainbowscarf", Outfit(code: "h=grad,e=pixel,n=rainbowscarf,p=midnight")),
            ("propeller+threed+bowtie", Outfit(code: "h=propeller,e=threed,n=bowtie,p=tropical")),
            ("cowboy+visor+bandana", Outfit(code: "h=cowboy,e=visor,n=bandana,p=camo")),
            ("tophat+starshades+medal", Outfit(code: "h=tophat,e=starshades,n=medal,p=gold")),
            ("pirate+shades+bell", Outfit(code: "h=pirate,e=shades,n=bell,p=tiger")),
            ("wizard+monocle+scarf", Outfit(code: "h=wizard,e=monocle,n=scarf,p=galaxy")),
            ("unicorn+heartglasses+lei", Outfit(code: "h=unicorn,e=heartglasses,n=lei,p=flamingo")),
            ("sombrero+aviators+bandana", Outfit(code: "h=sombrero,e=aviators,n=bandana,p=sunset")),
            ("party+nerd+bowtie", Outfit(code: "h=party,e=nerd,n=bowtie,p=bluejay")),
            ("halo+visor+rainbowscarf", Outfit(code: "h=halo,e=visor,n=rainbowscarf,p=neonpaint")),
        ]
        let birds = Catalog.playable
        for (name, o) in outfits {
            var row: [[NSImage]] = [[], [], []]
            for sp in birds {
                let v = render(sp, outfit: o, trail: false, size: cell, device: device)
                for r in 0..<3 { row[r].append(v[r]) }
            }
            let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(birds.count), height: cell.height * 2 + 30), flipped: false) { r in
                NSColor(white: 0.12, alpha: 1).setFill(); r.fill()
                for (i, img) in row[0].enumerated() { img.draw(in: NSRect(x: CGFloat(i) * cell.width, y: cell.height, width: cell.width, height: cell.height)) }
                for (i, img) in row[2].enumerated() { img.draw(in: NSRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height)) }
                (name as NSString).draw(at: NSPoint(x: 8, y: cell.height * 2 + 8), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 14)])
                return true
            }
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/combo-\(name).png"))
            }
        }
    }

    /// Returns [close-up or side view, chase view, rear close-up (not for trails)].
    static func render(_ sp: Species, outfit: Outfit, trail: Bool, size: CGSize, device: MTLDevice?,
                       pose: (Float, Float) = (0.15, 0)) -> [NSImage] {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = Sky.cachedFaces
        scene.lightingEnvironment.intensity = 1.25
        scene.background.contents = Sky.cachedFaces
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 2000
        sun.simdLook(at: -Sky.sunDir, up: kUp, localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(sun)
        let bird = BirdNode(look: sp.look, outfit: outfit)
        scene.rootNode.addChildNode(bird.node)
        scene.rootNode.addChildNode(bird.fxRoot)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.05
        cam.camera?.wantsHDR = true
        cam.camera?.bloomIntensity = 0.5
        cam.camera?.bloomThreshold = 1.1
        cam.camera?.exposureOffset = 0.15
        scene.rootNode.addChildNode(cam)
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = cam
        let k = 1.25 * sp.look.size
        func snap(_ t: Double) -> NSImage { r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X) }
        let wing = WingPose(elevation: pose.0, bend: pose.1)
        var t = 0.0
        if trail {
            // Fly a gentle curve for a moment so the trail builds up.
            var pos = SIMD3<Float>(0, 50, 0), yaw: Float = 0
            var camPos = pos + SIMD3(0, 1.45, 5)
            let dt: Float = 1.0 / 60
            for i in 0..<100 {
                yaw += dt * 0.35
                let fwd = SIMD3(-sin(yaw), 0, -cos(yaw))
                pos += fwd * 20 * dt
                let flap = sin(Float(i) * 0.35) * 0.6
                bird.node.simdPosition = pos
                bird.node.simdOrientation = simd_quatf(angle: yaw, axis: kUp) * simd_quatf(angle: 0.25, axis: SIMD3(0, 0, 1))
                bird.pose(left: WingPose(elevation: 0.15 + flap, bend: 0), right: WingPose(elevation: 0.15 + flap, bend: 0), fold: 0, pitchIn: 0, rollIn: 0, dt: dt)
                camPos = pos - fwd * 5 + SIMD3(0, 1.45, 0)
                bird.tick(dt: dt, speed: 20, camera: camPos, emitting: true)
                cam.simdPosition = camPos
                cam.simdLook(at: pos + fwd * 5 + SIMD3(0, 0.35, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                _ = r.snapshot(atTime: t, with: CGSize(width: 32, height: 24), antialiasingMode: .none)
                t += Double(dt)
            }
            let fwd = SIMD3(-sin(yaw), 0, -cos(yaw))
            let side = simd_normalize(simd_cross(fwd, kUp))
            cam.camera?.fieldOfView = 50
            cam.simdPosition = pos - fwd * 6 + side * 7 + SIMD3(0, 2.5, 0)
            cam.simdLook(at: pos - fwd * 5, up: kUp, localFront: SIMD3(0, 0, -1))
            // Ribbons turn to face whichever camera is looking.
            bird.tick(dt: 0.0001, speed: 20, camera: cam.simdPosition, emitting: true)
            let a = snap(t)
            bird.tick(dt: 0.0001, speed: 20, camera: camPos, emitting: true)
            cam.camera?.fieldOfView = 62
            cam.simdPosition = camPos
            cam.simdLook(at: pos + fwd * 5 + SIMD3(0, 0.35, 0), up: kUp, localFront: SIMD3(0, 0, -1))
            let b = snap(t + 0.001)
            return [a, b]
        }
        bird.node.simdPosition = .zero
        bird.pose(left: wing, right: wing, fold: 0, pitchIn: 0, rollIn: 0, dt: 1)
        for _ in 0..<3 { bird.tick(dt: 1.0 / 30, speed: 14, camera: .zero, emitting: false) }
        // Close 3/4 front view of the head.
        let headPos = sp.look.headCenter * k
        let hk = k * sp.look.headScale
        cam.camera?.fieldOfView = 34
        cam.simdPosition = headPos + SIMD3(0.55, 0.3, -1.12) * hk
        cam.simdLook(at: headPos + SIMD3(0, 0.02, 0) * k, up: kUp, localFront: SIMD3(0, 0, -1))
        let a = snap(0)
        // In-game chase camera.
        cam.camera?.fieldOfView = 60
        cam.simdPosition = SIMD3(0, 1.45, 4.6)
        cam.simdLook(at: SIMD3(0, 0.35, -5), up: kUp, localFront: SIMD3(0, 0, -1))
        let b = snap(0.01)
        // Close from behind and above (the pause-menu orbit sees the bird like this).
        cam.camera?.fieldOfView = 40
        cam.simdPosition = headPos + SIMD3(-0.55, 0.75, 1.5) * hk
        cam.simdLook(at: headPos + SIMD3(0, 0.0, 0.1) * hk, up: kUp, localFront: SIMD3(0, 0, -1))
        let c = snap(0.02)
        return [a, b, c]
    }
}

enum TutorialTest {
    /// A stand-in for the app: the real game and arm interpreter, fed with scripted body poses.
    final class Host: TutorialHost {
        let game: Game
        let shared: SharedControls
        let interp = ArmInterpreter()
        var paused = false
        var tourStarted = false
        var log: [String] = []
        init(game: Game, shared: SharedControls) { self.game = game; self.shared = shared }
        var tutorialStats: HUDStats { game.stats }
        var tutorialControl: ControlState { shared.control }
        var tutorialPaused: Bool { paused }
        func tutorialRecalibrate() { interp.recalibrate() }
        func tutorialRings(_ on: Bool) { game.setTutorialRings(on) }
        func tutorialTargets(_ on: Bool) { game.setPracticeTargets(on) }
        func tutorialBigPreview(_ on: Bool) {}
        func tutorialStartMenuTour() { tourStarted = true }
        func tutorialSound(_ success: Bool) {}
        var finished: Bool?
        func tutorialFinished(completed: Bool) { finished = completed }
    }

    /// Raw keypoints for arm elevations (radians above level, person's left then right), like DemoPoseSource.
    static func pose(_ t: Double, left eL: Float, right eR: Float, bendL: Float = 0, bendR: Float = 0, reach: Float = 1) -> RawPose {
        var p = RawPose(time: t, aspect: 1760.0 / 1328.0)
        let sw: Float = 0.17, l1: Float = 0.15, l2: Float = 0.14, cy: Float = 0.6
        func put(_ j: Joint, _ x: Float, _ y: Float) { p[j] = SIMD3(x / p.aspect + 0.5, y, 0.9) }
        put(.neck, 0, cy + 0.02); put(.nose, 0, cy + 0.12)
        put(.lHip, sw * 0.35, cy - 0.3); put(.rHip, -sw * 0.35, cy - 0.3)
        for (side, e, b) in [(Float(1), eL, bendL), (Float(-1), eR, bendR)] {
            let sx = side * sw / 2
            let ex = sx + side * cos(e) * l1 * reach, ey = cy + sin(e) * l1
            let wx = ex + side * cos(e + b) * l2 * reach, wy = ey + sin(e + b) * l2
            if side > 0 { put(.lShoulder, sx, cy); put(.lElbow, ex, ey); put(.lWrist, wx, wy) }
            else { put(.rShoulder, sx, cy); put(.rElbow, ex, ey); put(.rWrist, wx, wy) }
        }
        return p
    }

    /// `--tutorial-test`: play through every step with scripted arm poses (and once with the keyboard).
    static func run() {
        var failures = 0
        for keyboard in [false, true] {
            let shared = SharedControls()
            let sp = Catalog.species("gull")
            let g = Game(controls: shared, world: .meadow, mode: .freeRoam, species: sp, points: sp.base, terrainRadius: 3)
            g.synchronousTerrain = true
            g.setTutorialRings(false)
            let host = Host(game: g, shared: shared)
            let tut = TutorialController()
            var t = 0.0
            tut.clock = { t }
            tut.host = host
            tut.start()
            var stepTimes: [String: Double] = [:]
            var stepStart = 0.0
            var last = tut.index
            var phase: Float = 0
            let end = 400.0
            while t < end && host.finished == nil {
                let step = tut.step.id
                // What the "player" does for this step.
                var eL: Float = 0.02, eR: Float = -0.02, reach: Float = 1
                var steer: FlightInput?
                g.keys = KeyInput()
                let local = t - stepStart
                switch step {
                case "flap":
                    let ph = Float(local) * 2 * .pi * 1.2
                    eL = 0.25 + 0.85 * sin(ph); eR = eL
                    if keyboard { g.keys.flap = true }
                case "turn":
                    let right = local.truncatingRemainder(dividingBy: 4) < 2
                    eL = right ? 0.5 : -0.5; eR = -eL
                    if keyboard { if right { g.keys.right = true } else { g.keys.left = true } }
                case "up":
                    eL = 0.45; eR = 0.45
                    if keyboard { g.keys.up = true }
                case "down":
                    eL = -0.45; eR = -0.45
                    if keyboard { g.keys.down = true }
                case "dive":
                    eL = -1.45; eR = -1.45; reach = 0.2
                    if keyboard { g.keys.tuck = true }
                case "rings":
                    if let r = g.rings.next { steer = steerToward(g, r.center, phase: &phase, dt: 1.0 / 60) }
                case "attack":
                    // Fly at the nearest balloon and fire once locked on.
                    if let target = g.practice?.active.min(by: { simd_distance($0.pos, g.flight.pos) < simd_distance($1.pos, g.flight.pos) }) {
                        steer = steerToward(g, target.pos, phase: &phase, dt: 1.0 / 60)
                        if g.lockTarget != nil && g.fighter.cooldown <= 0 { g.keys.attack = true }
                    }
                case "menu":
                    if !host.paused && !host.tourStarted { host.paused = true; g.paused = true; tut.menuOpened() }
                    else if host.tourStarted && host.paused && local > 3 { tut.menuTourFinished(); host.paused = false; g.paused = false }
                default:
                    break
                }
                g.debugSteer = steer.map { s in { _ in s } }
                // Camera frames at 30 Hz, game at 60 Hz, tutorial ticks at 30 Hz.
                if Int(t * 60) % 2 == 0 {
                    if keyboard {
                        shared.publish(ControlState(), pose: nil)
                        if g.keys.any == false { g.keys.flap = step == "view" || step == "calibrate" }
                    } else {
                        let raw = pose(t, left: eL, right: eR, reach: reach)
                        shared.publish(host.interp.process(raw, time: t), pose: raw)
                    }
                    tut.tick()
                }
                g.update(time: t)
                if Int(t * 60) % 20 == 0 { RunLoop.main.run(until: Date()) }
                t += 1.0 / 60
                if tut.index != last || host.finished != nil {
                    stepTimes[TutorialSteps.all[last].id] = t - stepStart
                    stepStart = t
                    last = tut.index
                }
            }
            let label = keyboard ? "keyboard" : "arms"
            if host.finished == true {
                print("PASS  \(label): all \(TutorialSteps.all.count) steps in \(Int(t)) s   " +
                      TutorialSteps.all.map { String(format: "%@ %.1fs", $0.id, stepTimes[$0.id] ?? -1) }.joined(separator: ", "))
            } else {
                failures += 1
                print("FAIL  \(label): stuck on step \(tut.index + 1) (\(tut.step.id)) after \(Int(t)) s")
            }
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}

// MARK: - Update test

/// `--update-test`: checks the feed named by BIRD_UPDATE_FEED, installs what it offers and exits once the helper has
/// taken over (set BIRD_UPDATE_NO_RELAUNCH=1 so the new copy isn't opened). Exit 0 = handed over.
enum UpdateTest {
    static func run() {
        var ok = true
        func expect(_ c: Bool, _ what: String) { print((c ? "  ok  " : "  FAIL ") + what); if !c { ok = false } }
        expect(Updater.isNewer("0.3", than: "0.2.1"), "0.3 > 0.2.1")
        expect(Updater.isNewer("0.10", than: "0.9"), "0.10 > 0.9")
        expect(Updater.isNewer("v1.0", than: "0.9.9"), "v1.0 > 0.9.9")
        expect(!Updater.isNewer("0.3", than: "0.3.0"), "0.3 = 0.3.0")
        expect(!Updater.isNewer("0.2.1", than: "0.3"), "0.2.1 < 0.3")
        let sample = """
        {"tag_name":"v0.4","html_url":"https://example.com/r","body":"Intro\\n- **Bold** thing\\n* `code` thing\\nnot a bullet",
         "assets":[{"name":"notes.txt","browser_download_url":"https://example.com/n"},
                   {"name":"BirdGame-0.4.dmg","browser_download_url":"https://example.com/b.dmg","size":123,"digest":"sha256:ABCDEF"}]}
        """
        let r = Updater.parse(Data(sample.utf8))
        expect(r?.version == "0.4" && r?.tag == "v0.4", "parses the tag")
        expect(r?.dmg.absoluteString == "https://example.com/b.dmg" && r?.size == 123, "finds the DMG asset")
        expect(r?.sha256 == "abcdef", "reads the digest")
        expect(r?.notes == ["Bold thing", "code thing"], "cleans up the notes: \(r?.notes ?? [])")
        // A swap that didn't happen is noticed at the next launch (once), and one that did isn't.
        let probe = Updater()
        UserDefaults.standard.set("99.0", forKey: "update.pending")
        expect(probe.checkLastInstall() == "99.0" && probe.installFailedBefore == "99.0", "notices an install that didn't go in")
        expect(probe.checkLastInstall() == nil, "…only once")
        UserDefaults.standard.set(AppVersion.short, forKey: "update.pending")
        expect(Updater().checkLastInstall() == nil, "an install that went in is fine")
        guard ok else { print("update-test: unit checks FAILED"); exit(1) }
        guard ProcessInfo.processInfo.environment["BIRD_UPDATE_FEED"] != nil else { print("update-test: unit checks passed (no feed set)"); exit(0) }

        let u = Updater()
        print("update-test: running \(u.current) from \(Bundle.main.bundlePath)")
        u.quit = { print("update-test: helper started, exiting"); fflush(stdout); exit(0) }
        var lastPrinted = -1
        u.onChange = { s in
            if case .downloading(_, let p) = s {
                let pct = Int(p * 100)
                if pct / 25 != lastPrinted { lastPrinted = pct / 25; print("update-test: downloading \(pct)%") }
            } else {
                print("update-test: \(s)")
            }
            fflush(stdout)
            switch s {
            case .available: u.install()
            case .upToDate, .failed, .offline, .manual: exit(1)
            default: break
            }
        }
        u.check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("update-test: timed out"); exit(1) }
        RunLoop.main.run()
    }
}

enum ObstacleShots {
    /// `--obstacle-shots <dir>`: close-ups of the obstacles, standing and floating, in each world.
    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["OBST_WORLDS"]?.split(separator: ",").compactMap { WorldID(rawValue: String($0)) }
        for world in [WorldID.meadow, .volcano, .dogfight, .caves, .dino, .west] where only == nil || only!.contains(world) {
            let g = Game(controls: SharedControls(), world: world, terrainRadius: 4)
            g.synchronousTerrain = true
            g.bird.node.isHidden = true
            let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            r.scene = g.scene
            r.pointOfView = g.cameraNode
            var t = 0.0
            // A spot near the start (in the caves: inside the starting tunnel).
            let o = g.flight.pos
            let ground = TerrainShape.ground(o.x, o.z)
            let terrain = TerrainShape.active
            let items: [(String, (PathFrame) -> Obstacle)]
            switch world {
            case .meadow: items = [
                ("stacks", { Pillars(style: .seaStack, frame: $0, top: $0.origin.y + 22) }),
                ("stacks-floating", { Pillars(style: .seaStack, frame: $0, top: $0.origin.y + 22, floating: true) }),
                ("arch", { StoneArch(frame: $0) }),
                ("arch-floating", { StoneArch(frame: $0, floating: true) }),
            ]
            case .volcano: items = [
                ("spires", { Pillars(style: .spire, frame: $0, radius: 4.6, top: $0.origin.y + 16) }),
                ("spires-floating", { Pillars(style: .spire, frame: $0, radius: 4.6, top: $0.origin.y + 16, floating: true) }),
            ]
            case .dogfight: items = [
                ("balloons", { Balloons(frame: $0, pathY: $0.origin.y) }),
                ("barn", { Barn(frame: $0) }),
                ("windmill", { Windmill(style: .farm, frame: $0, length: 12, phase: 0) }),
                ("silos", { Pillars(style: .silo, frame: $0, count: 3, spacing: 30, offset: 6, radius: 4, top: $0.origin.y + 6) }),
            ]
            case .dino: items = [
                ("ribs", { FossilRibs(frame: $0) }),
                ("fallen", { FallenGiant(frame: $0) }),
                ("steam", { SteamGeysers(frame: $0) }),
                ("pteros", { PteroOrbit(frame: $0, phase: 0) }),
            ]
            case .west: items = [
                ("sandarch", { SandArch(frame: $0) }),
                ("hoodoos", { Hoodoos(frame: $0) }),
                ("cartbridge", { CartBridge(frame: $0, phase: 0) }),
                ("windpump", { Windpump(frame: $0) }),
                ("trestle", { LowTrestle(frame: $0) }),
            ]
            default: items = [
                ("crushers", { Crushers(frame: $0, terrain: terrain) }),
            ]
            }
            for (name, make) in items {
                let floating = name.hasSuffix("floating")
                let caves = world == .caves
                let fwd = simd_normalize(SIMD3(g.flight.forward.x, 0, g.flight.forward.z))
                let height: Float = floating ? 90 : 20
                let c: SIMD3<Float> = caves ? o + fwd * 30 : SIMD3(o.x, ground + height, o.z - 40)
                let f = PathFrame(c, caves ? fwd : SIMD3<Float>(0, 0, -1))
                let obstacle = make(f)
                g.scene.rootNode.addChildNode(obstacle.node)
                var views: [(String, SIMD3<Float>)] = [("side", c + SIMD3<Float>(55, 8, 30)), ("low", c + SIMD3<Float>(-20, -12, 60))]
                if caves {
                    let back1: SIMD3<Float> = c - fwd * 26 + SIMD3<Float>(0, 1, 0)
                    let back2: SIMD3<Float> = c - fwd * 16 + f.side * 3 - SIMD3<Float>(0, 2, 0)
                    views = [("side", back1), ("low", back2)]
                }
                for (view, cam) in views {
                    for _ in 0..<20 {
                        g.update(time: t)
                        obstacle.update(time: Float(t))
                        g.terrain.update(center: c, synchronous: true)
                        g.cameraNode.simdPosition = cam
                        g.cameraNode.simdLook(at: c + SIMD3(0, caves ? 1 : 4, 0), up: kUp, localFront: SIMD3(0, 0, -1))
                        g.cameraNode.camera?.fieldOfView = 55
                        t += 1.0 / 30
                    }
                    let img = r.snapshot(atTime: t, with: CGSize(width: 960, height: 600), antialiasingMode: .multisampling4X)
                    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(world.rawValue)-\(name)-\(view).png"))
                    }
                }
                obstacle.node.removeFromParentNode()
            }
        }
    }
}

enum SoakTest {
    /// `--soak-test [seconds]`: a long 5-bot fight with everyone dressed up (trails on), rendered offscreen, printing
    /// memory now and then. Memory that keeps climbing means something leaks.
    static func run(seconds: Double) {
        func residentMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        }
        let bots = BotSettings.count
        BotSettings.count = 5
        defer { BotSettings.count = bots }
        let sp = Catalog.species("phoenix")
        let g = Game(controls: SharedControls(), world: .meadow, mode: .pvp, species: sp, points: sp.base,
                     outfit: Outfit(code: "h=crown,e=visor,n=rainbowscarf,t=stardust,p=galaxy"), terrainRadius: 4)
        g.synchronousTerrain = true
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = g.scene
        r.pointOfView = g.cameraNode
        var phase: Float = 0
        g.debugSteer = { g in
            guard let b = g.bots.filter({ $0.fighter.alive }).min(by: { simd_distance($0.flight.pos, g.flight.pos) < simd_distance($1.flight.pos, g.flight.pos) })
            else { return nil }
            return steerToward(g, b.flight.pos, phase: &phase, dt: 1.0 / 60)
        }
        let trails = ["rainbow", "fire", "neon", "confetti", "smoke", "hearts"]
        var t = 0.0, nextPrint = 0.0, round = 0
        var dressed = false
        while t < seconds {
            RunLoop.main.run(until: Date())
            if !dressed && !g.bots.isEmpty {
                for (i, b) in g.bots.enumerated() {
                    b.avatar.setLook(species: b.avatar.speciesId, outfit: "h=tophat,e=aviators,n=scarf,t=\(trails[i % trails.count]),p=chrome")
                }
                dressed = true
            }
            g.keys.attack = true
            g.fighter.shield = 99; g.fighter.health = Fighter.maxHealth
            g.update(time: t)
            _ = r.snapshot(atTime: t, with: CGSize(width: 320, height: 200), antialiasingMode: .none)
            // A new round whenever this one ends, so knock-outs, respawns and fresh bots all get exercised.
            if g.phase == .done { round += 1; dressed = false; g.enqueue { $0.restartMatch() } }
            if t >= nextPrint {
                print(String(format: "t=%4.0f s  memory %.0f MB  bots %d  projectiles %d  round %d", t, residentMB(), g.bots.count,
                             g.combat.activeCount, round))
                fflush(stdout)
                nextPrint += 30
            }
            t += 1.0 / 60
        }
    }
}

enum RenderPathTest {
    /// `--render-path-test <dir>`: draws the same frame through SceneKit's own snapshot and through the uncapped
    /// V-Sync-off path (SCNRenderer into Metal textures), saves both, and checks the per-frame update still runs.
    final class Counter: NSObject, SCNSceneRendererDelegate {
        var updates = 0
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) { updates += 1 }
    }

    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), options: nil)
        print("SCNView colorPixelFormat \(view.colorPixelFormat.rawValue) depth \(view.depthPixelFormat.rawValue) layer \(type(of: view.layer as Any))")
        if let ml = view.layer as? CAMetalLayer { print("  layer pixelFormat \(ml.pixelFormat.rawValue) colorspace \(String(describing: ml.colorspace?.name))") }
        let g = Game(controls: SharedControls(), world: .meadow, terrainRadius: 4)
        g.synchronousTerrain = true
        for k in 0..<90 { g.update(time: Double(k) / 60) }
        let device = MTLCreateSystemDefaultDevice()!
        let size = CGSize(width: 960, height: 600)
        let ref = SCNRenderer(device: device, options: nil)
        ref.scene = g.scene; ref.pointOfView = g.cameraNode
        save(ref.snapshot(atTime: 1.5, with: size, antialiasingMode: .multisampling4X), "\(dir)/reference.png")
        for format in [MTLPixelFormat.bgra8Unorm, .bgra8Unorm_srgb] {
            let r = SCNRenderer(device: device, options: nil)
            let counter = Counter()
            r.delegate = counter
            r.scene = g.scene; r.pointOfView = g.cameraNode
            guard let img = MetalFrame.render(r, device: device, size: size, format: format, samples: 4, times: 5) else { print("render failed"); continue }
            save(img, "\(dir)/metal-\(format == .bgra8Unorm ? "unorm" : "srgb").png")
            print("format \(format.rawValue): delegate updates \(counter.updates) for 5 frames")
        }
    }

    static func save(_ img: NSImage, _ path: String) {
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Renders frames with an SCNRenderer into Metal textures and reads the last one back (for tests).
enum MetalFrame {
    static func render(_ r: SCNRenderer, device: MTLDevice, size: CGSize, format: MTLPixelFormat, samples: Int, times: Int) -> NSImage? {
        let w = Int(size.width), h = Int(size.height)
        func texture(_ f: MTLPixelFormat, _ n: Int, _ usage: MTLTextureUsage, _ mode: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.textureType = n > 1 ? .type2DMultisample : .type2D
            d.sampleCount = n
            d.usage = usage
            d.storageMode = mode
            return device.makeTexture(descriptor: d)
        }
        guard let queue = device.makeCommandQueue(),
              let msaa = texture(format, samples, .renderTarget, .private),
              let resolved = texture(format, 1, [.renderTarget, .shaderRead], .private),
              let depth = texture(.depth32Float, samples, .renderTarget, .private),
              let readback = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = r.usesReverseZ ? 0 : 1
        var last: MTLCommandBuffer?
        for k in 0..<times {
            guard let cb = queue.makeCommandBuffer() else { return nil }
            r.render(atTime: 1.5 + Double(k) / 60, viewport: CGRect(origin: .zero, size: size), commandBuffer: cb, passDescriptor: pass)
            if k == times - 1, let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                          destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
                blit.endEncoding()
            }
            cb.commit()
            last = cb
        }
        last?.waitUntilCompleted()
        // BGRA bytes → image.
        let data = Data(bytes: readback.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

/// How fast this Mac can draw a scene with nothing holding it back: renders it offscreen, back to back, at a given size
/// and antialiasing, and counts frames (the GPU included). Run it off the main thread while nothing else draws the scene.
enum FrameRateTest {
    static func run(scene: SCNScene, camera: SCNNode, device: MTLDevice, size: CGSize, samples: Int, seconds: Double) -> Double? {
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = camera
        guard let queue = device.makeCommandQueue() else { return nil }
        let w = Int(size.width), h = Int(size.height)
        func texture(_ format: MTLPixelFormat, samples n: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.textureType = n > 1 ? .type2DMultisample : .type2D
            d.sampleCount = n
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let color = texture(.bgra8Unorm, samples: samples), let depth = texture(.depth32Float, samples: samples) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        if samples > 1 {
            guard let resolved = texture(.bgra8Unorm, samples: 1) else { return nil }
            pass.colorAttachments[0].resolveTexture = resolved
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = r.usesReverseZ ? 0 : 1
        let viewport = CGRect(origin: .zero, size: size)
        var t = 0.0
        func frame() -> MTLCommandBuffer? {
            guard let cb = queue.makeCommandBuffer() else { return nil }
            r.render(atTime: t, viewport: viewport, commandBuffer: cb, passDescriptor: pass)
            cb.commit()
            t += 1.0 / 60
            return cb
        }
        // Warm up first (shaders compile on the first frames).
        for _ in 0..<15 { frame()?.waitUntilCompleted() }
        let start = CACurrentMediaTime()
        var frames = 0
        var inFlight: [MTLCommandBuffer] = []
        while CACurrentMediaTime() - start < seconds {
            guard let cb = frame() else { return nil }
            inFlight.append(cb)
            if inFlight.count >= 3 { inFlight.removeFirst().waitUntilCompleted() }
            frames += 1
        }
        inFlight.forEach { $0.waitUntilCompleted() }
        return Double(frames) / (CACurrentMediaTime() - start)
    }
}

enum UncappedTest {
    /// `--uncapped-test`: runs the V-Sync-off renderer (offscreen) and checks it goes past 60 fps, drops to 60 when
    /// paced (menu open), sleeps when hidden, and stops cleanly.
    final class Counter: NSObject, SCNSceneRendererDelegate {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) { lock.lock(); n += 1; lock.unlock() }
    }

    static func run() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        let g = Game(controls: SharedControls(), world: .meadow, terrainRadius: 4)
        g.synchronousTerrain = true
        for k in 0..<60 { g.update(time: Double(k) / 60) }
        let counter = Counter()
        guard let device = MTLCreateSystemDefaultDevice(),
              let u = UncappedView(device: device, delegate: counter, clock: { CACurrentMediaTime() }) else { print("FAIL  couldn't make the renderer"); exit(1) }
        u.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        u.set(scene: g.scene, camera: g.cameraNode)
        u.set(samples: 4)
        func measure(_ seconds: Double) -> Double {
            let a = counter.count, t0 = CACurrentMediaTime()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            return Double(counter.count - a) / (CACurrentMediaTime() - t0)
        }
        u.start()
        _ = measure(1)   // warm up (shaders)
        let free = measure(3)
        check(free > 70, String(format: "uncapped: %.0f fps at 2880x1800 with 4x MSAA", free))
        u.set(visible: true, paced: true)
        let paced = measure(2)
        check(paced > 50 && paced < 66, String(format: "menu open: paced to %.0f fps", paced))
        u.set(visible: false, paced: false)
        _ = measure(0.2)
        let hidden = measure(1)
        check(hidden < 1, String(format: "hidden window: %.0f fps (sleeping)", hidden))
        u.set(visible: true, paced: false)
        _ = measure(0.5)
        let t0 = CACurrentMediaTime()
        u.stop()
        check(CACurrentMediaTime() - t0 < 0.5, String(format: "stops in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        let after = counter.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(counter.count == after, "no frames after stopping")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
}
