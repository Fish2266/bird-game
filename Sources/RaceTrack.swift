import SceneKit
import simd

/// A fixed race course for one world: a smooth path through the sky (or the tunnels), gates to fly
/// through, boost rings and world-themed obstacles. Built deterministically so every player (and every
/// attempt at a best time) races the same course.
final class RaceTrack {
    struct Gate {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
        var radius: Float
        /// Arc length along the path.
        var s: Float
        var finish: Bool
        var node: SCNNode
        var materials: [SCNMaterial]
    }

    enum GateState { case upcoming, next, passed, missed }

    let mode: GameMode
    let world: WorldID
    let root = SCNNode()
    private(set) var path: [SIMD3<Float>] = []
    private(set) var arc: [Float] = []
    private(set) var gates: [Gate] = []
    private(set) var obstacles: [Obstacle] = []
    private(set) var boosts: [BoostRing] = []
    private(set) var start = SIMD3<Float>(0, 0, 0)
    private(set) var startYaw: Float = 0
    /// How far from the path you can stray before you're sent back.
    let corridor: Float
    var length: Float { arc.last ?? 0 }

    /// Gold, silver and bronze target times (seconds) for this course.
    var medalTimes: [Double] {
        let pace: Float = caves ? 0.8 : 1
        return [24, 20.5, 17].map { Double(length / ($0 * pace)).rounded() }
    }
    private var ribbonMat: SCNMaterial?
    private let caves: Bool
    private var pulsing = -1

    // Gate looks
    private static let ringNext = RaceTrack.ringMaterial(glow: 1.0, color: rgb(1, 0.78, 0.2))
    private static let ringIdle = RaceTrack.ringMaterial(glow: 0.3, color: rgb(1, 0.78, 0.2))
    private static let ringDone = RaceTrack.ringMaterial(glow: 0.6, color: rgb(0.35, 0.9, 0.45))
    private static let ringMiss = RaceTrack.ringMaterial(glow: 0.8, color: rgb(0.95, 0.25, 0.2))

    init(mode: GameMode, world: WorldID, spawn: (SIMD3<Float>, Float), terrain: WorldTerrain) {
        self.mode = mode
        self.world = world
        caves = world == .caves
        // Ring races have no road to follow, so you can cut corners toward the rings you see.
        corridor = caves ? 32 : (mode == .ringRace ? 110 : 48)
        var rng = SplitMix64(seed: 0xB1_2D00 &+ UInt64(mode == .ringRace ? 1 : 2) &* 7919 &+ UInt64(world.hashValueStable))

        // 1. Path
        let length: Float = mode == .ringRace ? 2700 : 3000
        if let cave = terrain as? CaveTerrain {
            path = RaceTrack.cavePath(cave, from: spawn.0, yaw: spawn.1, length: length)
        } else {
            path = RaceTrack.openPath(world: world, from: spawn.0, yaw: spawn.1, length: length, rng: &rng,
                                      clearance: mode == .ringRace ? 26 : 20)
        }
        arc = [0]
        for i in 1..<path.count { arc.append(arc[i - 1] + simd_distance(path[i - 1], path[i])) }

        // 2. Obstacles go between the gates; barns pull the path down before anything is placed on it.
        var plans = RaceTrack.planObstacles(world: world, mode: mode, gates: RaceTrack.gatePositions(mode, arc.last ?? 0), rng: &rng)
        if world == .dogfight { dipForBarns(&plans) }

        let startTangent = tangent(at: 12)
        start = path[0]
        startYaw = atan2(-startTangent.x, -startTangent.z)

        // 3. Gates
        buildGates(terrain: terrain)
        // 4. Obstacles & boosts
        buildObstacles(plans, terrain: terrain)
        buildBoosts()
        // 5. Start / finish dressing and the sky road
        buildStartArch()
        if mode == .speedRace { buildRibbon() }
        refresh(next: 0, states: [:])
    }

    // MARK: Path queries

