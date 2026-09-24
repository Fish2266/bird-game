import SceneKit
import simd

enum TerrainShape {
    /// The world currently being flown. Set when a world is built.
    static var active: WorldTerrain = MeadowTerrain()

    static var waterLevel: Float { active.waterLevel }

    /// Deterministic world height (meters) at (x, z). Same function drives the mesh and collisions.
    static func height(_ x: Float, _ z: Float) -> Float { active.height(x, z) }

    /// Ground or water/lava surface, whichever is higher.
    static func ground(_ x: Float, _ z: Float) -> Float { max(active.height(x, z), active.waterLevel) }

    static func ceiling(_ x: Float, _ z: Float) -> Float? { active.ceiling(x, z) }

    /// World 1 ("Home Isles") height.
    static func meadowHeight(_ x: Float, _ z: Float) -> Float {
        let wx = x + 220 * Noise.perlin(x * 0.0006 + 11.3, z * 0.0006 - 3.1)
        let wz = z + 220 * Noise.perlin(x * 0.0006 - 7.7, z * 0.0006 + 5.9)
        let continent = Noise.fbm(wx * 0.00032, wz * 0.00032, octaves: 4)
        var h = continent * 230 + 22
        let mountainMask = smoothstep(0.02, 0.4, continent)
        if mountainMask > 0 {
            let r = Noise.ridged(wx * 0.0011, wz * 0.0011, octaves: 5)
            h += mountainMask * r * r * 520
        }
        h += Noise.fbm(x * 0.005, z * 0.005, octaves: 3) * 7 * smoothstep(-2, 20, h)
        // Soften the coastline into beaches.
        if h > -4 && h < 6 { h = lerp(h, 1.2 + (h - 1.2) * 0.45, smoothstep(6, 1, abs(h - 1))) }
        return h
    }

    static func normal(_ x: Float, _ z: Float, e: Float = 2) -> SIMD3<Float> {
        let hx = height(x + e, z) - height(x - e, z)
        let hz = height(x, z + e) - height(x, z - e)
        return simd_normalize(SIMD3(-hx, 2 * e, -hz))
    }

    /// World 1 ("Home Isles") ground color.
    static func meadowColor(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.013, z * 0.013) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.07 + 5, z * 0.07) * 0.5 + 0.5
        let sandWet = SIMD3<Float>(0.62, 0.55, 0.40)
        let sand = SIMD3<Float>(0.86, 0.79, 0.60)
        let lush = SIMD3<Float>(0.24, 0.40, 0.14)
        let dry = SIMD3<Float>(0.47, 0.49, 0.25)
        let alpine = SIMD3<Float>(0.40, 0.44, 0.28)
        let rock = SIMD3<Float>(0.46, 0.43, 0.40)
        let rockDark = SIMD3<Float>(0.32, 0.30, 0.29)
        let snow = SIMD3<Float>(0.95, 0.96, 0.99)

        if h < 0.5 {
            let d = smoothstep(0.5, -25, h)
            return simd_mix(sandWet, SIMD3(0.20, 0.30, 0.30), SIMD3(repeating: d))
        }
        let meadow = SIMD3<Float>(0.36, 0.47, 0.18)
        let macro = Noise.perlin(x * 0.0021 + 3, z * 0.0021) * 0.5 + 0.5
        var c = simd_mix(lush, dry, SIMD3(repeating: n * 0.7 + n2 * 0.3))
        c = simd_mix(c, meadow, SIMD3(repeating: smoothstep(0.45, 0.8, macro) * 0.8))
        c = simd_mix(c, alpine, SIMD3(repeating: smoothstep(150, 260, h)))
        let beach = smoothstep(4.5, 2.2, h + n2 * 1.5)
        c = simd_mix(c, sand, SIMD3(repeating: beach))
        let steep = smoothstep(0.80, 0.62, ny)
        let r = simd_mix(rock, rockDark, SIMD3(repeating: n2))
        c = simd_mix(c, r, SIMD3(repeating: steep))
        let snowAmt = smoothstep(300, 360, h + n * 60) * smoothstep(0.55, 0.75, ny)
        c = simd_mix(c, snow, SIMD3(repeating: snowAmt))
        return c
    }
}

/// World 1: exactly the original island generator.
final class MeadowTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 700
    let radius = 7
    func height(_ x: Float, _ z: Float) -> Float { TerrainShape.meadowHeight(x, z) }
    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> { TerrainShape.meadowColor(h: h, ny: ny, x: x, z: z) }
    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        TerrainManager.addTrees(&m, key: key, ox: ox, oz: oz, chunkSize: chunkSize)
    }
}

