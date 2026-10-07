import SceneKit
import simd

/// Elevated trains on the el avenues and boats on the river.
final class CityTransit {
    let root = SCNNode()

    // MARK: Trains

    final class Train {
        let node = SCNNode()
        var cars: [SCNNode] = []
        var line: Int
        var dir: Float
        /// Position of the front of the train along the line (world z).
        var z: Float
        var speed: Float
        var dwell: Float = 0
        var lastStation = Int.min
        static let carLength: Float = 17, gap: Float = 0.9
        static let count = 4
        var length: Float { Float(Train.count) * (Train.carLength + Train.gap) - Train.gap }
        var x: Float { Float(line) * CityLayout.pitch - 1.7 * dir }

        init(line: Int, dir: Float, z: Float, speed: Float, livery: Int) {
            self.line = line; self.dir = dir; self.z = z; self.speed = speed
            for k in 0..<Train.count {
                let n = SCNNode(geometry: CityTransit.carGeometry(front: k == 0, back: k == Train.count - 1, livery: livery))
                n.castsShadow = true
                node.addChildNode(n)
                cars.append(n)
            }
        }
    }

    private(set) var trains: [Train] = []
    private var boats: [Boat] = []
    private var rng = SplitMix64(seed: 0x7EA1)
    private var manageTimer: Float = 0
    /// Nearest train's distance and closing speed (for sound), and whether one is about to pass the player.
    private(set) var trainSound: (gain: Float, pan: Float) = (0, 0)
    private(set) var hornNow = false

    private static let carMaterial = WorldMaterials.finishes()

    static func carGeometry(front: Bool, back: Bool, livery: Int) -> SCNGeometry {
        var m = MeshBuilder()
        let L = Train.carLength, hw: Float = 1.45
        let silver = SIMD3<Float>(0.78, 0.8, 0.83)
        let stripe = [SIMD3<Float>(0.15, 0.35, 0.75), SIMD3(0.75, 0.15, 0.15), SIMD3(0.15, 0.6, 0.35)][livery % 3]
        let paint = SIMD2<Float>(1, 0), glass = SIMD2<Float>(2, 0), lit = SIMD2<Float>(4, 0)
        let z0 = -L / 2 + (front ? 0.8 : 0), z1 = L / 2 - (back ? 0.8 : 0)
        CityVehicles.chamferBox(&m, hx: hw, z0: z0, z1: z1, y0: 0.55, y1: 3.65, ch: 0.35, silver, uv: SIMD2(3, 0), top: SIMD3(0.55, 0.56, 0.58))
        // Stripe and the window band (lit inside), doors.
        for s: Float in [-1, 1] {
            let x = s * (hw + 0.01)
            func side(_ y0: Float, _ y1: Float, _ za: Float, _ zb: Float, _ c: SIMD3<Float>, _ uv: SIMD2<Float>) {
                m.quad(SIMD3(x, y0, za), SIMD3(x, y0, zb), SIMD3(x, y1, zb), SIMD3(x, y1, za), c, uv: uv, facing: SIMD3(s, 0, 0))
            }
            side(1.05, 1.35, z0 + 0.3, z1 - 0.3, stripe, paint)
            // Windows (lit inside) between the doors.
            var z = z0 + 2.6
            while z < z1 - 2 {
                side(0.75, 3.1, z - 0.7, z + 0.7, SIMD3(0.55, 0.57, 0.6), SIMD2(3, 0))
                side(1.75, 2.85, z - 0.45, z + 0.45, SIMD3(0.08, 0.1, 0.12), glass)
                let w0 = z + 0.95, w1 = min(z + 3.45, z1 - 0.9)
                if w1 > w0 + 0.4 { side(1.75, 2.85, w0, w1, SIMD3(0.62, 0.56, 0.44), lit) }
                z += 4.2
            }
        }
        if front || back {
            // A sloped nose with a windshield and lights.
            let zf: Float = front ? -L / 2 : L / 2
            let zi: Float = front ? z0 : z1
            let n: Float = front ? -1 : 1
            m.quad(SIMD3(-hw, 0.55, zi), SIMD3(hw, 0.55, zi), SIMD3(hw * 0.9, 1.6, zf), SIMD3(-hw * 0.9, 1.6, zf), silver, uv: SIMD2(3, 0), facing: SIMD3(0, -0.3, n))
            m.quad(SIMD3(-hw * 0.9, 1.6, zf), SIMD3(hw * 0.9, 1.6, zf), SIMD3(hw * 0.85, 3.2, zi), SIMD3(-hw * 0.85, 3.2, zi), SIMD3(0.06, 0.08, 0.1), uv: glass,
                   facing: SIMD3(0, 0.5, n))
            m.quad(SIMD3(-hw * 0.85, 3.2, zi), SIMD3(hw * 0.85, 3.2, zi), SIMD3(hw, 3.65, zi), SIMD3(-hw, 3.65, zi), silver, uv: SIMD2(3, 0), facing: SIMD3(0, 0.2, n))
            for s: Float in [-1, 1] {
                m.box(SIMD3(s * 0.9, 1.05, zf + n * 0.02), SIMD3(0.18, 0.08, 0.03), front ? SIMD3(1, 0.95, 0.8) : SIMD3(1, 0.12, 0.08), uv: lit)
            }
            // Side panels of the nose.
            for s: Float in [-1, 1] {
                let i = m.vertexCount
                let a = SIMD3(s * hw, 0.55, zi), b = SIMD3(s * hw, 3.65, zi), c = SIMD3(s * hw * 0.9, 1.6, zf)
                let nn = SIMD3<Float>(s, 0, 0)
                m.vertex(a, nn, silver, uv: SIMD2(3, 0)); m.vertex(b, nn, silver, uv: SIMD2(3, 0)); m.vertex(c, nn, silver, uv: SIMD2(3, 0))
                if s * n > 0 { m.tri(i, i + 1, i + 2) } else { m.tri(i, i + 2, i + 1) }
            }
        }
        // Bogies
        for zc in [z0 + 3, z1 - 3] {
            m.box(SIMD3(0, 0.35, zc), SIMD3(hw - 0.2, 0.25, 1.3), SIMD3(0.12, 0.12, 0.13), uv: SIMD2(0, 0))
        }
        // Pantograph-free roof units.
        m.box(SIMD3(0, 3.8, 0), SIMD3(0.8, 0.15, 3), SIMD3(0.5, 0.5, 0.52), uv: SIMD2(0, 0))
        let g = m.geometry()
        g.materials = [carMaterial]
        return g
    }

