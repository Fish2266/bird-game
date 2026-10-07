import SceneKit
import simd

/// Cars, taxis, buses and trucks driving Skyline City's streets around the player: right-hand traffic in lanes,
/// following the car ahead, stopping for red lights (the same clock as the traffic light shader), turning at
/// intersections and crossing the bridges. Drawn into shared batched meshes (bodies and lights).
final class CityTraffic {
    struct Lane: Equatable {
        var alongX: Bool
        var i: Int, j: Int
        /// +1 travels from node (i, j) toward the edge's other end, -1 the other way.
        var dir: Int
        var lane: Int
        var key: Int64 {
            (Int64(i & 0xFFFF) << 32) | (Int64(j & 0xFFFF) << 16) | (alongX ? 8 : 0) | (dir > 0 ? 4 : 0) | Int64(lane)
        }
    }

    struct Turn {
        var p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>
        var y0: Float, y1: Float
        var length: Float
        var t: Float = 0
        var next: Lane
    }

    struct Car {
        var kind: CarKind
        var paint: SIMD3<Float>
        var lane: Lane
        var s: Float
        var speed: Float
        var cruise: Float
        var turn: Turn?
        var braking = false
        var pos = SIMD3<Float>(0, 0, 0)
        var yaw: Float = 0
        var pitch: Float = 0
        var honk: Float = 0
        var siren = false
        var waiting: Float = 0
        var id: Int
    }

    private(set) var cars: [Car] = []
    private var rng = SplitMix64(seed: 0xCA75)
    private var nextId = 1
    private var maintain: Float = 0
    private var edgeCache: [Int64: EdgeInfo?] = [:]
    let radius: Float = 520
    let maxCars = 240
    /// Honks this frame (position, loudness) and police cars with sirens.
    private(set) var honks: [(SIMD3<Float>, Float)] = []
    private(set) var sirens: [SIMD3<Float>] = []
    private(set) var hum: Float = 0

    /// An edge with its height profile (every 10 m) for quick lookups.
    struct EdgeInfo {
        var edge: CityEdge
        var heights: [Float]
    }

    // MARK: Network

    private func edgeKey(_ alongX: Bool, _ i: Int, _ j: Int) -> Int64 {
        (Int64(i & 0xFFFFF) << 24) | (Int64(j & 0xFFFFF) << 2) | (alongX ? 1 : 0)
    }

    func edge(_ alongX: Bool, _ i: Int, _ j: Int) -> EdgeInfo? {
        let k = edgeKey(alongX, i, j)
        if let cached = edgeCache[k] { return cached }
        var info: EdgeInfo?
        if let e = CityLayout.edge(alongX: alongX, i, j) {
            var hs: [Float] = []
            for n in 0...12 {
                let s = Float(n) * 10
                let p = e.start + e.dir * s
                hs.append(CityLayout.roadY(e, s: s, at: p))
            }
            info = EdgeInfo(edge: e, heights: hs)
        }
        if edgeCache.count > 6000 { edgeCache.removeAll(keepingCapacity: true) }
        edgeCache[k] = info
        return info
    }

    /// Road height at distance `s` from the edge start.
    private func height(_ info: EdgeInfo, _ s: Float) -> Float {
        let f = clamp(s / 10, 0, 11.999)
        let k = Int(f)
        return lerp(info.heights[k], info.heights[k + 1], f - Float(k))
    }

    private func line(_ l: Lane) -> CityLine { l.alongX ? CityLayout.lineZ(l.j) : CityLayout.lineX(l.i) }
    private func travel(_ l: Lane) -> SIMD2<Float> { (l.alongX ? SIMD2(1, 0) : SIMD2(0, 1)) * Float(l.dir) }
    private func entryNode(_ l: Lane) -> SIMD2<Float> {
        let a = CityLayout.nodePosition(l.i, l.j)
        if l.dir > 0 { return a }
        return a + (l.alongX ? SIMD2(CityLayout.pitch, 0) : SIMD2(0, CityLayout.pitch))
    }
    /// Grid indices of the node a lane leads to.
    private func exitNode(_ l: Lane) -> (Int, Int) {
        if l.dir > 0 { return l.alongX ? (l.i + 1, l.j) : (l.i, l.j + 1) }
        return (l.i, l.j)
    }
    private func crossLine(atExitOf l: Lane) -> CityLine {
        let (ni, nj) = exitNode(l)
        return l.alongX ? CityLayout.lineX(ni) : CityLayout.lineZ(nj)
    }
    private func crossLine(atEntryOf l: Lane) -> CityLine {
        if l.dir > 0 { return l.alongX ? CityLayout.lineX(l.i) : CityLayout.lineZ(l.j) }
        return l.alongX ? CityLayout.lineX(l.i + 1) : CityLayout.lineZ(l.j + 1)
    }
    private func offset(_ l: Lane) -> Float { line(l).lanes[min(l.lane, line(l).lanes.count - 1)] }

