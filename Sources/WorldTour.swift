import SceneKit
import AppKit
import simd

/// `--world-tour <dir> <world> [only]`: renders a set of framed views of a world offscreen (the chase camera, an aerial
/// view, street level, close-ups of its landmarks), for checking how it looks without opening the game window.
enum WorldTour {
    struct Shot {
        var name: String
        var eye: SIMD3<Float>
        var look: SIMD3<Float>
        var fov: CGFloat = 60
        /// Fly the bird here first (it shows up in the shot) instead of hiding it.
        var bird: (SIMD3<Float>, Float)? = nil
        var settle: Int = 30
        /// For things that move: eye and target worked out again every frame.
        var track: ((Game) -> (SIMD3<Float>, SIMD3<Float>))? = nil
        /// Render every settle frame (small), so particle effects run as they would on screen.
        var live = false
    }

    static func run(dir: String, world: WorldID, only: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let g = Game(controls: SharedControls(), world: world, terrainRadius: 6)
        g.synchronousTerrain = true
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = g.scene
        r.pointOfView = g.cameraNode
        var t = 0.0
        // Let the autopilot fly a moment so the world wakes up around the spawn.
        for _ in 0..<90 { g.update(time: t); t += 1.0 / 60 }
        let chase = g.flight.pos
        var shots = [Shot(name: "chase", eye: .zero, look: .zero)]
        // What a player sees first: just behind the bird at the spawn.
        let (sp0, yaw0) = g.spawn
        let f0 = SIMD3<Float>(-sin(yaw0), 0, -cos(yaw0))
        shots.append(Shot(name: "spawn", eye: sp0 - f0 * 13 + SIMD3<Float>(0, 3.5, 0), look: sp0 + f0 * 40, fov: 64, bird: (sp0, yaw0), settle: 2))
        shots += Self.liveShots(for: world, game: g, time: &t)
        shots += Self.shots(for: world, game: g)
        for s in shots where only == nil || s.name.hasPrefix(only!) {
            let start = CACurrentMediaTime()
            if s.name == "chase" {
                g.bird.node.isHidden = false
                for _ in 0..<60 { g.update(time: t); t += 1.0 / 60 }
            } else {
                if let (p, yaw) = s.bird { g.place(at: p, yaw: yaw, speed: 20) }
                let first = s.track?(g) ?? (s.eye, s.look)
                g.terrain.update(center: first.1, synchronous: true)
                // Keep the bird high above whatever's being filmed (out of shot, but close enough that the world around
                // the subject keeps living and the terrain stays loaded in one place).
                let hover = s.track == nil ? s.look + SIMD3(0, 2000, 0) : first.1 + SIMD3(0, 260, 0)
                for _ in 0..<s.settle {
                    if s.bird == nil { g.flight.reset(at: hover, yaw: 0) }
                    g.update(time: t)
                    let (e, l) = s.track?(g) ?? (s.eye, s.look)
                    g.terrain.update(center: (e + l) * 0.5, synchronous: true)
                    g.bird.node.isHidden = s.bird == nil
                    let (eye, look) = s.track?(g) ?? (s.eye, s.look)
                    g.cameraNode.simdPosition = eye
                    g.cameraNode.simdLook(at: look, up: kUp, localFront: SIMD3(0, 0, -1))
                    g.cameraNode.camera?.fieldOfView = s.fov
                    if s.live { _ = r.snapshot(atTime: t, with: CGSize(width: 160, height: 100), antialiasingMode: .none) }
                    t += 1.0 / 60
                }
            }
            let img = r.snapshot(atTime: t, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(world.rawValue)-\(s.name).png"))
            }
            print(String(format: "%@ %@ (%.1f s)", world.rawValue, s.name, CACurrentMediaTime() - start))
            _ = chase
        }
    }

