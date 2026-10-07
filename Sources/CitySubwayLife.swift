import SceneKit
import simd

/// Trains in the subway tunnels, gold tokens to collect down there, and the reward for finding it.
final class CitySubwayLife {
    let root = SCNNode()

    final class Train {
        let node = SCNNode()
        var cars: [SCNNode] = []
        let alongX: Bool
        let line: Int
        var dir: Float
        /// Front of the train: the world coordinate along the line (x for lines along x, z otherwise).
        var a: Float
        var speed: Float = 0
        var dwell: Float = 0
        var lastStop = Int.min
        static let cars = 3
        static let carLength: Float = 17.9
        var length: Float { Float(Train.cars) * Train.carLength }

        init(alongX: Bool, line: Int, dir: Float, a: Float, livery: Int) {
            self.alongX = alongX; self.line = line; self.dir = dir; self.a = a
            for k in 0..<Train.cars {
                let n = SCNNode(geometry: CityTransit.carGeometry(front: k == 0, back: k == Train.cars - 1, livery: livery))
                n.castsShadow = false
                node.addChildNode(n)
                cars.append(n)
            }
        }
    }

    private(set) var trains: [Train] = []
    private var rng = SplitMix64(seed: 0x5B5B)
    private var manageTimer: Float = 0
    private var collected: [Int64: Float] = [:]
    private var clock: Float = 0
    private var rewards: [WorldReward] = []
    private var found = false
    /// Nearest train (for sound) and whether one is bearing down on the bird.
    private(set) var trainSound: (gain: Float, pan: Float) = (0, 0)
    private(set) var hornNow = false
    private(set) var tokensHere: [SIMD3<Float>] = []

    private static let token: MeshTemplate = {
        var m = MeshBuilder()
        // A coin standing on its edge (spun when drawn), with a bright rim.
        m.tube(SIMD3(0, 0, -0.06), SIMD3(0, 0, 0.06), r0: 0.55, r1: 0.55, sides: 14, SIMD3(1, 0.78, 0.2), cap: true)
        m.tube(SIMD3(0, 0, 0.06), SIMD3(0, 0, -0.06), r0: 0.55, r1: 0.55, sides: 14, SIMD3(1, 0.78, 0.2), cap: true)
        m.ellipsoid(.zero, SIMD3(0.3, 0.3, 0.08), SIMD3(1, 0.95, 0.6), rings: 3, sides: 8)
        return MeshTemplate(m)
    }()

    // MARK: Lines

    /// The tunnel segment under a point on a line, if there's tunnel there.
    private func tunnel(_ alongX: Bool, _ line: Int, _ a: Float) -> (CitySubway.Segment, Float)? {
        let G = CityLayout.pitch
        let k = Int(floor(a / G))
        let s = a - Float(k) * G
        guard let seg = alongX ? CitySubway.segment(alongX: true, k, line) : CitySubway.segment(alongX: false, line, k), seg.has(s) else { return nil }
        // Portals open onto the river: trains turn back well before the mouth.
        for st in seg.stubs where (st.portal1 && s > st.s1 - 14) || (st.portal0 && s < st.s0 + 14) { return nil }
        return (seg, s)
    }

    private func floorAt(_ alongX: Bool, _ line: Int, _ a: Float) -> Float? {
        guard let (seg, s) = tunnel(alongX, line, a) else { return nil }
        return seg.floor(s)
    }

    // MARK: Update