    /// World position (x, z) of a point `s` along a lane.
    private func point(_ l: Lane, _ s: Float) -> SIMD2<Float> {
        let d = travel(l)
        return entryNode(l) + d * s + SIMD2(-d.y, d.x) * offset(l)
    }

    /// Where cars may be on a lane: from the far crosswalk to the stop line.
    private func span(_ l: Lane, length: Float) -> (Float, Float) {
        let a = crossLine(atEntryOf: l).halfWidth + 1 + length / 2
        let b = CityLayout.pitch - crossLine(atExitOf: l).halfWidth - 1.1 - length / 2
        return (a, b)
    }

    private func edgeInfo(_ l: Lane) -> EdgeInfo? { edge(l.alongX, l.i, l.j) }

    /// Height at lane distance s (s measured from the entry node).
    private func roadY(_ l: Lane, _ s: Float) -> Float {
        guard let info = edgeInfo(l) else { return 0 }
        return height(info, l.dir > 0 ? s : CityLayout.pitch - s)
    }

    // MARK: Simulation

    func update(dt: Float, clock: Float, player: SIMD3<Float>) {
        honks.removeAll(keepingCapacity: true)
        sirens.removeAll(keepingCapacity: true)
        maintain -= dt
        if maintain <= 0 || cars.isEmpty {
            maintain = 0.3
            manage(player: player, fill: cars.isEmpty)
        }
        // Who's ahead of whom: sort by lane, then distance along it.
        let order = cars.indices.sorted { a, b in
            let ka = cars[a].turn == nil ? cars[a].lane.key : Int64.max, kb = cars[b].turn == nil ? cars[b].lane.key : Int64.max
            return ka != kb ? ka < kb : cars[a].s < cars[b].s
        }
        var leaderOf = [Int](repeating: -1, count: cars.count)
        for k in 0..<(order.count - (order.isEmpty ? 0 : 1)) {
            let a = order[k], b = order[k + 1]
            if cars[a].turn == nil && cars[b].turn == nil && cars[a].lane == cars[b].lane { leaderOf[a] = b }
        }
        // Lane occupancy at the start of each lane (for cars entering it).
        var firstOnLane: [Int64: Float] = [:]
        for c in cars where c.turn == nil {
            let k = c.lane.key
            let back = c.s - c.kind.length / 2
            if let f = firstOnLane[k] { if back < f { firstOnLane[k] = back } } else { firstOnLane[k] = back }
        }
        var hum: Float = 0
        for idx in cars.indices {
            var c = cars[idx]
            if var t = c.turn {
                // Through the intersection on a curve.
                c.speed += (c.cruise * 0.7 - c.speed) * approach(1.5, dt)
                t.t = min(1, t.t + c.speed * dt / max(t.length, 1))
                let u = t.t
                let w0: Float = (1 - u) * (1 - u), w1: Float = 2 * u * (1 - u), w2: Float = u * u
                let p = t.p0 * w0 + t.p1 * w1 + t.p2 * w2
                let k0: Float = 2 * (1 - u), k1: Float = 2 * u
                let tan = (t.p1 - t.p0) * k0 + (t.p2 - t.p1) * k1
                c.pos = SIMD3(p.x, lerp(t.y0, t.y1, u), p.y)
                if simd_length(tan) > 1e-3 { c.yaw = atan2(-tan.x, -tan.y) }
                c.pitch = 0
                c.braking = false
                if t.t >= 1 {
                    c.lane = t.next
                    c.s = span(t.next, length: c.kind.length).0
                    c.turn = nil
                } else {
                    c.turn = t
                }
            } else {
                let (s0, sStop) = span(c.lane, length: c.kind.length)
                _ = s0
                var target = c.cruise
                // Follow the car ahead.
                let l = leaderOf[idx]
                if l >= 0 {
                    let gap = cars[l].s - cars[l].kind.length / 2 - (c.s + c.kind.length / 2)
                    let want = 2.5 + c.speed * 1.1
                    if gap < want { target = min(target, max(0, (gap - 2) / 1.1)) }
                }
                // Traffic light at the end of the lane.
                let (ni, nj) = exitNode(c.lane)
                let axis = c.lane.alongX ? 0 : 1
                let light = CityLayout.signal(ni, nj, axis: axis, time: clock)
                let toStop = sStop - c.s
                var mustStop = false
                if light != 0 && toStop > -0.5 {
                    // Yellow: stop only if there's room to.
                    if light == 2 || toStop > c.speed * c.speed / 8 { mustStop = true }
                }
                // Don't enter the intersection if there's no room on the other side.
                if !mustStop && toStop < 6, c.waiting > 0 { mustStop = true }
                if mustStop {
                    target = min(target, sqrt(max(0, 2 * 3.2 * max(0, toStop - 0.3))))
                }
                c.braking = target < c.speed - 0.5 || (mustStop && c.speed < 0.5)
                c.speed += clamp(target - c.speed, -7 * dt, 2.6 * dt)
                c.speed = max(0, c.speed)
                c.s += c.speed * dt
                if c.s >= sStop - 0.05 && !mustStop {
                    // Enter the intersection.
                    if let next = chooseNext(c.lane) {
                        let (ns, _) = span(next, length: c.kind.length)
                        let back = firstOnLane[next.key] ?? .infinity
                        if back < ns + c.kind.length / 2 + 2 {
                            c.waiting = 1
                            c.s = min(c.s, sStop)
                            c.speed = 0
                        } else {
                            c.waiting = 0
                            let p0 = point(c.lane, c.s), p2 = point(next, ns)
                            let d0 = travel(c.lane), d2 = travel(next)
                            // Corner point: where the two lane lines meet (straight: the middle).
                            var p1: SIMD2<Float>
                            let crossV = d0.x * d2.y - d0.y * d2.x
                            if abs(crossV) < 0.5 { p1 = (p0 + p2) * 0.5 } else {
                                let tt = ((p2 - p0).x * d2.y - (p2 - p0).y * d2.x) / crossV
                                p1 = p0 + d0 * tt
                            }
                            var len: Float = 0
                            var prev = p0
                            for k in 1...6 {
                                let u = Float(k) / 6
                                let w0: Float = (1 - u) * (1 - u), w1: Float = 2 * u * (1 - u), w2: Float = u * u
                                let q = p0 * w0 + p1 * w1 + p2 * w2
                                len += simd_distance(prev, q); prev = q
                            }
                            c.turn = Turn(p0: p0, p1: p1, p2: p2, y0: roadY(c.lane, c.s), y1: roadY(next, ns), length: len, next: next)
                            firstOnLane[next.key] = -10
                        }
                    } else {
                        c.s = min(c.s, sStop)
                        c.speed = 0
                    }
                } else if c.s > sStop {
                    c.s = sStop
                }
                if c.waiting > 0 { c.waiting = max(0, c.waiting - dt * 0.2) }
                let p = point(c.lane, c.s)
                let y = roadY(c.lane, c.s)
                let yAhead = roadY(c.lane, c.s + 2)
                c.pos = SIMD3(p.x, y, p.y)
                let d = travel(c.lane)
                c.yaw = atan2(-d.x, -d.y)
                c.pitch += (atan2(yAhead - y, 2) - c.pitch) * approach(6, dt)
            }
            c.honk = max(0, c.honk - dt)
            if c.siren { sirens.append(c.pos) }
            let dp = simd_distance(c.pos, player)
            hum += c.speed / (1 + dp * dp * 0.004)
            cars[idx] = c
        }
        self.hum = hum
    }

