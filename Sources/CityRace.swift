import SceneKit
import simd

/// Race courses down Skyline City's streets: long avenue canyons, turns only where the corner can be flown (a wide
/// intersection, or cutting across a low building or a park), dips low over the traffic and climbs over the el, checked
/// against every building so the path never clips a wall.
enum CityRace {
    static func path(from spawn: SIMD3<Float>, yaw: Float, length: Float, rng: inout SplitMix64) -> [SIMD3<Float>] {
        let G = CityLayout.pitch
        var d = SIMD2(-sin(yaw), -cos(yaw))
        d = abs(d.x) > abs(d.y) ? SIMD2(d.x > 0 ? 1 : -1, 0) : SIMD2(0, d.y > 0 ? 1 : -1)
        // Start on the street centre line under the spawn.
        var start = SIMD2(spawn.x, spawn.z)
        if d.x != 0 { start.y = (start.y / G).rounded() * G } else { start.x = (start.x / G).rounded() * G }
        // The first node ahead.
        var ni = d.x > 0 ? Int(ceil(start.x / G + 0.01)) : (d.x < 0 ? Int(floor(start.x / G - 0.01)) : Int((start.x / G).rounded()))
        var nj = d.y > 0 ? Int(ceil(start.y / G + 0.01)) : (d.y < 0 ? Int(floor(start.y / G - 0.01)) : Int((start.y / G).rounded()))

        struct Way { var p: SIMD2<Float>; var h: Float }
        var ways: [Way] = []
        var height = segmentHeight(onAvenue: lineAlong(d, ni, nj).avenue, el: lineAlong(d, ni, nj).el, &rng)
        ways.append(Way(p: start, h: height))
        var visited = Set<Int64>()
        var total: Float = 0
        var blocksSinceTurn = 0
        var guardCount = 0
        while total < length + 250 && guardCount < 200 {
            guardCount += 1
            let node = CityLayout.nodePosition(ni, nj)
            visited.insert(key(ni, nj))
            blocksSinceTurn += 1
            // Options at this node.
            let left = SIMD2(d.y, -d.x), right = SIMD2(-d.y, d.x)
            func next(_ dir: SIMD2<Float>) -> (Int, Int)? {
                let ti = ni + Int(dir.x), tj = nj + Int(dir.y)
                let alongX = dir.x != 0
                let e = alongX ? CityLayout.edge(alongX: true, min(ni, ti), nj) : CityLayout.edge(alongX: false, ni, min(nj, tj))
                return e == nil ? nil : (ti, tj)
            }
            var turnTo: SIMD2<Float>? = nil
            var radius: Float = 0
            var cornerTop: Float = 0
            let straight = next(d)
            let wantTurn = straight == nil || visited.contains(key(straight!.0, straight!.1)) ||
                rng.float() < (blocksSinceTurn >= 4 ? 0.85 : (blocksSinceTurn >= 2 ? 0.45 : 0.08))
            if wantTurn {
                var best: (SIMD2<Float>, Float, Float, Float)? = nil   // dir, radius, corner top, score
                for cand in [left, right] {
                    guard let t = next(cand), !visited.contains(key(t.0, t.1)) else { continue }
                    let inner = SIMD2(-d.x + cand.x, -d.y + cand.y)
                    var top: Float = 0
                    for k: Float in [14, 22, 32] {
                        let q = node + inner * k * 0.7071
                        top = max(top, CityLayout.roofHeight(q.x, q.y) - CityLayout.ground(node.x, node.y))
                    }
                    let lineIn = lineAlong(d, ni, nj), lineOut = cand.x != 0 ? CityLayout.lineZ(nj) : CityLayout.lineX(ni)
                    var r: Float, score: Float
                    if top < 55 { r = 46; score = 2 }
                    else if lineIn.avenue && lineOut.avenue { r = 32; score = 1.4 }
                    else { r = 26; score = 1 }
                    score += rng.float(0, 0.6)
                    if best == nil || score > best!.3 { best = (cand, r, top, score) }
                }
                if let b = best { turnTo = b.0; radius = b.1; cornerTop = b.2 }
            }
            if let d1 = turnTo {
                // Arc around the corner: in along d, out along d1.
                let a = node - d * radius, c = node + d1 * radius
                if let last = ways.last { total += simd_distance(last.p, a) }
                let lineOut = d1.x != 0 ? CityLayout.lineZ(nj) : CityLayout.lineX(ni)
                let newH = segmentHeight(onAvenue: lineOut.avenue, el: lineOut.el, &rng)
                // Cutting over a low corner: stay above it.
                let hTurn = max(height, radius > 40 ? cornerTop + 12 : 0)
                ways.append(Way(p: a, h: hTurn))
                for k in 1...8 {
                    let u = Float(k) / 8
                    let w0: Float = (1 - u) * (1 - u), w1: Float = 2 * u * (1 - u), w2: Float = u * u
                    let q: SIMD2<Float> = a * w0 + node * w1 + c * w2
                    total += simd_distance(ways.last!.p, q)
                    ways.append(Way(p: q, h: lerp(hTurn, max(newH, hTurn * 0.6), u)))
                }
                d = d1
                height = newH
                blocksSinceTurn = 0
            } else {
                guard straight != nil else { break }
                if let last = ways.last { total += simd_distance(last.p, node) }
                ways.append(Way(p: node, h: height))
                // Change height now and then along a straight.
                if rng.float() < 0.35 { let l = lineAlong(d, ni, nj); height = segmentHeight(onAvenue: l.avenue, el: l.el, &rng) }
            }
            ni += Int(d.x); nj += Int(d.y)
        }
        // The last stretch to the end of the course.
        let endNode = CityLayout.nodePosition(ni, nj)
        ways.append(Way(p: endNode, h: height))

        // Dense samples every ~6 m.
        var pts: [SIMD3<Float>] = []
        for k in 1..<ways.count {
            let a = ways[k - 1], b = ways[k]
            let n = max(1, Int(simd_distance(a.p, b.p) / 6))
            for s in 0..<n {
                let u = Float(s) / Float(n)
                let p = a.p + (b.p - a.p) * u
                pts.append(SIMD3(p.x, lerp(a.h, b.h, u), p.y))
            }
        }
        // Trim to the length.
        var out: [SIMD3<Float>] = [pts[0]]
        var len: Float = 0
        for k in 1..<pts.count {
            len += simd_distance(SIMD2(pts[k - 1].x, pts[k - 1].z), SIMD2(pts[k].x, pts[k].z))
            out.append(pts[k])
            if len > length { break }
        }
        // Heights: above the ground (and clear of the el), smooth, never inside anything.
        var floorY = out.map { p -> Float in
            let g = CityLayout.ground(p.x, p.z)
            var y = g + p.y
            if let el = elNear(p), abs(p.x - el) < 9 {
                // Over the elevated railway (or well under its beam).
                y = p.y < 9 ? min(y, g + 8.5) : max(y, CityTerrain.trackY(el, p.z) + 9)
            }
            return y
        }
        func smooth() {
            let slope: Float = 0.38 * 6
            for i in 1..<floorY.count { floorY[i] = max(floorY[i], floorY[i - 1] - slope) }
            for i in stride(from: floorY.count - 2, through: 0, by: -1) { floorY[i] = max(floorY[i], floorY[i + 1] - slope) }
        }
        smooth()
        for _ in 0..<3 {
            var raised = false
            for i in floorY.indices {
                let q = SIMD3(out[i].x, floorY[i], out[i].z)
                let solids = CityRuntime.staticSolids(near: q, radius: 20)
                var y = floorY[i]
                var tries = 0
                while tries < 40 && solids.contains(where: { $0.contains(SIMD3(q.x, y, q.z), margin: 5) }) { y += 2; tries += 1 }
                if y > floorY[i] { floorY[i] = y; raised = true }
            }
            smooth()
            if !raised { break }
        }
        var y = floorY
        for _ in 0..<2 {
            var s = y
            for i in 2..<(y.count - 2) { s[i] = max((y[i - 2] + y[i - 1] + y[i] + y[i + 1] + y[i + 2]) / 5, floorY[i]) }
            y = s
        }
        return out.indices.map { SIMD3(out[$0].x, y[$0], out[$0].z) }
    }