    /// Close-ups of things that move, found by letting the world run near the spawn first.
    /// Dino Valley in motion: let it run until there's a fight near the bird, then frame the herds, a rex, the fight.
    static func dinoLiveShots(game g: Game, time t: inout Double) -> [Shot] {
        guard let rt = g.runtime as? DinoRuntime else { return [] }
        let life = rt.life
        var out: [Shot] = []
        var fightSeen = false
        for _ in 0..<(60 * 200) {
            g.update(time: t); t += 1.0 / 60
            if life.fights.contains(where: { $0.t > 4 && $0.a.distToPlayer < 1200 }) { fightSeen = true; break }
        }
        print("dino live: \(life.dinos.count) dinosaurs, fight \(fightSeen ? "found" : "not found") after \(Int(t)) s")
        if let f = life.fights.first {
            let a = f.a, b = f.b
            out.append(Shot(name: "fight", eye: .zero, look: .zero, fov: 55, settle: 90, track: { _ in
                let c = (a.position + b.position) * 0.5
                let across = simd_normalize(SIMD3(-(b.pos.y - a.pos.y), 0, b.pos.x - a.pos.x) + SIMD3(0.001, 0, 0))
                return (c + across * 34 + SIMD3(0, 9, 0), c + SIMD3(0, 2, 0))
            }))
            for k in 1...5 {
                out.append(Shot(name: "fight-seq\(k)", eye: .zero, look: .zero, fov: 52, settle: 50, track: { _ in
                    let c = (a.position + b.position) * 0.5
                    let across = simd_normalize(SIMD3(-(b.pos.y - a.pos.y), 0, b.pos.x - a.pos.x) + SIMD3(0.001, 0, 0))
                    return (c + across * 24 + SIMD3(0, 5, 0), c + SIMD3(0, 2.5, 0))
                }))
            }
            out.append(Shot(name: "fight-close", eye: .zero, look: .zero, fov: 50, settle: 40, track: { _ in
                let c = (a.position + b.position) * 0.5
                let across = simd_normalize(SIMD3(-(b.pos.y - a.pos.y), 0, b.pos.x - a.pos.x) + SIMD3(0.001, 0, 0))
                return (c + across * 16 + SIMD3(0, 3, 0) + simd_normalize(a.position - b.position) * 4, c + SIMD3(0, 2.5, 0))
            }))
        }
        let bird = g.flight.pos
        func nearest(_ k: DinoKind) -> Dino? {
            life.dinos.filter { $0.kind == k && $0.fight == nil }.min { simd_distance($0.position, bird) < simd_distance($1.position, bird) }
        }
        for (k, name, back, up) in [(DinoKind.longneck, "herd", Float(48), Float(10)), (.rex, "rex", 20, 5), (.trike, "trikes", 22, 4),
                                    (.para, "paras", 22, 4), (.stego, "stego", 18, 3.5), (.raptor, "raptors", 10, 2.5)] {
            guard let d = nearest(k) else { continue }
            out.append(Shot(name: name, eye: .zero, look: .zero, fov: 55, settle: 30, track: { _ in
                let side = SIMD3(cos(d.yaw), 0, -sin(d.yaw))
                let fwd = SIMD3(-sin(d.yaw), 0, -cos(d.yaw))
                return (d.position + side * back + fwd * back * 0.4 + SIMD3(0, up, 0), d.position + SIMD3(0, d.sp.hip * 0.2, 0))
            }))
        }
        if let p = life.pteros.birds.min(by: { simd_distance($0.pos, bird) < simd_distance($1.pos, bird) }) {
            out.append(Shot(name: "ptero", eye: .zero, look: .zero, fov: 50, settle: 20, track: { _ in
                (p.pos - simd_normalize(p.vel) * 10 + SIMD3(0, 3, 0) + simd_normalize(SIMD3(-p.vel.z, 0, p.vel.x)) * 5, p.pos)
            }))
        }
        return out
    }

    static func liveShots(for world: WorldID, game g: Game, time t: inout Double) -> [Shot] {
        if world == .dino { return dinoLiveShots(game: g, time: &t) }
        if world == .west { return westLiveShots(game: g, time: &t) }
        guard world == .city, let rt = g.runtime as? CityRuntime else { return [] }
        var out: [Shot] = []
        let life = rt.life
        // Let the city run a few seconds where the bird is.
        for _ in 0..<240 { g.update(time: t); t += 1.0 / 60 }
        let bird = g.flight.pos
        if let p = life.people.people.filter({ !$0.inPark }).min(by: { simd_distance(SIMD2($0.pos.x, $0.pos.y), SIMD2(bird.x, bird.z)) <
                                                                         simd_distance(SIMD2($1.pos.x, $1.pos.y), SIMD2(bird.x, bird.z)) }) {
            let at = SIMD3(p.pos.x, p.y, p.pos.y)
            let fwd = SIMD3(-sin(p.yaw), 0, -cos(p.yaw))
            out.append(Shot(name: "people", eye: at + fwd * 6 + SIMD3(1.5, 1.8, 0), look: at + SIMD3(0, 0.9, 0), fov: 50, settle: 4))
        }
        if let c = life.traffic.cars.min(by: { simd_distance($0.pos, bird) < simd_distance($1.pos, bird) }) {
            let fwd = SIMD3(-sin(c.yaw), 0, -cos(c.yaw)), side = SIMD3(cos(c.yaw), 0, -sin(c.yaw))
            out.append(Shot(name: "cars", eye: c.pos + fwd * 14 + side * 6 + SIMD3(0, 4.5, 0), look: c.pos - fwd * 4, fov: 55, settle: 4))
        }
        if let tr = life.transit.trains.min(by: { abs($0.z - bird.z) + abs($0.x - bird.x) < abs($1.z - bird.z) + abs($1.x - bird.x) }) {
            let y = CityTerrain.trackY(tr.x, tr.z)
            out.append(Shot(name: "train", eye: SIMD3(tr.x + 16, y + 9, tr.z + tr.dir * 30), look: SIMD3(tr.x, y + 2, tr.z - tr.dir * 10), fov: 60, settle: 2))
        }
        out.append(Shot(name: "heli", eye: life.sky.heliPos, look: life.sky.heliPos, fov: 55, settle: 3, track: { _ in
            (life.sky.heliPos + SIMD3(14, 4, 18), life.sky.heliPos + SIMD3(0, 1.5, 0)) }))
        out.append(Shot(name: "blimp", eye: life.sky.blimpPos, look: life.sky.blimpPos, fov: 55, settle: 3, track: { _ in
            (life.sky.blimpPos + SIMD3(40, -12, 60), life.sky.blimpPos) }))
        if let f = life.sky.flocks.first {
            out.append(Shot(name: "pigeons", eye: f.home + SIMD3(4, 2.2, 4), look: f.home, fov: 50, settle: 2))
        }
        return out
    }

    static func shots(for world: WorldID, game g: Game) -> [Shot] {
        switch world {
        case .city: return cityShots(g)
        case .dino: return dinoShots(g)
        case .west: return westShots(g)
        case .finale: return finaleShots(g)
        default:
            let p = g.spawn.0
            return [Shot(name: "aerial", eye: p + SIMD3(260, 180, 260), look: p)]
        }
    }