    private func stationCenter(_ z: Float) -> Float? {
        let G = CityLayout.pitch
        let b = Int(floor(z / G))
        return fmodi(b, 5) == 2 ? Float(b) * G + 60 : nil
    }

    func update(dt: Float, player: SIMD3<Float>, sound: SoundEngine?) {
        manageTimer -= dt
        if manageTimer <= 0 { manageTimer = 1; manageTrains(player) ; manageBoats(player) }
        var best: (Float, Float) = (0, 0)
        hornNow = false
        for t in trains {
            // Stop at stations so the middle of the train lines up with the platform.
            let G = CityLayout.pitch
            var target: Float = 19
            let mid = t.z - t.dir * t.length / 2
            let ahead = Int(floor((mid + t.dir * 40) / G))
            if t.dwell > 0 {
                t.dwell -= dt
                target = 0
            } else {
                for k in 0...3 {
                    let b = ahead + Int(t.dir) * k
                    guard fmodi(b, 5) == 2, b != t.lastStation, let c = stationCenter(Float(b) * G + 1) else { continue }
                    let dist = (c - mid) * t.dir
                    if dist > -2 && dist < 160 {
                        target = min(target, sqrt(max(0, 2 * 1.1 * max(0, dist))))
                        if dist < 0.8 && t.speed < 0.6 { t.dwell = 8; t.lastStation = b; target = 0 }
                    }
                    break
                }
            }
            t.speed += clamp(target - t.speed, -2.2 * dt, 1.3 * dt)
            t.speed = max(0, t.speed)
            t.z += t.dir * t.speed * dt
            for (k, car) in t.cars.enumerated() {
                let zc = t.z - t.dir * (Train.carLength / 2 + Float(k) * (Train.carLength + Train.gap))
                let y = CityTerrain.trackY(t.x, zc)
                let yf = CityTerrain.trackY(t.x, zc + t.dir * 6), yb = CityTerrain.trackY(t.x, zc - t.dir * 6)
                car.simdPosition = SIMD3(t.x, y, zc)
                let pitch = atan2(yf - yb, 12)
                car.simdOrientation = yawQuat(t.dir > 0 ? .pi : 0) * simd_quatf(angle: t.dir > 0 ? -pitch : pitch, axis: SIMD3(1, 0, 0))
            }
            let d = simd_distance(SIMD3(t.x, CityTerrain.trackY(t.x, mid), mid), player)
            let g = smoothstep(420, 25, d) * min(1, t.speed / 6 + 0.15)
            if g > best.0 { best = (g, clamp((t.x - player.x) / 60, -1, 1)) }
            // Horn when the bird is on the track ahead.
            let rel = (player.z - t.z) * t.dir
            if rel > 0 && rel < 90 && abs(player.x - t.x) < 6 && abs(player.y - CityTerrain.trackY(t.x, t.z) - 2) < 6 && t.speed > 5 { hornNow = true }
        }
        trainSound = best
        updateBoats(dt: dt)
    }