    private static func key(_ i: Int, _ j: Int) -> Int64 { Int64(i) << 32 ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: j))) }

    private static func lineAlong(_ d: SIMD2<Float>, _ ni: Int, _ nj: Int) -> CityLine {
        d.x != 0 ? CityLayout.lineZ(nj) : CityLayout.lineX(ni)
    }

    private static func elNear(_ p: SIMD3<Float>) -> Float? {
        let i = Int((p.x / CityLayout.pitch).rounded())
        return CityLayout.lineX(i).el ? Float(i) * CityLayout.pitch : nil
    }

    /// Height above the street for a stretch: mostly mid-canyon, sometimes low over the traffic or up among the roofs.
    private static func segmentHeight(onAvenue: Bool, el: Bool, _ rng: inout SplitMix64) -> Float {
        let r = rng.float()
        if r < 0.22 && onAvenue && !el { return rng.float(9, 12) }
        if r > 0.9 { return rng.float(42, 58) }
        return el ? rng.float(27, 36) : rng.float(17, 33)
    }

    /// Street half-width (to the building line) at a point, for gates and obstacles.
    static func streetHalfWidth(at p: SIMD3<Float>) -> Float {
        let s = CityLayout.nearestStreet(p.x, p.z)
        return (s.alongX ? CityLayout.lineZ(s.index) : CityLayout.lineX(s.index)).halfWidth
    }
}