    func update(dt: Float, player: FlightModel, underground: Float) -> [HazardHit] {
        clock += dt
        let p = player.pos
        manageTimer -= dt
        if manageTimer <= 0 { manageTimer = 1.5; manage(p) }
        var hits: [HazardHit] = []
        var best: (Float, Float) = (0, 0)
        hornNow = false
        for t in trains {
            move(t, dt: dt)
            // Where the cars are.
            let l: Float = (t.alongX ? t.dir : -t.dir) * CitySubway.track
            for (k, car) in t.cars.enumerated() {
                let ac = t.a - t.dir * (Train.carLength / 2 + Float(k) * Train.carLength)
                let y = (floorAt(t.alongX, t.line, ac) ?? floorAt(t.alongX, t.line, t.a) ?? 0) + 0.15
                let c = t.alongX ? SIMD3(ac, y, Float(t.line) * CityLayout.pitch + l) : SIMD3(Float(t.line) * CityLayout.pitch + l, y, ac)
                car.simdPosition = c
                car.simdOrientation = yawQuat(t.alongX ? (t.dir > 0 ? -.pi / 2 : .pi / 2) : (t.dir > 0 ? .pi : 0))
                // Hit the bird?
                if simd_distance(c, p) < 14 {
                    let box = OBox(center: c + SIMD3(0, 2.1, 0), rot: car.simdOrientation, half: SIMD3(1.5, 1.7, Train.carLength / 2))
                    if let push = box.push(p, 1) {
                        let away = simd_normalize(push + SIMD3(0, 0.01, 0))
                        hits.append(HazardHit(impulse: away * 13 + (t.alongX ? SIMD3(t.dir, 0, 0) : SIMD3(0, 0, t.dir)) * t.speed * 0.6, coins: 3, kind: .wall))
                    }
                }
            }
            // Sound and the horn when the bird's in the tunnel ahead on this track.
            let front = t.alongX ? SIMD3(t.a, 0, Float(t.line) * CityLayout.pitch + l) : SIMD3(Float(t.line) * CityLayout.pitch + l, 0, t.a)
            let d = simd_length(SIMD2(front.x - p.x, front.z - p.z))
            if underground > 0.3 {
                let g = smoothstep(260, 15, d) * min(1, t.speed / 5 + 0.2)
                if g > best.0 { best = (g, 0) }
                let rel = ((t.alongX ? p.x : p.z) - t.a) * t.dir
                let lateral = abs((t.alongX ? p.z : p.x) - (t.alongX ? front.z : front.x))
                if rel > 0 && rel < 130 && lateral < 3.5 && t.speed > 4 { hornNow = true }
            }
        }
        trainSound = best
        updateTokens(p, underground: underground)
        if underground > 0.75 && !found {
            found = true
            rewards.append(WorldReward(id: "city.subway", title: "You found the subway!", coins: 60, once: true))
        }
        return hits
    }

    private func move(_ t: Train, dt: Float) {
        var target: Float = 17
        if t.dwell > 0 {
            t.dwell -= dt
            target = 0
            if t.dwell <= 0, t.speed < 0.2, tunnel(t.alongX, t.line, t.a + t.dir * 4) == nil {
                // End of the line: run back the other way.
                t.a -= t.dir * t.length
                t.dir = -t.dir
                t.lastStop = Int.min
            }
        } else {
            // The end of the tunnel ahead?
            var probe = t.a
            var endAt: Float?
            let reach = t.speed * t.speed / (2 * 1.2) + 20
            while (probe - t.a) * t.dir < reach {
                probe += t.dir * 3
                if tunnel(t.alongX, t.line, probe) == nil { endAt = probe - t.dir * 3; break }
            }
            if let e = endAt {
                let room = (e - t.a) * t.dir - 2
                target = min(target, sqrt(max(0, 2 * 1.2 * room)))
                if room < 0.6 && t.speed < 0.5 { t.dwell = 6; t.speed = 0 }
            }
            // Stations: stop with the middle of the train at the middle of the hall.
            let mid = t.a - t.dir * t.length / 2
            let G = CityLayout.pitch
            let k = Int(floor((mid + t.dir * 40) / G))
            for q in [k, k + Int(t.dir)] {
                guard q != t.lastStop else { continue }
                let seg = t.alongX ? CitySubway.segment(alongX: true, q, t.line) : CitySubway.segment(alongX: false, t.line, q)
                guard let seg, seg.station else { continue }
                let center = Float(q) * G + 60
                let dist = (center - mid) * t.dir
                if dist > -1.5 && dist < 140 {
                    target = min(target, sqrt(max(0, 2 * 1.1 * max(0, dist))))
                    if dist < 0.8 && t.speed < 0.6 { t.dwell = 7; t.lastStop = q; t.speed = 0 }
                }
                break
            }
        }
        t.speed += clamp(target - t.speed, -2.4 * dt, 1.5 * dt)
        t.speed = max(0, t.speed)
        t.a += t.dir * t.speed * dt
    }

