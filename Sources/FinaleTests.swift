import SceneKit
import AppKit
import simd

/// Headless checks for 1.0: The Finale's cutscene (frames saved to look at), the jetpack, the clap, the goals that
/// open The Finale.
enum FinaleTests {
    private static func check(_ ok: Bool, _ what: String, _ failures: inout Int) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(what)")
    }

    /// `--finale-test <dir>`: play the whole cutscene offscreen, saving frames at its big moments.
    static func cutscene(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failures = 0
        let sp = Catalog.species(ProcessInfo.processInfo.environment["FINALE_BIRD"] ?? "phoenix")
        let g = Game(controls: SharedControls(), world: .finale, species: sp, points: sp.base, outfit: Outfit(code: "t=stardust"), terrainRadius: 4)
        g.synchronousTerrain = true
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = g.scene
        r.pointOfView = g.cameraNode
        var crowned = false, given = false, done = false
        g.onCrowned = { crowned = true; g.setSpecies(sp, points: sp.base, outfit: Outfit(code: "h=skycrown,t=stardust")) }
        g.onJetpackGiven = { given = true }
        g.onCutsceneDone = { done = true }
        // FINALE_WAV=<file>: also record what it sounds like (offline, nothing plays) and print a loudness table.
        let wavPath = ProcessInfo.processInfo.environment["FINALE_WAV"]
        let sr: Float = 48000
        let audio = wavPath == nil ? nil : SoundEngine(offline: sr)
        g.sound = audio
        var outL: [Float] = [], outR: [Float] = []
        let frameN = Int(sr / 60)
        var bufL = [Float](repeating: 0, count: frameN), bufR = [Float](repeating: 0, count: frameN)
        func record() {
            guard let audio else { return }
            bufL.withUnsafeMutableBufferPointer { l in bufR.withUnsafeMutableBufferPointer { r in audio.synth.render(l.baseAddress!, r.baseAddress!, frameN) } }
            outL += bufL; outR += bufR
        }
        var t = 0.0
        for _ in 0..<30 { g.update(time: t); t += 1.0 / 60 }
        g.startFinaleCutscene()
        let shots: [Float] = ProcessInfo.processInfo.environment["FINALE_SHOTS"].map { $0.split(separator: ",").compactMap { Float($0) } }
            ?? [3, 9, 12, 16, 22, 25, 28.5, 32.6, 34.6, 36.4, 40.8, 43.2, 44.6, 47.4, 49.6, 52.5, 55.2]
        var next = 0
        var captions: [String] = []
        var worst = 0.0
        while !done && t < 80 {
            let s0 = CACurrentMediaTime()
            g.update(time: t)
            worst = max(worst, CACurrentMediaTime() - s0)
            record()
            // Render every frame (small) so particles run as on screen.
            _ = r.snapshot(atTime: t, with: CGSize(width: 160, height: 100), antialiasingMode: .none)
            if let o = g.cutsceneOverlay, !o.caption.isEmpty, captions.last != o.caption { captions.append(o.caption) }
            if let cs = g.cutscene, next < shots.count, cs.t >= shots[next] {
                let img = r.snapshot(atTime: t, with: CGSize(width: 1280, height: 720), antialiasingMode: .multisampling4X)
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: String(format: "%@/finale-%04.1f.png", dir, shots[next])))
                }
                print(String(format: "  frame at %.1f s: %@", shots[next], g.cutsceneOverlay?.caption ?? ""))
                next += 1
            }
            t += 1.0 / 60
            RunLoop.main.run(until: Date())
        }
        for _ in 0..<5 { g.update(time: t); t += 1.0 / 60; RunLoop.main.run(until: Date()) }
        if let wavPath, !outL.isEmpty {
            AudioTest.writeWAV(outL, outR, sr: sr, path: wavPath)
            var nan = 0
            print("  sec   peak   rms dB  >0.9")
            var k = 0
            while k < outL.count {
                let e = min(outL.count, k + Int(sr))
                var peak: Float = 0, sum: Float = 0, hot = 0
                for j in k..<e {
                    let v = max(abs(outL[j]), abs(outR[j]))
                    if !v.isFinite { nan += 1; continue }
                    peak = max(peak, v); sum += outL[j] * outL[j]; if v > 0.9 { hot += 1 }
                }
                print(String(format: "  %3d  %5.2f  %6.1f  %4d", k / Int(sr), peak, 10 * log10(max(sum / Float(e - k), 1e-12)), hot))
                k = e
            }
            check(nan == 0, "no broken (NaN) samples", &failures)
        }
        print("captions: " + captions.joined(separator: " | "))
        check(crowned, "the crowning happened", &failures)
        check(given, "the jetpack was given", &failures)
        check(done, String(format: "the cutscene finished (after %.0f s)", t), &failures)
        check(g.cutscene == nil && g.jetEquipped, "back to flying, the jetpack on", &failures)
        check(g.flight.pos.y > FinaleLayout.ground + 60, String(format: "the bird left through the roof (now %.0f m up)", g.flight.pos.y), &failures)
        check(g.bird.hasJetpack, "the bird is wearing the jetpack", &failures)
        check(worst < 1.5, String(format: "no frame stalled (worst %.0f ms, terrain built in-line)", worst * 1000), &failures)
        print(failures == 0 ? "finale-test: all passed" : "finale-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--jetpack-test`: burn it for a long time: speed keeps climbing, nothing breaks, it still steers, letting go coasts.
    static func jetpack() {
        var failures = 0
        let sp = Catalog.species("gull")
        let g = Game(controls: SharedControls(), world: .meadow, species: sp, points: sp.base, terrainRadius: 3)
        g.synchronousTerrain = false
        g.jetEquipped = true
        var t = 0.0
        var notices: [String] = []
        g.onNotice = { notices.append($0) }
        var turning = false
        g.debugSteer = { g in
            var i = FlightInput()
            i.pitch = clamp(-g.flight.pitch * 2 + 0.05, -1, 1)
            i.roll = turning ? 0.8 : 0
            return i
        }
        for _ in 0..<30 { g.update(time: t); t += 1.0 / 60 }
        g.toggleJet()
        var speeds: [Float] = []
        var maxSpeed: Float = 0
        var finite = true
        let burn = 45.0
        let start = t
        var yawBefore: Float = 0
        while t < start + burn {
            if t > start + 30 && !turning { turning = true; yawBefore = g.flight.yaw }
            g.update(time: t)
            t += 1.0 / 60
            maxSpeed = max(maxSpeed, g.flight.speed)
            if !g.flight.pos.x.isFinite || !g.flight.speed.isFinite { finite = false }
            if Int((t - start) * 60) % 600 == 0 && !turning { speeds.append(g.flight.speed) }
            if Int(t * 60) % 30 == 0 { RunLoop.main.run(until: Date()) }
        }
        let yawChange = abs(g.flight.yaw - yawBefore)
        print("speeds every 10 s: " + speeds.map { String(format: "%.0f", $0) }.joined(separator: ", ") + String(format: " m/s; top %.0f m/s (Mach %.0f)", maxSpeed, maxSpeed / 343))
        check(finite, "the numbers never ran away", &failures)
        check(maxSpeed > 5000, String(format: "no top speed: %.0f m/s after 30 s of burning", maxSpeed), &failures)
        check(speeds.count >= 3 && zip(speeds, speeds.dropFirst()).allSatisfy { $1 > $0 }, "still accelerating at the end", &failures)
        check(yawChange > 0.5, String(format: "still steers flat out (turned %.2f rad in 15 s)", yawChange), &failures)
        check(notices.contains("Sound barrier broken!"), "the sound barrier announced", &failures)
        // Let it go out: the speed bleeds off over a few seconds (not in one frame).
        turning = false
        let before = g.flight.speed
        g.toggleJet()
        g.update(time: t); t += 1.0 / 60
        let oneFrame = g.flight.speed
        for _ in 0..<60 { g.update(time: t); t += 1.0 / 60 }
        let oneSecond = g.flight.speed
        for _ in 0..<(60 * 8) { g.update(time: t); t += 1.0 / 60; if Int(t * 60) % 30 == 0 { RunLoop.main.run(until: Date()) } }
        let later = g.flight.speed
        print(String(format: "after letting go: %.0f → %.0f (1 frame) → %.0f (1 s) → %.0f m/s (9 s)", before, oneFrame, oneSecond, later))
        check(oneFrame > before * 0.9, "no sudden stop when it goes out", &failures)
        check(oneSecond > 300, "coasting for a moment", &failures)
        check(later < 200, "the air catches up after the coast", &failures)
        check(notices.contains { $0.contains("round the world") } || simd_length(SIMD2(g.flight.pos.x, g.flight.pos.z)) < 400_000,
              "far away it wraps round the world instead of breaking", &failures)
        print(failures == 0 ? "jetpack-test: all passed" : "jetpack-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--clap-test`: a made-up person: arms out (calibrates), flapping (no claps), two claps, arms tucked (no clap).
    static func clap() {
        var failures = 0
        let ai = ArmInterpreter()
        var t = 0.0
        func pose(_ wl: SIMD2<Float>, _ wr: SIMD2<Float>, _ el: SIMD2<Float>, _ er: SIMD2<Float>) -> RawPose {
            var p = RawPose(time: t, aspect: 1.78)
            p[.lShoulder] = SIMD3(0.58, 0.62, 0.9); p[.rShoulder] = SIMD3(0.42, 0.62, 0.9)
            p[.lElbow] = SIMD3(el.x, el.y, 0.9); p[.rElbow] = SIMD3(er.x, er.y, 0.9)
            p[.lWrist] = SIMD3(wl.x, wl.y, 0.9); p[.rWrist] = SIMD3(wr.x, wr.y, 0.9)
            p[.neck] = SIMD3(0.5, 0.64, 0.9); p[.nose] = SIMD3(0.5, 0.74, 0.9)
            p[.lHip] = SIMD3(0.55, 0.32, 0.9); p[.rHip] = SIMD3(0.45, 0.32, 0.9)
            return p
        }
        var s = ControlState()
        func run(_ seconds: Double, _ make: (Double) -> RawPose) {
            let end = t + seconds
            while t < end { s = ai.process(make(t), time: t); t += 1.0 / 30 }
        }
        let wingsOut = { (_: Double) in pose(SIMD2(0.82, 0.62), SIMD2(0.18, 0.62), SIMD2(0.7, 0.62), SIMD2(0.3, 0.62)) }
        run(1.6, wingsOut)
        check(s.calibrated, "holding the arms out calibrates", &failures)
        // Flapping hard for two seconds.
        run(2.0) { tt in
            let a = Float(sin(tt * 2 * .pi * 1.6)) * 0.35
            return pose(SIMD2(0.82, 0.62 + a), SIMD2(0.18, 0.62 + a), SIMD2(0.7, 0.62 + a * 0.5), SIMD2(0.3, 0.62 + a * 0.5))
        }
        check(s.clapCount == 0, "flapping is never a clap (\(s.clapCount))", &failures)
        let together = { (_: Double) in pose(SIMD2(0.51, 0.55), SIMD2(0.49, 0.55), SIMD2(0.6, 0.52), SIMD2(0.4, 0.52)) }
        let apart = { (_: Double) in pose(SIMD2(0.75, 0.5), SIMD2(0.25, 0.5), SIMD2(0.66, 0.55), SIMD2(0.34, 0.55)) }
        run(0.4, apart); run(0.35, together)
        check(s.clapCount == 1, "a clap counts once (\(s.clapCount))", &failures)
        run(0.6, together)
        check(s.clapCount == 1, "holding the hands together doesn't count again", &failures)
        run(0.5, apart); run(0.35, together)
        check(s.clapCount == 2, "a second clap counts (\(s.clapCount))", &failures)
        run(0.5, apart)
        run(1.0) { _ in pose(SIMD2(0.62, 0.3), SIMD2(0.38, 0.3), SIMD2(0.61, 0.45), SIMD2(0.39, 0.45)) }
        check(s.clapCount == 2, "arms tucked to dive aren't a clap", &failures)
        print(failures == 0 ? "clap-test: all passed" : "clap-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--finale-goals-test`: The Finale opens when every goal but the bonus one is done, and not before.
    static func goals() {
        var failures = 0
        let key = "progress.finale-test"
        UserDefaults.standard.removeObject(forKey: key)
        let p = Progress(key: key)
        let finale = WorldCatalog.info("finale")
        check(!p.finaleUnlocked && !p.ownsWorld(finale), "locked at the start", &failures)
        check(!p.buyWorld(finale), "can't be bought", &failures)
        check(GoalCatalog.required.count == GoalCatalog.all.count - 1, "one bonus goal (\(GoalCatalog.all.filter(\.bonus).map(\.id)))", &failures)
        p.debugCompleteGoals(GoalCatalog.required.dropLast().map(\.id))
        check(!p.finaleUnlocked, "one goal short: still locked", &failures)
        p.debugCompleteGoals([GoalCatalog.required.last!.id])
        check(p.finaleUnlocked && p.ownsWorld(finale), "every goal done: open (without the LAN bonus)", &failures)
        check(!p.finaleSeen && !p.jetpackOwned, "nothing given before the end", &failures)
        p.awardCrown()
        p.finishFinale()
        check(p.finaleSeen && p.jetpackOwned && p.outfit.hat == "skycrown", "the end gives the jetpack and the crown", &failures)
        check(GoalCatalog.raceCourses == 14, "gold everywhere means 14 courses", &failures)
        // The cheat code opens it without touching the goals, and it stays open after a restart.
        UserDefaults.standard.removeObject(forKey: key)
        let c = Progress(key: key)
        c.debugCompleteGoals(["tutorial"])
        c.openFinaleByCode()
        check(c.finaleUnlocked && c.ownsWorld(finale) && c.goalsDoneCount == 1, "the cheat code opens it, goals left alone", &failures)
        check(Progress(key: key).finaleUnlocked, "…and it stays open after a restart", &failures)
        c.resetAll()
        check(!c.finaleUnlocked, "a reset closes it again", &failures)
        UserDefaults.standard.removeObject(forKey: key)
        print(failures == 0 ? "finale-goals-test: all passed" : "finale-goals-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
