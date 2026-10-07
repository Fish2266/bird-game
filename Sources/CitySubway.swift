import SceneKit
import simd

// Skyline City's subway: tunnels under some avenues, stations with platforms and stairs up to the sidewalks, and
// tunnel mouths in the river walls under the bridges. Fly in if you dare (and fit).
//
// Lines run under every twelfth x-line (the avenues along z) and every eighth z-line (along x). Along an edge
// (street segment) the tunnel floor sits `depth` under the street; every fifth block along a line has a station
// in the middle of the block, with four stair entrances on the sidewalks. Where a line meets the river, the tunnel
// stops at the quay in a concrete headwall under the bridge, open to the water.
//
// Coordinates along an edge: `s` (0…pitch from the edge's first node) and `l`, the offset across the line
// (world z − line z for edges along x, world x − line x for edges along z).

enum CitySubway {
    static let depth: Float = 11.5
    static let half: Float = 6
    static let height: Float = 7.5
    static let hallHalf: Float = 12
    static let hallHeight: Float = 9
    static let platformY: Float = 1.1
    static let platformEdge: Float = 5.6
    static let hall: ClosedRange<Float> = 28...92
    /// Stair openings: where on the edge the opening starts (at the street) and which way the stairs go down.
    static let stairTops: [(s: Float, dir: Float)] = [(16, 1), (104, -1)]
    static let stairOpening: Float = 8
    static let stairL: ClosedRange<Float> = 8...12
    static let stairHeight: Float = 4.5
    static let track: Float = 2.6

    static func lineX(_ i: Int) -> Bool { fmodi(i, 12) == 0 }
    static func lineZ(_ j: Int) -> Bool { fmodi(j, 8) == 4 }

    struct Stub {
        var s0: Float
        var s1: Float
        var portal0: Bool
        var portal1: Bool
    }

    struct Segment {
        let alongX: Bool
        let i: Int, j: Int
        var stubs: [Stub]
        var station: Bool
        /// Tunnel floor every 6 m along the edge.
        var floors: [Float]
        var name: Int
        var color: SIMD3<Float>
        /// Bridge deck height above the portals (the headwall tucks under it).
        var deck: Float?