    /// Next lane at the end of `l`: straight on mostly, sometimes left or right; a U-turn at a dead end.
    private func chooseNext(_ l: Lane) -> Lane? {
        let (ni, nj) = exitNode(l)
        let d = travel(l)
        let left = SIMD2(d.y, -d.x), right = SIMD2(-d.y, d.x)
        func laneFrom(_ dir: SIMD2<Float>) -> Lane? {
            let alongX = dir.x != 0
            let positive = (alongX ? dir.x : dir.y) > 0
            let ei = alongX ? (positive ? ni : ni - 1) : ni
            let ej = alongX ? nj : (positive ? nj : nj - 1)
            guard edge(alongX, ei, ej) != nil else { return nil }
            return Lane(alongX: alongX, i: ei, j: ej, dir: positive ? 1 : -1, lane: 0)
        }
        let r = rng.float()
        var options: [(SIMD2<Float>, Float, Int)] = [(d, 0.62, -1), (right, 0.2, 1), (left, 0.18, 0)]
        if r < 0.62 { options = [options[0], options[1], options[2]] }
        else if r < 0.82 { options = [options[1], options[0], options[2]] }
        else { options = [options[2], options[0], options[1]] }
        for (dir, _, laneIdx) in options {
            if var n = laneFrom(dir) {
                let lanes = line(n).lanes.count
                n.lane = laneIdx < 0 ? min(l.lane, lanes - 1) : (laneIdx == 1 ? lanes - 1 : 0)
                return n
            }
        }
        if var back = laneFrom(-d) { back.lane = 0; return back }
        return nil
    }

    // MARK: Spawning