// MARK: - Obstacles

/// A crane on the sidewalk swings a wrecking ball across the street: go when it's swung away.
final class WreckingBall: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 90
    private let pivot: SIMD3<Float>
    private let side: SIMD3<Float>
    private let length: Float = 19
    private let period: Float = 4.4
    private let phase: Float
    private let ball = SCNNode()
    private let cable = SCNNode()
    private let base: SIMD3<Float>

    init(frame: PathFrame, halfWidth hw: Float, phase: Float) {
        center = frame.origin
        side = frame.side
        self.phase = phase
        pivot = frame.origin + SIMD3(0, length, 0)
        let g = TerrainShape.ground(frame.origin.x, frame.origin.z)
        base = frame.at(-(hw + 2.5), 0, 0)
        let foot = SIMD3(base.x, g, base.z)
        let yellow = pbr(rgb(0.95, 0.72, 0.1), rough: 0.6)
        // Crawler base, cab and a lattice boom out over the street.
        let body = SCNNode(geometry: SCNBox(width: 4, height: 2.2, length: 6, chamferRadius: 0.3))
        body.geometry?.materials = [yellow]
        body.simdPosition = foot + SIMD3(0, 2, 0)
        body.simdOrientation = frame.rot
        node.addChildNode(body)
        let tracks = SCNNode(geometry: SCNBox(width: 4.6, height: 1, length: 6.6, chamferRadius: 0.4))
        tracks.geometry?.materials = [pbr(rgb(0.12, 0.12, 0.12), rough: 0.9)]
        tracks.simdPosition = foot + SIMD3(0, 0.5, 0)
        tracks.simdOrientation = frame.rot
        node.addChildNode(tracks)
        let boomStart = foot + SIMD3(0, 3, 0)
        let boomEnd = pivot + SIMD3(0, 0.5, 0)
        let boom = SCNNode(geometry: SCNBox(width: 0.9, height: CGFloat(simd_distance(boomStart, boomEnd)), length: 0.9, chamferRadius: 0.1))
        boom.geometry?.materials = [yellow]
        orientBetween(boom, boomStart, boomEnd)
        node.addChildNode(boom)
        let ballGeo = SCNSphere(radius: 2.2)
        ballGeo.segmentCount = 16
        ballGeo.materials = [pbr(rgb(0.15, 0.15, 0.16), rough: 0.35, metal: 0.8)]
        ball.geometry = ballGeo
        node.addChildNode(ball)
        cable.geometry = SCNCylinder(radius: 0.08, height: CGFloat(length))
        cable.geometry?.materials = [pbr(rgb(0.1, 0.1, 0.1), rough: 0.5, metal: 0.6)]
        node.addChildNode(cable)
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
        update(time: 0)
    }

    private func ballPos(_ t: Float) -> SIMD3<Float> {
        let a = 0.95 * sin(t * 2 * .pi / period + phase)
        return pivot + side * sin(a) * length - kUp * cos(a) * length
    }

    func update(time: Float) {
        let b = ballPos(time)
        ball.simdPosition = b
        orientBetween(cable, pivot, b)
    }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        let b = ballPos(time)
        if let v = Capsule(a: b, b: b, r: 2.3).push(p, radius) { return v * 1.6 + side * 2 }
        if let v = Capsule(a: pivot, b: b, r: 0.3).push(p, radius) { return v }
        return Capsule(a: base + SIMD3(0, -10, 0), b: pivot, r: 0.8).push(p, radius)
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 90 ? "Wrecking ball — time it!" : nil
    }
}