    /// The Finale: the castle from afar and close, the gate, the courtyard, the great hall, the throne, the lantern
    /// from below, the Sky Tower, the village, the crowds.
    private static func finaleShots(_ g: Game) -> [Shot] {
        let L = FinaleLayout.self
        let gy = L.ground
        var out: [Shot] = []
        out.append(Shot(name: "aerial", eye: SIMD3<Float>(260, 190, 520), look: SIMD3<Float>(0, gy + 30, -20), fov: 55, settle: 60, live: true))
        out.append(Shot(name: "approach", eye: SIMD3<Float>(0, gy + 6, 260), look: SIMD3<Float>(0, gy + 22, 60), fov: 62, settle: 40, live: true))
        out.append(Shot(name: "gate", eye: SIMD3<Float>(14, gy + 4, 150), look: SIMD3<Float>(0, gy + 9, L.gateZ), fov: 60, settle: 30, live: true))
        out.append(Shot(name: "courtyard", eye: SIMD3<Float>(0, gy + 9, L.gateZ - 6), look: SIMD3<Float>(0, gy + 14, L.hallSouth), fov: 64, settle: 30, live: true))
        out.append(Shot(name: "crowd", eye: SIMD3<Float>(3, gy + 2.2, 70), look: SIMD3<Float>(-10, gy + 1.2, 64), fov: 55, settle: 30, live: true))
        out.append(Shot(name: "hall", eye: SIMD3<Float>(0, gy + 5, L.hallSouth - 3), look: SIMD3<Float>(0, gy + 6, L.daisBack), fov: 66, settle: 30, live: true))
        out.append(Shot(name: "throne", eye: SIMD3<Float>(4, gy + 4, -54), look: SIMD3<Float>(0, gy + 4, -71), fov: 58, settle: 30, live: true))
        out.append(Shot(name: "lantern", eye: SIMD3<Float>(0, gy + 3, -56), look: SIMD3<Float>(0, gy + 60, L.lanternZ), fov: 70, settle: 30, live: true))
        out.append(Shot(name: "roof", eye: SIMD3<Float>(30, gy + 70, -20), look: SIMD3<Float>(0, gy + 44, L.lanternZ), fov: 58, settle: 30, live: true))
        out.append(Shot(name: "skytower", eye: SIMD3<Float>(-120, gy + 60, -40), look: SIMD3<Float>(0, gy + 80, L.skyTower.y), fov: 60, settle: 30, live: true))
        let v = L.village
        out.append(Shot(name: "village", eye: SIMD3<Float>(v.x + 60, 30, v.y + 90), look: SIMD3<Float>(v.x, 8, v.y), fov: 60, settle: 30, live: true))
        out.append(Shot(name: "lake", eye: SIMD3<Float>(0, gy + 60, -160), look: SIMD3<Float>(L.lake.x, 20, L.lake.y - 300), fov: 64, settle: 30, live: true))
        return out
    }