        var lineIndex: Int { alongX ? j : i }
        func floor(_ s: Float) -> Float {
            let f = clamp(s / 6, 0, Float(floors.count - 1) - 0.001)
            let k = Int(f)
            return lerp(floors[k], floors[k + 1], f - Float(k))
        }
        func world(_ s: Float, _ l: Float, _ y: Float) -> SIMD3<Float> {
            let G = CityLayout.pitch
            return alongX ? SIMD3(Float(i) * G + s, y, Float(j) * G + l) : SIMD3(Float(i) * G + l, y, Float(j) * G + s)
        }
        /// (s, l) of a world point.
        func local(_ p: SIMD3<Float>) -> (Float, Float) {
            let G = CityLayout.pitch
            return alongX ? (p.x - Float(i) * G, p.z - Float(j) * G) : (p.z - Float(j) * G, p.x - Float(i) * G)
        }
        var axis: SIMD3<Float> { alongX ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1) }
        var across: SIMD3<Float> { alongX ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0) }
        func has(_ s: Float) -> Bool { stubs.contains { s >= $0.s0 - 0.01 && s <= $0.s1 + 0.01 } }
    }

    static let names = ["Feather St", "Canal St", "Nest Ave", "Pigeon Sq", "Robin Rd", "Park Pl", "Downtown", "Union Sq",
                        "Beak St", "Crow Hall", "Sparrow St", "Owl Ave", "Gull Pier", "Wren St", "Lark Ln", "Hawk Hill",
                        "Finch St", "Heron Ave", "Kite St", "Swift Sq", "Tern Terr", "Egret Way", "Plover Pk", "Starling St"]
    static let lineColors: [SIMD3<Float>] = [SIMD3(0.85, 0.18, 0.15), SIMD3(0.15, 0.4, 0.85), SIMD3(0.12, 0.6, 0.3), SIMD3(0.95, 0.55, 0.1),
                                             SIMD3(0.55, 0.25, 0.7), SIMD3(0.95, 0.8, 0.15)]

    private static let lock = NSLock()
    private static var cache: [Int64: Segment?] = [:]

    /// The tunnel along an edge (nil where there's none).
    static func segment(alongX: Bool, _ i: Int, _ j: Int) -> Segment? {
        guard alongX ? lineZ(j) : lineX(i) else { return nil }
        let key = (Int64(i & 0xFFFFF) << 24) | (Int64(j & 0xFFFFF) << 2) | (alongX ? 1 : 0)
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        let seg = makeSegment(alongX: alongX, i, j)
        lock.lock()
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = seg
        lock.unlock()
        return seg
    }

    private static func makeSegment(alongX: Bool, _ i: Int, _ j: Int) -> Segment? {
        let G = CityLayout.pitch
        let start = CityLayout.nodePosition(i, j)
        let d = alongX ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
        func at(_ s: Float) -> SIMD2<Float> { start + d * s }
        func groundAt(_ s: Float) -> Float { let p = at(s); return CityLayout.ground(p.x, p.y) }
        func wet(_ s: Float) -> Bool { let p = at(s); return CityLayout.riverDistance(p.x, p.y) < CityLayout.riverHalf + 2.5 }
        var floors: [Float] = []
        for k in 0...20 { floors.append(max(max(groundAt(Float(k) * 6), CityLayout.quayTop) - depth, 0.3)) }
        let lineIdx = alongX ? j : i
        let e = CityLayout.edge(alongX: alongX, i, j)
        var seg = Segment(alongX: alongX, i: i, j: j, stubs: [], station: false, floors: floors,
                          name: Int(ihash(lineIdx, alongX ? i : j, 0x5B) % UInt32(names.count)),
                          color: lineColors[fmodi(lineIdx * 7 + (alongX ? 3 : 0), lineColors.count)], deck: e?.bridge?.deck)
        var wetLo: Float?, wetHi: Float?
        var s: Float = 0
        while s <= G { if wet(s) { wetLo = wetLo ?? s; wetHi = s }; s += 1 }
        if let lo = wetLo, let hi = wetHi {
            // The line meets the river: tunnels from each bank to the quay. Where it meets the water squarely the
            // tunnel opens in the quay wall; at a slant it stops short in a dead end.
            func square(_ s: Float) -> Bool {
                let p = at(s), h: Float = 2
                let g = SIMD2(CityLayout.riverDistance(p.x + h, p.y) - CityLayout.riverDistance(p.x - h, p.y),
                              CityLayout.riverDistance(p.x, p.y + h) - CityLayout.riverDistance(p.x, p.y - h))
                return simd_length(g) > 1e-3 && abs(simd_dot(simd_normalize(g), d)) > 0.9
            }
            if lo > 14 {
                let portal = square(lo - 3)
                let end = portal ? lo : lo - 10
                if end > 14 { seg.stubs.append(Stub(s0: 0, s1: end, portal0: false, portal1: portal)) }
            }
            if G - hi > 14 {
                let portal = square(hi + 3)
                let begin = portal ? hi : hi + 10
                if G - begin > 14 { seg.stubs.append(Stub(s0: begin, s1: G, portal0: portal, portal1: false)) }
            }
            if seg.stubs.isEmpty { return nil }
        } else {
            seg.stubs = [Stub(s0: 0, s1: G, portal0: false, portal1: false)]
            // A station every fifth block, under a street, where it's high enough for the hall.
            let along = alongX ? i : j
            if e != nil && fmodi(along, 5) == 2 {
                var ok = true
                for k in 0...12 where groundAt(Float(k) * 10) < 12.2 { ok = false }
                seg.station = ok
            }
        }
        return seg
    }

    /// Top of a portal's headwall: tucked under the bridge deck, or a low parapet on the promenade.
    static func headwallTop(_ seg: Segment, at s: Float, outward: Float) -> Float {
        if let deck = seg.deck { return deck - 1.8 }
        let p = seg.world(s - outward * 9, 0, 0)
        return max(CityLayout.ground(p.x, p.z), CityLayout.quayTop) + 0.5
    }

    /// Is there a tunnel continuing past node `n` (in grid terms) from this segment, at its start (atStart) or end?
    static func continues(_ seg: Segment, atStart: Bool) -> Bool {
        if seg.alongX {
            let ni = atStart ? seg.i - 1 : seg.i + 1
            guard let next = segment(alongX: true, ni, seg.j) else { return false }
            return atStart ? next.has(CityLayout.pitch) : next.has(0)
        } else {
            let nj = atStart ? seg.j - 1 : seg.j + 1
            guard let next = segment(alongX: false, seg.i, nj) else { return false }
            return atStart ? next.has(CityLayout.pitch) : next.has(0)
        }
    }

    /// A crossing line's tunnel meets this one at the node at the start (or end) of the segment.
    static func junction(_ seg: Segment, atStart: Bool) -> Bool {
        let ni = seg.alongX ? (atStart ? seg.i : seg.i + 1) : seg.i
        let nj = seg.alongX ? seg.j : (atStart ? seg.j : seg.j + 1)
        if seg.alongX {
            guard lineX(ni) else { return false }
            return (segment(alongX: false, ni, nj)?.has(0) ?? false) || (segment(alongX: false, ni, nj - 1)?.has(CityLayout.pitch) ?? false)
        } else {
            guard lineZ(nj) else { return false }
            return (segment(alongX: true, ni, nj)?.has(0) ?? false) || (segment(alongX: true, ni - 1, nj)?.has(CityLayout.pitch) ?? false)
        }
    }

    /// Segments whose tunnel could be near (x, z).
    static func segments(near x: Float, _ z: Float, radius r: Float) -> [Segment] {
        let G = CityLayout.pitch
        var out: [Segment] = []
        let i0 = Int(floor((x - r - hallHalf) / G)), i1 = Int(ceil((x + r + hallHalf) / G))
        let j0 = Int(floor((z - r - hallHalf) / G)), j1 = Int(ceil((z + r + hallHalf) / G))
        for i in i0...i1 where lineX(i) {
            for j in Int(floor((z - r) / G)) - 1...Int(floor((z + r) / G)) {
                if let s = segment(alongX: false, i, j) { out.append(s) }
            }
        }
        for j in j0...j1 where lineZ(j) {
            for i in Int(floor((x - r) / G)) - 1...Int(floor((x + r) / G)) {
                if let s = segment(alongX: true, i, j) { out.append(s) }
            }
        }
        return out
    }

    /// Quick test: could (x, z) be over any subway at all?
    @inline(__always) static func nearLine(_ x: Float, _ z: Float) -> Bool {
        let G = CityLayout.pitch
        let i = Int((x / G).rounded()), j = Int((z / G).rounded())
        return (lineX(i) && abs(x - Float(i) * G) < hallHalf + 1) || (lineZ(j) && abs(z - Float(j) * G) < hallHalf + 1)
    }

    // MARK: Holes in the street

    /// Terrain cells (by centre) the subway cuts out: stair openings and the quay where a tunnel meets the river.
    static func isHole(_ x: Float, _ z: Float) -> Bool {
        guard nearLine(x, z) else { return false }
        let G = CityLayout.pitch
        let i = Int((x / G).rounded()), j = Int((z / G).rounded())
        if lineX(i), let seg = segment(alongX: false, i, Int(floor(z / G))) {
            let (s, l) = seg.local(SIMD3(x, 0, z))
            if hole(seg, s, l) { return true }
        }
        if lineZ(j), let seg = segment(alongX: true, Int(floor(x / G)), j) {
            let (s, l) = seg.local(SIMD3(x, 0, z))
            if hole(seg, s, l) { return true }
        }
        return false
    }

    private static func hole(_ seg: Segment, _ s: Float, _ l: Float) -> Bool {
        if seg.station && stairL.contains(abs(l)) {
            for (top, dir) in stairTops {
                let a = dir > 0 ? top : top - stairOpening, b = dir > 0 ? top + stairOpening : top
                if s > a && s < b { return true }
            }
        }
        for st in seg.stubs {
            if st.portal1 && abs(l) < 9 && s > st.s1 - 5 && s < st.s1 + 3.5 { return true }
            if st.portal0 && abs(l) < 9 && s > st.s0 - 3.5 && s < st.s0 + 5 { return true }
        }
        return false
    }

    // MARK: The space you can fly in

    /// A box of air underground (tunnel slice, station hall, stairwell), possibly tilted (stairs), and possibly
    /// cut by a sloping floor (the steps under a stair opening).
    struct Air {
        var box: OBox
        /// The sloping floor: its upward normal and a point on it.
        var slopeN: SIMD3<Float>?
        var slopeP = SIMD3<Float>.zero

        /// The floor under a point inside (sloped for stairs).
        func floorY(_ p: SIMD3<Float>) -> Float {
            let n = box.rot.act(kUp)
            var f: Float
            if abs(n.y) > 0.3 {
                // Bottom plane: dot(q - c, n) = -half.y
                f = box.center.y + (-box.half.y - n.x * (p.x - box.center.x) - n.z * (p.z - box.center.z)) / n.y
            } else {
                f = box.center.y - box.half.y
            }
            if let sn = slopeN { f = max(f, slopeP.y - (sn.x * (p.x - slopeP.x) + sn.z * (p.z - slopeP.z)) / sn.y) }
            return f
        }
        func contains(_ p: SIMD3<Float>, shrink: SIMD3<Float>) -> Bool {
            let q = box.rot.inverse.act(p - box.center)
            guard abs(q.x) <= box.half.x - shrink.x && abs(q.y) <= box.half.y - shrink.y && abs(q.z) <= box.half.z - shrink.z else { return false }
            if let sn = slopeN { return simd_dot(p - slopeP, sn) >= shrink.y }
            return true
        }
        /// A point inside (shrunk by `shrink`) near `p` — the nearest one for a plain box.
        func clamp(_ p: SIMD3<Float>, shrink: SIMD3<Float>) -> SIMD3<Float> {
            let h = simd_max(box.half - shrink, SIMD3(repeating: 0.05))
            func inBox(_ p: SIMD3<Float>) -> SIMD3<Float> { box.center + box.rot.act(simd_clamp(box.rot.inverse.act(p - box.center), -h, h)) }
            var q = inBox(p)
            if let sn = slopeN {
                for _ in 0..<3 {
                    let d = simd_dot(q - slopeP, sn) - shrink.y
                    if d >= -1e-4 { break }
                    q = inBox(q - sn * d)
                }
            }
            return q
        }
    }

    static let identity = simd_quatf(angle: 0, axis: kUp)

    private static var airCache: [Int64: [Air]] = [:]
    private static func key(_ seg: Segment) -> Int64 { (Int64(seg.i & 0xFFFFF) << 24) | (Int64(seg.j & 0xFFFFF) << 2) | (seg.alongX ? 1 : 0) }

    /// Air volumes of one segment (cached).
    static func air(_ seg: Segment) -> [Air] {
        let k = key(seg)
        lock.lock()
        if let a = airCache[k] { lock.unlock(); return a }
        lock.unlock()
        let a = makeAir(seg)
        lock.lock()
        if airCache.count > 2000 { airCache.removeAll(keepingCapacity: true) }
        airCache[k] = a
        lock.unlock()
        return a
    }

    /// Every air volume near a point.
    static func air(near p: SIMD3<Float>, radius r: Float = 2) -> [Air] {
        guard nearLine(p.x, p.z) || r > 2 else { return [] }
        return segments(near: p.x, p.z, radius: r).flatMap(air)
    }

    /// The floor under a point that's down in the subway (or over a stair opening or tunnel mouth); nil anywhere else.
    static func floorUnder(_ p: SIMD3<Float>) -> Float? {
        guard nearLine(p.x, p.z) else { return nil }
        let street = CityLayout.ground(p.x, p.z)
        // Up at street level the street holds you up, except over the openings.
        if p.y > street - 0.4 && !isHole(p.x, p.z) { return nil }
        var best: Float?
        // A little slack sideways, so brushing a wall never pops you up through the street.
        for a in air(near: p) where a.contains(p, shrink: SIMD3(-1.2, -0.8, -1.2)) {
            let f = a.floorY(p)
            if f <= p.y + 0.6, f < street - 0.05, best == nil || f > best! { best = f }
        }
        return best
    }

    /// Is a point inside the subway's air (shrunk by the bird's size)?
    static func inside(_ p: SIMD3<Float>, shrink: Float) -> Bool {
        air(near: p).contains { $0.contains(p, shrink: SIMD3(repeating: shrink)) }
    }

    private static func makeAir(_ seg: Segment) -> [Air] {
        var out: [Air] = []
        // Tunnel slices (~24 m) following the floor. Neighbouring slices overlap by more than the bird is wide, so
        // flying along never finds a seam; the ends stop at the walls, except where the tunnel carries on.
        let overlap: Float = 1.6
        for st in seg.stubs {
            let begin = st.s0 - (st.portal0 ? 4 : 0)
            let end = st.s1 + (st.portal1 ? 4 : 0)
            let openStart = !st.portal0 && st.s0 < 0.01 && (continues(seg, atStart: true) || junction(seg, atStart: true))
            let openEnd = !st.portal1 && st.s1 > CityLayout.pitch - 0.01 && (continues(seg, atStart: false) || junction(seg, atStart: false))
            var s = begin
            while s < end - 0.01 {
                let e = min(s + 24, end)
                let a = s - (s > begin + 0.01 || openStart ? overlap : 0)
                let b = e + (e < end - 0.01 || openEnd ? overlap : 0)
                let f = seg.floor((s + e) / 2)
                let c = seg.world((a + b) / 2, 0, f + height / 2)
                let h = seg.alongX ? SIMD3((b - a) / 2, height / 2, half) : SIMD3(half, height / 2, (b - a) / 2)
                out.append(Air(box: OBox(center: c, rot: identity, half: h)))
                s = e
            }
        }
        if seg.station {
            let f = seg.floor(60)
            let len = (hall.upperBound - hall.lowerBound) / 2
            let c = seg.world((hall.lowerBound + hall.upperBound) / 2, 0, f + hallHeight / 2)
            let h = seg.alongX ? SIMD3(len, hallHeight / 2, hallHalf) : SIMD3(hallHalf, hallHeight / 2, len)
            out.append(Air(box: OBox(center: c, rot: identity, half: h)))
            for st in stairs(seg) {
                out.append(Air(box: st.box))
                out.append(Air(box: st.shaft, slopeN: st.up, slopeP: st.top))
            }
        }
        return out
    }

    struct Stair {
        /// The stairwell (tilted), and the open shaft over the opening (from the steps to a little above the street).
        var box: OBox
        var shaft: OBox
        var top: SIMD3<Float>
        var bottom: SIMD3<Float>
        /// Upward normal of the steps.
        var up: SIMD3<Float>
        var l: Float
        var dir: Float
    }

    /// The four stairwells of a station.
    static func stairs(_ seg: Segment) -> [Stair] {
        var out: [Stair] = []
        let floorY = seg.floor(60) + platformY
        for (topS, dir) in stairTops {
            for side: Float in [-1, 1] {
                let l = side * (stairL.lowerBound + stairL.upperBound) / 2
                let street = CityLayout.ground(seg.world(topS, l, 0).x, seg.world(topS, l, 0).z)
                let drop = street - floorY
                // Steep enough that the stairwell's ceiling goes under the street right at the end of the opening (≈ 34°).
                let angle = asin(stairHeight / stairOpening)
                let run = drop / tan(angle)
                let topP = seg.world(topS, l, street)
                let botP = seg.world(topS + dir * run, l, floorY)
                let mid = (topP + botP) / 2
                let along = simd_normalize(botP - topP)
                // Box axes: x across, y up the stairwell, z along it.
                let zAxis = along
                var xAxis = seg.across
                var yAxis = simd_normalize(simd_cross(zAxis, xAxis))
                // Keep y up — flipping x with it so the frame stays a proper rotation.
                if yAxis.y < 0 { yAxis = -yAxis; xAxis = -xAxis }
                let rot = simd_quatf(simd_float3x3(xAxis, yAxis, zAxis))
                let len = simd_distance(topP, botP)
                let up = rot.act(kUp)
                let center = mid + up * (stairHeight / 2)
                let box = OBox(center: center, rot: rot, half: SIMD3(2, stairHeight / 2, len / 2 + 1.5))
                // Over the opening the air goes from the steps (the sloping cut) right up past the street, with
                // straight ends at the edges of the opening.
                let a = dir > 0 ? topS : topS - stairOpening, b = dir > 0 ? topS + stairOpening : topS
                let low = street - stairOpening * tan(angle) - 0.6, high = street + 3
                let shaft = OBox(center: seg.world((a + b) / 2, l, (low + high) / 2), rot: identity,
                                 half: seg.alongX ? SIMD3((b - a) / 2, (high - low) / 2, 2) : SIMD3(2, (high - low) / 2, (b - a) / 2))
                out.append(Stair(box: box, shaft: shaft, top: topP, bottom: botP, up: up, l: l, dir: dir))
            }
        }
        return out
    }

    /// Solid things underground: platforms, columns, ledges, junction pillars, portal headwalls.
    static func solids(_ seg: Segment) -> [CitySolid] {
        var out: [CitySolid] = []
        func box(_ s0: Float, _ s1: Float, _ l0: Float, _ l1: Float, _ y0: Float, _ y1: Float) {
            let a = seg.world(s0, l0, y0), b = seg.world(s1, l1, y1)
            let lo = simd_min(a, b), hi = simd_max(a, b)
            out.append(.box(OBox(center: (lo + hi) / 2, rot: identity, half: (hi - lo) / 2)))
        }
        for st in seg.stubs {
            // Walkway ledges along both walls.
            var s = st.s0
            while s < st.s1 - 0.01 {
                let e = min(s + 24, st.s1)
                let f = seg.floor((s + e) / 2)
                if !(seg.station && s >= hall.lowerBound - 24 && e <= hall.upperBound + 24) {
                    box(s, e, half - 1.2, half + 0.5, f - 1, f + 0.8)
                    box(s, e, -half - 0.5, -half + 1.2, f - 1, f + 0.8)
                }
                s = e
            }
            // Headwalls where the tunnel opens onto the river.
            for (portal, at, outward) in [(st.portal1, st.s1, Float(1)), (st.portal0, st.s0, Float(-1))] where portal {
                let f = seg.floor(at)
                let top = headwallTop(seg, at: at, outward: outward)
                let sIn = at - outward * 7.9, sOut = at + outward * 3.9
                box(min(sIn, sOut), max(sIn, sOut), -11.9, -half, -6, top)
                box(min(sIn, sOut), max(sIn, sOut), half, 11.9, -6, top)
                box(min(sIn, sOut), max(sIn, sOut), -half, half, f + height, top)
                box(min(sIn, sOut), max(sIn, sOut), -half, half, -6, f)
            }
        }
        if seg.station {
            let f = seg.floor(60)
            for side: Float in [-1, 1] {
                box(hall.lowerBound, hall.upperBound, side * platformEdge, side * hallHalf, f - 1, f + platformY)
                var s = hall.lowerBound + 6.4
                while s < hall.upperBound - 3 {
                    box(s - 0.3, s + 0.3, side * 8.8 - 0.3, side * 8.8 + 0.3, f + platformY, f + hallHeight)
                    s += 9.6
                }
            }
        }
        for atStart in [true, false] where junction(seg, atStart: atStart) && seg.alongX {
            let s: Float = atStart ? 0 : CityLayout.pitch
            let f = seg.floor(s)
            for a: Float in [-1, 1] { for b: Float in [-1, 1] { box(s + a * half - 0.6, s + a * half + 0.6, b * half - 0.6, b * half + 0.6, f, f + height) } }
        }
        return out
    }
}