/// A glass walkway across the street, low over the course: duck under it.
final class StreetSkybridge: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private let box: OBox

    init(frame: PathFrame, halfWidth hw: Float) {
        center = frame.origin
        let y0 = frame.origin.y + 3.6, h: Float = 5
        let mid = frame.origin + SIMD3(0, 3.6 + h / 2, 0)
        box = OBox(center: mid, rot: frame.rot, half: SIMD3(hw + 4, h / 2, 3.2))
        let glass = pbr(rgb(0.45, 0.62, 0.72), rough: 0.08, metal: 0.85)
        let g = SCNNode(geometry: SCNBox(width: CGFloat(hw * 2 + 8), height: CGFloat(h), length: 6.4, chamferRadius: 0))
        g.geometry?.materials = [glass]
        g.simdPosition = mid
        g.simdOrientation = frame.rot
        node.addChildNode(g)
        let white = pbr(rgb(0.92, 0.92, 0.9), rough: 0.5)
        for (dy, dz) in [(-h / 2, -3.2), (-h / 2, 3.2), (h / 2, -3.2), (h / 2, 3.2)] as [(Float, Float)] {
            let beam = SCNNode(geometry: SCNBox(width: CGFloat(hw * 2 + 8.2), height: 0.35, length: 0.35, chamferRadius: 0))
            beam.geometry?.materials = [white]
            beam.simdPosition = frame.origin + SIMD3(0, 3.6 + h / 2 + dy, 0) + frame.fwd * dz
            beam.simdOrientation = frame.rot
            node.addChildNode(beam)
        }
        // A sign so it reads from a distance.
        let sign = SCNNode(geometry: SCNPlane(width: 10, height: 1.4))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = signImage("SKYWALK", width: 512, height: 72, background: rgb(0.1, 0.12, 0.15), color: rgb(1, 0.85, 0.3),
                                       font: NSFont.systemFont(ofSize: 46, weight: .heavy))
        m.isDoubleSided = true
        sign.geometry?.materials = [m]
        sign.simdPosition = frame.origin + SIMD3(0, y0 - frame.origin.y + h + 0.9, 0) - frame.fwd * 3.3
        sign.simdOrientation = frame.rot
        node.addChildNode(sign)
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    func update(time: Float) {}
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? { box.push(p, radius) }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 80 && p.y > center.y + 1.5 ? "Duck under the skywalk!" : nil
    }
}

