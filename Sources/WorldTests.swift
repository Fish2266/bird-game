import SceneKit
import simd

/// Headless checks for the 0.4 worlds.
enum WorldTests {
    /// `--subway-test`: fly down a station's stairs, along the platform and into the tunnel; check the bird gets in,
    /// stays inside, the light fades, the camera never ends up in the rock and the subway pays out.
    static func subway() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        let g = Game(controls: SharedControls(), world: .city, terrainRadius: 3)
        g.synchronousTerrain = true
        var rewards: [WorldReward] = []
        g.onReward = { rewards.append($0) }
        let sp = g.spawn.0
        guard let seg = CitySubway.segments(near: sp.x, sp.z, radius: 3000).filter({ $0.station })
            .min(by: { simd_distance($0.world(60, 0, 0), sp) < simd_distance($1.world(60, 0, 0), sp) }) else {
            print("FAIL  no station near the spawn"); exit(1)
        }
        let st = CitySubway.stairs(seg).first { $0.dir > 0 && $0.l > 0 }!
        let f = seg.floor(60)
        // Waypoints: line up over the opening, down the stairs, along the platform, out over the tracks into the tunnel.
        let back = -seg.axis * st.dir
        let approach = st.top + back * 30 + SIMD3(0, 10, 0)
        let ways: [SIMD3<Float>] = [
            st.top + back * 6 + SIMD3(0, 2.5, 0),
            st.top + seg.axis * st.dir * 4 - SIMD3(0, 1.0, 0),
            st.bottom + SIMD3(0, 2.2, 0) - seg.axis * st.dir * 2,
            seg.world(55, 8.0, f + CitySubway.platformY + 2.6),
            seg.world(75, 1.5, f + 5.8),
            seg.world(150, 0, seg.floor(110) + 5.8),
            seg.world(200, 0, seg.floor(119) + 5.8),
        ]
        g.place(at: approach, yaw: atan2(-st.dir * seg.axis.x, -st.dir * seg.axis.z), speed: 13)
        var wp = 0
        var t = 0.0
        var deepest: Float = 0
        var maxUnder: Float = 0
        var outside = 0
        var camInRock = 0
        var phase: Float = 0
        var log: [String] = []
        g.debugSteer = { g in
            guard wp < ways.count else { return FlightInput() }
            let target = ways[wp]
            if simd_distance(target, g.flight.pos) < (wp < 3 ? 2.5 : 6) { wp += 1 }
            var i = FlightInput()
            let (d, bearing, above) = g.pointer(to: target)
            i.roll = clamp(bearing * 3, -1, 1)
            let want = atan2(above, max(d, 1))
            i.pitch = clamp((want - g.flight.pitch) * 3.5, -1, 1)
            phase += 1.0 / 60 * 2 * .pi * 1.7
            if g.flight.speed < 11 && above > -2 { let down: Float = cos(phase) < 0 ? 0.9 : 0; i.flapL = down; i.flapR = down }
            if g.flight.speed > 17 { i.pitch = max(i.pitch, -0.2) }
            return i
        }
        while t < 40 && wp < ways.count {
            g.update(time: t)
            t += 1.0 / 60
            let p = g.flight.pos
            let surface = CityLayout.ground(p.x, p.z)
            deepest = max(deepest, surface - p.y)
            maxUnder = max(maxUnder, g.runtime?.underground ?? 0)
            if surface - p.y > 1 && !CitySubway.inside(p, shrink: 0.3) { outside += 1 }
            let cam = g.cameraPosition
            if cam.y < CityLayout.ground(cam.x, cam.z) - 0.3 && !CitySubway.inside(cam, shrink: 0) { camInRock += 1 }
            if Int(t * 60) % 60 == 0 || (ProcessInfo.processInfo.environment["SUBWAY_TRACE"] != nil && Int(t * 60) % 3 == 0 && t > 1.6 && t < 3.2) {
                let (ss, ll) = seg.local(p)
                log.append(String(format: "t=%4.1f wp %d  depth %5.1f  speed %4.1f  under %.2f  s %.1f l %.1f  ground %.2f (y %.2f) pitch %.2f", t, wp, surface - p.y, g.flight.speed,
                                  g.runtime?.underground ?? 0, ss, ll, TerrainShape.collisionGround(p.x, p.z, p.y) - surface, p.y - surface, g.flight.pitch))
            }
            RunLoop.main.run(until: Date())
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        log.forEach { print("   " + $0) }
        check(deepest > 8, String(format: "got down into the subway (deepest %.1f m under the street)", deepest))
        check(wp >= ways.count - 1, "flew stairs → platform → tunnel (reached waypoint \(wp) of \(ways.count))")
        check(outside < 10, "stayed inside the tunnels (\(outside) frames outside)")
        check(camInRock < 10, "camera stayed out of the rock (\(camInRock) frames)")
        check(maxUnder > 0.9, String(format: "light faded underground (%.2f)", maxUnder))
        check(rewards.contains { $0.id == "city.subway" }, "found-the-subway reward")
        print("rewards: " + rewards.map { "\($0.title) +\($0.coins)" }.joined(separator: ", "))
        // Holes in the ground where the stairs are, and only there.
        check(CitySubway.isHole(st.top.x + seg.axis.x * st.dir * 4, st.top.z + seg.axis.z * st.dir * 4), "stair opening is cut out of the street")
        check(!CitySubway.isHole(st.top.x - seg.axis.x * st.dir * 4, st.top.z - seg.axis.z * st.dir * 4), "street before the opening is solid")
        // The floor under a point in the tunnel is the tunnel floor; above the street it's the street.
        let inTunnel = seg.world(110, 0, seg.floor(110) + 3)
        check(abs((TerrainShape.collisionHeight(inTunnel.x, inTunnel.z, inTunnel.y)) - seg.floor(110)) < 0.6, "tunnel floor under a point in the tunnel")
        let high = seg.world(110, 0, CityLayout.ground(inTunnel.x, inTunnel.z) + 20)
        check(abs(TerrainShape.collisionHeight(high.x, high.z, high.y) - CityLayout.ground(high.x, high.z)) < 0.01, "street under a point above it")
        // In from the river: line up with a tunnel mouth over the water and fly straight in.
        var portal: (CitySubway.Segment, Float, Float)?
        for seg in CitySubway.segments(near: sp.x, sp.z, radius: 4000) {
            for stub in seg.stubs where stub.portal0 || stub.portal1 {
                let at = stub.portal1 ? stub.s1 : stub.s0
                if portal == nil || simd_distance(seg.world(at, 0, 0), sp) < simd_distance(portal!.0.world(portal!.1, 0, 0), sp) {
                    portal = (seg, at, stub.portal1 ? 1 : -1)
                }
            }
        }
        if let (seg, at, out) = portal {
            let f = seg.floor(at)
            let start = seg.world(at + out * 70, 0, f + 4.2)
            let inward = seg.axis * -out
            g.place(at: start, yaw: atan2(-inward.x, -inward.z), speed: 16)
            g.debugSteer = { g in
                var i = FlightInput()
                let target = seg.world(at - out * 80, 0, seg.floor(at - out * 60) + 3.8)
                let (d, bearing, above) = g.pointer(to: target)
                i.roll = clamp(bearing * 3, -1, 1)
                i.pitch = clamp((atan2(above, max(d, 1)) - g.flight.pitch) * 3.5, -1, 1)
                if g.flight.speed < 13 { let down: Float = Int(t * 3.4) % 2 == 0 ? 0.9 : 0; i.flapL = down; i.flapR = down }
                return i
            }
            var deepest: Float = 0, outsidePortal = 0
            let t0 = t
            while t < t0 + 13 {
                g.update(time: t)
                t += 1.0 / 60
                let (sNow, _) = seg.local(g.flight.pos)
                deepest = max(deepest, (sNow - at) * -out)
                let p = g.flight.pos
                if p.y < CityLayout.ground(p.x, p.z) - 1 && !CitySubway.inside(p, shrink: 0.3) { outsidePortal += 1 }
                if ProcessInfo.processInfo.environment["SUBWAY_TRACE"] != nil && Int((t - t0) * 60) % 30 == 0 {
                    let (ss, ll) = seg.local(p)
                    print(String(format: "   river t=%4.1f  in %5.1f  l %5.1f  above floor %4.1f  speed %4.1f  stubs %@", t - t0, (ss - at) * -out, ll,
                                 p.y - seg.floor(ss), g.flight.speed, seg.stubs.map { "\($0.s0)…\($0.s1)" }.joined(separator: " ")))
                }
                RunLoop.main.run(until: Date())
            }
            check(deepest > 60, String(format: "flew in from the river through a tunnel mouth (%.0f m in)", deepest))
            check(outsidePortal < 10, "stayed inside from the river (\(outsidePortal) frames outside)")
        } else {
            check(false, "a tunnel mouth on the river within 4 km")
        }
        print(failures == 0 ? "subway-test: all passed" : "subway-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--dino-test`: let Dino Valley run for a while with the bird on autopilot; check the herds spawn and stay on
    /// their feet, the director stages hunts and fights, notices and rewards come through, and it's all cheap enough.
    static func dino() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        let g = Game(controls: SharedControls(), world: .dino, terrainRadius: 3)
        g.synchronousTerrain = true
        guard let rt = g.runtime as? DinoRuntime else { print("FAIL  no dino runtime"); exit(1) }
        var t = 0.0
        var notices: [String] = []
        var rewards: [String] = []
        var hits = 0
        g.onNotice = { n in notices.append(String(format: "%5.1f  %@", t, n)) }
        g.onReward = { r in rewards.append(r.title) }
        g.onHit = { _ in hits += 1 }
        let minutes = Double(ProcessInfo.processInfo.environment["DINO_MINUTES"] ?? "6") ?? 6
        var fightIDs = Set<ObjectIdentifier>()
        var kindsInFights = Set<String>()
        var maxDinos = 0, frames = 0, offGround = 0, inWater = 0, nan = 0
        var simTotal = 0.0, simWorst = 0.0
        print("spawn \(g.spawn.0) yaw \(g.spawn.1)")
        while t < minutes * 60 {
            let s0 = CACurrentMediaTime()
            g.update(time: t)
            let e = CACurrentMediaTime() - s0
            simTotal += e; simWorst = max(simWorst, frames > 120 ? e : 0)
            frames += 1
            t += 1.0 / 60
            let life = rt.life
            maxDinos = max(maxDinos, life.dinos.count)
            for f in life.fights where !fightIDs.contains(ObjectIdentifier(f)) {
                fightIDs.insert(ObjectIdentifier(f))
                kindsInFights.insert(f.title)
            }
            if frames % 30 == 0 {
                for d in life.dinos {
                    if !d.pos.x.isFinite || !d.rootY.isFinite { nan += 1; continue }
                    let lift = d.rootY - d.ground - d.hop
                    if abs(lift - d.sp.hip * d.scale) > d.sp.hip * d.scale * 0.45 + 0.6 && d.motion.rear < 0.1 { offGround += 1 }
                    if d.ground < (d.kind == .longneck ? -4.5 : -1.5) {
                        inWater += 1
                        if inWater < 6 { print("   in water: \(d.kind.name) ground \(d.ground) mind \(d.mind) at \(d.pos) home \(d.home) hop \(d.hop)") }
                    }
                }
            }
            if frames % 1800 == 0 {
                var counts: [String: Int] = [:]
                for d in life.dinos { counts[d.kind.name, default: 0] += 1 }
                let near = life.dinos.filter { $0.distToPlayer < 600 }.count
                print(String(format: "t=%5.0f  dinos %3d (%d within 600 m)  fights %d  pteros %d  bird %.0f,%.0f,%.0f  ", t, life.dinos.count, near,
                             life.fights.count, life.pteros.birds.count, g.flight.pos.x, g.flight.pos.y, g.flight.pos.z)
                      + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            RunLoop.main.run(until: Date())
        }
        notices.prefix(40).forEach { print("   notice " + $0) }
        print("fights: " + kindsInFights.sorted().joined(separator: "; "))
        print("rewards: " + rewards.joined(separator: ", ") + "   hits taken: \(hits)")
        print(String(format: "frame %.2f ms avg, %.2f ms worst (terrain built in-line here); creatures %.2f ms avg, %.2f ms worst",
                     simTotal / Double(frames) * 1000, simWorst * 1000, DinoRuntime.lifeTime / Double(frames) * 1000, DinoRuntime.lifeWorst * 1000))
        check(maxDinos >= 15, "herds spawn around the bird (\(maxDinos) at most)")
        check(fightIDs.count >= Int(minutes / 2), "the director stages fights (\(fightIDs.count) in \(Int(minutes)) min)")
        check(notices.contains { $0.contains("Dino fight") }, "fight notices")
        check(nan == 0, "no runaway positions (\(nan))")
        check(offGround < 20, "dinosaurs stand on the ground (\(offGround) samples off)")
        check(inWater < 20, "and out of deep water (\(inWater) samples)")
        check(DinoRuntime.lifeTime / Double(frames) < 0.0015, "creatures are cheap (under 1.5 ms a frame on average)")
        // The volcano blows: hold the bird off its flank, set it off, and watch the bombs fly and land.
        let sp = g.spawn.0
        if let v = rt.terrain.nearestVolcano(sp.x, sp.z) {
            let c = SIMD3(v.x, rt.terrain.craterFloor(v), v.y)
            let away = simd_normalize(SIMD3(sp.x - v.x, 0, sp.z - v.y))
            let hold = c + away * (v.z * 0.4) + SIMD3(0, 40, 0)
            g.place(at: hold, yaw: 0, speed: 12)
            g.terrain.update(center: hold, synchronous: true)
            rt.eruption.debugErupt()
            var flying = 0, landed = 0, bombHits = 0, maxY: Float = 0, sawThreat = false
            let h0 = hits, t1 = t
            var ended = false
            while t < t1 + 26 {
                g.place(at: hold, yaw: 0, speed: 12)
                g.update(time: t)
                t += 1.0 / 60
                flying = max(flying, rt.eruption.bombs.filter { $0.state == 1 }.count)
                landed = max(landed, rt.eruption.bombs.filter { $0.state == 2 }.count)
                for b in rt.eruption.bombs where b.state == 1 { maxY = max(maxY, b.pos.y - c.y) }
                if rt.threat == "Lava bombs!" { sawThreat = true }
                if rt.eruption.left == 0 && t - t1 > 9.5 { ended = true }
                RunLoop.main.run(until: Date())
            }
            bombHits = hits - h0
            print(String(format: "eruption: %d bombs in the air at once, %d smouldering, highest %.0f m over the crater, %d hits on the bird", flying, landed, maxY, bombHits))
            check(flying >= 6, "the volcano throws lava bombs")
            check(landed >= 4, "they come down on the flanks and smoulder")
            check(maxY > 80, "high arcs")
            check(sawThreat, "a warning while they're flying")
            check(ended, "the eruption dies down")
            check(rewards.contains("You braved the eruption!") || bombHits > 0, "braving it pays (unless a bomb got you)")
            check(notices.contains { $0.contains("erupting") }, "an eruption notice")
        } else { check(false, "a volcano near the spawn") }
        print(failures == 0 ? "dino-test: all passed" : "dino-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The process's memory footprint (what Activity Monitor shows), MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// `--mem-test <world>`: load a world at its full view distance the way the game does, fly a little, render a
    /// frame, and report memory and how much geometry the loaded terrain holds.
    static func memory(_ w: WorldID) {
        let before = footprintMB()
        let g = Game(controls: SharedControls(), world: w)
        g.synchronousTerrain = true
        var t = 0.0
        for _ in 0..<240 { g.update(time: t); t += 1.0 / 60; RunLoop.main.run(until: Date()) }
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = g.scene
        r.pointOfView = g.cameraNode
        for _ in 0..<3 { _ = r.snapshot(atTime: t, with: CGSize(width: 960, height: 600), antialiasingMode: .none); t += 1.0 / 60 }
        var verts = 0, tris = 0, nodes = 0
        func count(_ geo: SCNGeometry?) {
            guard let geo else { return }
            verts += geo.sources(for: .vertex).first?.vectorCount ?? 0
            tris += geo.elements.reduce(0) { $0 + $1.primitiveCount }
        }
        var chunkCount = 0
        var byName: [String: Int] = [:]
        for c in g.terrain.root.childNodes {
            chunkCount += 1
            c.enumerateHierarchy { n, _ in
                nodes += 1
                let v0 = verts
                count(n.geometry)
                for lod in n.geometry?.levelsOfDetail ?? [] { count(lod.geometry) }
                byName[n === c ? "ground" : (n.name ?? "unnamed"), default: 0] += verts - v0
            }
        }
        for (k, v) in byName.sorted(by: { $0.value > $1.value }) { print(String(format: "   %-14@ %6.2fM vertices", k as NSString, Double(v) / 1e6)) }
        print("   (\(g.terrain.detailCount) chunks with close-up detail)")
        let after = footprintMB()
        print(String(format: "%@: %d chunks, %d nodes, %.2fM vertices, %.2fM triangles; footprint %.0f MB (world adds %.0f MB)",
                     w.rawValue, chunkCount, nodes, Double(verts) / 1e6, Double(tris) / 1e6, after, after - before))
        exit(0)
    }

    /// `--dust-test <dir>`: one dust burst on its own, filmed as it grows (particle sizes are easy to get wrong).
    static func dust(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let g = Game(controls: SharedControls(), world: .dino, terrainRadius: 2)
        g.synchronousTerrain = true
        guard let rt = g.runtime as? DinoRuntime else { exit(1) }
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = g.scene
        r.pointOfView = g.cameraNode
        var t = 0.0
        let p: SIMD3<Float> = g.flight.pos + SIMD3<Float>(0, -30, -60)
        let at = SIMD3(p.x, TerrainShape.ground(p.x, p.z), p.z)
        let cam: SIMD3<Float> = SIMD3<Float>(at.x, at.y + 7, at.z)
        for _ in 0..<30 { g.update(time: t); t += 1.0 / 60 }
        rt.debugBurst(cam + SIMD3<Float>(0, -4, -16), 1.1)
        for k in 0..<4 {
            for _ in 0..<30 {
                g.flight.reset(at: at + SIMD3<Float>(0, 300, 0), yaw: 0)
                g.update(time: t); t += 1.0 / 60
                g.cameraNode.simdPosition = cam
                g.cameraNode.simdLook(at: cam + SIMD3<Float>(0, -3, -20), up: kUp, localFront: SIMD3<Float>(0, 0, -1))
            }
            let img = r.snapshot(atTime: t, with: CGSize(width: 640, height: 400), antialiasingMode: .none)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/dust\(k).png"))
            }
        }
        exit(0)
    }

    /// `--west-test`: fly through a saloon (front door to back door), through an old mine, under a trestle; then let
    /// the West run with the bird on autopilot and check the train, the townsfolk and the cost.
    static func west() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL")  \(what)") }
        let g = Game(controls: SharedControls(), world: .west, terrainRadius: 3)
        g.synchronousTerrain = true
        guard let rt = g.runtime as? WestRuntime, let terrain = TerrainShape.active as? WestTerrain else { print("FAIL  no west runtime"); exit(1) }
        var t = 0.0
        var rewards: [String] = []
        var hits = 0
        g.onReward = { rewards.append($0.id) }
        g.onHit = { _ in hits += 1 }
        let sp = g.spawn.0
        /// Steer at a moving target point for a while; returns the furthest the bird got along `axis` past `from`.
        func fly(from start: SIMD3<Float>, to end: SIMD3<Float>, seconds: Double, speed: Float = 13) -> (Float, Int) {
            let axis = simd_normalize(SIMD3(end.x - start.x, 0, end.z - start.z))
            g.place(at: start, yaw: atan2(-axis.x, -axis.z), speed: speed)
            var furthest: Float = -1e9
            var rock = 0
            let t0 = t
            g.debugSteer = { g in
                var i = FlightInput()
                // Aim at the line from start to end, a little ahead of where we are.
                let along = simd_dot(g.flight.pos - start, axis)
                let aim = start + axis * (along + 14) + SIMD3(0, (end.y - start.y) * min(max((along + 14) / max(simd_distance(start, end), 1), 0), 1), 0)
                let (d, bearing, above) = g.pointer(to: aim)
                i.roll = clamp(bearing * 3, -1, 1)
                let wantPitch = atan2(above, max(d, 1)) + clamp(above * 0.15, -0.3, 0.3)
                i.pitch = clamp((wantPitch - g.flight.pitch) * 4, -1, 1)
                if g.flight.speed < speed - 1 && above > -1 { let down: Float = Int(t * 3.4) % 2 == 0 ? 0.9 : 0; i.flapL = down; i.flapR = down }
                return i
            }
            var frame = 0
            while t < t0 + seconds {
                g.update(time: t)
                t += 1.0 / 60
                frame += 1
                let p = g.flight.pos
                if ProcessInfo.processInfo.environment["WEST_TRACE"] != nil && frame % 12 == 0 {
                    print(String(format: "   t %4.1f along %6.1f  across %5.2f  y-start %5.2f  speed %4.1f", t - t0, simd_dot(p - start, axis),
                                 simd_dot(p - start, simd_normalize(simd_cross(axis, kUp))), p.y - start.y, g.flight.speed))
                }
                furthest = max(furthest, simd_dot(p - start, axis))
                if p.y < terrain.height(p.x, p.z) - 1 && WestMine.floorUnder(p, terrain) == nil { rock += 1 }
                RunLoop.main.run(until: Date())
            }
            g.debugSteer = nil
            return (furthest, rock)
        }
        // 1. The saloon.
        if let town = WestLayout.towns(near: SIMD2(sp.x, sp.z), radius: 2500).min(by: { simd_distance($0.center, SIMD2(sp.x, sp.z)) < simd_distance($1.center, SIMD2(sp.x, sp.z)) }),
           let s = WestTown.plan(town).saloon {
            let mid = (s.lo.x + s.hi.x) / 2
            let front = SIMD3(mid, s.lo.y + 2.0, s.frontZ), back = SIMD3(mid, s.lo.y + 2.0, s.facing > 0 ? s.lo.z : s.hi.z)
            let dir = simd_normalize(back - front)
            let (got, _) = fly(from: front - dir * 16, to: back + dir * 40, seconds: 8, speed: 11)
            let depth = simd_distance(front, back)
            check(got > 16 + depth + 8, String(format: "flew in the saloon's front door and out the back (%.0f m of %.0f)", got, 16 + depth + 8))
            check(rewards.contains("west.saloon"), "saloon reward")
        } else { check(false, "a saloon near the spawn") }
        // 2. The mine.
        var mine: WestMineTunnel?
        for r in 0..<10 where mine == nil {
            for dj in -r...r { for di in -r...r where max(abs(di), abs(dj)) == r && mine == nil {
                let bc = WestTerrain.butteCell
                mine = WestMine.tunnel(Int(floor(sp.x / bc)) + di, Int(floor(sp.z / bc)) + dj, terrain)
            } }
        }
        if let m = mine {
            g.terrain.update(center: m.mid, synchronous: true)
            var deepest: Float = 0
            let start = m.a - m.axis * 35 + SIMD3(0, 3.2, 0), end = m.b + m.axis * 35 + SIMD3(0, 3.2, 0)
            let (got, rock) = fly(from: start, to: end, seconds: 18, speed: 12)
            deepest = rt.underground
            check(got > m.length + 50, String(format: "flew through the old mine (%.0f m of %.0f)", got, m.length + 50))
            check(rock < 10, "stayed in the tunnel, not the rock (\(rock) frames)")
            check(rewards.contains("west.mine"), "mine reward")
            check(!rewards.contains("west.nugget"), "no gold for flying straight down the middle")
            // Again, hugging one wall low: the gold on that side.
            let off = m.side * 1.3 + SIMD3(0, 2.4 - 3.2, 0)
            _ = fly(from: start + off, to: end + off, seconds: 18, speed: 12)
            let nuggets = rewards.filter { $0 == "west.nugget" }.count
            check(nuggets >= 2, "picked up gold along the wall (\(nuggets) nuggets)")
            check(rewards.contains("west.gold"), "gold discovery")
            _ = deepest
        } else { check(false, "a mine within reach") }
        // 3. Under a trestle, across the line between two bents.
        var bent: WestRail.Bent?
        let (k0, _) = WestLayout.nearestLine(sp.z)
        for k in [k0, k0 + 1, k0 - 1] where bent == nil {
            var x = sp.x - 4000
            while x < sp.x + 4000 && bent == nil {
                bent = WestRail.bents(line: k, from: x, to: x + 300, terrain).first { $0.height > 40 }
                x += 300
            }
        }
        if let b = bent {
            let x = b.x + WestRail.bentSpacing / 2
            let y = b.ground + b.height * 0.5
            g.terrain.update(center: SIMD3(x, y, b.z), synchronous: true)
            let (got, _) = fly(from: SIMD3(x, y, b.z - 50), to: SIMD3(x, y, b.z + 50), seconds: 9, speed: 13)
            check(got > 85, String(format: "flew under the trestle between the bents (%.0f m)", got))
            check(rewards.contains("west.trestle"), "trestle reward")
        } else { check(false, "a tall trestle within reach") }
        // 4. Let it run.
        g.place(at: sp, yaw: g.spawn.1, speed: 15)
        var trainMoved: Float = 0, trainStopped = false, lastX: Float?, maxFolk = 0
        var lifeTime = 0.0, frames = 0
        let t0 = t
        while t < t0 + 120 {
            let s0 = CACurrentMediaTime()
            g.update(time: t)
            lifeTime += CACurrentMediaTime() - s0
            frames += 1
            t += 1.0 / 60
            if let tr = rt.life.train {
                if let lx = lastX, abs(tr.x - lx) < 5 { trainMoved += abs(tr.x - lx) }
                lastX = tr.x
                if tr.dwell > 0 { trainStopped = true }
            }
            RunLoop.main.run(until: Date())
            _ = maxFolk
        }
        print(String(format: "train ran %.0f m, stopped at a station: %@; frame %.2f ms avg (terrain built in-line)", trainMoved, trainStopped ? "yes" : "no",
                     lifeTime / Double(frames) * 1000))
        check(trainMoved > 600, "the train runs")
        // 5. A station stop: wait above a platform for a fresh train to pull in, stand, whistle and go.
        let (kl, _) = WestLayout.nearestLine(sp.z)
        if let town = WestLayout.towns(near: SIMD2(sp.x, WestLayout.lineZ(kl)), radius: 4000).filter({ $0.line == kl })
            .min(by: { abs($0.center.x - sp.x) < abs($1.center.x - sp.x) }) {
            let hold = SIMD3(town.station.x, town.ground + 45, town.station.y + 40)
            g.place(at: hold, yaw: 0, speed: 12)
            rt.life.resetTrain()
            var stoppedAt: Float?, dir: Float = 0, offset: Float = 0, leftAgain = false, dwellSeen: Float = 0
            let t1 = t
            while t < t1 + 260 && !leftAgain {
                g.place(at: hold, yaw: 0, speed: 12)
                g.update(time: t)
                t += 1.0 / 60
                guard let tr = rt.life.train else { continue }
                if tr.dwell > 0 {
                    if stoppedAt == nil { stoppedAt = tr.x; dir = tr.dir; offset = tr.stopOffset }
                    dwellSeen += 1.0 / 60
                } else if stoppedAt != nil && tr.speed > 6 { leftAgain = true }
                RunLoop.main.run(until: Date())
            }
            if let x = stoppedAt {
                let want = town.center.x + dir * offset
                check(abs(x - want) < 3, String(format: "the train stopped at %@'s platform (%.1f m off), coaches alongside", WestLayout.townNames[town.name % WestLayout.townNames.count], abs(x - want)))
                check(dwellSeen > 7, String(format: "stood at the station (%.1f s)", dwellSeen))
                check(leftAgain, "pulled out again")
            } else { check(false, "the train stopped at a station within 260 s") }
        } else { check(false, "a town on the spawn's line") }
        // 6. Buzz the longhorns: the herd stampedes, the cowboy rides after them.
        g.place(at: sp, yaw: g.spawn.1, speed: 15)
        for _ in 0..<30 { g.update(time: t); t += 1.0 / 60 }
        if let steer = rt.life.animals.first(where: { $0.sp.kind == .steer }) {
            let at = SIMD3(steer.pos.x, terrain.height(steer.pos.x, steer.pos.y) + 6, steer.pos.y)
            let from = at + SIMD3(60, 2, 0)
            _ = fly(from: from, to: at - SIMD3(60, 0, 0), seconds: 6, speed: 15)
            let herd = rt.life.animals.filter { $0.town == steer.town && $0.sp.kind == .steer }
            let running = herd.filter { $0.panic > 0 && $0.speed > 3 }.count
            check(rewards.contains("west.stampede"), "buzzing the longhorns starts a stampede")
            check(running * 2 >= herd.count, "the herd is running (\(running) of \(herd.count))")
            let herder = rt.life.animals.first { $0.herder && $0.town == steer.town }
            check(herder.map { $0.speed > 3 } ?? true, "the cowboy rides after them")
            check(rt.life.stampedeAt != nil, "dust over the stampede")
        } else { check(false, "longhorns near the spawn") }
        // 7. Wait under a trestle for the train to cross overhead.
        if let b = bent {
            let k = WestLayout.nearestLine(b.z).0
            let hold = SIMD3(b.x + WestRail.bentSpacing / 2, b.ground + min(b.height * 0.4, 25), b.z)
            g.place(at: hold, yaw: 0, speed: 12)
            g.terrain.update(center: hold, synchronous: true)
            rt.life.resetTrain()
            let t2 = t
            while t < t2 + 220 && !rewards.contains("west.trestle.train") {
                g.place(at: hold, yaw: 0, speed: 12)
                g.update(time: t)
                t += 1.0 / 60
                RunLoop.main.run(until: Date())
            }
            check(rewards.contains("west.trestle.train"), String(format: "the train crossed the trestle overhead (line %d, after %.0f s)", k, t - t2))
        }
        // 8. No spikes in the canyon: every mesh vertex near the spawn's stretch of the great canyon sits within reach of
        // its neighbours.
        var spikes = 0, samples = 0
        var river: SIMD2<Float>?
        search: for r in stride(from: Float(0), to: 4000, by: 40) {
            for k in 0..<max(1, Int(r / 30)) {
                let a = Float(k) / Float(max(1, Int(r / 30))) * 2 * .pi
                let q = SIMD2(sp.x, sp.z) + SIMD2(cos(a), sin(a)) * r
                if terrain.height(q.x, q.y) < -0.5 { river = q; break search }
            }
        }
        if let c0 = river {
            let step: Float = 4
            for j in -150..<150 {
                for i in -150..<150 {
                    let x = (c0.x / step).rounded() * step + Float(i) * step, z = (c0.y / step).rounded() * step + Float(j) * step
                    let h = terrain.height(x, z)
                    let top = max(max(terrain.height(x + step, z), terrain.height(x - step, z)), max(terrain.height(x, z + step), terrain.height(x, z - step)))
                    if h > top + 10 {
                        spikes += 1
                        if spikes <= 8 {
                            let (s1, s2) = WestLayout.canyonDistances(x, z, steady: true), (p1, p2) = WestLayout.canyonDistances(x, z)
                            let (w1, w2) = WestLayout.canyonWidths(x, z)
                            print(String(format: "   spike at %.0f,%.0f: h %.1f, neighbours up to %.1f; d1 %.0f (plain %.0f) / w1 %.0f, d2 %.0f (plain %.0f) / w2 %.0f",
                                         x, z, h, top, s1, p1, w1, s2, p2, w2))
                        }
                    }
                    samples += 1
                }
            }
        }
        check(river != nil && spikes == 0, "no spikes standing out of the canyon (\(spikes) of \(samples) samples)")
        print("rewards: " + rewards.joined(separator: ", ") + "  hits: \(hits)")
        print(failures == 0 ? "west-test: all passed" : "west-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--race-trace <world> <ringRace|speedRace>`: the economy sim's autopilot on one course, saying where it is every
    /// 5 s and what happens to it (for a course it can't get round).
    static func raceTrace(_ world: WorldID, _ mode: GameMode) {
        let sp = Catalog.species("gull")
        let g = Game(controls: SharedControls(), world: world, mode: mode, species: sp, points: sp.base, terrainRadius: 3)
        g.synchronousTerrain = true
        guard let track = g.track else { print("no track"); exit(1) }
        for (k, gt) in track.gates.enumerated() {
            print(String(format: "  gate %d at %.0f, %.0f, %.0f  r %.1f", k, gt.center.x, gt.center.y, gt.center.z, gt.radius))
        }
        for o in track.obstacles {
            print(String(format: "  %@ at %.0f, %.0f, %.0f", String(describing: type(of: o)), o.center.x, o.center.y, o.center.z))
        }
        var phase: Float = 0
        g.debugSteer = { g in
            var target = g.nextGate < track.gates.count && simd_distance(track.gates[g.nextGate].center, g.flight.pos) < 60
                ? track.gates[g.nextGate].center : track.point(atArc: min(g.progressS + 45, track.length))
            // Follow dips (down to a barn door) closer in than the turns.
            target.y = min(target.y, track.point(atArc: min(g.progressS + 18, track.length)).y)
            return steerToward(g, target, phase: &phase, dt: 1.0 / 60)
        }
        var t = 0.0, done = false
        g.onMatchOver = { _ in done = true }
        g.onNotice = { n in print(String(format: "  %6.1f  notice: %@", t, n)) }
        g.onHit = { c in print(String(format: "  %6.1f  hit (-%d coins)", t, c)) }
        var frame = 0
        while !done && t < 600 {
            g.update(time: t)
            t += 1.0 / 60
            frame += 1
            if frame % 300 == 0 {
                let p = g.flight.pos
                for o in track.obstacles where simd_distance(o.center, p) < o.reach {
                    if let v = o.push(p, radius: 0.9, time: Float(t)) { print(String(format: "           pushed by %@ (%.2f m)", String(describing: type(of: o)), simd_length(v))) }
                }
                print(String(format: "  %6.1f  arc %7.1f of %.0f  gate %d of %d  at %.0f, %.0f, %.0f  speed %.1f", t, g.progressS, track.length,
                             g.nextGate, track.gates.count, p.x, p.y, p.z, g.flight.speed))
            }
            if frame % 30 == 0 { RunLoop.main.run(until: Date()) }
        }
        print(done ? String(format: "finished in %.1f s", t) : "did not finish")
        exit(0)
    }
}