    private static func westShots(_ g: Game) -> [Shot] {
        guard let t = TerrainShape.active as? WestTerrain else { return [] }
        let sp = g.spawn.0
        var out: [Shot] = []
        guard let town = WestLayout.towns(near: SIMD2(sp.x, sp.z), radius: 2500).min(by: { simd_distance($0.center, SIMD2(sp.x, sp.z)) < simd_distance($1.center, SIMD2(sp.x, sp.z)) })
        else { return out }
        let c = SIMD3(town.center.x, town.ground, town.center.y)
        let L = WestLayout.streetHalfLength
        out.append(Shot(name: "aerial", eye: c + SIMD3(-230, 150, 170), look: c + SIMD3(40, 0, -20), fov: 60))
        out.append(Shot(name: "street", eye: c + SIMD3(-L - 10, 4.5, 2), look: c + SIMD3(L, 3, 0), fov: 62))
        if let s = WestTown.plan(town).saloon {
            let mid = (s.lo.x + s.hi.x) / 2
            let front = SIMD3(mid, s.lo.y, s.frontZ)
            out.append(Shot(name: "saloon", eye: front + SIMD3(-9, 4, s.facing * 18), look: front + SIMD3(0, 4.5, 0), fov: 60))
            out.append(Shot(name: "saloon-inside", eye: front + SIMD3(0, 2.2, s.facing * -1.5), look: SIMD3(mid, s.lo.y + 1.6, s.facing > 0 ? s.lo.z : s.hi.z), fov: 72))
        }
        let lz = WestLayout.lineZ(town.line)
        out.append(Shot(name: "station", eye: SIMD3(c.x - 40, c.y + 5, lz - 22), look: SIMD3(c.x, c.y + 4, lz + 10), fov: 60))
        // The canyon: walk out from the town until the ground falls away.
        var rim: (SIMD3<Float>, SIMD3<Float>)?
        for k in 0..<48 where rim == nil {
            let a = Float(k) / 48 * 2 * .pi
            let d = SIMD3(cos(a), 0, sin(a))
            var r: Float = 150
            while r < 2500 {
                let q = c + d * r
                if t.height(q.x, q.z) < WestLayout.rim - 90 { rim = (q - d * 70, d); break }
                r += 20
            }
        }
        if let (edge, d) = rim {
            let e = SIMD3(edge.x, t.height(edge.x, edge.z) + 18, edge.z)
            out.append(Shot(name: "canyon-rim", eye: e - d * 30, look: e + d * 500 + SIMD3(0, -110, 0), fov: 64))
            // Down inside: halfway down, looking along the canyon.
            let inside = edge + d * 260
            let side = SIMD3(-d.z, 0, d.x)
            let gi = max(t.height(inside.x, inside.z), 0)
            out.append(Shot(name: "canyon-inside", eye: SIMD3(inside.x, gi + 70, inside.z), look: SIMD3(inside.x, gi + 40, inside.z) + side * 400, fov: 66))
            var riverP: SIMD3<Float>?
            for k in 0..<60 where riverP == nil {
                let q = edge + d * Float(k) * 15
                if t.height(q.x, q.z) < -0.5 { riverP = q }
            }
            if let rp = riverP {
                out.append(Shot(name: "river", eye: SIMD3(rp.x, 4, rp.z) - side * 40, look: SIMD3(rp.x, 6, rp.z) + side * 200, fov: 66))
            }
        }
        // The great canyon: find its river nearest the spawn and look along it, from above and from inside.
        var great: SIMD3<Float>?
        search: for r in stride(from: Float(0), to: 4000, by: 40) {
            for k in 0..<max(1, Int(r / 30)) {
                let a = Float(k) / Float(max(1, Int(r / 30))) * 2 * .pi
                let q = sp + SIMD3<Float>(cos(a), 0, sin(a)) * r
                if WestLayout.canyonDistances(q.x, q.z).0 < 20 && t.height(q.x, q.z) < 0 { great = SIMD3(q.x, 0, q.z); break search }
            }
        }
        if let rv = great {
            let e: Float = 4
            let f0 = WestLayout.fields(rv.x, rv.z).0
            var across = SIMD3<Float>(WestLayout.fields(rv.x + e, rv.z).0 - f0, 0, WestLayout.fields(rv.x, rv.z + e).0 - f0)
            across = simd_length(across) > 1e-9 ? simd_normalize(across) : SIMD3<Float>(1, 0, 0)
            let along = SIMD3<Float>(-across.z, 0, across.x)
            out.append(Shot(name: "gc-aerial", eye: rv + across * 700 + SIMD3<Float>(0, 420, 0), look: rv + along * 250, fov: 62))
            out.append(Shot(name: "gc-high", eye: rv + SIMD3<Float>(0, 230, 0) - along * 60, look: rv + along * 900 + SIMD3<Float>(0, 60, 0), fov: 64))
            out.append(Shot(name: "gc-inside", eye: rv + across * 110 + SIMD3<Float>(0, 70, 0), look: rv + along * 500 + SIMD3<Float>(0, 50, 0), fov: 66))
            out.append(Shot(name: "gc-wall", eye: rv - across * 30 + SIMD3<Float>(0, 40, 0), look: rv + across * 320 + SIMD3<Float>(0, 110, 0), fov: 64))
            out.append(Shot(name: "gc-back", eye: rv + across * 110 - along * 220 + SIMD3<Float>(0, 90, 0), look: rv + along * 120 + SIMD3<Float>(0, 40, 0), fov: 66))
            out.append(Shot(name: "gc-river", eye: rv + SIMD3<Float>(0, 7, 0) - along * 40, look: rv + along * 300 + SIMD3<Float>(0, 25, 0), fov: 70))
        }
        // A trestle on a line near the spawn.
        var trestle: WestRail.Bent?
        for k in [town.line, town.line + 1, town.line - 1] where trestle == nil {
            var x = sp.x - 3000
            while x < sp.x + 3000 && trestle == nil {
                if let b = WestRail.bents(line: k, from: x, to: x + 200, t).first(where: { $0.height > 60 }) { trestle = b }
                x += 200
            }
        }
        if let b = trestle {
            out.append(Shot(name: "trestle", eye: SIMD3(b.x - 90, b.ground + b.height * 0.45, b.z + 120), look: SIMD3(b.x + 40, b.deck - 20, b.z), fov: 60))
            out.append(Shot(name: "trestle-under", eye: SIMD3(b.x - 60, b.ground + b.height * 0.5, b.z), look: SIMD3(b.x + 200, b.ground + b.height * 0.55, b.z), fov: 70))
        }
        // The nearest mine and butte.
        var mine: WestMineTunnel?
        for r in 0..<8 where mine == nil {
            for dj in -r...r {
                for di in -r...r where max(abs(di), abs(dj)) == r && mine == nil {
                    let bc = WestTerrain.butteCell
                    mine = WestMine.tunnel(Int(floor(sp.x / bc)) + di, Int(floor(sp.z / bc)) + dj, t)
                }
            }
        }
        if let m = mine {
            let mouth = m.a + SIMD3(0, WestMineTunnel.height / 2, 0)
            out.append(Shot(name: "mine", eye: mouth - m.axis * 45 + m.side * 18 + SIMD3(0, 8, 0), look: mouth, fov: 60))
            out.append(Shot(name: "mine-inside", eye: m.a + m.axis * 4 + SIMD3(0, 3.2, 0), look: m.b + SIMD3(0, 3, 0), fov: 70))
            out.append(Shot(name: "butte", eye: m.mid - m.side * 320 + SIMD3(0, 60, 0), look: m.mid + SIMD3(0, 40, 0), fov: 58))
        }
        return out
    }