/// A giant parade balloon (a cartoon duck) held down by ropes: weave between them.
final class ParadeBalloon: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 80
    private var ropes: [Capsule] = []
    private let body: SCNNode
    private let bodyAt: SIMD3<Float>

    init(frame: PathFrame, halfWidth hw: Float) {
        center = frame.origin
        bodyAt = frame.origin + SIMD3(0, 22, 0)
        body = SCNNode()
        let yellow = pbr(rgb(1, 0.85, 0.15), rough: 0.35)
        let b = SCNNode(geometry: SCNSphere(radius: 7))
        b.geometry?.materials = [yellow]
        b.scale = SCNVector3(1, 0.85, 1.25)
        body.addChildNode(b)
        let head = SCNNode(geometry: SCNSphere(radius: 4.2))
        head.geometry?.materials = [yellow]
        head.simdPosition = SIMD3(0, 6.5, -6)
        body.addChildNode(head)
        let beak = SCNNode(geometry: SCNBox(width: 3.4, height: 1.2, length: 3.6, chamferRadius: 0.6))
        beak.geometry?.materials = [pbr(rgb(1, 0.5, 0.1), rough: 0.4)]
        beak.simdPosition = SIMD3(0, 5.8, -10.2)
        body.addChildNode(beak)
        for s: Float in [-1, 1] {
            let eye = SCNNode(geometry: SCNSphere(radius: 1.1))
            eye.geometry?.materials = [pbr(.white, rough: 0.3)]
            eye.simdPosition = SIMD3(s * 1.9, 7.6, -9.2)
            body.addChildNode(eye)
            let pupil = SCNNode(geometry: SCNSphere(radius: 0.6))
            pupil.geometry?.materials = [pbr(rgb(0.05, 0.05, 0.05), rough: 0.3)]
            pupil.simdPosition = SIMD3(s * 1.95, 7.7, -10.0)
            body.addChildNode(pupil)
            let wing = SCNNode(geometry: SCNSphere(radius: 3))
            wing.geometry?.materials = [yellow]
            wing.scale = SCNVector3(0.35, 0.8, 1.2)
            wing.simdPosition = SIMD3(s * 6.6, 0.5, 1)
            body.addChildNode(wing)
        }
        body.simdPosition = bodyAt
        body.simdOrientation = frame.rot
        node.addChildNode(body)
        // Ropes from the balloon down to handlers' stakes in the street.
        let ground = TerrainShape.ground(frame.origin.x, frame.origin.z)
        let rope = pbr(rgb(0.85, 0.82, 0.75), rough: 0.9)
        for (s, f) in [(-0.55, -9), (0.55, -9), (-0.55, 9), (0.55, 9), (0, 0)] as [(Float, Float)] {
            let footP = frame.at(s * hw, f, 0) + SIMD3(0, ground - frame.origin.y, 0)
            let topP = bodyAt + frame.side * s * 5 + frame.fwd * f * 0.6 - SIMD3(0, 5, 0)
            ropes.append(Capsule(a: footP, b: topP, r: 0.45))
            let c = SCNNode(geometry: SCNCylinder(radius: 0.12, height: CGFloat(simd_distance(footP, topP))))
            c.geometry?.materials = [rope]
            orientBetween(c, footP, topP)
            node.addChildNode(c)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    func update(time: Float) {
        body.simdPosition = bodyAt + SIMD3(0, sin(time * 0.8) * 0.7, 0)
    }
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        for r in ropes { if let v = r.push(p, radius) { return v } }
        return Capsule(a: bodyAt - SIMD3(0, 2, 0), b: bodyAt + SIMD3(0, 4, 0), r: 8).push(p, radius)
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 85 ? "Parade balloon — weave through the ropes!" : nil
    }
}

/// A news helicopter hovering low in the street, rotor turning: pass on the other side or underneath.
final class HoverHeli: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 70
    private let at: SIMD3<Float>
    private let heli: SCNNode

    init(frame: PathFrame, halfWidth hw: Float, side: Float) {
        center = frame.origin
        at = frame.origin + frame.side * side * min(4.5, hw * 0.35) + SIMD3(0, -1.5, 0)
        heli = CitySky.helicopter()
        heli.simdPosition = at
        heli.simdOrientation = frame.rot * yawQuat(.pi)
        node.addChildNode(heli)
    }

    func update(time: Float) {
        heli.simdPosition = at + SIMD3(sin(time * 0.7) * 0.4, sin(time * 1.1) * 0.5, 0)
    }
    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        let h = heli.simdPosition
        let fwd = heli.simdOrientation.act(SIMD3(0, 0, -1))
        if let v = Capsule(a: h + SIMD3(0, 1.4, 0) + fwd * 2, b: h + SIMD3(0, 1.8, 0) - fwd * 6.5, r: 1.5).push(p, radius) { return v }
        return CitySolid.cylinder(c: SIMD2(h.x, h.z), r: 6.4, y0: h.y + 3.0, y1: h.y + 3.5).push(p, radius)
    }
    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        simd_distance(p, center) < 80 ? "Helicopter in the street!" : nil
    }
}

