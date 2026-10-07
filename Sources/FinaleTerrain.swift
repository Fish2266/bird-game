import SceneKit
import simd

// The Finale's island: flowering meadows rolling down to the sea, the castle hill in the middle with its road climbing
// from the village, a lake to the north under a ring of snowy mountains, woods and orchards. Golden evening light.

final class FinaleTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 720
    let radius = 7

    // MARK: Shape

    /// Meadows: gentle swells above the sea.
    @inline(__always) private func meadow(_ x: Float, _ z: Float) -> Float {
        5 + 13 * (Noise.fbm(x * 0.0017 + 3.1, z * 0.0017 - 7.7, octaves: 3) * 0.5 + 0.5) + 2.5 * Noise.perlin(x * 0.01, z * 0.01)
    }

    func height(_ x: Float, _ z: Float) -> Float {
        let L = FinaleLayout.self
        let r = simd_length(SIMD2(x, z))
        var h = meadow(x, z)
        // The sea all round the island.
        let coast = L.islandRadius + 120 * Noise.perlin(x * 0.0011 + 9, z * 0.0011 - 4)
        h = lerp(h, -16, smoothstep(coast - 260, coast + 140, r))
        // Mountains in an arc to the north: ridges climbing to snowy peaks.
        let north = smoothstep(-500, -1300, z) * smoothstep(L.islandRadius + 200, 1500, r) * smoothstep(1000, 1700, r)
        if north > 0 {
            let ridge = Noise.ridged(x * 0.0021 + 4.4, z * 0.0021 + 1.9, octaves: 4)
            h += north * (90 + 330 * ridge * ridge)
        }
        // The lake below the castle's north side.
        let lq = (SIMD2(x, z) - L.lake) / L.lakeRadii
        let ld = simd_length(lq) * (1 + 0.16 * Noise.perlin(atan2(lq.y, lq.x) * 1.7 + 3.3, 0.5) + 0.06 * Noise.perlin(x * 0.012, z * 0.012))
        if ld < 1.25 { h = lerp(h, -5, smoothstep(1.2, 0.85, ld)) }
        // The castle hill: a flat top with rocky sides.
        let rock = 10 * Noise.fbm(x * 0.03, z * 0.03, octaves: 2)
        let rr = r + rock * smoothstep(L.plateau - 20, L.plateau + 10, r)
        // (Dead flat inside the walls, so the hall's floor and the paths sit right on it.)
        let hill = L.ground + 0.4 * Noise.perlin(x * 0.05, z * 0.05) * smoothstep(L.wallRadius - 2, L.wallRadius + 40, r)
        h = max(h, lerp(h, hill, smoothstep(L.hillFoot, L.plateau, rr)))
        // The ditch round the walls.
        if r > L.ditchIn - 6 && r < L.ditchOut + 6 && r < L.plateau {
            let d = smoothstep(L.ditchIn - 3, L.ditchIn + 2, r) * smoothstep(L.ditchOut + 3, L.ditchOut - 2, r)
            h -= L.ditchDepth * d
        }
        // The village: level ground round a plaza.
        let vd = simd_distance(SIMD2(x, z), L.village)
        if vd < L.villageRadius + 60 { h = lerp(h, L.villageY, smoothstep(L.villageRadius + 60, L.villageRadius - 20, vd)) }
        // The road up the hill (a causeway where the slope falls away under it).
        if let (y, k) = L.roadY(x, z) { h = lerp(h, y, k) }
        return h
    }

    // MARK: Colour

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let L = FinaleLayout.self
        let n = Noise.perlin(x * 0.02, z * 0.02) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.09 + 3, z * 0.09 - 5) * 0.5 + 0.5
        if h < 0.8 { return simd_mix(SIMD3(0.40, 0.38, 0.30), SIMD3(0.86, 0.80, 0.62), SIMD3(repeating: smoothstep(-2, 0.8, h))) }
        // Grass: rich green with lighter swathes; flowers in drifts (pink, yellow, violet, white).
        var grass = simd_mix(SIMD3<Float>(0.26, 0.50, 0.18), SIMD3(0.46, 0.66, 0.24), SIMD3(repeating: n * 0.8))
        let drift = Noise.perlin(x * 0.012 + 7, z * 0.012 - 2) * 0.5 + 0.5
        if drift > 0.62 {
            let pick = Int((Noise.perlin(x * 0.004 + 1, z * 0.004 + 9) * 0.5 + 0.5) * 3.99)
            let flower: [SIMD3<Float>] = [SIMD3(0.95, 0.55, 0.72), SIMD3(0.98, 0.86, 0.30), SIMD3(0.66, 0.50, 0.92), SIMD3(0.96, 0.94, 0.90)]
            grass = simd_mix(grass, flower[min(pick, 3)], SIMD3(repeating: smoothstep(0.62, 0.8, drift) * 0.55 * smoothstep(0.35, 0.8, n2)))
        }
        // Rock on the steep bits (castle crags, the mountains), snow up high.
        var rockC = simd_mix(SIMD3<Float>(0.52, 0.50, 0.48), SIMD3(0.66, 0.62, 0.56), SIMD3(repeating: n))
        if h > 230 { rockC = simd_mix(rockC, SIMD3(0.95, 0.96, 0.98), SIMD3(repeating: smoothstep(230, 300, h + 30 * (n - 0.5)))) }
        var c = simd_mix(rockC, grass, SIMD3(repeating: smoothstep(0.72, 0.86, ny)))
        if h > 260 && ny > 0.6 { c = simd_mix(c, SIMD3(0.96, 0.97, 0.99), SIMD3(repeating: smoothstep(260, 320, h))) }
        // The road (packed earth with cart ruts) and the village lanes.
        if let (_, k) = L.roadY(x, z) {
            let rut = smoothstep(0.6, 1.2, abs(abs(x) - 2.4))
            c = simd_mix(c, SIMD3(0.70, 0.58, 0.42) * (0.88 + 0.12 * rut) * (0.94 + 0.1 * n2), SIMD3(repeating: k * smoothstep(L.roadHalf + 1, L.roadHalf - 1, abs(x))))
        }
        let vd = simd_distance(SIMD2(x, z), L.village)
        if vd < 60 { c = simd_mix(c, SIMD3(0.72, 0.66, 0.56) * (0.9 + 0.15 * n2), SIMD3(repeating: smoothstep(60, 44, vd))) }
        // The courtyard: lawns with gravel paths, the ditch's bare earth.
        let r = simd_length(SIMD2(x, z))
        if r < L.plateau {
            if L.insideWalls(x, z) {
                let path = abs(x) < 4.2 || (abs(z - 50) < 3.5 && abs(x) < 34)
                if path { c = SIMD3(0.80, 0.76, 0.66) * (0.92 + 0.1 * n2) }
                else { c = simd_mix(SIMD3<Float>(0.30, 0.56, 0.20), SIMD3(0.40, 0.64, 0.24), SIMD3(repeating: n2)) }
            } else if r > L.ditchIn - 2 && r < L.ditchOut + 2 {
                c = simd_mix(c, SIMD3(0.42, 0.36, 0.28), SIMD3(repeating: 0.7))
            }
        }
        return c * (0.94 + 0.1 * n2)
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        // Boulders on the crags and the mountain slopes.
        var rng = cellRNG(key.x, key.z, 0xF1_7A)
        for _ in 0..<18 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let h = height(x, z)
            guard h > 2 else { continue }
            let r = simd_length(SIMD2(x, z))
            if r < FinaleLayout.plateau - 4 { continue }
            if FinaleLayout.roadY(x, z) != nil { continue }
            let slope = abs(height(x + 2, z) - h) + abs(height(x, z + 2) - h)
            guard slope > 1.2 || h > 150 else { continue }
            m.boulder(at: SIMD3(lx, h + 0.3, lz), radius: rng.float(1.2, 3.4), color: SIMD3(0.56, 0.54, 0.5), grass: SIMD3(0.32, 0.52, 0.2), &rng)
        }
    }

    // MARK: Trees, hedges, flowers

    private static let plantMaterial: SCNMaterial = WorldMaterials.vertexColor(rough: 0.9, doubleSided: true)

    /// Woods on the far hills, orchards near the village, poplars along the road, flowers everywhere. `detail` decides
    /// whether the close-up versions are built (the far stand-ins always are).
    private func plants(key: ChunkKey, ox: Float, oz: Float, detail: Bool) -> (near: MeshBuilder, far: MeshBuilder) {
        var near = MeshBuilder(), far = MeshBuilder()
        near.disabled = !detail
        let L = FinaleLayout.self
        var rng = cellRNG(key.x, key.z, 0x7E_E5)
        let spacing: Float = 11
        let n = Int(chunkSize / spacing)
        for j in 0..<n {
            for i in 0..<n {
                let lx = (Float(i) + rng.float(0.1, 0.9)) * spacing, lz = (Float(j) + rng.float(0.1, 0.9)) * spacing
                let x = ox + lx, z = oz + lz
                let roll = rng.float(), kind = rng.float()
                let h = height(x, z)
                guard h > 1.5, h < 200 else { continue }
                let r = simd_length(SIMD2(x, z))
                if r < L.hillFoot - 10 { continue }
                if let (_, k) = L.roadY(x, z), k > 0.05 {
                    // Poplars standing in a line beside the road.
                    if abs(abs(x) - 12) < 1.6 && Int(z) % 3 == 0 && roll < 0.5 {
                        let ht = rng.float(11, 15)
                        near.poplar(at: SIMD3(lx, h - 0.2, lz), height: ht, &rng)
                        far.farBlob(at: SIMD3(lx, h - 0.2, lz), height: ht, color: SIMD3(0.24, 0.42, 0.18))
                    }
                    continue
                }
                if simd_distance(SIMD2(x, z), L.village) < L.villageRadius - 30 { continue }
                let sx = height(x + 2.5, z) - h, sz = height(x, z + 2.5) - h
                guard sx * sx + sz * sz < 2.4 else { continue }
                let p = SIMD3(lx, h - 0.2, lz)
                let wood = Noise.fbm(x * 0.003 + 11, z * 0.003 - 6, octaves: 2)
                let orchard = simd_distance(SIMD2(x, z), L.village) < L.villageRadius + 220
                if wood > 0.12 && roll < 0.5 {
                    let ht = rng.float(9, 16)
                    near.roundTree(at: p, height: ht, &rng)
                    far.farBlob(at: p, height: ht, color: SIMD3(0.22, 0.42, 0.16))
                } else if orchard && roll < 0.12 {
                    let ht = rng.float(4, 6)
                    near.blossomTree(at: p, height: ht, &rng)
                    far.farBlob(at: p, height: ht, color: SIMD3(0.92, 0.70, 0.78))
                } else if roll < 0.035 {
                    let ht = rng.float(7, 12)
                    near.roundTree(at: p, height: ht, &rng)
                    far.farBlob(at: p, height: ht, color: SIMD3(0.24, 0.44, 0.17))
                } else if roll < 0.5 && kind < 0.6 {
                    near.flowerClump(at: p, &rng)
                }
            }
        }
        return (near, far)
    }

    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var out = FinaleVillage.nodes(key: key, ox: ox, oz: oz, self)
        let (_, far) = plants(key: key, ox: ox, oz: oz, detail: false)
        if !far.isEmpty {
            let g = far.geometry()
            g.materials = [FinaleTerrain.plantMaterial]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 2000)]
            let n = SCNNode(geometry: g)
            n.name = "swap:plants"
            n.castsShadow = true
            out.append(n)
        }
        return out
    }

    var detailDistance: Float { 560 }

    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        let (near, far) = plants(key: key, ox: ox, oz: oz, detail: true)
        guard !near.isEmpty else { return [] }
        let g = near.geometry()
        g.materials = [FinaleTerrain.plantMaterial]
        var lods: [SCNLevelOfDetail] = []
        if !far.isEmpty {
            let low = far.geometry()
            low.materials = [FinaleTerrain.plantMaterial]
            lods.append(SCNLevelOfDetail(geometry: low, worldSpaceDistance: 460))
        }
        lods.append(SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 2000))
        g.levelsOfDetail = lods
        let n = SCNNode(geometry: g)
        n.name = "plants"
        n.castsShadow = true
        return [n]
    }
}

