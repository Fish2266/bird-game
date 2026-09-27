import SceneKit
import simd

/// Small procedural meshes for cosmetics and props. Everything is built in local space with +Y up.
enum Shapes {
    // MARK: Materials

    /// Lit, slightly soft material (the bird's own look).
    static func mat(_ c: NSColor, rough: CGFloat = 0.6, metal: CGFloat = 0, glow: NSColor? = nil, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = metal
        if let glow { m.emission.contents = glow }
        m.isDoubleSided = doubleSided
        return m
    }

    /// Unlit, glowing material (blooms when bright).
    static func glow(_ c: NSColor, _ intensity: CGFloat = 1.6, doubleSided: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        m.diffuse.intensity = intensity
        m.isDoubleSided = doubleSided
        return m
    }

    /// See-through tinted glass (lenses).
    static func glass(_ c: NSColor, opacity: CGFloat, rough: CGFloat = 0.08, metal: CGFloat = 0.3) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = metal
        m.transparency = opacity
        m.blendMode = .alpha
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    static func node(_ g: SCNGeometry, _ m: SCNMaterial, at p: SIMD3<Float> = .zero) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        return n
    }

    // MARK: 2D outlines (x right, y up, counter-clockwise)

    static func circle(_ r: Float, _ n: Int = 24, rx: Float? = nil) -> [SIMD2<Float>] {
        (0..<n).map { i in
            let a = Float(i) / Float(n) * 2 * .pi
            return SIMD2(cos(a) * (rx ?? r), sin(a) * r)
        }
    }

    static func roundedRect(_ w: Float, _ h: Float, _ r: Float, _ n: Int = 5) -> [SIMD2<Float>] {
        let hw = w / 2 - r, hh = h / 2 - r
        var out: [SIMD2<Float>] = []
        for (cx, cy, a0) in [(hw, -hh, -Float.pi / 2), (hw, hh, 0), (-hw, hh, Float.pi / 2), (-hw, -hh, Float.pi)] {
            for k in 0...n {
                let a = a0 + Float(k) / Float(n) * .pi / 2
                out.append(SIMD2(cx + cos(a) * r, cy + sin(a) * r))
            }
        }
        return out
    }

    /// A heart about `s` wide, point down.
    static func heart(_ s: Float, _ n: Int = 40) -> [SIMD2<Float>] {
        (0..<n).map { i in
            let t = Float(i) / Float(n) * 2 * .pi
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            return SIMD2(x, y + 2) * (s / 34)
        }
    }

    static func star(_ outer: Float, _ inner: Float, points: Int = 5, rotation: Float = .pi / 2) -> [SIMD2<Float>] {
        (0..<(points * 2)).map { i in
            let a = rotation + Float(i) / Float(points * 2) * 2 * .pi
            let r = i % 2 == 0 ? outer : inner
            return SIMD2(cos(a) * r, sin(a) * r)
        }
    }

    /// Aviator lens: rounded on top, drooping to a soft point at the bottom-inside.
    static func teardrop(_ w: Float, _ h: Float, inward: Float = 1, _ n: Int = 32) -> [SIMD2<Float>] {
        (0..<n).map { i in
            let a = Float(i) / Float(n) * 2 * .pi
            var x = cos(a) * w / 2, y = sin(a) * h / 2
            if y < 0 {
                // Lower half sags toward the nose side.
                let k = -y / (h / 2)
                y *= 1 + 0.25 * k
                x -= inward * k * k * w * 0.12
            }
            return SIMD2(x, y)
        }
    }

    /// Grow an outline outward by `d` along its vertex normals (for frames around lenses).
    static func offset(_ o: [SIMD2<Float>], by d: Float) -> [SIMD2<Float>] {
        let n = o.count
        return (0..<n).map { i in
            let p = o[(i + n - 1) % n], c = o[i], q = o[(i + 1) % n]
            let e1 = simd_normalize(c - p), e2 = simd_normalize(q - c)
            let n1 = SIMD2(e1.y, -e1.x), n2 = SIMD2(e2.y, -e2.x)
            var nn = n1 + n2
            nn = simd_length(nn) > 1e-5 ? simd_normalize(nn) : n1
            let cosHalf = max(simd_dot(nn, n1), 0.35)
            return c + nn * (d / cosHalf)
        }
    }

    // MARK: Mesh building

    /// Adds a triangle wound so its front faces along `facing`.
    private static func tri(_ m: inout MeshBuilder, _ a: UInt32, _ b: UInt32, _ c: UInt32, facing: SIMD3<Float>) {
        let pa = SIMD3(m.pos[Int(a) * 3], m.pos[Int(a) * 3 + 1], m.pos[Int(a) * 3 + 2])
        let pb = SIMD3(m.pos[Int(b) * 3], m.pos[Int(b) * 3 + 1], m.pos[Int(b) * 3 + 2])
        let pc = SIMD3(m.pos[Int(c) * 3], m.pos[Int(c) * 3 + 1], m.pos[Int(c) * 3 + 2])
        if simd_dot(simd_cross(pb - pa, pc - pa), facing) >= 0 { m.tri(a, b, c) } else { m.tri(a, c, b) }
    }

    private static let white = SIMD3<Float>(1, 1, 1)

    /// A flat polygon in the XY plane pushed out to `depth` along Z (centered on z = 0).
    /// Star-shaped outlines (hearts, stars, lenses) are fanned from their centroid.
    static func extrude(_ outline: [SIMD2<Float>], depth: Float, bevelSides: Bool = true) -> SCNGeometry {
        var m = MeshBuilder()
        let n = outline.count
        let c = outline.reduce(SIMD2<Float>(0, 0), +) / Float(n)
        let hz = depth / 2
        for (z, nz) in [(hz, Float(1)), (-hz, Float(-1))] {
            let base = m.vertexCount
            let nrm = SIMD3<Float>(0, 0, nz)
            m.vertex(SIMD3(c.x, c.y, z), nrm, white, uv: SIMD2(0.5, 0.5))
            for p in outline { m.vertex(SIMD3(p.x, p.y, z), nrm, white, uv: SIMD2(p.x, p.y)) }
            for i in 0..<UInt32(n) {
                tri(&m, base, base + 1 + i, base + 1 + (i + 1) % UInt32(n), facing: nrm)
            }
        }
        // Side walls
        for i in 0..<n {
            let p = outline[i], q = outline[(i + 1) % n]
            let e = simd_normalize(q - p)
            var out = SIMD3<Float>(e.y, -e.x, 0)
            let mid = (p + q) / 2
            if simd_dot(SIMD2(out.x, out.y), mid - c) < 0 { out = -out }
            let b = m.vertexCount
            m.vertex(SIMD3(p.x, p.y, hz), out, white); m.vertex(SIMD3(q.x, q.y, hz), out, white)
            m.vertex(SIMD3(p.x, p.y, -hz), out, white); m.vertex(SIMD3(q.x, q.y, -hz), out, white)
            tri(&m, b, b + 1, b + 2, facing: out); tri(&m, b + 1, b + 3, b + 2, facing: out)
        }
        return m.geometry()
    }

    /// A flat ring between two outlines of the same length, extruded to `depth` (lens frames).
    static func frame(outer: [SIMD2<Float>], inner: [SIMD2<Float>], depth: Float) -> SCNGeometry {
        var m = MeshBuilder()
        let n = outer.count
        let hz = depth / 2
        for (z, nz) in [(hz, Float(1)), (-hz, Float(-1))] {
            let nrm = SIMD3<Float>(0, 0, nz)
            let base = m.vertexCount
            for i in 0..<n {
                m.vertex(SIMD3(outer[i].x, outer[i].y, z), nrm, white)
                m.vertex(SIMD3(inner[i].x, inner[i].y, z), nrm, white)
            }
            for i in 0..<UInt32(n) {
                let a = base + i * 2, b = base + ((i + 1) % UInt32(n)) * 2
                tri(&m, a, b, a + 1, facing: nrm); tri(&m, b, b + 1, a + 1, facing: nrm)
            }
        }
        let c = outer.reduce(SIMD2<Float>(0, 0), +) / Float(n)
        for (ring, sign) in [(outer, Float(1)), (inner, Float(-1))] {
            for i in 0..<n {
                let p = ring[i], q = ring[(i + 1) % n]
                let mid = (p + q) / 2
                var out = simd_normalize(SIMD3(mid.x - c.x, mid.y - c.y, 0)) * sign
                if !out.x.isFinite { out = SIMD3(0, 1, 0) }
                let b = m.vertexCount
                m.vertex(SIMD3(p.x, p.y, hz), out, white); m.vertex(SIMD3(q.x, q.y, hz), out, white)
                m.vertex(SIMD3(p.x, p.y, -hz), out, white); m.vertex(SIMD3(q.x, q.y, -hz), out, white)
                tri(&m, b, b + 1, b + 2, facing: out); tri(&m, b + 1, b + 3, b + 2, facing: out)
            }
        }
        return m.geometry()
    }

    /// Revolve a profile of (radius, height) points around the Y axis. Normals are smooth except where the
    /// profile turns sharply (`crease` radians), so brims keep crisp edges. `stretchZ` squashes it front-to-back.
    static func lathe(_ profile: [SIMD2<Float>], segments: Int = 24, crease: Float = 0.9, stretchZ: Float = 1,
                      capTop: Bool = false) -> SCNGeometry {
        var m = MeshBuilder()
        let np = profile.count
        // Per-segment 2D normals (pointing away from the axis for a surface drawn bottom to top).
        var segN: [SIMD2<Float>] = []
        for i in 0..<(np - 1) {
            let d = profile[i + 1] - profile[i]
            let l = simd_length(d)
            segN.append(l > 1e-6 ? SIMD2(d.y, -d.x) / l : SIMD2(1, 0))
        }
        // Rows of vertices: each profile point once (smooth) or twice (crease).
        struct Row { var p: SIMD2<Float>; var n: SIMD2<Float>; var seg: Int }
        var rows: [[Row]] = []   // rows[i] = variants for point i: [for segment i-1, for segment i]
        for i in 0..<np {
            let before = i > 0 ? segN[i - 1] : nil, after = i < np - 1 ? segN[i] : nil
            switch (before, after) {
            case let (b?, a?):
                if acos(clamp(simd_dot(b, a), -1, 1)) > crease {
                    rows.append([Row(p: profile[i], n: b, seg: i - 1), Row(p: profile[i], n: a, seg: i)])
                } else {
                    let s = simd_normalize(a + b)
                    rows.append([Row(p: profile[i], n: s, seg: i - 1), Row(p: profile[i], n: s, seg: i)])
                }
            case let (b?, nil): rows.append([Row(p: profile[i], n: b, seg: i - 1)])
            case let (nil, a?): rows.append([Row(p: profile[i], n: a, seg: i)])
            default: break
            }
        }
        let seg = segments
        func emit(_ r: Row) -> UInt32 {
            let start = m.vertexCount
            for k in 0...seg {
                let a = Float(k) / Float(seg) * 2 * .pi
                let (ca, sa) = (cos(a), sin(a))
                let p = SIMD3(r.p.x * ca, r.p.y, r.p.x * sa * stretchZ)
                var nrm = SIMD3(r.n.x * ca, r.n.y, r.n.x * sa / max(stretchZ, 0.01))
                nrm = simd_length(nrm) > 1e-6 ? simd_normalize(nrm) : SIMD3(0, 1, 0)
                m.vertex(p, nrm, white, uv: SIMD2(Float(k) / Float(seg), r.p.y))
            }
            return start
        }
        for i in 0..<(np - 1) {
            let lower = rows[i].last!, upper = rows[i + 1].first!
            let a = emit(lower), b = emit(upper)
            for k in 0..<UInt32(seg) {
                let angle = (Float(k) + 0.5) / Float(seg) * 2 * .pi
                let n2 = segN[i]
                let facing = SIMD3(n2.x * cos(angle), n2.y, n2.x * sin(angle))
                tri(&m, a + k, a + k + 1, b + k, facing: facing)
                tri(&m, a + k + 1, b + k + 1, b + k, facing: facing)
            }
        }
        if capTop, let top = profile.last, top.x > 1e-4 {
            let nrm = SIMD3<Float>(0, 1, 0)
            let c = m.vertexCount
            m.vertex(SIMD3(0, top.y, 0), nrm, white)
            for k in 0...seg {
                let a = Float(k) / Float(seg) * 2 * .pi
                m.vertex(SIMD3(top.x * cos(a), top.y, top.x * sin(a) * stretchZ), nrm, white)
            }
            for k in 0..<UInt32(seg) { tri(&m, c, c + 1 + k, c + 2 + k, facing: nrm) }
        }
        return m.geometry()
    }

    /// A tube along a 3D path, radius per point (tapers, horns, cables). Ends are capped.
    static func tube(_ path: [SIMD3<Float>], radii: [Float], sides: Int = 10, capEnds: Bool = true) -> SCNGeometry {
        var m = MeshBuilder()
        let n = path.count
        guard n >= 2 else { return m.geometry() }
        // Parallel-transport frames.
        var tangents: [SIMD3<Float>] = []
        for i in 0..<n {
            let d = path[min(i + 1, n - 1)] - path[max(i - 1, 0)]
            tangents.append(simd_normalize(d))
        }
        var normal = simd_normalize(simd_cross(tangents[0], abs(tangents[0].y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        var frames: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<n {
            if i > 0 {
                let axis = simd_cross(tangents[i - 1], tangents[i])
                let l = simd_length(axis)
                if l > 1e-6 {
                    let ang = acos(clamp(simd_dot(tangents[i - 1], tangents[i]), -1, 1))
                    normal = simd_quatf(angle: ang, axis: axis / l).act(normal)
                }
            }
            frames.append((normal, simd_cross(tangents[i], normal)))
        }
        let base = m.vertexCount
        for i in 0..<n {
            let (nn, bb) = frames[i]
            for k in 0...sides {
                let a = Float(k) / Float(sides) * 2 * .pi
                let dir = nn * cos(a) + bb * sin(a)
                m.vertex(path[i] + dir * radii[i], dir, white, uv: SIMD2(Float(k) / Float(sides), Float(i) / Float(n - 1)))
            }
        }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(n - 1) {
            for k in 0..<UInt32(sides) {
                let a = base + i * row + k, b = a + 1, c = a + row, d = c + 1
                let angle = (Float(k) + 0.5) / Float(sides) * 2 * .pi
                let (nn, bb) = frames[Int(i)]
                let facing = nn * cos(angle) + bb * sin(angle)
                tri(&m, a, b, c, facing: facing); tri(&m, b, d, c, facing: facing)
            }
        }
        if capEnds {
            for (i, sgn) in [(0, Float(-1)), (n - 1, Float(1))] where radii[i] > 1e-4 {
                let nrm = tangents[i] * sgn
                let c = m.vertexCount
                m.vertex(path[i], nrm, white)
                let (nn, bb) = frames[i]
                for k in 0...sides {
                    let a = Float(k) / Float(sides) * 2 * .pi
                    m.vertex(path[i] + (nn * cos(a) + bb * sin(a)) * radii[i], nrm, white)
                }
                for k in 0..<UInt32(sides) { tri(&m, c, c + 1 + k, c + 2 + k, facing: nrm) }
            }
        }
        return m.geometry()
    }

    /// Points along a quadratic curve (for bent horns, hats and chains).
    static func curve(_ a: SIMD3<Float>, _ control: SIMD3<Float>, _ b: SIMD3<Float>, _ n: Int) -> [SIMD3<Float>] {
        (0...n).map { i in
            let t = Float(i) / Float(n)
            return a * (1 - t) * (1 - t) + control * 2 * t * (1 - t) + b * t * t
        }
    }

    /// Boxes of `size` centred on each cell, merged into one mesh (pixel-art shapes).
    static func voxels(_ cells: [SIMD3<Float>], size: SIMD3<Float>) -> SCNGeometry {
        var m = MeshBuilder()
        let h = size / 2
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for c in cells {
            for (n, u, v) in faces {
                let center = c + n * h
                let b = m.vertexCount
                for (su, sv) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                    m.vertex(center + u * h * su + v * h * sv, n, white)
                }
                tri(&m, b, b + 1, b + 2, facing: n); tri(&m, b, b + 2, b + 3, facing: n)
            }
        }
        return m.geometry()
    }

    /// Low-poly sphere (faceted), for pom-poms, gems, flower centres.
    static func ball(_ r: Float, segments: Int = 10) -> SCNGeometry {
        let s = SCNSphere(radius: CGFloat(r))
        s.segmentCount = segments
        return s
    }
}

/// Tiny procedural textures for cosmetics (stripes, dots, knit, stars).
enum Patterns {
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    static func cached(_ key: String, _ make: () -> CGImage) -> CGImage {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let img = make()
        cache[key] = img
        return img
    }

    /// Diagonal stripes of two colors.
    static func stripes(_ a: SIMD3<Float>, _ b: SIMD3<Float>, count: Float = 4, diagonal: Bool = true) -> CGImage {
        cached("stripes\(a)\(b)\(count)\(diagonal)") {
            makeImage(width: 64, height: 64) { x, y in
                let u = Float(x) / 64, v = Float(y) / 64
                let t = (diagonal ? u + v : u) * count
                let on = t - floor(t) < 0.5
                return SIMD4(on ? a : b, 1)
            }
        }
    }

    /// Polka dots on a background.
    static func dots(_ bg: SIMD3<Float>, _ dot: SIMD3<Float>, count: Int = 4) -> CGImage {
        cached("dots\(bg)\(dot)\(count)") {
            makeImage(width: 64, height: 64) { x, y in
                let cell = 64 / Float(count)
                var fx = Float(x) / cell, fy = Float(y) / cell
                if Int(floor(fy)) % 2 == 1 { fx += 0.5 }
                fx -= floor(fx); fy -= floor(fy)
                let d = simd_length(SIMD2(fx - 0.5, fy - 0.5))
                return SIMD4(d < 0.26 ? dot : bg, 1)
            }
        }
    }

    /// Knitted ribs (beanies).
    static func knit(_ c: SIMD3<Float>) -> CGImage {
        cached("knit\(c)") {
            makeImage(width: 64, height: 64) { x, y in
                let u = Float(x) / 64 * 16, v = Float(y) / 64 * 8
                let rib = 0.82 + 0.18 * abs(sin(u * .pi))
                let row = 0.94 + 0.06 * sin(v * 2 * .pi + (Int(u) % 2 == 0 ? 0 : 1.5))
                return SIMD4(c * rib * row, 1)
            }
        }
    }

    /// Little yellow stars scattered on a color (wizard hat).
    static func starry(_ bg: SIMD3<Float>, _ star: SIMD3<Float>) -> CGImage {
        cached("starry\(bg)\(star)") {
            var rng = SplitMix64(seed: 77)
            let stars = (0..<7).map { _ in (rng.float(0, 1), rng.float(0, 1), rng.float(0.035, 0.06)) }
            return makeImage(width: 128, height: 128) { x, y in
                let u = Float(x) / 128, v = Float(y) / 128
                var on: Float = 0
                for (sx, sy, r) in stars {
                    var dx = u - sx, dy = v - sy
                    dx -= (dx).rounded(); dy -= (dy).rounded()
                    let a = atan2(dy, dx), d = simd_length(SIMD2(dx, dy))
                    let lim = r * (0.55 + 0.45 * cos(5 * a))
                    on = max(on, smoothstep(lim + 0.004, lim - 0.004, d))
                }
                return SIMD4(simd_mix(bg, star, SIMD3(repeating: on)), 1)
            }
        }
    }

    /// A zig-zag band (sombrero).
    static func zigzag(_ colors: [SIMD3<Float>]) -> CGImage {
        cached("zigzag\(colors)") {
            makeImage(width: 128, height: 32) { x, y in
                let u = Float(x) / 128 * 8, v = Float(y) / 32
                let tri = abs((u - floor(u)) - 0.5) * 2
                let band = Int(floor((v + tri * 0.25) * Float(colors.count))) % colors.count
                return SIMD4(colors[max(0, band)], 1)
            }
        }
    }
}