    /// The Wild West in motion: the train, townsfolk, horses, cattle, a dust devil, tumbleweeds, vultures.
    static func westLiveShots(game g: Game, time t: inout Double) -> [Shot] {
        guard let rt = g.runtime as? WestRuntime else { return [] }
        let life = rt.life
        for _ in 0..<240 { g.update(time: t); t += 1.0 / 60 }
        var out: [Shot] = []
        if let tr = life.train {
            out.append(Shot(name: "train", eye: .zero, look: .zero, fov: 55, settle: 40, track: { _ in
                let z = WestLayout.lineZ(tr.line)
                let y = WestLayout.trackY(tr.x, line: tr.line)
                return (SIMD3(tr.x + tr.dir * 25, y + 6, z + 24), SIMD3(tr.x - tr.dir * 10, y + 2.5, z))
            }))
        }
        if !life.cowboys.isEmpty {
            out.append(Shot(name: "folk", eye: .zero, look: .zero, fov: 55, settle: 20, track: { _ in
                guard let c = life.cowboys.first else { return (.zero, SIMD3(0, 0, -1)) }
                let at = SIMD3(c.pos.x, c.y, c.pos.y)
                let f = SIMD3(-sin(c.yaw), 0, -cos(c.yaw)), side = SIMD3(cos(c.yaw), 0, -sin(c.yaw))
                return (at + f * 4.5 + side * 1.8 + SIMD3(0, 1.6, 0), at + SIMD3(0, 0.9, 0))
            }))
        }
        if let h = life.animals.first(where: { $0.tied }) {
            let at = SIMD3(h.pos.x, life.terrain.height(h.pos.x, h.pos.y), h.pos.y)
            out.append(Shot(name: "horses", eye: at + SIMD3(5, 2.5, h.yaw == 0 ? -6 : 6), look: at + SIMD3(0, 1.3, 0), fov: 55, settle: 20))
        }
        if let s = life.animals.first(where: { $0.sp.kind == .steer }) {
            let at = SIMD3(s.pos.x, life.terrain.height(s.pos.x, s.pos.y), s.pos.y)
            out.append(Shot(name: "cattle", eye: at + SIMD3(14, 4, 10), look: at + SIMD3(0, 1, 0), fov: 55, settle: 20))
            // Set them running and follow the dust.
            var started = false
            func herd() -> SIMD3<Float> {
                let list = life.animals.filter { $0.town == s.town && $0.sp.kind == .steer }
                let m = list.reduce(SIMD2<Float>.zero) { $0 + $1.pos } / Float(max(list.count, 1))
                return SIMD3(m.x, life.terrain.height(m.x, m.y), m.y)
            }
            out.append(Shot(name: "stampede", eye: .zero, look: .zero, fov: 55, settle: 150, track: { _ in
                if !started { started = true; life.debugStampede() }
                let h = herd()
                let fwd = SIMD3<Float>(s.flee.x, 0, s.flee.y), side = SIMD3<Float>(-s.flee.y, 0, s.flee.x)
                return (h + fwd * 34 + side * 22 + SIMD3<Float>(0, 7, 0), h + SIMD3<Float>(0, 1.5, 0))
            }, live: true))
            out.append(Shot(name: "stampede-high", eye: .zero, look: .zero, fov: 55, settle: 120, track: { _ in
                let h = herd()
                let fwd = SIMD3<Float>(s.flee.x, 0, s.flee.y), side = SIMD3<Float>(-s.flee.y, 0, s.flee.x)
                return (h - fwd * 50 + side * 40 + SIMD3<Float>(0, 45, 0), h + fwd * 10)
            }, live: true))
        }
        if let d = life.devils.first {
            out.append(Shot(name: "devil", eye: .zero, look: .zero, fov: 60, settle: 60, track: { _ in
                let at = d.node.simdPosition
                return (at + SIMD3(70, 20, 60), at + SIMD3(0, 22, 0))
            }))
        }
        if !life.weeds.isEmpty {
            out.append(Shot(name: "tumbleweed", eye: .zero, look: .zero, fov: 50, settle: 10, track: { _ in
                guard let w = life.weeds.first else { return (.zero, SIMD3(0, 0, -1)) }
                return (w.pos + SIMD3(5, 1.5, 5), w.pos)
            }))
        }
        if let v = life.vultures.first {
            out.append(Shot(name: "vulture", eye: .zero, look: .zero, fov: 50, settle: 20, track: { _ in
                (v.pos - simd_normalize(v.vel) * 8 + SIMD3(0, 2, 0) + simd_normalize(SIMD3(-v.vel.z, 0, v.vel.x)) * 4, v.pos)
            }))
        }
        return out
    }

