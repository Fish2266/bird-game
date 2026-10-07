import SceneKit
import simd

// Things worth finding in Dino Valley: giant fossil skeletons lying in the valleys (fly through the ribs), nests of
// eggs, and waterfalls pouring off the cliffs (fly through those too). All placed deterministically, so every chunk
// and the runtime agree on where they are.

struct DinoWaterfall {
    /// From the lip down the cliff, a little out from the rock.
    let profile: [SIMD3<Float>]
    /// Out from the cliff (horizontal), and across the fall.
    let out: SIMD3<Float>
    let side: SIMD3<Float>
    let halfWidth: Float
    var lip: SIMD3<Float> { profile[0] }
    var foot: SIMD3<Float> { profile[profile.count - 1] }

    /// Is a point in the falling water?
    func contains(_ p: SIMD3<Float>) -> Bool {
        guard abs(simd_dot(p - lip, side)) < halfWidth else { return false }
        for k in 1..<profile.count {
            let a = profile[k - 1], b = profile[k]
            guard p.y <= a.y + 1, p.y >= b.y - 1 else { continue }
            let t = clamp((a.y - p.y) / max(a.y - b.y, 0.01), 0, 1)
            let q = a + (b - a) * t
            if abs(simd_dot(p - q, out)) < 2.6 { return true }
        }
        return false
    }
}

struct DinoSkeleton {
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let halfWidth: Float
    let caps: [Capsule]
    var center: SIMD3<Float> { (a + b) * 0.5 }

    /// Inside the ribcage (under the spine, between the ribs)?
    func inside(_ p: SIMD3<Float>, ground: Float) -> Bool {
        let ab = b - a
        let t = simd_dot(p - a, ab) / simd_length_squared(ab)
        guard t > 0.08, t < 0.92 else { return false }
        let q = a + ab * t
        let lateral = simd_length(SIMD2(p.x - q.x, p.z - q.z))
        return lateral < halfWidth * 0.55 && p.y > ground + 0.8 && p.y < q.y - 1
    }
}

struct DinoNest {
    let pos: SIMD3<Float>
    let eggs: Int
    let id: Int64
}

enum DinoLandmarks {
    static let skeletonCell: Float = 1700
    static let nestCell: Float = 800

    private static let lock = NSLock()
    private static var falls: [ChunkKey: DinoWaterfall?] = [:]
    private static var bones: [ChunkKey: DinoSkeleton?] = [:]
    private static var nests: [ChunkKey: DinoNest?] = [:]

    private static func cached<T>(_ dict: inout [ChunkKey: T?], _ k: ChunkKey, _ make: () -> T?) -> T? {
        lock.lock()
        if let v = dict[k] { lock.unlock(); return v }
        lock.unlock()
        let v = make()
        lock.lock()
        if dict.count > 4000 { dict.removeAll(keepingCapacity: true) }
        dict[k] = v
        lock.unlock()
        return v
    }

    // MARK: Waterfalls

    /// The waterfall in a terrain chunk, if it has one: a cliff edge where the plateau drops into a valley.
    static func waterfall(_ key: ChunkKey, _ t: DinoTerrain) -> DinoWaterfall? {
        cached(&falls, key) {
            var rng = cellRNG(key.x, key.z, 0xFA_11)
            guard rng.float() < 0.22 else { return nil }
            let size = t.chunkSize
            for _ in 0..<18 {
                let x = (Float(key.x) + rng.float(0.1, 0.9)) * size, z = (Float(key.z) + rng.float(0.1, 0.9)) * size
                let h = t.height(x, z)
                guard h > 75 else { continue }
                // Not down a volcano's gullies: no springs up there.
                if let v = t.nearestVolcano(x, z), simd_length(SIMD2(x - v.x, z - v.y)) < v.z * 1.1 { continue }
                let g = SIMD2(t.height(x + 3, z) - t.height(x - 3, z), t.height(x, z + 3) - t.height(x, z - 3))
                guard simd_length(g) > 1e-3 else { continue }
                let d = -simd_normalize(g)
                // Walk off the plateau to the lip, then down the cliff to the valley floor.
                var p = SIMD2(x, z)
                var lip: SIMD2<Float>?
                for _ in 0..<30 {
                    let q = p + d * 3
                    if t.height(q.x, q.y) < t.height(p.x, p.y) - 2.2 { lip = p; break }
                    p = q
                }
                guard let l = lip else { continue }
                let top = t.height(l.x, l.y)
                var foot = l, steps = 0
                while steps < 40 {
                    let q = foot + d * 3
                    let hq = t.height(q.x, q.y)
                    foot = q; steps += 1
                    if hq < top - 45 && t.height(q.x + d.x * 3, q.y + d.y * 3) > hq - 1.5 { break }
                }
                let bottom = t.height(foot.x, foot.y)
                guard top - bottom > 45, steps < 40, bottom > 1 else { continue }
                // The sheet follows the cliff a little way out from the rock, falling free where the rock is undercut.
                let out = SIMD3(d.x, 0, d.y)
                var profile: [SIMD3<Float>] = []
                var lastY = top + 0.5
                for k in 0...steps {
                    let q = l + d * (Float(k) * 3)
                    let y = min(lastY, t.height(q.x, q.y) + 0.4)
                    profile.append(SIMD3(q.x, y, q.y) + out * 1.6)
                    lastY = y
                }
                return DinoWaterfall(profile: profile, out: out, side: simd_normalize(simd_cross(out, kUp)), halfWidth: rng.float(4.5, 7.5))
            }
            return nil
        }
    }