/// Plain float arrays that become one SCNGeometry.
struct MeshBuilder {
    var pos: [Float] = []
    var nrm: [Float] = []
    var col: [Float] = []
    var uv: [Float] = []
    var idx: [UInt32] = []
    var vertexCount: UInt32 { UInt32(pos.count / 3) }
    var isEmpty: Bool { idx.isEmpty }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ c: SIMD3<Float>, uv t: SIMD2<Float> = .zero) {
        pos += [p.x, p.y, p.z]
        uv += [t.x, t.y]
        nrm += [n.x, n.y, n.z]
        // Vertex colors are authored in sRGB; SceneKit shades in linear space.
        col += [pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2)]
    }

    mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) { idx += [a, b, c] }

    func geometry() -> SCNGeometry {
        let n = pos.count / 3
        func src(_ a: [Float], _ s: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: s, vectorCount: n, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let idata = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        let el = SCNGeometryElement(data: idata, primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let uvData = uv.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSrc = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: n, usesFloatComponents: true,
                                      componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        return SCNGeometry(sources: [src(pos, .vertex), src(nrm, .normal), src(col, .color), uvSrc], elements: [el])
    }
}

struct ChunkKey: Hashable { let x: Int; let z: Int }

final class TerrainManager {
    let terrain: WorldTerrain
    var chunkSize: Float { terrain.chunkSize }
    let root = SCNNode()
    let radius: Int
    private var chunks: [ChunkKey: SCNNode] = [:]
    private var inFlight = Set<ChunkKey>()
    private var ready: [(ChunkKey, SCNNode)] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "bird.terrain", qos: .userInitiated, attributes: .concurrent)
    private let material: SCNMaterial
    private let glowMaterial: SCNMaterial

    init(terrain: WorldTerrain, radius: Int? = nil) {
        self.terrain = terrain
        self.radius = radius ?? terrain.radius
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = TerrainManager.detailTexture()
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        m.roughness.contents = 0.93
        m.metalness.contents = 0.0
        m.isDoubleSided = terrain.ceiling(0, 0) != nil
        material = m
        let g = SCNMaterial()
        g.lightingModel = .constant
        g.diffuse.contents = NSColor.white
        g.diffuse.intensity = 2.2   // bright enough to bloom in HDR
        glowMaterial = g
    }

    var loadedCount: Int { chunks.count }

    /// Tileable grey speckle/blotch texture multiplied over the vertex colors.
    static func detailTexture() -> CGImage {
        let n = 256
        var rng = SplitMix64(seed: 5150)
        func blurred(_ radius: Int, _ passes: Int) -> [Float] {
            var a = (0..<(n * n)).map { _ in rng.float() }
            var b = a
            for _ in 0..<passes {
                for y in 0..<n { for x in 0..<n {
                    var s: Float = 0
                    for k in -radius...radius { s += a[y * n + (x + k + n) % n] }
                    b[y * n + x] = s / Float(2 * radius + 1)
                } }
                for y in 0..<n { for x in 0..<n {
                    var s: Float = 0
                    for k in -radius...radius { s += b[((y + k + n) % n) * n + x] }
                    a[y * n + x] = s / Float(2 * radius + 1)
                } }
            }
            // Normalize to 0…1
            let lo = a.min()!, hi = a.max()!
            return a.map { ($0 - lo) / (hi - lo) }
        }
        let fine = blurred(1, 1), mid = blurred(4, 2), big = blurred(14, 2)
        return makeImage(width: n, height: n) { x, y in
            let i = y * n + x
            let v = 0.84 + (fine[i] - 0.5) * 0.16 + (mid[i] - 0.5) * 0.16 + (big[i] - 0.5) * 0.2
            return SIMD4(v, v * 1.01, v * 0.98, 1)
        }
    }

    func update(center: SIMD3<Float>, synchronous: Bool = false) {
        let cx = Int(floor(center.x / chunkSize)), cz = Int(floor(center.z / chunkSize))

        // Attach finished chunks (a few per frame to avoid hitches).
        lock.lock()
        let batch = synchronous ? ready : Array(ready.prefix(3))
        ready.removeFirst(batch.count)
        lock.unlock()
        for (key, node) in batch {
            inFlight.remove(key)
            root.addChildNode(node)
            chunks[key] = node
        }

        // Drop far chunks.
        let dropR = Float(radius) + 1.5
        for (key, node) in chunks {
            let dx = Float(key.x - cx), dz = Float(key.z - cz)
            if dx * dx + dz * dz > dropR * dropR {
                node.removeFromParentNode()
                chunks.removeValue(forKey: key)
            }
        }

        // Request missing chunks, nearest first.
        var wanted: [(ChunkKey, Int)] = []
        for dz in -radius...radius {
            for dx in -radius...radius where dx * dx + dz * dz <= radius * radius {
                let k = ChunkKey(x: cx + dx, z: cz + dz)
                if chunks[k] == nil && !inFlight.contains(k) { wanted.append((k, dx * dx + dz * dz)) }
            }
        }
        wanted.sort { $0.1 < $1.1 }
        let budget = synchronous ? wanted.count : max(0, 6 - inFlight.count)
        for (k, _) in wanted.prefix(budget) {
            inFlight.insert(k)
            let work = { [self] in
                let node = buildChunk(k)
                lock.lock(); ready.append((k, node)); lock.unlock()
            }
            if synchronous { work() } else { queue.async(execute: work) }
        }
        if synchronous && !wanted.isEmpty { update(center: center, synchronous: true) }
    }

    // MARK: Chunk generation

    private func buildChunk(_ key: ChunkKey) -> SCNNode {
        var glow = MeshBuilder()
        let high = buildSurface(key, cells: terrain.cells, decorate: true, glow: &glow)
        high.materials = [material]
        if let lowCells = terrain.lowCells {
            var unused = MeshBuilder()
            let low = buildSurface(key, cells: lowCells, decorate: false, glow: &unused)
            low.materials = [material]
            high.levelsOfDetail = [SCNLevelOfDetail(geometry: low, worldSpaceDistance: CGFloat(terrain.lodDistance))]
        }
        let node = SCNNode(geometry: high)
        node.simdPosition = SIMD3(Float(key.x) * chunkSize, 0, Float(key.z) * chunkSize)
        node.castsShadow = true
        node.categoryBitMask = 1 | 2   // also lit by world lights that skip the bird (cave lantern)
        if !glow.isEmpty {
            let g = glow.geometry()
            g.materials = [glowMaterial]
            let gn = SCNNode(geometry: g)
            gn.castsShadow = false
            node.addChildNode(gn)
        }
        return node
    }

    private func buildSurface(_ key: ChunkKey, cells n: Int, decorate: Bool, glow: inout MeshBuilder) -> SCNGeometry {
        let size = chunkSize
        let step = size / Float(n)
        let ox = Float(key.x) * size, oz = Float(key.z) * size
        var m = MeshBuilder()
        m.pos.reserveCapacity((n + 1) * (n + 1) * 3 + 4 * (n + 1) * 3)
        let t = terrain
        addGrid(&m, n: n, step: step, ox: ox, oz: oz, sample: { t.height($0, $1) }, color: t.color, flip: false)
        if t.lowCells != nil {
            // Skirts hide cracks between LOD levels.
            let row = UInt32(n + 1)
            func skirt(_ edge: [UInt32], flip: Bool) {
                var lower: [UInt32] = []
                for v in edge {
                    let vi = Int(v) * 3
                    let p = SIMD3(m.pos[vi], m.pos[vi + 1] - 18, m.pos[vi + 2])
                    let nn = SIMD3(m.nrm[vi], m.nrm[vi + 1], m.nrm[vi + 2])
                    lower.append(m.vertexCount)
                    m.pos += [p.x, p.y, p.z]; m.nrm += [nn.x, nn.y, nn.z]
                    m.col += [m.col[vi], m.col[vi + 1], m.col[vi + 2]]
                    m.uv += [m.uv[Int(v) * 2], m.uv[Int(v) * 2 + 1]]
                }
                for k in 0..<(edge.count - 1) {
                    let a = edge[k], b = edge[k + 1], c = lower[k], d = lower[k + 1]
                    if flip { m.tri(a, b, c); m.tri(b, d, c) } else { m.tri(a, c, b); m.tri(b, c, d) }
                }
            }
            skirt((0...UInt32(n)).map { $0 }, flip: true)                        // z = 0
            skirt((0...UInt32(n)).map { UInt32(n) * row + $0 }, flip: false)     // z = max
            skirt((0...UInt32(n)).map { $0 * row }, flip: false)                 // x = 0
            skirt((0...UInt32(n)).map { $0 * row + UInt32(n) }, flip: true)      // x = max
        }
        if t.ceiling(ox, oz) != nil {
            addGrid(&m, n: n, step: step, ox: ox, oz: oz, sample: { t.ceiling($0, $1) ?? 0 }, color: t.ceilingColor, flip: true)
        }
        if decorate { t.decorate(&m, glow: &glow, key: key, ox: ox, oz: oz) }
        return m.geometry()
    }

    /// One height-field sheet. `flip` makes it face downward (cave ceilings).
    private func addGrid(_ m: inout MeshBuilder, n: Int, step: Float, ox: Float, oz: Float,
                         sample: (Float, Float) -> Float,
                         color: (Float, Float, Float, Float) -> SIMD3<Float>, flip: Bool) {
        let w = n + 3  // one-sample border on each side for normals
        var hs = [Float](repeating: 0, count: w * w)
        for j in 0..<w {
            for i in 0..<w {
                hs[j * w + i] = sample(ox + Float(i - 1) * step, oz + Float(j - 1) * step)
            }
        }
        let base = m.vertexCount
        for j in 0...n {
            for i in 0...n {
                let h = hs[(j + 1) * w + (i + 1)]
                let hx = hs[(j + 1) * w + (i + 2)] - hs[(j + 1) * w + i]
                let hz = hs[(j + 2) * w + (i + 1)] - hs[j * w + (i + 1)]
                var nrm = simd_normalize(SIMD3(-hx, 2 * step, -hz))
                let lx = Float(i) * step, lz = Float(j) * step
                let c = color(h, nrm.y, ox + lx, oz + lz)
                if flip { nrm = -nrm }
                // Detail texture repeats every 16 m; chunk edges land on whole repeats, so it's seamless.
                m.vertex(SIMD3(lx, h, lz), nrm, c * 1.12, uv: SIMD2(lx, lz) / 16)
            }
        }
        let row = UInt32(n + 1)
        for j in 0..<UInt32(n) {
            for i in 0..<UInt32(n) {
                let a = base + j * row + i, b = a + 1, c = a + row, d = c + 1
                if flip { m.tri(a, b, c); m.tri(b, d, c) } else { m.tri(a, c, b); m.tri(b, c, d) }
            }
        }
    }

    static func addTrees(_ m: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float, chunkSize: Float) {
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(key.x &* 73856093 ^ key.z &* 19349663)))
        for _ in 0..<140 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let forest = Noise.fbm(x * 0.0035 + 40, z * 0.0035 - 12, octaves: 2)
            let r = rng.float()
            if forest < -0.02 || r > (forest + 0.1) * 2.2 { continue }
            let h = TerrainShape.height(x, z)
            if h < 5 || h > 250 { continue }
            let n = TerrainShape.normal(x, z, e: 3)
            if n.y < 0.86 { continue }
            let height = rng.float(9, 17) * (h > 170 ? 0.75 : 1)
            let tint = rng.float(-0.05, 0.05)
            let green = SIMD3<Float>(0.12 + tint, 0.30 + tint * 1.5, 0.13)
            addPine(&m, base: SIMD3(lx, h - 0.8, lz), height: height, radius: height * 0.3, foliage: green, yaw: rng.float(0, 6.28))
        }
    }

    static func addPine(_ m: inout MeshBuilder, base: SIMD3<Float>, height: Float, radius: Float, foliage: SIMD3<Float>, yaw: Float) {
        let trunk = SIMD3<Float>(0.35, 0.25, 0.16)
        cone(&m, base: base, height: height * 0.35, radius: radius * 0.13, top: radius * 0.1, sides: 5, color: trunk, yaw: yaw)
        cone(&m, base: base + SIMD3(0, height * 0.22, 0), height: height * 0.55, radius: radius, top: 0, sides: 7, color: foliage * 0.85, yaw: yaw)
        cone(&m, base: base + SIMD3(0, height * 0.5, 0), height: height * 0.5, radius: radius * 0.72, top: 0, sides: 7, color: foliage, yaw: yaw + 0.4)
    }

    static func cone(_ m: inout MeshBuilder, base: SIMD3<Float>, height: Float, radius: Float, top: Float, sides: Int, color: SIMD3<Float>, yaw: Float) {
        let slope = (radius - top) / height
        for s in 0..<sides {
            let a0 = yaw + Float(s) / Float(sides) * 2 * .pi
            let a1 = yaw + Float(s + 1) / Float(sides) * 2 * .pi
            let am = (a0 + a1) * 0.5
            let nrm = simd_normalize(SIMD3(cos(am), slope, sin(am)))
            let b0 = base + SIMD3(cos(a0) * radius, 0, sin(a0) * radius)
            let b1 = base + SIMD3(cos(a1) * radius, 0, sin(a1) * radius)
            let i = m.vertexCount
            if top <= 0.001 {
                let apex = base + SIMD3(0, height, 0)
                m.vertex(b0, nrm, color * 0.8); m.vertex(b1, nrm, color * 0.8); m.vertex(apex, nrm, color * 1.15)
                m.tri(i, i + 2, i + 1)
            } else {
                let t0 = base + SIMD3(cos(a0) * top, height, sin(a0) * top)
                let t1 = base + SIMD3(cos(a1) * top, height, sin(a1) * top)
                m.vertex(b0, nrm, color); m.vertex(b1, nrm, color); m.vertex(t0, nrm, color); m.vertex(t1, nrm, color)
                m.tri(i, i + 2, i + 1); m.tri(i + 1, i + 2, i + 3)
            }
        }
    }
}