    private static func dinoShots(_ g: Game) -> [Shot] {
        guard let t = TerrainShape.active as? DinoTerrain else { return [] }
        let (sp, yaw) = g.spawn
        let fwd = SIMD3(-sin(yaw), 0, -cos(yaw))
        var out: [Shot] = []
        let gy = t.height(sp.x, sp.z)
        out.append(Shot(name: "aerial", eye: sp - fwd * 300 + SIMD3(120, 260, 0), look: sp + fwd * 400, fov: 62))
        out.append(Shot(name: "valley", eye: SIMD3(sp.x, max(gy, 0) + 24, sp.z) - fwd * 40, look: SIMD3(sp.x, max(gy, 0) + 30, sp.z) + fwd * 300, fov: 64))
        // Walk outward from the spawn to find a cliff, and look at it from the valley.
        var cliff: SIMD3<Float>?
        for k in 0..<64 where cliff == nil {
            let a = Float(k) / 64 * 2 * .pi
            let d = SIMD3(cos(a), 0, sin(a))
            var r: Float = 30
            while r < 600 {
                let q = sp + d * r
                if t.height(q.x, q.z) > 80 { cliff = SIMD3(q.x, 0, q.z); break }
                r += 10
            }
        }
        if let c = cliff {
            let away = simd_normalize(SIMD3(sp.x - c.x, 0, sp.z - c.z))
            let eye = c + away * 160
            out.append(Shot(name: "cliff", eye: SIMD3(eye.x, t.height(eye.x, eye.z) + 18, eye.z), look: SIMD3(c.x, 70, c.z), fov: 62))
            out.append(Shot(name: "plateau", eye: SIMD3(c.x, t.height(c.x, c.z) + 35, c.z) - away * 60, look: SIMD3(c.x, t.height(c.x, c.z), c.z) - away * 300, fov: 62))
        }
        if let v = t.nearestVolcano(sp.x, sp.z) {
            let c = SIMD3(v.x, t.craterFloor(v), v.y)
            let dir = simd_normalize(SIMD3(sp.x - v.x, 0, sp.z - v.y))
            out.append(Shot(name: "volcano", eye: c + dir * (v.z * 1.9) + SIMD3(0, 40, 0), look: c, fov: 58))
            out.append(Shot(name: "crater", eye: c + dir * 120 + SIMD3(0, 110, 0), look: c, fov: 60))
            // It blows: from across the valley, then down on the flank where the bombs come down, then after.
            var fired = false
            let side = simd_normalize(simd_cross(dir, kUp))
            let flank = SIMD3(v.x, 0, v.y) + dir * (v.z * 0.55) + side * (v.z * 0.12)
            let flankEye = SIMD3(flank.x, t.height(flank.x, flank.z) + 30, flank.z) + dir * 60
            out.append(Shot(name: "erupt", eye: .zero, look: .zero, fov: 58, settle: 240, track: { g in
                if !fired, let rt = g.runtime as? DinoRuntime { fired = true; rt.eruption.debugErupt() }
                return (c + dir * (v.z * 1.5) + SIMD3(0, 40, 0), c + SIMD3(0, 140, 0))
            }, live: true))
            out.append(Shot(name: "erupt-flank", eye: flankEye, look: c + SIMD3(0, 60, 0), fov: 62, settle: 300, live: true))
            out.append(Shot(name: "erupt-after", eye: flankEye + SIMD3(0, 20, 0), look: SIMD3(flank.x, t.height(flank.x, flank.z), flank.z) - dir * 120, fov: 62,
                            settle: 240, live: true))
        }
        // Low over the meadow, and in among the trees of the nearest grove.
        out.append(Shot(name: "meadow-low", eye: SIMD3(sp.x, max(gy, 0) + 4, sp.z) + fwd * 60, look: SIMD3(sp.x, max(gy, 0) + 5, sp.z) + fwd * 160, fov: 68))
        var grove: SIMD3<Float>?
        for r: Float in stride(from: 20, to: 900, by: 25) where grove == nil {
            for k in 0..<16 {
                let a = Float(k) / 16 * 2 * .pi
                let q = sp + SIMD3(cos(a), 0, sin(a)) * r
                let h = t.height(q.x, q.z)
                if h > 3 && h < 30 && t.forest(q.x, q.z) > 0.25 { grove = SIMD3(q.x, h, q.z); break }
            }
        }
        if let gp = grove {
            out.append(Shot(name: "grove", eye: gp + SIMD3(0, 6, 0) - fwd * 25, look: gp + SIMD3(0, 5, 0) + fwd * 40, fov: 70))
        }
        // Landmarks: the nearest waterfall, skeleton and nest.
        var bestFall: DinoWaterfall?
        for r in 0..<14 where bestFall == nil {
            for dj in -r...r {
                for di in -r...r where max(abs(di), abs(dj)) == r {
                    let k = ChunkKey(x: Int(floor(sp.x / t.chunkSize)) + di, z: Int(floor(sp.z / t.chunkSize)) + dj)
                    if bestFall == nil, let w = DinoLandmarks.waterfall(k, t) { bestFall = w }
                }
            }
        }
        if let w = bestFall {
            let mid = w.profile[w.profile.count / 2]
            out.append(Shot(name: "land-waterfall", eye: mid + w.out * 70 + w.side * 25 + SIMD3(0, -5, 0), look: mid, fov: 60, settle: 20))
            out.append(Shot(name: "land-waterfall-foot", eye: w.foot + w.out * 30 + SIMD3(0, 6, 0), look: w.foot + SIMD3(0, 12, 0), fov: 65, settle: 20))
        }
        var bestBones: DinoSkeleton?
        for r in 0..<5 where bestBones == nil {
            for dj in -r...r {
                for di in -r...r where max(abs(di), abs(dj)) == r {
                    let c = DinoLandmarks.skeletonCell
                    if bestBones == nil, let b = DinoLandmarks.skeleton(Int(floor(sp.x / c)) + di, Int(floor(sp.z / c)) + dj, t) { bestBones = b }
                }
            }
        }
        if let b = bestBones {
            let dir = simd_normalize(b.b - b.a), side = simd_normalize(simd_cross(dir, kUp))
            out.append(Shot(name: "land-skeleton", eye: b.center + side * 40 + dir * 10 + SIMD3(0, 8, 0), look: b.center, fov: 60, settle: 10))
            out.append(Shot(name: "land-skeleton-inside", eye: b.a - dir * 3 + SIMD3(0, -4.5, 0), look: b.b + SIMD3(0, -5, 0), fov: 70, settle: 10))
        }
        var bestNest: DinoNest?
        for r in 0..<6 where bestNest == nil {
            for dj in -r...r {
                for di in -r...r where max(abs(di), abs(dj)) == r {
                    let c = DinoLandmarks.nestCell
                    if bestNest == nil, let n = DinoLandmarks.nest(Int(floor(sp.x / c)) + di, Int(floor(sp.z / c)) + dj, t) { bestNest = n }
                }
            }
        }
        if let n = bestNest {
            out.append(Shot(name: "land-nest", eye: n.pos + SIMD3(6, 4, 7), look: n.pos + SIMD3(0, 0.6, 0), fov: 55, settle: 10))
        }
        out += dinoLineup(g, t)
        return out
    }