/// An elevated railway crossing the street at course height: a train comes through every few seconds.
final class TrainCrossing: Obstacle {
    let node = SCNNode()
    let center: SIMD3<Float>
    let reach: Float = 90
    private let deck: OBox
    private let side: SIMD3<Float>
    private var cars: [SCNNode] = []
    private let rail: SIMD3<Float>
    private let span: Float
    private let period: Float = 9
    private let phase: Float

    init(frame: PathFrame, halfWidth hw: Float, phase: Float) {
        center = frame.origin
        side = frame.side
        self.phase = phase
        span = hw + 40
        rail = frame.origin + SIMD3(0, -2.6, 0)
        deck = OBox(center: rail - SIMD3(0, 0.7, 0), rot: frame.rot, half: SIMD3(hw + 6, 0.7, 3.2))
        let concrete = pbr(rgb(0.6, 0.59, 0.56), rough: 0.9)
        let d = SCNNode(geometry: SCNBox(width: CGFloat(hw * 2 + 12), height: 1.4, length: 6.4, chamferRadius: 0))
        d.geometry?.materials = [concrete]
        d.simdPosition = rail - SIMD3(0, 0.7, 0)
        d.simdOrientation = frame.rot
        node.addChildNode(d)
        // Steel bents on the sidewalks
        let g = TerrainShape.ground(frame.origin.x, frame.origin.z)
        for s: Float in [-1, 1] {
            for f: Float in [-2.4, 2.4] {
                let foot = frame.at(s * (hw - 1.5), f, 0)
                let col = SCNNode(geometry: SCNBox(width: 0.7, height: CGFloat(rail.y - 1.4 - g), length: 0.7, chamferRadius: 0))
                col.geometry?.materials = [pbr(rgb(0.25, 0.35, 0.3), rough: 0.6, metal: 0.4)]
                col.simdPosition = SIMD3(foot.x, (g + rail.y - 1.4) / 2, foot.z)
                node.addChildNode(col)
            }
        }
        for k in 0..<3 {
            let car = SCNNode(geometry: CityTransit.carGeometry(front: k == 0, back: k == 2, livery: 1))
            car.castsShadow = true
            node.addChildNode(car)
            cars.append(car)
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
        update(time: 0)
    }

    /// Lateral position of the train's front (relative to the course), or nil when no train is on the bridge.
    private func trainFront(_ t: Float) -> Float? {
        var u = (t + phase).truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        let travel: Float = 3.8
        guard u < travel else { return nil }
        return -span + (u / travel) * (2 * span + 54)
    }

    func update(time: Float) {
        let front = trainFront(time)
        for (k, car) in cars.enumerated() {
            guard let f = front else { car.isHidden = true; continue }
            let s = f - (8.5 + Float(k) * 17.9)
            car.isHidden = abs(s) > span
            car.simdPosition = rail + side * s
            car.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: side)
        }
    }

    func push(_ p: SIMD3<Float>, radius: Float, time: Float) -> SIMD3<Float>? {
        if let v = deck.push(p, radius) { return v }
        guard let f = trainFront(time) else { return nil }
        for k in 0..<3 {
            let s = f - (8.5 + Float(k) * 17.9)
            guard abs(s) < span else { continue }
            let c = rail + side * s + SIMD3(0, 2.1, 0)
            let b = OBox(center: c, rot: simd_quatf(from: SIMD3(0, 0, -1), to: side), half: SIMD3(1.5, 1.6, 8.5))
            if let v = b.push(p, radius) { return v + SIMD3(0, 3, 0) }
        }
        return nil
    }

    func warning(_ p: SIMD3<Float>, time: Float) -> String? {
        guard simd_distance(p, center) < 100 else { return nil }
        var u = (time + phase).truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        return u > period - 2 || u < 3.8 ? "Train crossing!" : nil
    }
}