// MARK: - Geometry

extension CityChunk {
    /// Tunnels, stations, stairs and portals whose middle is in this chunk.
    mutating func addSubway() {
        let G = CityLayout.pitch
        let i0 = Int(floor(origin.x / G)) - 1, i1 = Int(floor((origin.x + size) / G)) + 1
        let j0 = Int(floor(origin.z / G)) - 1, j1 = Int(floor((origin.z + size) / G)) + 1
        for j in j0...j1 {
            for i in i0...i1 {
                for alongX in [true, false] {
                    guard let seg = CitySubway.segment(alongX: alongX, i, j) else { continue }
                    let mid = seg.world(G / 2, 0, 0)
                    guard mid.x >= origin.x && mid.x < origin.x + size && mid.z >= origin.z && mid.z < origin.z + size else { continue }
                    addSegment(seg)
                }
            }
        }
    }

    /// Light falling off from the tunnel lamps (baked into the vertex colours).
    private func lampLight(_ s: Float, lampEvery: Float = 12) -> Float {
        let d = abs(s - (s / lampEvery).rounded() * lampEvery)
        return 0.13 + 1.0 / (1 + d * d / 14)
    }

    private mutating func addSegment(_ seg: CitySubway.Segment) {
        let G = CityLayout.pitch
        let H = CitySubway.height, W = CitySubway.half
        let concrete = SIMD3<Float>(0.55, 0.54, 0.52), ceilingC = SIMD3<Float>(0.32, 0.32, 0.33)
        let ballast = SIMD3<Float>(0.22, 0.21, 0.2), rail = SIMD3<Float>(0.5, 0.47, 0.44)
        let junctionStart = CitySubway.junction(seg, atStart: true), junctionEnd = CitySubway.junction(seg, atStart: false)
        for st in seg.stubs {
            let begin = st.s0 - (st.portal0 ? 3.9 : 0), end = st.s1 + (st.portal1 ? 3.9 : 0)
            // Slices of at most 3 m that break exactly at the junction squares and the station hall.
            var cuts = [begin, end]
            for c in [W, G - W, CitySubway.hall.lowerBound, CitySubway.hall.upperBound] where c > begin && c < end { cuts.append(c) }
            cuts.sort()
            var slices: [(Float, Float)] = []
            for k in 0..<(cuts.count - 1) {
                let a = cuts[k], b = cuts[k + 1]
                let n = max(1, Int(ceil((b - a) / 3)))
                for q in 0..<n { slices.append((a + (b - a) * Float(q) / Float(n), a + (b - a) * Float(q + 1) / Float(n))) }
            }
            for (s, e) in slices {
                let f0 = seg.floor(s), f1 = seg.floor(e)
                let k0 = lampLight(s), k1 = lampLight(e)
                let mid = (s + e) / 2
                let inHall = seg.station && mid > CitySubway.hall.lowerBound && mid < CitySubway.hall.upperBound
                let atJunction = (junctionStart && mid < W) || (junctionEnd && mid > G - W)
                let skipFloor = atJunction && seg.alongX
                func P(_ ss: Float, _ l: Float, _ h: Float) -> SIMD3<Float> { L(seg.world(ss, l, (ss == s ? f0 : f1) + h)) }
                guard !inHall else { continue }
                // Each surface shades from this slice's lamp light to the next, so the light pools blend smoothly.
                func quadK(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD3<Float>, facing: SIMD3<Float>) {
                    subway.quadColors(a, b, c, d, col * k0, col * k1, col * k1, col * k0, facing: facing)
                }
                if !skipFloor {
                    quadK(P(s, -W + 1.2, 0), P(e, -W + 1.2, 0), P(e, W - 1.2, 0), P(s, W - 1.2, 0), ballast, facing: kUp)
                    subway.quadColors(P(s, -4.6, H), P(s, 4.6, H), P(e, 4.6, H), P(e, -4.6, H), ceilingC * k0, ceilingC * k0, ceilingC * k1, ceilingC * k1,
                                      facing: -kUp)
                }
                for side: Float in [-1, 1] {
                    let inward = seg.across * -side
                    quadK(P(s, side * (W - 1.2), 0.8), P(e, side * (W - 1.2), 0.8), P(e, side * W, 0.8), P(s, side * W, 0.8), concrete * 0.9, facing: kUp)
                    quadK(P(s, side * (W - 1.2), 0), P(e, side * (W - 1.2), 0), P(e, side * (W - 1.2), 0.8), P(s, side * (W - 1.2), 0.8), concrete * 0.7,
                          facing: inward)
                    if !atJunction {
                        quadK(P(s, side * W, 0.8), P(e, side * W, 0.8), P(e, side * W, 6.2), P(s, side * W, 6.2), concrete, facing: inward)
                        quadK(P(s, side * W, 6.2), P(e, side * W, 6.2), P(e, side * 4.6, H), P(s, side * 4.6, H), concrete * 0.85, facing: inward - kUp)
                        // Cable tray
                        subway.quad(P(s, side * (W - 0.05), 4.1), P(e, side * (W - 0.05), 4.1), P(e, side * (W - 0.05), 4.3), P(s, side * (W - 0.05), 4.3),
                                    SIMD3(0.12, 0.12, 0.13), facing: inward)
                    }
                }
                for t: Float in [-CitySubway.track, CitySubway.track] {
                    for r: Float in [-0.72, 0.72] {
                        let a = seg.world(s, t + r - 0.04, f0), b = seg.world(e, t + r + 0.04, f1 + 0.15)
                        subway.boxAA(L(simd_min(a, b)), L(simd_max(a, b)), rail * k0)
                    }
                }
                // Lamps on alternating walls every 12 m.
                let lampS = (mid / 12).rounded() * 12
                if lampS >= s && lampS < e && !atJunction {
                    let side: Float = Int(lampS / 12) % 2 == 0 ? 1 : -1
                    let c = seg.world(lampS, side * (W - 0.15), seg.floor(lampS) + 5.2)
                    glow.box(L(c), seg.alongX ? SIMD3(0.6, 0.12, 0.12) : SIMD3(0.12, 0.12, 0.6), SIMD3(1, 0.85, 0.6))
                }
            }
            // Pillars at the corners of a junction square.
            if seg.alongX {
                for (atStart, sn) in [(true, Float(0)), (false, G)] where atStart ? junctionStart : junctionEnd {
                    let f = seg.floor(sn)
                    for a: Float in [-1, 1] {
                        for b: Float in [-1, 1] {
                            let lo = seg.world(sn + a * W - 0.6, b * W - 0.6, f), hi = seg.world(sn + a * W + 0.6, b * W + 0.6, f + H)
                            subway.boxAA(L(simd_min(lo, hi)), L(simd_max(lo, hi)), concrete * 0.8)
                        }
                    }
                }
            }
            // Dead ends: a wall with a bumper and a red lamp.
            for (atStart, sEnd) in [(true, st.s0), (false, st.s1)] {
                let portal = atStart ? st.portal0 : st.portal1
                guard !portal, !CitySubway.continues(seg, atStart: atStart), !(atStart ? junctionStartOf(seg) : junctionEndOf(seg)) else { continue }
                let f = seg.floor(sEnd)
                let n = seg.axis * (atStart ? 1 : -1)
                subway.quad(L(seg.world(sEnd, -W, f)), L(seg.world(sEnd, W, f)), L(seg.world(sEnd, W, f + H)), L(seg.world(sEnd, -W, f + H)),
                            concrete * 0.6, facing: n)
                for t: Float in [-CitySubway.track, CitySubway.track] {
                    let b = seg.world(sEnd, t, f + 0.8) + n * 0.6
                    subway.box(L(b), SIMD3(0.9, 0.5, 0.9), SIMD3(0.75, 0.6, 0.1))
                    glow.box(L(b + SIMD3(0, 1.0, 0) + n * 0.3), SIMD3(0.2, 0.2, 0.2), SIMD3(1, 0.1, 0.08))
                }
            }
            // Portals: a stone headwall in the quay wall around the tunnel mouth (open to the water), with a frame and
            // keystone, the line's colour band and name board over the top, lamps either side.
            for (portal, at, outward) in [(st.portal1, st.s1, Float(1)), (st.portal0, st.s0, Float(-1))] where portal {
                let f = seg.floor(at)
                let top = CitySubway.headwallTop(seg, at: at, outward: outward)
                let sIn = at - outward * 7.9, sOut = at + outward * 3.9
                let wallC = SIMD3<Float>(0.68, 0.66, 0.62), stone = SIMD3<Float>(0.8, 0.76, 0.69)
                let o = seg.axis * outward
                func block(_ l0: Float, _ l1: Float, _ y0: Float, _ y1: Float, _ c: SIMD3<Float>, proud: Float = 0) {
                    let a = seg.world(min(sIn, sOut), l0, y0), b = seg.world(max(sIn, sOut), l1, y1)
                    let lo = simd_min(a, b), hi = simd_max(a, b)
                    farProps.boxAA(L(simd_min(lo, lo + o * proud)), L(simd_max(hi, hi + o * proud)), c, uv: .zero)
                }
                // (Set back a hair from the tunnel's own walls so the two never fight.)
                block(-11.9, -W - 0.05, -6, top, wallC); block(W + 0.05, 11.9, -6, top, wallC)
                block(-W, W, f + H + 0.05, top, wallC); block(-W, W, -6, f - 0.05, wallC)
                // Coping along the top.
                let c0 = seg.world(sOut, -12.3, top), c1 = seg.world(sIn, 12.3, top + 0.35) + o * 0.35
                farProps.boxAA(L(simd_min(c0, c1)), L(simd_max(c0, c1)), stone * 1.05)
                // Pilasters and a lintel standing proud of the face, and a keystone.
                func proud(_ l0: Float, _ l1: Float, _ y0: Float, _ y1: Float, _ d: Float, _ c: SIMD3<Float>) {
                    let a = seg.world(sOut, l0, y0), b = seg.world(sOut, l1, y1) + o * d
                    farProps.boxAA(L(simd_min(a, b)), L(simd_max(a, b)), c)
                }
                proud(-W - 1.1, -W, -1, f + H + 1.2, 0.5, stone)
                proud(W, W + 1.1, -1, f + H + 1.2, 0.5, stone)
                proud(-W - 1.1, W + 1.1, f + H, f + H + 1.2, 0.5, stone)
                proud(-0.8, 0.8, f + H - 0.35, f + H + 1.5, 0.75, stone * 1.08)
                // The line's colour: a band over the lintel and, if there's room, a lit disc you can spot from the water.
                proud(-W - 1.1, W + 1.1, f + H + 1.2, f + H + 1.65, 0.55, seg.color)
                if top - (f + H) > 3.6 {
                    let c = seg.world(sOut, 0, f + H + 2.75) + o * 0.1
                    glow.ellipsoid(L(c), seg.alongX ? SIMD3(0.1, 0.95, 0.95) : SIMD3(0.95, 0.95, 0.1), seg.color, rings: 4, sides: 12)
                }
                for side: Float in [-1, 1] {
                    let lamp = seg.world(sOut, side * (W + 2.3), f + H - 0.6) + o * 0.9
                    farProps.boxAA(L(lamp - SIMD3(0.12, 0.6, 0.12) - o * 0.9), L(lamp + SIMD3(0.12, -0.3, 0.12)), SIMD3(0.15, 0.16, 0.17))
                    glow.ellipsoid(L(lamp), SIMD3(repeating: 0.36), SIMD3(1, 0.85, 0.55), rings: 3, sides: 6)
                }
            }
        }
        if seg.station { addStation(seg) }
    }