    private func manageTrains(_ p: SIMD3<Float>) {
        let G = CityLayout.pitch
        // El lines near the player.
        var lines: [Int] = []
        let i0 = Int(floor((p.x - 1600) / G)), i1 = Int(floor((p.x + 1600) / G))
        for i in i0...i1 where CityLayout.lineX(i).el { lines.append(i) }
        trains.removeAll { t in
            let gone = !lines.contains(t.line)
            if gone { t.node.removeFromParentNode() }
            return gone
        }
        for line in lines {
            for dir: Float in [1, -1] {
                let mine = trains.filter { $0.line == line && $0.dir == dir }
                // Recycle trains that got far behind: move them ahead.
                for t in mine where abs(t.z - p.z) > 1700 {
                    t.z = p.z + (t.z > p.z ? -1 : 1) * rng.float(900, 1400)
                    t.speed = 15; t.dwell = 0
                }
                if mine.count < 3 {
                    for k in mine.count..<3 {
                        let z = p.z + Float(k - 1) * 1100 + rng.float(-200, 200)
                        let t = Train(line: line, dir: dir, z: z, speed: rng.float(10, 18), livery: Int(rng.float(0, 2.99)))
                        root.addChildNode(t.node)
                        trains.append(t)
                    }
                }
            }
        }
    }

    /// Boxes for each train car near `p`.
    func trainSolids(near p: SIMD3<Float>, radius r: Float) -> [CitySolid] {
        var out: [CitySolid] = []
        for t in trains where abs(t.x - p.x) < r + 4 {
            for car in t.cars {
                let c = car.simdPosition
                guard abs(c.z - p.z) < r + 10 else { continue }
                out.append(.box(OBox(center: c + SIMD3(0, 2.1, 0), rot: car.simdOrientation, half: SIMD3(1.5, 1.6, Train.carLength / 2))))
            }
        }
        return out
    }

    // MARK: Boats

    final class Boat {
        let node: SCNNode
        var pos: SIMD2<Float>
        var dir: SIMD2<Float>
        var speed: Float
        var rock: Float
        init(node: SCNNode, pos: SIMD2<Float>, dir: SIMD2<Float>, speed: Float, rock: Float) {
            self.node = node; self.pos = pos; self.dir = dir; self.speed = speed; self.rock = rock
        }
    }

    private static func boatGeometry(_ kind: Int) -> SCNGeometry {
        var m = MeshBuilder()
        let paint = SIMD2<Float>(1, 0), glass = SIMD2<Float>(2, 0)
        switch kind {
        case 0:  // Tour boat: long white hull, glass-roofed cabin.
            CityVehicles.chamferBox(&m, hx: 2.6, z0: -9, z1: 9, y0: -0.6, y1: 1.2, ch: 1.6, SIMD3(0.95, 0.95, 0.94), uv: paint)
            m.box(SIMD3(0, 0.2, 0), SIMD3(2.62, 0.18, 8.0), SIMD3(0.12, 0.3, 0.55), uv: paint)
            CityVehicles.chamferBox(&m, hx: 2.2, z0: -6.5, z1: 6, y0: 1.2, y1: 3.0, ch: 0.8, SIMD3(0.12, 0.2, 0.28), uv: glass,
                                    top: SIMD3(0.75, 0.85, 0.9))
        case 1:  // Tug: red and black with a wheelhouse and a funnel.
            CityVehicles.chamferBox(&m, hx: 2.4, z0: -5, z1: 5, y0: -0.6, y1: 1.4, ch: 1.4, SIMD3(0.65, 0.12, 0.1), uv: paint, top: SIMD3(0.4, 0.38, 0.35))
            m.box(SIMD3(0, -0.2, 0), SIMD3(2.42, 0.3, 4.7), SIMD3(0.08, 0.08, 0.09), uv: paint)
            m.box(SIMD3(0, 2.4, -0.5), SIMD3(1.4, 1.0, 1.6), SIMD3(0.92, 0.9, 0.85), uv: paint)
            m.box(SIMD3(0, 2.7, -2.1), SIMD3(1.3, 0.35, 0.02), SIMD3(0.08, 0.1, 0.12), uv: glass)
            m.cylinder(SIMD3(0, 3.2, 1.6), r0: 0.45, r1: 0.45, y0: 0, y1: 1.8, sides: 8, SIMD3(0.1, 0.1, 0.1), uv: paint)
            for k in 0..<6 { m.ellipsoid(SIMD3(Float(k % 2 == 0 ? 2.5 : -2.5), 0.6, Float(k / 2) * 3 - 3), SIMD3(0.2, 0.35, 0.35), SIMD3(0.1, 0.1, 0.1)) }
        default:  // Speedboat
            CityVehicles.chamferBox(&m, hx: 1.2, z0: -3.2, z1: 3.2, y0: -0.3, y1: 0.8, ch: 1.0, SIMD3(0.96, 0.96, 0.96), uv: paint)
            m.box(SIMD3(0, 0.45, 0), SIMD3(1.22, 0.12, 2.8), SIMD3(0.85, 0.2, 0.15), uv: paint)
            m.quad(SIMD3(-1.0, 0.8, -0.8), SIMD3(1.0, 0.8, -0.8), SIMD3(0.9, 1.4, -0.2), SIMD3(-0.9, 1.4, -0.2), SIMD3(0.1, 0.12, 0.15),
                   uv: glass, facing: SIMD3(0, 0.6, -1))
        }
        // Foam: a white V behind the stern and along the bow.
        let len: Float = kind == 0 ? 9 : (kind == 1 ? 5 : 3.2)
        let w: Float = kind == 2 ? 1.2 : 2.5
        for s: Float in [-1, 1] {
            m.quad(SIMD3(s * w * 0.6, 0.05, len), SIMD3(s * (w * 0.6 + 0.6), 0.05, len), SIMD3(s * (w + 5), 0.05, len + 16),
                   SIMD3(s * (w + 3.8), 0.05, len + 16), SIMD3(0.9, 0.93, 0.95), facing: kUp)
        }
        m.quad(SIMD3(-w * 0.5, 0.04, len), SIMD3(w * 0.5, 0.04, len), SIMD3(w * 0.9, 0.04, len + 9), SIMD3(-w * 0.9, 0.04, len + 9),
               SIMD3(0.82, 0.88, 0.9), facing: kUp)
        let g = m.geometry()
        g.materials = [carMaterial]
        return g
    }