    /// Every species standing in a row on flat ground near the spawn (and again mid-stride), to check the models.
    private static func dinoLineup(_ g: Game, _ t: DinoTerrain) -> [Shot] {
        guard let mesh = DynamicMesh(maxVertices: 300_000, maxTriangles: 400_000, material: WorldMaterials.vertexColor(rough: 0.75)) else { return [] }
        mesh.node.castsShadow = true
        g.scene.rootNode.addChildNode(mesh.node)
        // A flat-ish spot on the valley floor.
        var spot = g.spawn.0
        var best: Float = .infinity
        for k in 0..<400 {
            let a = Float(k) * 2.4, r = Float(k) * 3
            let q = g.spawn.0 + SIMD3(cos(a) * r, 0, sin(a) * r)
            guard t.walkable(q.x, q.z) else { continue }
            let h = t.height(q.x, q.z)
            var rough: Float = 0
            for (dx, dz) in [(30, 0), (-30, 0), (0, 30), (0, -30), (60, 0), (-60, 0)] as [(Float, Float)] { rough += abs(t.height(q.x + dx, q.z + dz) - h) }
            if rough < best { best = rough; spot = SIMD3(q.x, h, q.z) }
        }
        let kinds: [DinoKind] = [.longneck, .rex, .trike, .stego, .para, .ankylo, .raptor, .ptero]
        func draw(walking: Bool, time: Float) {
            mesh.begin()
            var x: Float = -40
            for k in kinds {
                let sp = DinoSpecies.all[k]!
                var m = DinoMotion()
                m.time = time
                if walking {
                    m.speed = k == .raptor ? sp.run : sp.walk
                    m.phase = (time * 0.6).truncatingRemainder(dividingBy: 1)
                    m.flap = 1
                } else {
                    m.neck = k == .longneck ? 0.4 : 0
                    m.jaw = k == .rex ? 0.6 : 0
                    m.flap = 0.2
                }
                var q: [simd_quatf] = []
                sp.pose(m, into: &q)
                let w = k == .longneck ? Float(14) : max(sp.length * 0.45, 3)
                x += w
                let p = SIMD3(spot.x + x, t.height(spot.x + x, spot.z) + sp.hip - m.bob(sp) + (k == .ptero ? 9 : 0), spot.z)
                var mats: [simd_float4x4] = []
                sp.rig.solve(root: trs(p, yawQuat(-.pi / 2)), pose: q, into: &mats)
                sp.rig.draw(mats, into: mesh, far: false)
                x += w
            }
            mesh.end()
        }
        let eye = spot + SIMD3(8, 8, 46), at = spot + SIMD3(8, 5, 0)
        func shot(_ name: String, _ e: SIMD3<Float>, _ l: SIMD3<Float>, fov: CGFloat = 70, walking: Bool) -> Shot {
            Shot(name: name, eye: e, look: l, fov: fov, settle: 4, track: { _ in draw(walking: walking, time: walking ? 0.3 : 1); return (e, l) })
        }
        return [shot("lineup", eye, at, walking: false),
                shot("lineup-walk", eye, at, walking: true),
                shot("lineup-big", spot + SIMD3(-14, 6, 26), spot + SIMD3(-14, 6, 0), walking: false),
                shot("lineup-mid", spot + SIMD3(14, 3.5, 17), spot + SIMD3(14, 2.5, 0), walking: false),
                shot("lineup-small", spot + SIMD3(36, 2.5, 11), spot + SIMD3(36, 1.5, 0), walking: false),
                shot("lineup-rexhead", spot + SIMD3(-3, 5.5, 5), spot + SIMD3(-1, 5.2, 0), fov: 55, walking: false)]
    }