    private func activeLanes(player: SIMD3<Float>, minDist: Float) -> [Lane] {
        let G = CityLayout.pitch
        let ci = Int(floor(player.x / G)), cj = Int(floor(player.z / G))
        let n = Int(radius / G) + 1
        var out: [Lane] = []
        for j in (cj - n)...(cj + n) {
            for i in (ci - n)...(ci + n) {
                for alongX in [true, false] {
                    guard let info = edge(alongX, i, j) else { continue }
                    let mid = info.edge.start + info.edge.dir * (G / 2)
                    let d = simd_distance(mid, SIMD2(player.x, player.z))
                    guard d < radius - 40, d >= minDist else { continue }
                    let lanes = info.edge.line.lanes.count
                    for dir in [1, -1] { for k in 0..<lanes { out.append(Lane(alongX: alongX, i: i, j: j, dir: dir, lane: k)) } }
                }
            }
        }
        return out
    }

    private func manage(player: SIMD3<Float>, fill: Bool) {
        // Drop cars that drove out of range.
        cars.removeAll { simd_length(SIMD2($0.pos.x - player.x, $0.pos.z - player.z)) > radius + 80 && $0.turn == nil }
        let lanes = activeLanes(player: player, minDist: fill ? 0 : radius * 0.6)
        guard !lanes.isEmpty else { return }
        let D = CityLayout.district(player.x, player.z)
        // Busier downtown: about one car per 30–45 m of lane.
        let allLanes = fill ? lanes.count : activeLanes(player: player, minDist: 0).count
        let target = min(maxCars, Int(Float(allLanes) * CityLayout.pitch / (46 - 14 * D)))
        var tries = 0
        while cars.count < target && tries < (fill ? 600 : 24) {
            tries += 1
            let l = lanes[Int(rng.float(0, Float(lanes.count) - 0.01))]
            spawn(on: l, fill: fill)
        }
    }

    private func spawn(on l: Lane, fill: Bool) {
        var kind = CarKind.sedan
        var r = rng.float()
        for (k, w) in CarKind.mix { if r < w { kind = k; break }; r -= w }
        if kind == .bus && !line(l).avenue { kind = .sedan }
        let (s0, s1) = span(l, length: kind.length)
        guard s1 > s0 else { return }
        let s = fill ? rng.float(s0, s1) : s0
        // Room?
        for c in cars where c.turn == nil && c.lane == l && abs(c.s - s) < (c.kind.length + kind.length) / 2 + 4 { return }
        let paint: SIMD3<Float>
        switch kind {
        case .taxi: paint = CityVehicles.taxiYellow
        case .police: paint = SIMD3(0.95, 0.95, 0.95)
        case .bus: paint = CityVehicles.busPaints[Int(rng.float(0, Float(CityVehicles.busPaints.count) - 0.01))]
        default: paint = CityVehicles.paints[Int(rng.float(0, Float(CityVehicles.paints.count) - 0.01))]
        }
        let cruise = (line(l).avenue ? 13.5 : 10) * kind.cruise * rng.float(0.88, 1.1)
        var c = Car(kind: kind, paint: SIMD3(pow(paint.x, 2.2), pow(paint.y, 2.2), pow(paint.z, 2.2)), lane: l, s: s,
                    speed: fill ? cruise * rng.float(0.3, 1) : cruise * 0.8, cruise: cruise, id: nextId)
        c.siren = kind == .police && rng.float() < 0.6
        if c.siren { c.cruise *= 1.25 }
        nextId += 1
        let p = point(l, s)
        c.pos = SIMD3(p.x, roadY(l, s), p.y)
        let d = travel(l)
        c.yaw = atan2(-d.x, -d.y)
        cars.append(c)
    }

    // MARK: Player interaction

    /// The bird is low over the street near some cars: they honk (each now and then).
    func honkAt(_ p: SIMD3<Float>, velocity: SIMD3<Float>) {
        for k in cars.indices where cars[k].honk == 0 {
            let d = simd_distance(cars[k].pos + SIMD3(0, 1, 0), p)
            guard d < 16 else { continue }
            cars[k].honk = rng.float(3, 6)
            honks.append((cars[k].pos, smoothstep(16, 3, d)))
            if honks.count > 2 { break }
        }
    }

    /// Solid boxes of cars near `p` (buses and trucks are worth bumping into).
    func solids(near p: SIMD3<Float>, radius r: Float) -> [CitySolid] {
        var out: [CitySolid] = []
        for c in cars where abs(c.pos.x - p.x) < r && abs(c.pos.z - p.z) < r {
            let h = SIMD3(c.kind.width / 2, c.kind.height / 2, c.kind.length / 2)
            out.append(.box(OBox(center: c.pos + SIMD3(0, h.y, 0), rot: simd_quatf(angle: c.yaw, axis: kUp), half: h)))
        }
        return out
    }
}