    private func manageBoats(_ p: SIMD3<Float>) {
        boats.removeAll { b in
            let gone = simd_distance(b.pos, SIMD2(p.x, p.z)) > 1100
            if gone { b.node.removeFromParentNode() }
            return gone
        }
        guard boats.count < 4 else { return }
        // Find the river near the player.
        for _ in 0..<6 {
            let a = rng.float(0, 6.28), r = rng.float(150, 800)
            var q = SIMD2(p.x + cos(a) * r, p.z + sin(a) * r)
            q = recenter(q)
            guard CityLayout.riverDistance(q.x, q.y) < 6 else { continue }
            if boats.contains(where: { simd_distance($0.pos, q) < 120 }) { continue }
            let kind = rng.float() < 0.45 ? 0 : (rng.float() < 0.5 ? 1 : 2)
            let node = SCNNode(geometry: CityTransit.boatGeometry(kind))
            node.castsShadow = true
            root.addChildNode(node)
            var d = tangent(q, prefer: SIMD2(1, 0))
            if rng.float() < 0.5 { d = -d }
            boats.append(Boat(node: node, pos: q, dir: d, speed: kind == 2 ? rng.float(10, 14) : rng.float(4, 6.5), rock: rng.float(0, 6)))
            break
        }
    }

    private func gradient(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let e: Float = 3
        return SIMD2(CityLayout.riverField(p.x + e, p.y) - CityLayout.riverField(p.x - e, p.y),
                     CityLayout.riverField(p.x, p.y + e) - CityLayout.riverField(p.x, p.y - e)) / (2 * e)
    }

    private func recenter(_ p: SIMD2<Float>) -> SIMD2<Float> {
        var q = p
        for _ in 0..<6 {
            let f = CityLayout.riverField(q.x, q.y), g = gradient(q)
            let gg = simd_length_squared(g)
            guard gg > 1e-14 else { break }
            var step = g * (f / gg)
            if simd_length(step) > 60 { step = simd_normalize(step) * 60 }
            q -= step
        }
        return q
    }

    private func tangent(_ p: SIMD2<Float>, prefer: SIMD2<Float>) -> SIMD2<Float> {
        let g = gradient(p)
        var t = SIMD2(-g.y, g.x)
        let l = simd_length(t)
        guard l > 1e-9 else { return prefer }
        t /= l
        return simd_dot(t, prefer) < 0 ? -t : t
    }

    private func updateBoats(dt: Float) {
        for b in boats {
            b.dir = tangent(b.pos, prefer: b.dir)
            b.pos += b.dir * b.speed * dt
            // Stay in the middle of the river.
            let c = recenter(b.pos)
            b.pos += (c - b.pos) * approach(0.5, dt)
            b.rock += dt
            b.node.simdPosition = SIMD3(b.pos.x, 0.15 + 0.08 * sin(b.rock * 1.7), b.pos.y)
            b.node.simdOrientation = yawQuat(atan2(-b.dir.x, -b.dir.y)) * simd_quatf(angle: 0.02 * sin(b.rock * 1.3), axis: SIMD3(0, 0, 1))
        }
    }
}