    private func junctionStartOf(_ seg: CitySubway.Segment) -> Bool { CitySubway.junction(seg, atStart: true) }
    private func junctionEndOf(_ seg: CitySubway.Segment) -> Bool { CitySubway.junction(seg, atStart: false) }

    private mutating func addStation(_ seg: CitySubway.Segment) {
        let f = seg.floor(60)
        let hall = CitySubway.hall
        let HH = CitySubway.hallHeight, HW = CitySubway.hallHalf, PE = CitySubway.platformEdge, PY = CitySubway.platformY
        let tileC = SIMD3<Float>(0.86, 0.84, 0.78), floorC = SIMD3<Float>(0.6, 0.58, 0.55), ceilC = SIMD3<Float>(0.75, 0.74, 0.72)
        let line = seg.color
        let ballast = SIMD3<Float>(0.22, 0.21, 0.2)
        func W(_ s: Float, _ l: Float, _ y: Float) -> SIMD3<Float> { L(seg.world(s, l, f + y)) }
        let k: Float = 1.05   // stations are bright
        var s = hall.lowerBound
        while s < hall.upperBound - 0.01 {
            let e = min(s + 4, hall.upperBound)
            // Track bed between the platforms
            subway.quad(W(s, -PE, 0), W(e, -PE, 0), W(e, PE, 0), W(s, PE, 0), ballast, facing: kUp)
            for side: Float in [-1, 1] {
                // Platform top (tiled), its face toward the tracks with a yellow edge strip, the wall with a coloured band.
                subway.quadUV(W(s, side * PE, PY), W(e, side * PE, PY), W(e, side * HW, PY), W(s, side * HW, PY), floorC * k,
                              SIMD2(s, 1000), SIMD2(e, 1000), SIMD2(e, 1000 + 6), SIMD2(s, 1000 + 6), facing: kUp)
                subway.quad(W(s, side * PE, PY - 0.001), W(e, side * PE, PY - 0.001), W(e, side * (PE + 0.45), PY + 0.003),
                            W(s, side * (PE + 0.45), PY + 0.003), SIMD3(0.95, 0.8, 0.15), facing: kUp)
                subway.quad(W(s, side * PE, 0), W(e, side * PE, 0), W(e, side * PE, PY), W(s, side * PE, PY), floorC * 0.6,
                            facing: seg.across * -side)
                subway.quadUV(W(s, side * HW, PY), W(e, side * HW, PY), W(e, side * HW, 3.2), W(s, side * HW, 3.2), tileC * k,
                              SIMD2(s, 1000 + PY), SIMD2(e, 1000 + PY), SIMD2(e, 1003.2), SIMD2(s, 1003.2), facing: seg.across * -side)
                subway.quad(W(s, side * HW, 3.2), W(e, side * HW, 3.2), W(e, side * HW, 4.0), W(s, side * HW, 4.0), line, facing: seg.across * -side)
                subway.quadUV(W(s, side * HW, 4.0), W(e, side * HW, 4.0), W(e, side * HW, HH), W(s, side * HW, HH), tileC * k,
                              SIMD2(s, 1004), SIMD2(e, 1004), SIMD2(e, 1000 + HH), SIMD2(s, 1000 + HH), facing: seg.across * -side)
            }
            subway.quad(W(s, -HW, HH), W(s, HW, HH), W(e, HW, HH), W(e, -HW, HH), ceilC, facing: -kUp)
            // Light strips across the ceiling.
            glow.quad(W(s + 1.8, -HW + 1, HH - 0.05), W(s + 1.8, HW - 1, HH - 0.05), W(s + 2.2, HW - 1, HH - 0.05), W(s + 2.2, -HW + 1, HH - 0.05),
                      SIMD3(1, 0.97, 0.9), facing: -kUp)
            s = e
        }
        // Rails through the station
        for t: Float in [-CitySubway.track, CitySubway.track] {
            for r: Float in [-0.72, 0.72] {
                let a = seg.world(hall.lowerBound, t + r - 0.04, f), b = seg.world(hall.upperBound, t + r + 0.04, f + 0.15)
                subway.boxAA(L(simd_min(a, b)), L(simd_max(a, b)), SIMD3(0.55, 0.52, 0.48))
            }
        }
        // Columns down each platform, benches against the walls, the station's name on the walls.
        for side: Float in [-1, 1] {
            var c = hall.lowerBound + 6.4
            while c < hall.upperBound - 3 {
                let lo = seg.world(c - 0.3, side * 8.8 - 0.3, f + PY), hi = seg.world(c + 0.3, side * 8.8 + 0.3, f + HH)
                subway.boxAA(L(simd_min(lo, hi)), L(simd_max(lo, hi)), line * 0.85)
                c += 9.6
            }
            var b = hall.lowerBound + 11
            while b < hall.upperBound - 6 {
                let p = seg.world(b, side * (HW - 0.6), f + PY)
                subway.box(L(p + SIMD3(0, 0.45, 0)), seg.alongX ? SIMD3(1.0, 0.05, 0.25) : SIMD3(0.25, 0.05, 1.0), SIMD3(0.45, 0.3, 0.18))
                subway.box(L(p + SIMD3(0, 0.22, 0)), seg.alongX ? SIMD3(0.9, 0.22, 0.2) : SIMD3(0.2, 0.22, 0.9), SIMD3(0.2, 0.2, 0.22))
                b += 19.2
            }
            var n = hall.lowerBound + 4
            let inward = seg.across * -side
            let right = simd_normalize(simd_cross(-inward, kUp))   // the reader's right, facing the wall
            while n < hall.upperBound - 4 {
                let c = seg.world(n, side * (HW - 0.03), f + 3.6)
                let r = right * 3.4, up = SIMD3<Float>(0, 0.4, 0)
                let col = Float(seg.name / 8), row = Float(seg.name % 8)
                let u0 = col / 3, u1 = (col + 1) / 3, v0 = row / 8, v1 = (row + 1) / 8
                signs.quadUV(L(c - r - up), L(c + r - up), L(c + r + up), L(c - r + up), SIMD3(1, 1, 1),
                             SIMD2(u0, v1), SIMD2(u1, v1), SIMD2(u1, v0), SIMD2(u0, v0), facing: inward)
                n += 16
            }
        }
        // End walls: open where the tunnel and the stairwells come through.
        let stairTopAtWall = PY + 7.7
        for (sEnd, n) in [(hall.lowerBound, Float(1)), (hall.upperBound, Float(-1))] {
            let nn = seg.axis * n
            func panel(_ l0: Float, _ l1: Float, _ y0: Float, _ y1: Float) {
                subway.quad(W(sEnd, l0, y0), W(sEnd, l1, y0), W(sEnd, l1, y1), W(sEnd, l0, y1), tileC * 0.9, facing: nn)
            }
            let sl = CitySubway.stairL
            panel(-sl.lowerBound, -CitySubway.half, PY, HH); panel(CitySubway.half, sl.lowerBound, PY, HH)
            panel(-CitySubway.half, CitySubway.half, CitySubway.height, HH)
            panel(sl.lowerBound, sl.upperBound, stairTopAtWall, HH); panel(-sl.upperBound, -sl.lowerBound, stairTopAtWall, HH)
        }
        // Stairwells and their openings on the sidewalk.
        for st in CitySubway.stairs(seg) { addStairs(seg, st) }
    }