    private static func cityShots(_ g: Game) -> [Shot] {
        let G = CityLayout.pitch
        let (sp, yaw) = g.spawn
        let fwd = SIMD3(-sin(yaw), 0, -cos(yaw))
        var out: [Shot] = []
        let gy = CityLayout.ground(sp.x, sp.z)
        out.append(Shot(name: "aerial", eye: sp - fwd * 260 + SIMD3(80, 230, 0), look: sp + fwd * 300 + SIMD3(0, 40, 0), fov: 62))
        out.append(Shot(name: "skyline", eye: sp - fwd * 700 + SIMD3(-200, 120, 0), look: sp + fwd * 200 + SIMD3(0, 90, 0), fov: 55))
        out.append(Shot(name: "avenue", eye: SIMD3(sp.x, gy + 9, sp.z) - fwd * 30, look: SIMD3(sp.x, gy + 14, sp.z) + fwd * 200, fov: 62))
        out.append(Shot(name: "street-low", eye: SIMD3(sp.x, gy + 2.2, sp.z) + fwd * 30, look: SIMD3(sp.x, gy + 3, sp.z) + fwd * 90, fov: 70))
        // A node near the spawn, seen from a corner.
        let ni = Int((sp.x / G).rounded()), nj = Int((sp.z / G).rounded())
        let node = CityLayout.nodePosition(ni, nj)
        let ng = CityLayout.ground(node.x, node.y)
        out.append(Shot(name: "intersection", eye: SIMD3(node.x + 26, ng + 14, node.y + 30), look: SIMD3(node.x, ng + 2, node.y), fov: 60))
        // The tallest building nearby, close up.
        var tallest: CityBuilding?
        for b in CityLayout.blocks(near: sp.x, sp.z, radius: 400) {
            for bld in b.buildings where bld.top > (tallest?.top ?? 0) { tallest = bld }
        }
        if let t = tallest, let p = t.parts.first {
            let c = p.center
            out.append(Shot(name: "facade", eye: SIMD3(p.lo.x - 45, t.base + 30, p.lo.z - 30), look: SIMD3(c.x, t.base + 45, c.z), fov: 55))
            out.append(Shot(name: "tower-top", eye: SIMD3(p.hi.x + 60, t.top + 30, p.hi.z + 60), look: SIMD3(c.x, t.top - 10, c.z), fov: 55))
        }
        // The nearest bridge.
        var bridge: CityEdge?
        var bd: Float = .infinity
        for j in (nj - 18)...(nj + 18) {
            for i in (ni - 18)...(ni + 18) {
                for ax in [true, false] {
                    guard let e = CityLayout.edge(alongX: ax, i, j), let br = e.bridge else { continue }
                    let m = e.start + e.dir * ((br.s0 + br.s1) / 2)
                    let d = simd_distance(m, SIMD2(sp.x, sp.z)) - (e.line.avenue ? 400 : 0)
                    if d < bd { bd = d; bridge = e }
                }
            }
        }
        if let e = bridge, let br = e.bridge {
            let m = e.start + e.dir * ((br.s0 + br.s1) / 2)
            let side = SIMD3(-e.dir.y, 0, e.dir.x)
            let mid = SIMD3(m.x, br.deck, m.y)
            out.append(Shot(name: "bridge", eye: mid + side * 140 + SIMD3(0, 22, 0) + SIMD3(e.dir.x, 0, e.dir.y) * 40, look: mid + SIMD3(0, 10, 0), fov: 60))
            out.append(Shot(name: "river", eye: mid + side * 60 + SIMD3(0, 4, 0), look: mid - side * 80 + SIMD3(0, 8, 0), fov: 70))
        }
        // A park and a plaza.
        var park: CityBlock?, plaza: CityBlock?, crane: CityBlock?
        for b in CityLayout.blocks(near: sp.x, sp.z, radius: 900) {
            let d = simd_distance(b.center, SIMD2(sp.x, sp.z))
            if b.kind == .park && (park == nil || d < simd_distance(park!.center, SIMD2(sp.x, sp.z))) { park = b }
            if b.kind == .plaza && (plaza == nil || d < simd_distance(plaza!.center, SIMD2(sp.x, sp.z))) { plaza = b }
            if b.kind == .construction && (crane == nil || d < simd_distance(crane!.center, SIMD2(sp.x, sp.z))) { crane = b }
        }
        for (name, b) in [("park", park), ("plaza", plaza), ("crane", crane)] {
            guard let b else { continue }
            let c = SIMD3(b.center.x, CityLayout.ground(b.center.x, b.center.y), b.center.y)
            let up: Float = name == "crane" ? 60 : 30
            out.append(Shot(name: name, eye: c + SIMD3(70, up, 80), look: c + SIMD3(0, name == "crane" ? 40 : 0, 0), fov: 60))
        }
        // The subway: a station near the spawn (entrance, stairwell, platform), a tunnel and a river portal.
        var station: CitySubway.Segment?, portal: (CitySubway.Segment, Float, Float)?, tunnel: CitySubway.Segment?
        var portals = 0
        for seg in CitySubway.segments(near: sp.x, sp.z, radius: 6000) {
            let d = simd_distance(seg.world(60, 0, 0), sp)
            if seg.station, station == nil || d < simd_distance(station!.world(60, 0, 0), sp) { station = seg }
            if !seg.station && seg.stubs.count == 1 && seg.stubs[0].s0 == 0 && seg.stubs[0].s1 == CityLayout.pitch,
               tunnel == nil || d < simd_distance(tunnel!.world(60, 0, 0), sp) { tunnel = seg }
            for st in seg.stubs where st.portal1 || st.portal0 {
                portals += 1
                let at = st.portal1 ? st.s1 : st.s0
                if portal == nil || d < simd_distance(portal!.0.world(60, 0, 0), sp) { portal = (seg, at, st.portal1 ? 1 : -1) }
            }
        }
        if let seg = station {
            let f = seg.floor(60)
            let st = CitySubway.stairs(seg)[1]
            // From over the middle of the avenue, looking down into the opening.
            let overRoad = SIMD3(st.top.x, 0, st.top.z) - seg.across * st.l + seg.across * st.l * 0.1
            out.append(Shot(name: "subway-entrance", eye: overRoad + seg.axis * -st.dir * 8 + SIMD3(0, st.top.y + 9, 0),
                            look: st.top + seg.axis * st.dir * 4 - SIMD3(0, 2, 0), fov: 60))
            let stairEye = st.top + (st.bottom - st.top) * 0.15 + SIMD3(0, 2.4, 0)
            out.append(Shot(name: "subway-stairs", eye: stairEye, look: st.bottom + SIMD3(0, 1.2, 0), fov: 70,
                            bird: (stairEye + (st.bottom - stairEye) * 0.25, atan2(-(st.bottom - st.top).x, -(st.bottom - st.top).z))))
            let platEye = seg.world(34, 9.5, f + CitySubway.platformY + 2.4)
            out.append(Shot(name: "subway-station", eye: platEye, look: seg.world(80, 3, f + 2.5), fov: 72,
                            bird: (seg.world(44, 3, f + 5), seg.alongX ? -.pi / 2 : .pi)))
        }
        if let seg = tunnel {
            let f = seg.floor(30)
            out.append(Shot(name: "subway-tunnel", eye: seg.world(20, -1.5, f + 3.6), look: seg.world(80, 0, f + 3), fov: 70,
                            bird: (seg.world(30, 0, f + 4), seg.alongX ? -.pi / 2 : .pi)))
        }
        print("subway: \(portals) portals within 6 km; nearest at \(portal.map { Int(simd_distance($0.0.world(60, 0, 0), sp)) } ?? -1) m")
        if let (seg, at, out1) = portal {
            let f = seg.floor(at)
            out.append(Shot(name: "subway-portal", eye: seg.world(at + out1 * 45, 14, f + 6), look: seg.world(at, 0, f + 4), fov: 60, settle: 240))
        }
        // The elevated railway.
        let elI = (Int((sp.x / G).rounded()) / 12) * 12 + 6
        let ex = Float(elI) * G
        let ez = sp.z + 60
        let ey = CityTerrain.trackY(ex, ez)
        out.append(Shot(name: "el", eye: SIMD3(ex + 30, ey + 8, ez - 40), look: SIMD3(ex, ey - 4, ez + 40), fov: 65))
        return out
    }
}