    // MARK: Skeletons

    static func skeleton(_ i: Int, _ j: Int, _ t: DinoTerrain) -> DinoSkeleton? {
        cached(&bones, ChunkKey(x: i, z: j)) {
            var rng = cellRNG(i, j, 0x5_4E1)
            guard rng.float() < 0.45 else { return nil }
            let c = skeletonCell
            for _ in 0..<16 {
                let x = (Float(i) + rng.float(0.2, 0.8)) * c, z = (Float(j) + rng.float(0.2, 0.8)) * c
                guard t.walkable(x, z) else { continue }
                let a0 = rng.float(0, 6.28)
                let dir = SIMD3(cos(a0), 0, sin(a0))
                // Room for the whole beast on gentle ground.
                var ok = true
                let h = t.height(x, z)
                for s: Float in [-30, -15, 15, 30, 45] {
                    let q = SIMD3(x, 0, z) + dir * s
                    if abs(t.height(q.x, q.z) - h) > 4 || t.height(q.x, q.z) < 1.5 { ok = false }
                }
                guard ok else { continue }
                let mid = SIMD3(x, 0, z)
                var a = mid - dir * 17, b = mid + dir * 17
                a.y = t.height(a.x, a.z) + 8.5
                b.y = t.height(b.x, b.z) + 8.5
                var none = MeshBuilder()
                none.disabled = true
                let caps = Fossil.build(&none, spine: a, b, halfWidth: 7, origin: .zero, ground: { t.height($0, $1) }, ribEvery: 3.2)
                return DinoSkeleton(a: a, b: b, halfWidth: 7, caps: caps)
            }
            return nil
        }
    }

    // MARK: Nests