    private func manage(_ p: SIMD3<Float>) {
        let G = CityLayout.pitch
        // Lines near the player.
        var lines: [(Bool, Int)] = []
        for i in Int(floor((p.x - 500) / G))...Int(ceil((p.x + 500) / G)) where CitySubway.lineX(i) { lines.append((false, i)) }
        for j in Int(floor((p.z - 500) / G))...Int(ceil((p.z + 500) / G)) where CitySubway.lineZ(j) { lines.append((true, j)) }
        trains.removeAll { t in
            let along = t.alongX ? p.x : p.z
            let gone = !lines.contains { $0 == (t.alongX, t.line) } || abs(t.a - along) > 1100
            if gone { t.node.removeFromParentNode() }
            return gone
        }
        for (alongX, line) in lines {
            for dir: Float in [1, -1] where !trains.contains(where: { $0.alongX == alongX && $0.line == line && $0.dir == dir }) {
                let along = alongX ? p.x : p.z
                // Somewhere with tunnel, a few hundred metres off.
                for _ in 0..<8 {
                    let a = along + rng.float(-650, 650)
                    guard tunnel(alongX, line, a) != nil, tunnel(alongX, line, a - dir * 60) != nil else { continue }
                    let t = Train(alongX: alongX, line: line, dir: dir, a: a, livery: fmodi(line, 3))
                    t.speed = rng.float(8, 16)
                    root.addChildNode(t.node)
                    trains.append(t)
                    break
                }
            }
        }
    }

    // MARK: Tokens

    private func updateTokens(_ p: SIMD3<Float>, underground: Float) {
        tokensHere.removeAll(keepingCapacity: true)
        guard underground > 0.05 || (CitySubway.nearLine(p.x, p.z) && p.y < CityLayout.ground(p.x, p.z) + 4) else { return }
        for seg in CitySubway.segments(near: p.x, p.z, radius: 120) {
            for k in 0..<4 {
                let s = 10 + Float(k) * 30
                guard seg.has(s) else { continue }
                var l = Float(k % 2 == 0 ? 1 : -1) * CitySubway.track
                var y = seg.floor(s) + 5.7
                if seg.station && CitySubway.hall.contains(s) { l = (k % 2 == 0 ? 1 : -1) * 10.3; y = seg.floor(s) + CitySubway.platformY + 2.3 }
                let id = Int64(ihash(seg.i * 4 + k, seg.j, seg.alongX ? 0x70C : 0x70D))
                if let t = collected[id], clock - t < 240 { continue }
                let at = seg.world(s, l, y)
                if simd_distance(at, p) < 2.4 {
                    collected[id] = clock
                    rewards.append(WorldReward(id: "city.token", title: "Subway token", coins: 4, once: false))
                    continue
                }
                tokensHere.append(at)
            }
        }
    }

    func draw(into glow: DynamicMesh, camera: SIMD3<Float>) {
        for t in tokensHere where simd_distance(t, camera) < 140 {
            glow.add(CitySubwayLife.token, trs(t + SIMD3(0, sin(clock * 2 + t.x) * 0.15, 0), yawQuat(clock * 2.5 + t.z)), tint: 1.3)
        }
    }

    func drainRewards() -> [WorldReward] { defer { rewards.removeAll() }; return rewards }
}