    func index(atArc s: Float) -> Int {
        var lo = 0, hi = arc.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if arc[mid] <= s { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func point(atArc s: Float) -> SIMD3<Float> {
        let i = index(atArc: clamp(s, 0, length))
        guard i + 1 < path.count else { return path[path.count - 1] }
        let t = (s - arc[i]) / max(arc[i + 1] - arc[i], 1e-3)
        return path[i] + (path[i + 1] - path[i]) * clamp(t, 0, 1)
    }

    func tangent(at s: Float) -> SIMD3<Float> {
        let a = point(atArc: max(0, s - 6)), b = point(atArc: min(length, s + 6))
        let d = b - a
        return simd_length(d) > 1e-3 ? simd_normalize(d) : SIMD3(0, 0, -1)
    }

    /// Nearest point on the path to `p`, searching around `hint` (the index found last frame).
    func nearest(_ p: SIMD3<Float>, hint: inout Int) -> (s: Float, distance: Float) {
        let lo = max(0, hint - 30), hi = min(path.count - 2, hint + 60)
        var best = (Float.infinity, hint, Float(0))
        for i in lo...max(lo, hi) {
            let a = path[i], b = path[i + 1]
            let ab = b - a
            let t = clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0, 1)
            let d = simd_distance(p, a + ab * t)
            if d < best.0 { best = (d, i, t) }
        }
        hint = best.1
        let s = arc[best.1] + (arc[min(best.1 + 1, arc.count - 1)] - arc[best.1]) * best.2
        return (s, best.0)
    }

    /// Where player `slot` waits before the start: rows of three behind the start line.
    func gridPose(slot: Int) -> (SIMD3<Float>, Float) {
        let row = slot / 3, col = slot % 3
        let t = tangent(at: 0)
        let f = PathFrame(start, t)
        let lateral: Float = (Float(col) - 1) * (caves ? 3.5 : 7)
        var p = f.at(lateral, -10 - Float(row) * (caves ? 8 : 9), 0)
        if caves, let cave = TerrainShape.active as? CaveTerrain {
            let s = cave.sample(p.x, p.z)
            if s.open < 0.3 { p = start - f.fwd * (10 + Float(slot) * 5) }
        }
        return (p, atan2(-f.fwd.x, -f.fwd.z))
    }

    /// Pose to put a bird back on the course (after straying too far).
    func resetPose(atArc s: Float) -> (SIMD3<Float>, Float) {
        let p = point(atArc: s)
        let t = tangent(at: s)
        return (p, atan2(-t.x, -t.z))
    }

    // MARK: Per-frame

    func update(time: Float, dt: Float, near p: SIMD3<Float>) {
        for o in obstacles where simd_distance(o.center, p) < o.reach + 400 { o.update(time: time) }
        for b in boosts { b.update(time: time, dt: dt) }
        if let m = ribbonMat {
            // Chevrons crawl forward along the road.
            let r = SCNMatrix4MakeTranslation(0, CGFloat(-time * 0.9), 0)
            m.diffuse.contentsTransform = r
            m.emission.contentsTransform = r
        }
        if gates.indices.contains(pulsing) {
            gates[pulsing].node.simdScale = SIMD3(repeating: 1 + 0.05 * sin(time * 6))
        }
    }

    /// Push-out from any obstacle the bird is touching.
    func collide(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for o in obstacles where simd_distance(o.center, p) < o.reach {
            if let v = o.push(p, radius: radius, time: time) { return v }
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        for o in obstacles where simd_distance(o.center, p) < o.reach + 40 {
            if let w = o.warning(p, time: time) { return w }
        }
        return nil
    }

    /// Recolor gates: the next one glows, passed ones turn green, missed ones red.
    func refresh(next: Int, states: [Int: GateState]) {
        pulsing = -1
        for (i, g) in gates.enumerated() {
            let st = states[i] ?? (i == next ? .next : (i < next ? .passed : .upcoming))
            if st == .next { pulsing = i } else { g.node.simdScale = SIMD3(repeating: 1) }
            let m: SCNMaterial
            switch st {
            case .next: m = g.finish ? RaceTrack.ringMaterial(glow: 1.2, color: .white) : RaceTrack.ringNext
            case .passed: m = RaceTrack.ringDone
            case .missed: m = RaceTrack.ringMiss
            case .upcoming: m = RaceTrack.ringIdle
            }
            for mat in g.materials { mat.emission.contents = m.emission.contents; mat.diffuse.contents = m.diffuse.contents }
            g.node.opacity = st == .passed || st == .missed ? 0.35 : 1
        }
    }

    // MARK: Generation — open worlds

    private static func openPath(world: WorldID, from spawn: SIMD3<Float>, yaw: Float, length: Float,
                                 rng: inout SplitMix64, clearance: Float) -> [SIMD3<Float>] {
        // Control points: a winding line that prefers valleys (so you thread between mountains), with
        // bends that change every few points and never cross back over itself.
        var p = SIMD2(spawn.x, spawn.z)
        var heading = SIMD2(-sin(yaw), -cos(yaw))
        var ctrl: [SIMD2<Float>] = [p - heading * 60, p]
        let step: Float = 115
        var bend = rng.float(-0.3, 0.3)
        var travelled: Float = 0
        /// Ground height score for a leg (higher = better): valleys between the peaks, lava in the volcano.
        func legScore(_ from: SIMD2<Float>, _ to: SIMD2<Float>) -> Float {
            var hmax: Float = -1e9, lava: Float = 0
            for sIdx in 1...6 {
                let x = from + (to - from) * (Float(sIdx) / 6)
                hmax = max(hmax, TerrainShape.ground(x.x, x.y))
                if TerrainShape.height(x.x, x.y) < 0 { lava += 1 }
            }
            switch world {
            // Rolling hills and valleys between the peaks, not open sea or summits.
            case .meadow: return -abs(hmax - 70) * 0.012
            case .volcano: return lava * 0.08 - hmax * 0.006
            default: return -hmax * 0.004
            }
        }
        func rotate(_ v: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
            SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
        }
        while travelled < length + step * 2 {
            if rng.float() < 0.35 { bend = rng.float(-0.42, 0.42) }
            var best = SIMD2<Float>(0, 0), bestDir = heading, bestScore = -Float.infinity
            for k in -6...6 {
                let a = bend + Float(k) * 0.13
                let d = rotate(heading, a)
                let q = p + d * step
                var score = -abs(a - bend) * 1.0 + rng.float(0, 0.25) + legScore(p, q)
                // Look one leg further so the course doesn't walk into a dead end of mountains.
                var ahead = -Float.infinity
                for k2 in -2...2 { ahead = max(ahead, legScore(q, q + rotate(d, Float(k2) * 0.3) * step)) }
                score += ahead * 0.7
                for c in ctrl.dropLast(3) {
                    let dd = simd_distance(c, q)
                    if dd < 220 { score -= (220 - dd) / 30 }
                }
                if score > bestScore { bestScore = score; best = q; bestDir = d }
            }
            p = best; heading = bestDir
            ctrl.append(p)
            travelled += step
        }
        ctrl.append(p + heading * step)

        // Dense Catmull-Rom samples every ~6 m, starting at the spawn.
        var flat: [SIMD2<Float>] = []
        for i in 1..<(ctrl.count - 2) {
            let p0 = ctrl[i - 1], p1 = ctrl[i], p2 = ctrl[i + 1], p3 = ctrl[i + 2]
            let n = max(2, Int(simd_distance(p1, p2) / 6))
            for k in 0..<n {
                let t = Float(k) / Float(n)
                let t2 = t * t, t3 = t2 * t
                // Catmull-Rom basis weights.
                let w0: Float = -t3 + 2 * t2 - t
                let w1: Float = 3 * t3 - 5 * t2 + 2
                let w2: Float = -3 * t3 + 4 * t2 + t
                let w3: Float = t3 - t2
                var q: SIMD2<Float> = p0 * w0
                q += p1 * w1
                q += p2 * w2
                q += p3 * w3
                flat.append(q * 0.5)
            }
        }
        // Trim to length.
        var out: [SIMD2<Float>] = [flat[0]]
        var total: Float = 0
        for i in 1..<flat.count {
            total += simd_distance(flat[i - 1], flat[i])
            out.append(flat[i])
            if total > length { break }
        }

        // Heights: clear the ground (sampled across the path's width) with a limited climb/descent rate,
        // plus a gentle swell so it isn't a flat line.
        let n = out.count
        var floorY = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let c = out[i]
            var g = TerrainShape.ground(c.x, c.y)
            for (dx, dz) in [(12, 0), (-12, 0), (0, 12), (0, -12), (8, 8), (-8, -8)] as [(Float, Float)] {
                g = max(g, TerrainShape.ground(c.x + dx, c.y + dz))
            }
            let swell = 6 * (1 + sin(Float(i) * 6 / 170)) + (world == .dogfight ? 14 * max(0, sin(Float(i) * 6 / 400)) : 0)
            floorY[i] = g + clearance + swell
        }
        var y = floorY
        y[0] = max(y[0], spawn.y)
        let slope: Float = 0.42 * 6
        for i in 1..<n { y[i] = max(y[i], y[i - 1] - slope) }
        for i in stride(from: n - 2, through: 0, by: -1) { y[i] = max(y[i], y[i + 1] - slope) }
        // Smooth, never dipping under the floor.
        for _ in 0..<3 {
            var s = y
            for i in 2..<(n - 2) { s[i] = max((y[i - 2] + y[i - 1] + y[i] + y[i + 1] + y[i + 2]) / 5, floorY[i] - 3) }
            y = s
        }
        return (0..<n).map { SIMD3(out[$0].x, y[$0], out[$0].y) }
    }

    // MARK: Generation — caves

    private static func cavePath(_ cave: CaveTerrain, from spawn: SIMD3<Float>, yaw: Float, length: Float) -> [SIMD3<Float>] {
        var p = cave.recenter(SIMD2(spawn.x, spawn.z))
        var d = SIMD2(-sin(yaw), -cos(yaw))
        var pts: [SIMD3<Float>] = []
        var travelled: Float = 0, sinceSample: Float = 99
        while travelled < length {
            if sinceSample >= 6 {
                let s = cave.sample(p.x, p.y)
                let mid = (s.floor + s.ceiling) * 0.5
                // Loop closed on itself? Stop there (the tunnel network is made of loops).
                if travelled > 600, let first = pts.first, simd_distance(SIMD2(first.x, first.z), p) < 25 { break }
                pts.append(SIMD3(p.x, mid, p.y))
                sinceSample = 0
            }
            d = cave.tangent(p.x, p.y, prefer: d)
            p = cave.recenter(p + d * 3)
            travelled += 3
            sinceSample += 3
        }
        // Smooth heights (the mid line can jump where the floor has bumps).
        var y = pts.map(\.y)
        for _ in 0..<4 {
            var s = y
            for i in 1..<(y.count - 1) { s[i] = (y[i - 1] + y[i] * 2 + y[i + 1]) / 4 }
            y = s
        }
        for i in pts.indices {
            let sm = cave.sample(pts[i].x, pts[i].z)
            pts[i].y = clamp(y[i], sm.floor + 2.5, sm.ceiling - 2.5)
        }
        return pts
    }

    // MARK: Gates

    private static func ringMaterial(glow: CGFloat, color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.6
        m.roughness.contents = 0.3
        m.emission.contents = color.blended(withFraction: 1 - glow, of: .black) ?? color
        return m
    }

    /// Opening radius at arc position `s`: fits the tunnel in the caves.
    private func openingRadius(at s: Float, terrain: WorldTerrain, open: Float) -> Float {
        guard let cave = terrain as? CaveTerrain else { return open }
        let p = point(atArc: s)
        let sm = cave.sample(p.x, p.z)
        let g = simd_length(cave.gradient(p.x, p.z))
        let halfWidth = g > 1e-6 ? sm.w / g : 20
        return clamp(min(halfWidth * 0.6, (sm.ceiling - sm.floor) * 0.4), 3.4, open)
    }

    /// Arc positions of the gates: 16 rings, or a checkpoint every ~420 m; the last one is the finish.
    private static func gatePositions(_ mode: GameMode, _ L: Float) -> [Float] {
        let n = mode == .ringRace ? 16 : max(4, Int(L / 420))
        return (0..<n).map { k in L * Float(k + 1) / Float(n) - (k == n - 1 ? 4 : 0) }
    }

    private func buildGates(terrain: WorldTerrain) {
        let positions = RaceTrack.gatePositions(mode, length)
        for (i, s) in positions.enumerated() {
            let finish = i == positions.count - 1
            let c = point(atArc: s)
            let n = tangent(at: s)
            if mode == .ringRace {
                let r = openingRadius(at: s, terrain: terrain, open: finish ? 10 : 7.5)
                let torus = SCNTorus(ringRadius: CGFloat(r), pipeRadius: CGFloat(finish ? 0.8 : 0.55))
                torus.ringSegmentCount = 48
                torus.pipeSegmentCount = 12
                let m = RaceTrack.ringMaterial(glow: 0.3, color: rgb(1, 0.78, 0.2))
                torus.materials = [m]
                let node = SCNNode(geometry: torus)
                node.simdPosition = c
                node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: n)
                node.castsShadow = false
                if finish {
                    let flag = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(r) + 1.2, pipeRadius: 0.3))
                    flag.geometry?.materials = [glowMat(.white, 1.6)]
                    node.addChildNode(flag)
                }
                root.addChildNode(node)
                gates.append(Gate(center: c, normal: n, radius: r, s: s, finish: finish, node: node, materials: [m]))
            } else {
                let r = openingRadius(at: s, terrain: terrain, open: 13)
                let (node, mats) = RaceTrack.arch(center: c, tangent: n, halfWidth: r, finish: finish)
                root.addChildNode(node)
                gates.append(Gate(center: c, normal: n, radius: r, s: s, finish: finish, node: node, materials: mats))
            }
        }
    }

    /// A checkpoint hoop: a big glowing ring with running lights, facing along the course. Start and finish
    /// hoops are checkered and carry a banner above. Returns the node and the materials to recolor.
    private static func arch(center: SIMD3<Float>, tangent: SIMD3<Float>, halfWidth r: Float, finish: Bool, start: Bool = false) -> (SCNNode, [SCNMaterial]) {
        let node = SCNNode()
        let ring = SCNNode()
        ring.simdPosition = center
        ring.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(tangent))
        node.addChildNode(ring)
        let special = finish || start
        let glow = RaceTrack.ringMaterial(glow: 0.3, color: rgb(0.3, 0.85, 1))
        let torus = SCNTorus(ringRadius: CGFloat(r), pipeRadius: CGFloat(special ? 1.1 : 0.75))
        torus.ringSegmentCount = 64
        torus.pipeSegmentCount = 14
        if special {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = RaceTrack.checker
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(max(8, r * 1.2)), 2, 1)
            m.emission.contents = NSColor(white: 0.25, alpha: 1)
            m.roughness.contents = 0.5
            torus.materials = [m]
            // A thin glowing inner rim that takes the gate colors.
            let rim = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(r - 1.3), pipeRadius: 0.3))
            rim.geometry?.materials = [glow]
            ring.addChildNode(rim)
        } else {
            torus.materials = [glow]
        }
        ring.addChildNode(SCNNode(geometry: torus))
        // Running lights around the hoop.
        let lamp = glowMat(.white, 2.5)
        let n = special ? 12 : 8
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            let l = SCNNode(geometry: SCNSphere(radius: special ? 0.55 : 0.45))
            l.geometry?.materials = [lamp]
            l.simdPosition = SIMD3(cos(a) * r, 0, sin(a) * r)
            ring.addChildNode(l)
        }
        if special {
            let f = PathFrame(center, tangent)
            let label = SCNNode(geometry: SCNPlane(width: CGFloat(max(9, r * 0.9)), height: CGFloat(max(9, r * 0.9)) * 104 / 480))
            let lm = SCNMaterial()
            lm.lightingModel = .constant
            lm.diffuse.contents = RaceTrack.banner(finish ? "FINISH" : "START")
            lm.isDoubleSided = true
            label.geometry?.materials = [lm]
            label.simdPosition = center + SIMD3(0, r + 2.8, 0)
            label.simdOrientation = f.rot
            node.addChildNode(label)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = false }
        return (node, [glow])
    }

    static let checker: CGImage = makeImage(width: 64, height: 16) { x, y in
        let on = ((x / 8) + (y / 8)) % 2 == 0
        return on ? SIMD4(0.1, 0.1, 0.1, 1) : SIMD4(1, 1, 1, 1)
    }

    static func banner(_ text: String) -> NSImage {
        NSImage(size: NSSize(width: 480, height: 104), flipped: false) { r in
            NSColor(white: 0.08, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: Wii.font(64, bold: true), .foregroundColor: NSColor.white, .paragraphStyle: para]
            (text as NSString).draw(in: r.offsetBy(dx: 0, dy: -12), withAttributes: attrs)
            return true
        }
    }

    private func buildStartArch() {
        let t = tangent(at: 0)
        let r: Float = caves ? max(4, (gates.first?.radius ?? 8) * 0.9) : 14
        // Just ahead of the grid so everyone flies through it at GO.
        let (node, _) = RaceTrack.arch(center: point(atArc: 6), tangent: t, halfWidth: r, finish: false, start: true)
        root.addChildNode(node)
    }

    // MARK: Obstacles

    private enum Kind { case stacks, turbine, arch, lava, spires, crusher, crystals, barn, farmMill, balloons, silos }

    private struct Plan { var kind: Kind; var s: Float }

    private static func planObstacles(world: WorldID, mode: GameMode, gates: [Float], rng: inout SplitMix64) -> [Plan] {
        let cycle: [Kind]
        switch world {
        case .meadow: cycle = [.turbine, .stacks, .arch, .turbine, .stacks]
        case .volcano: cycle = [.lava, .spires, .lava, .spires]
        case .caves: cycle = [.crusher, .crystals, .crusher, .crystals]
        case .dogfight: cycle = [.barn, .farmMill, .balloons, .silos, .farmMill, .balloons]
        }
        var plans: [Plan] = []
        var k = world == .dogfight ? 0 : Int(rng.float(0, Float(cycle.count)))
        // Speed race: two obstacles between each pair of checkpoints. Ring race: one between every other pair of rings.
        var prev: Float = 0
        for (i, g) in gates.enumerated() {
            defer { prev = g }
            if mode == .speedRace {
                for f: Float in [0.36, 0.7] {
                    guard i > 0 || f > 0.5 else { continue }
                    plans.append(Plan(kind: cycle[k % cycle.count], s: prev + (g - prev) * f)); k += 1
                }
            } else if i % 2 == 1 && i < gates.count - 1 {
                plans.append(Plan(kind: cycle[k % cycle.count], s: (prev + g) * 0.5)); k += 1
            }
        }
        return plans
    }

    /// Barns sit on the ground: bring the path down to fly through the doors (dogfight farmland is flat).
    private func dipForBarns(_ plans: inout [Plan]) {
        for (pi, plan) in plans.enumerated() where plan.kind == .barn {
            // Slide to a flat spot nearby.
            var bestS = plan.s, bestFlat = Float.infinity
            for ds in stride(from: Float(-60), through: 60, by: 10) {
                let c = point(atArc: plan.s + ds)
                var lo: Float = 1e9, hi: Float = -1e9
                for (dx, dz) in [(0, 0), (20, 0), (-20, 0), (0, 20), (0, -20), (14, 14), (-14, -14)] as [(Float, Float)] {
                    let g = TerrainShape.ground(c.x + dx, c.z + dz)
                    lo = min(lo, g); hi = max(hi, g)
                }
                if hi - lo < bestFlat { bestFlat = hi - lo; bestS = plan.s + ds }
            }
            guard bestFlat < 4 else { plans[pi].kind = .farmMill; continue }
            plans[pi].s = bestS
            let c = point(atArc: bestS)
            let floorY = TerrainShape.ground(c.x, c.z) + Barn.doorH * 0.5
            let inner: Float = Barn.length / 2 + 18, outer: Float = inner + 110
            for i in path.indices {
                let d = abs(arc[i] - bestS)
                guard d < outer else { continue }
                let t = d < inner ? 1 : smoothstep(outer, inner, d)
                path[i].y = lerp(path[i].y, floorY, t)
            }
        }
        arc = [0]
        for i in 1..<path.count { arc.append(arc[i - 1] + simd_distance(path[i - 1], path[i])) }
    }

    private func buildObstacles(_ plans: [Plan], terrain: WorldTerrain) {
        for plan in plans {
            let c = point(atArc: plan.s)
            let f = PathFrame(c, tangent(at: plan.s))
            // High above the ground, rock obstacles float instead of rising from it.
            let floating = !caves && c.y - TerrainShape.ground(c.x, c.z) > 55
            let o: Obstacle
            switch plan.kind {
            case .stacks: o = Pillars(style: .seaStack, frame: f, top: c.y + 22, floating: floating)
            case .spires: o = Pillars(style: .spire, frame: f, radius: 4.6, top: c.y + 16, floating: floating)
            case .silos: o = Pillars(style: .silo, frame: f, count: 3, spacing: 30, offset: 6, radius: 4, top: c.y + 6)
            case .crystals: o = Pillars(style: .crystal, frame: f, count: 3, spacing: 22, offset: 2.5, radius: 2.2, top: c.y,
                                        ceiling: { terrain.ceiling($0, $1) })
            case .turbine: o = Windmill(style: .turbine, frame: f, length: 13, phase: plan.s)
            case .farmMill: o = Windmill(style: .farm, frame: f, length: 12, phase: plan.s)
            case .arch: o = StoneArch(frame: f, floating: floating)
            case .lava: o = LavaColumns(frame: f, top: c.y + 25)
            case .crusher: o = Crushers(frame: f, terrain: terrain)
            case .barn: o = Barn(frame: f)
            case .balloons: o = Balloons(frame: f, pathY: c.y)
            }
            obstacles.append(o)
            root.addChildNode(o.node)
        }
    }

    private func buildBoosts() {
        var s: Float = 180
        while s < length - 150 {
            let tooClose = gates.contains { abs($0.s - s) < 35 } ||
                obstacles.contains { simd_distance($0.center, point(atArc: s)) < 70 }
            if !tooClose {
                let c = point(atArc: s)
                let r: Float = caves ? min(4, (gates.first?.radius ?? 5)) : 5.5
                let b = BoostRing(center: c, normal: tangent(at: s), radius: r)
                boosts.append(b)
                root.addChildNode(b.node)
                s += mode == .speedRace ? 330 : 480
            } else {
                s += 40
            }
        }
    }

    // MARK: Sky road

    private func buildRibbon() {
        var m = MeshBuilder()
        let w: Float = caves ? 3.5 : 6
        let drop: Float = caves ? 2.2 : 3.5
        for i in path.indices {
            let t = simd_normalize(path[min(i + 1, path.count - 1)] - path[max(i - 1, 0)])
            var side = simd_cross(t, kUp)
            side = simd_length(side) > 1e-3 ? simd_normalize(side) : SIMD3(1, 0, 0)
            let c = path[i] - SIMD3(0, drop, 0)
            let v = arc[i] / 10
            m.vertex(c - side * w, kUp, SIMD3(1, 1, 1), uv: SIMD2(0, v))
            m.vertex(c + side * w, kUp, SIMD3(1, 1, 1), uv: SIMD2(1, v))
        }
        for i in 0..<UInt32(path.count - 1) {
            let a = i * 2, b = a + 1, c = a + 2, d = a + 3
            m.tri(a, c, b); m.tri(b, c, d)
        }
        let g = m.geometry()
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        let tex = RaceTrack.chevrons(world: world)
        mat.diffuse.contents = tex
        mat.diffuse.wrapS = .clamp
        mat.diffuse.wrapT = .repeat
        mat.diffuse.mipFilter = .linear
        mat.emission.contents = tex
        mat.emission.wrapT = .repeat
        mat.emission.intensity = 0.6
        mat.isDoubleSided = true
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false
        mat.transparency = 0.85
        g.materials = [mat]
        let node = SCNNode(geometry: g)
        node.castsShadow = false
        node.renderingOrder = 10
        root.addChildNode(node)
        ribbonMat = mat
    }

    /// Chevron strip texture (arrows point toward +v, i.e. along the course).
    private static func chevrons(world: WorldID) -> CGImage {
        let tint: SIMD3<Float>
        switch world {
        case .volcano: tint = SIMD3(1, 0.7, 0.3)
        case .caves: tint = SIMD3(0.4, 1, 0.9)
        case .dogfight: tint = SIMD3(1, 0.95, 0.55)
        case .meadow: tint = SIMD3(0.55, 0.9, 1)
        }
        return makeImage(width: 64, height: 64) { x, y in
            let u = (Float(x) + 0.5) / 64, v = (Float(y) + 0.5) / 64
            let edge = smoothstep(0.1, 0.04, min(u, 1 - u))
            // Chevron: |u - 0.5| relates to v
            let cv = (v + abs(u - 0.5) * 0.9).truncatingRemainder(dividingBy: 1)
            let chev = smoothstep(0.08, 0.02, abs(cv - 0.5)) * smoothstep(0.42, 0.3, abs(u - 0.5))
            let a = max(edge * 0.95, chev * 0.9, 0.12)
            let c = simd_mix(tint * 0.6, SIMD3(1, 1, 1), SIMD3(repeating: chev * 0.6))
            return SIMD4(c, a)
        }
    }
}

extension WorldID {
    /// Stable across launches (unlike `hashValue`), for seeding.
    var hashValueStable: Int {
        switch self { case .meadow: return 1; case .volcano: return 2; case .caves: return 3; case .dogfight: return 4 }
    }
}