    static func nest(_ i: Int, _ j: Int, _ t: DinoTerrain) -> DinoNest? {
        cached(&nests, ChunkKey(x: i, z: j)) {
            var rng = cellRNG(i, j, 0x4E_57)
            guard rng.float() < 0.5 else { return nil }
            let c = nestCell
            for _ in 0..<12 {
                let x = (Float(i) + rng.float(0.15, 0.85)) * c, z = (Float(j) + rng.float(0.15, 0.85)) * c
                guard t.walkable(x, z), t.forest(x, z) < 0.15 else { continue }
                return DinoNest(pos: SIMD3(x, t.height(x, z), z), eggs: Int(rng.float(3, 7.99)), id: Int64(i) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: j))))
            }
            return nil
        }
    }

    /// Landmarks near a point (for the runtime).
    static func skeletons(near p: SIMD3<Float>, _ t: DinoTerrain) -> [DinoSkeleton] {
        let c = skeletonCell
        let ci = Int(floor(p.x / c)), cj = Int(floor(p.z / c))
        var out: [DinoSkeleton] = []
        for dj in -1...1 { for di in -1...1 { if let s = skeleton(ci + di, cj + dj, t) { out.append(s) } } }
        return out
    }

    static func nests(near p: SIMD3<Float>, _ t: DinoTerrain) -> [DinoNest] {
        let c = nestCell
        let ci = Int(floor(p.x / c)), cj = Int(floor(p.z / c))
        var out: [DinoNest] = []
        for dj in -1...1 { for di in -1...1 { if let n = nest(ci + di, cj + dj, t) { out.append(n) } } }
        return out
    }

    static func waterfalls(near p: SIMD3<Float>, _ t: DinoTerrain, chunks r: Int = 2) -> [DinoWaterfall] {
        let s = t.chunkSize
        let ci = Int(floor(p.x / s)), cj = Int(floor(p.z / s))
        var out: [DinoWaterfall] = []
        for dj in -r...r { for di in -r...r { if let w = waterfall(ChunkKey(x: ci + di, z: cj + dj), t) { out.append(w) } } }
        return out
    }

    // MARK: Looks

    static let boneMaterial = WorldMaterials.vertexColor(rough: 0.85)
    static let nestMaterial = WorldMaterials.vertexColor(rough: 0.9)
    /// Churned white water where a fall lands: soft and see-through.
    static let foamMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        m.transparency = 0.55
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }()

    /// Falling water: pale streaks pouring down, foaming white at the edges, see-through.
    static let waterMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = WorldMaterials.whitePixel
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: """
        #pragma transparent
        #pragma body
        float2 uv = _surface.diffuseTexcoord;
        float t = scn_frame.time;
        float n = sin(uv.x * 41.0) * 0.25 + sin(uv.x * 97.0 + 1.7) * 0.15;
        float s = fract(uv.y * 0.07 - t * 1.1 + n);
        float streak = smoothstep(0.05, 0.3, s) * (1.0 - smoothstep(0.45, 0.9, s));
        float s2 = fract(uv.y * 0.19 - t * 1.9 + n * 1.7 + 0.37);
        float fine = smoothstep(0.1, 0.25, s2) * (1.0 - smoothstep(0.35, 0.6, s2));
        float edge = 1.0 - smoothstep(0.0, 0.18, min(uv.x, 1.0 - uv.x));
        float3 col = mix(float3(0.55, 0.74, 0.8), float3(0.97, 0.99, 1.0), clamp(streak * 0.7 + fine * 0.5 + edge * 0.6, 0.0, 1.0));
        float a = clamp(0.5 + streak * 0.35 + fine * 0.2 + edge * 0.25, 0.0, 0.92) * smoothstep(0.0, 4.0, uv.y);
        _output.color = float4(col * a, a);
        """]
        return m
    }()

    static func waterNode(_ w: DinoWaterfall, origin: SIMD3<Float>) -> SCNNode {
        var m = MeshBuilder()
        var along: Float = 0
        for k in 1..<w.profile.count {
            let a = w.profile[k - 1] - origin, b = w.profile[k] - origin
            let wa = w.halfWidth * (1 + 0.25 * Float(k - 1) / Float(w.profile.count)), wb = w.halfWidth * (1 + 0.25 * Float(k) / Float(w.profile.count))
            let l = simd_distance(a, b)
            m.quadUV(a - w.side * wa, a + w.side * wa, b + w.side * wb, b - w.side * wb, SIMD3(1, 1, 1),
                     SIMD2(0, along), SIMD2(1, along), SIMD2(1, along + l), SIMD2(0, along + l), facing: w.out)
            along += l
        }
        let g = m.geometry()
        g.materials = [waterMaterial]
        g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1700)]
        let n = SCNNode(geometry: g)
        n.name = "waterfall"
        n.castsShadow = false
        n.renderingOrder = 5
        // Spray where it lands.
        let mist = SCNNode()
        mist.simdPosition = w.foot - origin + SIMD3(0, 1.5, 0) + w.out * 2
        mist.addParticleSystem(spray(width: w.halfWidth))
        n.addChildNode(mist)
        return n
    }

    private static let puff: CGImage = makeImage(width: 64, height: 64) { x, y in
        let d = simd_length(SIMD2(Float(x) - 31.5, Float(y) - 31.5)) / 32
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, a * a * (3 - 2 * a))
    }

    private static func spray(width: Float) -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 16
        s.emitterShape = SCNBox(width: CGFloat(width * 2.2), height: 2, length: 5, chamferRadius: 0)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 60
        s.particleVelocity = 3.5
        s.particleLifeSpan = 4
        s.particleSize = 6
        s.particleSizeVariation = 2
        s.particleImage = puff
        s.particleColor = NSColor(white: 1, alpha: 0.4)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [0, 0.7, 0]
        fade.keyTimes = [0, 0.3, 1]
        let grow = CAKeyframeAnimation()
        grow.values = [0.6, 1.8]
        grow.keyTimes = [0, 1]
        s.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade), .size: SCNParticlePropertyController(animation: grow)]
        s.warmupDuration = 4
        return s
    }

    static func nestMesh(_ n: DinoNest, into m: inout MeshBuilder, origin: SIMD3<Float>) {
        var rng = SplitMix64(seed: UInt64(bitPattern: n.id) | 1)
        let c = n.pos - origin
        // A ring of heaped twigs and ferns…
        for k in 0..<26 {
            let a = Float(k) / 26 * 2 * .pi + rng.float(-0.1, 0.1)
            let r = rng.float(2.2, 2.8)
            let p = c + SIMD3(cos(a) * r, 0.5, sin(a) * r)
            let d = SIMD3(-sin(a), rng.float(-0.2, 0.3), cos(a))
            m.limb(from: p - d * 1.2, to: p + d * 1.2, r0: 0.16, r1: 0.1, sides: 4, color: SIMD3(0.45, 0.34, 0.22) * rng.float(0.8, 1.2))
        }
        m.cylinder(c, r0: 2.6, r1: 2.2, y0: -0.3, y1: 0.5, sides: 12, SIMD3(0.36, 0.28, 0.2))
        // …and the eggs.
        for k in 0..<n.eggs {
            let a = Float(k) / Float(n.eggs) * 2 * .pi
            let p = c + SIMD3(cos(a) * 1.0, 0.95, sin(a) * 1.0)
            m.ellipsoid(p, SIMD3(0.42, 0.55, 0.42), SIMD3(0.92, 0.88, 0.76) * rng.float(0.92, 1.05), rings: 4, sides: 8)
            m.ellipsoid(p + SIMD3(0.15, 0.25, 0.1), SIMD3(0.12, 0.1, 0.12), SIMD3(0.55, 0.42, 0.3), rings: 2, sides: 5)
        }
    }
}