    private mutating func addStairs(_ seg: CitySubway.Segment, _ st: CitySubway.Stair) {
        let tileC = SIMD3<Float>(0.84, 0.82, 0.76), stepC = SIMD3<Float>(0.55, 0.53, 0.5)
        let along = simd_normalize(SIMD3(st.bottom.x - st.top.x, 0, st.bottom.z - st.top.z))
        let run = simd_length(SIMD2(st.bottom.x - st.top.x, st.bottom.z - st.top.z))
        let drop = st.top.y - st.bottom.y
        let steps = max(8, Int(drop / 0.3))
        let across = seg.across
        let hw: Float = 2
        // Steps
        for k in 0..<steps {
            let t0 = Float(k) / Float(steps), t1 = Float(k + 1) / Float(steps)
            let y0 = st.top.y - drop * t0, y1 = st.top.y - drop * t1
            let a = st.top + along * run * t0, b = st.top + along * run * t1
            let p0 = SIMD3(a.x, y0, a.z), p1 = SIMD3(b.x, y0, b.z), p2 = SIMD3(b.x, y1, b.z)
            subway.quad(L(p0 - across * hw), L(p0 + across * hw), L(p1 + across * hw), L(p1 - across * hw), stepC * (k % 2 == 0 ? 1 : 0.92), facing: kUp)
            subway.quad(L(p1 - across * hw), L(p1 + across * hw), L(p2 + across * hw), L(p2 - across * hw), stepC * 0.7, facing: along)
        }
        // Side walls (tiled) from the steps up to street level / the stairwell ceiling, and the ceiling where it's covered.
        let n = 10
        let ceilAt: (Float) -> Float = { t in st.top.y - drop * t + CitySubway.stairHeight / cos(atan2(drop, run)) }
        for k in 0..<n {
            let t0 = Float(k) / Float(n), t1 = Float(k + 1) / Float(n)
            let a = st.top + along * run * t0, b = st.top + along * run * t1
            let fy0 = st.top.y - drop * t0 - 0.2, fy1 = st.top.y - drop * t1 - 0.2
            let street = st.top.y
            let cy0 = min(ceilAt(t0), street), cy1 = min(ceilAt(t1), street)
            for side: Float in [-1, 1] {
                let o = across * side * hw
                subway.quadUV(L(SIMD3(a.x, fy0, a.z) + o), L(SIMD3(b.x, fy1, b.z) + o), L(SIMD3(b.x, cy1, b.z) + o), L(SIMD3(a.x, cy0, a.z) + o),
                              tileC, SIMD2(0, 1000 + fy0), SIMD2(run / Float(n), 1000 + fy1), SIMD2(run / Float(n), 1000 + cy1),
                              SIMD2(0, 1000 + cy0), facing: -across * side)
                // Handrail
                let r0 = SIMD3(a.x, fy0 + 1.1, a.z) + across * side * (hw - 0.12), r1 = SIMD3(b.x, fy1 + 1.1, b.z) + across * side * (hw - 0.12)
                subway.tube(L(r0), L(r1), r0: 0.04, r1: 0.04, sides: 4, SIMD3(0.7, 0.72, 0.75))
            }
            if ceilAt(t0) < street - 0.05 {
                let c0 = ceilAt(t0), c1 = ceilAt(t1)
                subway.quad(L(SIMD3(a.x, c0, a.z) - across * hw), L(SIMD3(b.x, c1, b.z) - across * hw), L(SIMD3(b.x, c1, b.z) + across * hw),
                            L(SIMD3(a.x, c0, a.z) + across * hw), SIMD3(0.7, 0.69, 0.66), facing: -kUp)
                if k % 3 == 1 { glow.box(L((SIMD3(a.x, c0, a.z) + SIMD3(b.x, c1, b.z)) / 2 - SIMD3(0, 0.08, 0)), SIMD3(0.25, 0.04, 0.25), SIMD3(1, 0.95, 0.85)) }
            }
            // Back wall behind the top step.
            if k == 0 {
                subway.quad(L(SIMD3(a.x, fy0 - 0.5, a.z) - across * hw), L(SIMD3(a.x, fy0 - 0.5, a.z) + across * hw), L(SIMD3(a.x, street, a.z) + across * hw),
                            L(SIMD3(a.x, street, a.z) - across * hw), tileC, facing: along)
            }
        }
        // Up on the sidewalk: a stone curb around the opening, green railings on three sides, globe lamps and a sign.
        let green = SIMD3<Float>(0.12, 0.3, 0.2)
        let o0 = st.top, o1 = st.top + along * CitySubway.stairOpening
        let g = st.top.y
        for side: Float in [-1, 1] {
            let a = o0 + across * side * (hw + 0.1), b = o1 + across * side * (hw + 0.1)
            props.box(L((a + b) / 2 + SIMD3(0, 0.5, 0)), seg.alongX ? SIMD3(CitySubway.stairOpening / 2, 0.5, 0.05) : SIMD3(0.05, 0.5, CitySubway.stairOpening / 2),
                      green, uv: SIMD2(0, 0))
            props.tube(L(SIMD3(a.x, g, a.z)), L(SIMD3(a.x, g + 2.6, a.z)), r0: 0.06, r1: 0.06, sides: 4, green)
            glow.ellipsoid(L(SIMD3(a.x, g + 2.85, a.z)), SIMD3(repeating: 0.26), SIMD3(0.45, 1, 0.6), rings: 3, sides: 6)
        }
        let farEnd = o1 + along * 0.1
        props.box(L(farEnd + SIMD3(0, 0.5, 0)), seg.alongX ? SIMD3(0.05, 0.5, hw) : SIMD3(hw, 0.5, 0.05), green, uv: SIMD2(0, 0))
        // "SUBWAY" sign on a post at the open end.
        let post = o0 - along * 0.6 + across * (st.l > 0 ? 1 : -1) * (hw + 0.4)
        props.tube(L(SIMD3(post.x, g, post.z)), L(SIMD3(post.x, g + 3.2, post.z)), r0: 0.07, r1: 0.07, sides: 4, green)
        let signC = SIMD3(post.x, g + 3.4, post.z)
        glow.box(L(signC), seg.alongX ? SIMD3(0.05, 0.28, 0.9) : SIMD3(0.9, 0.28, 0.05), seg.color)
    }
}