// MARK: - Plants

extension MeshBuilder {
    /// A round broadleaf tree: a short trunk, a cloud of leaf clumps.
    mutating func roundTree(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let bark = SIMD3<Float>(0.38, 0.28, 0.2)
        let leaf = SIMD3<Float>(0.26, 0.50, 0.18) * rng.float(0.85, 1.15)
        tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h * 0.5, 0), r0: h * 0.05, r1: h * 0.035, sides: 6, bark)
        ellipsoid(p + SIMD3(0, h * 0.66, 0), SIMD3(h * 0.34, h * 0.3, h * 0.34), leaf, rings: 4, sides: 8)
        for k in 0..<3 {
            let a = rng.float(0, 6.28) + Float(k) * 2.1
            ellipsoid(p + SIMD3(cos(a) * h * 0.2, h * (0.58 + 0.08 * Float(k)), sin(a) * h * 0.2), SIMD3(repeating: h * 0.2),
                      leaf * rng.float(0.9, 1.12), rings: 3, sides: 7)
        }
    }

    /// A tall, slim poplar.
    mutating func poplar(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h * 0.3, 0), r0: h * 0.03, r1: h * 0.025, sides: 5, SIMD3(0.42, 0.36, 0.28))
        ellipsoid(p + SIMD3(0, h * 0.6, 0), SIMD3(h * 0.11, h * 0.42, h * 0.11), SIMD3(0.24, 0.44, 0.17) * rng.float(0.9, 1.1), rings: 5, sides: 7)
    }

    /// A little fruit tree in blossom.
    mutating func blossomTree(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        tube(p - SIMD3(0, 0.2, 0), p + SIMD3(0, h * 0.45, 0), r0: h * 0.05, r1: h * 0.035, sides: 5, SIMD3(0.40, 0.30, 0.24))
        let pink = simd_mix(SIMD3<Float>(0.98, 0.78, 0.86), SIMD3(0.96, 0.95, 0.94), SIMD3(repeating: rng.float(0, 0.6)))
        ellipsoid(p + SIMD3(0, h * 0.68, 0), SIMD3(h * 0.4, h * 0.3, h * 0.4), pink, rings: 4, sides: 8)
        ellipsoid(p + SIMD3(h * 0.15, h * 0.8, -h * 0.1), SIMD3(repeating: h * 0.22), pink * 1.02, rings: 3, sides: 6)
    }

    /// A tuft of flowers.
    mutating func flowerClump(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        let cols: [SIMD3<Float>] = [SIMD3(0.98, 0.55, 0.70), SIMD3(0.98, 0.86, 0.30), SIMD3(0.70, 0.52, 0.95), SIMD3(0.98, 0.96, 0.92), SIMD3(0.95, 0.35, 0.30)]
        let c = cols[Int(rng.float(0, Float(cols.count) - 0.01))]
        ellipsoid(p + SIMD3(0, 0.25, 0), SIMD3(0.55, 0.22, 0.55), SIMD3(0.30, 0.52, 0.2), rings: 2, sides: 6)
        for _ in 0..<4 {
            let q = p + SIMD3(rng.float(-0.45, 0.45), rng.float(0.42, 0.62), rng.float(-0.45, 0.45))
            ellipsoid(q, SIMD3(repeating: rng.float(0.09, 0.14)), c * rng.float(0.92, 1.05), rings: 2, sides: 5)
        }
    }
}