extension DinoTerrain {
    /// The landmarks whose anchor is in this chunk, as nodes (part of every loaded chunk).
    func landmarkNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var out: [SCNNode] = []
        let origin = SIMD3(ox, 0, oz)
        func inChunk(_ p: SIMD3<Float>) -> Bool { p.x >= ox && p.x < ox + chunkSize && p.z >= oz && p.z < oz + chunkSize }
        if let w = DinoLandmarks.waterfall(key, self) {
            let n = DinoLandmarks.waterNode(w, origin: origin)
            out.append(n)
            // Foam where it hits the ground.
            var foam = MeshBuilder()
            foam.ellipsoid(w.foot - origin + w.out * 2 - SIMD3(0, 0.3, 0), SIMD3(w.halfWidth * 1.5, 0.9, 5.5), SIMD3(1, 1, 1), rings: 3, sides: 12)
            let g = foam.geometry()
            g.materials = [DinoLandmarks.foamMaterial]
            out.append(SCNNode(geometry: g))
        }
        let sc = DinoLandmarks.skeletonCell
        if let s = DinoLandmarks.skeleton(Int(floor((ox + chunkSize / 2) / sc)), Int(floor((oz + chunkSize / 2) / sc)), self), inChunk(s.center) {
            var m = MeshBuilder()
            _ = Fossil.build(&m, spine: s.a, s.b, halfWidth: s.halfWidth, origin: origin, ground: { self.height($0, $1) }, ribEvery: 3.2)
            let g = m.geometry()
            g.materials = [DinoLandmarks.boneMaterial]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1700)]
            let n = SCNNode(geometry: g)
            n.name = "skeleton"
            n.castsShadow = true
            out.append(n)
        }
        let nc = DinoLandmarks.nestCell
        let ni = Int(floor((ox + chunkSize / 2) / nc)), nj = Int(floor((oz + chunkSize / 2) / nc))
        for dj in -1...1 {
            for di in -1...1 {
                guard let nest = DinoLandmarks.nest(ni + di, nj + dj, self), inChunk(nest.pos) else { continue }
                var m = MeshBuilder()
                DinoLandmarks.nestMesh(nest, into: &m, origin: origin)
                let g = m.geometry()
                g.materials = [DinoLandmarks.nestMaterial]
                g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 500)]
                let n = SCNNode(geometry: g)
                n.name = "nest"
                n.castsShadow = true
                out.append(n)
            }
        }
        return out
    }
}
