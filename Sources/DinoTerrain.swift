import SceneKit
import simd

// Dino Valley: broad green valleys with rivers and lakes, walled by jungle-topped cliffs, and a smoking volcano or two
// on the skyline. The valleys are the zero lines of two warped noise fields, so they wind, branch and cross; their
// floors are meadows and fern forests where the dinosaurs roam.

final class DinoTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 720
    let radius = 7
    static let volcanoCell: Float = 3600

    // MARK: Shape

    /// The two valley fields (zero along the middle of each valley network).
    @inline(__always) private func fields(_ x: Float, _ z: Float) -> (Float, Float) {
        let wx = x + 260 * Noise.perlin(x * 0.0004 + 7.1, z * 0.0004 - 2.3)
        let wz = z + 260 * Noise.perlin(x * 0.0004 - 4.4, z * 0.0004 + 9.2)
        return (Noise.perlin(wx * 0.00052 + 0.37, wz * 0.00052 + 0.71), Noise.perlin(wx * 0.00085 + 31.7, wz * 0.00085 - 12.9))
    }

    /// Roughly how far (m) a point is from the middle of each valley network.
    func valleyDistances(_ x: Float, _ z: Float) -> (Float, Float) {
        let e: Float = 3
        let (a, b) = fields(x, z)
        let (ax, bx) = fields(x + e, z)
        let (az, bz) = fields(x, z + e)
        let ga = simd_length(SIMD2(ax - a, az - a)) / e
        let gb = simd_length(SIMD2(bx - b, bz - b)) / e
        return (abs(a) / max(ga, 1e-6), abs(b) / max(gb, 1e-6))
    }

    /// Half-widths of the two networks' valleys (meadow floor, before the cliffs).
    @inline(__always) func valleyWidths(_ x: Float, _ z: Float) -> (Float, Float) {
        (150 + 70 * Noise.perlin(x * 0.0005 + 11.3, z * 0.0005 - 3.7), 100 + 40 * Noise.perlin(x * 0.0007 - 8.1, z * 0.0007 + 2.9))
    }

    /// Half-width of the river (swelling into lakes in places).
    @inline(__always) func riverHalf(_ x: Float, _ z: Float) -> Float {
        19 + 52 * smoothstep(0.22, 0.62, Noise.perlin(x * 0.0015 + 3.1, z * 0.0015 - 8.3))
    }

    /// Height of the jungle plateau the valleys are cut into (with mountains here and there).
    @inline(__always) func plateau(_ x: Float, _ z: Float) -> Float {
        let r = Noise.ridged(x * 0.0006 + 4.2, z * 0.0006 - 1.9, octaves: 3)
        let m = max(0, r - 0.5) / 0.5
        return 125 + 42 * Noise.fbm(x * 0.0012 + 2.2, z * 0.0012 - 5.1, octaves: 3) + 120 * m * m
    }

    /// The volcano in a cell, if any: (x, z, radius, height).
    func volcano(_ i: Int, _ j: Int) -> SIMD4<Float>? {
        var rng = cellRNG(i, j, 0xD1_7A0)
        guard rng.float() < 0.5 else { return nil }
        let c = Self.volcanoCell
        return SIMD4((Float(i) + rng.float(0.28, 0.72)) * c, (Float(j) + rng.float(0.28, 0.72)) * c, rng.float(640, 820), rng.float(390, 480))
    }

    /// The nearest volcano to a point (for the runtime's smoke plume and the colours).
    func nearestVolcano(_ x: Float, _ z: Float) -> SIMD4<Float>? {
        let c = Self.volcanoCell
        let ci = Int(floor(x / c)), cj = Int(floor(z / c))
        var best: SIMD4<Float>?
        for dj in -1...1 {
            for di in -1...1 {
                guard let v = volcano(ci + di, cj + dj) else { continue }
                if best == nil || simd_distance(SIMD2(v.x, v.y), SIMD2(x, z)) < simd_distance(SIMD2(best!.x, best!.y), SIMD2(x, z)) { best = v }
            }
        }
        return best
    }

    /// Cone height above 60 m at a point (0 outside any volcano), and how far up it you are (0…1).
    @inline(__always) private func cone(_ x: Float, _ z: Float) -> (Float, Float) {
        let c = Self.volcanoCell
        let ci = Int(floor(x / c)), cj = Int(floor(z / c))
        var best: Float = 0, up: Float = 0
        for dj in -1...1 {
            for di in -1...1 {
                guard let v = volcano(ci + di, cj + dj) else { continue }
                let d = simd_length(SIMD2(x - v.x, z - v.y))
                guard d < v.z else { continue }
                let t = 1 - d / v.z
                var h = v.w * pow(t, 1.6)
                // Gullies and ridges running down the flanks.
                let ang = atan2(z - v.y, x - v.x)
                let rib = Noise.ridged(ang * 2.6 + v.x * 0.001, d * 0.012, octaves: 2)
                h *= 1 + 0.07 * (rib - 0.5) * smoothstep(0.05, 0.4, t) * smoothstep(0.95, 0.75, t)
                let crater = v.z * 0.13
                if d < crater { h -= v.w * 0.3 * smoothstep(crater, crater * 0.35, d) }
                if h > best { best = h; up = t }
            }
        }
        return (best, up)
    }

    /// Crater floor (where the lava pool sits) of a volcano.
    func craterFloor(_ v: SIMD4<Float>) -> Float { 60 + v.w * 0.7 }

    /// One network's ground at distance `d` from its valley's middle.
    @inline(__always) private func profile(_ d: Float, width w: Float, river: Float, plateau P: Float, bumps: Float) -> Float {
        let floorT = min(1, max(0, d - river) / max(w - river, 1))
        let floorH = 2.6 + 7 * floorT * floorT + bumps
        let bed = -1.2 - 3.2 * max(0, 1 - (d / river) * (d / river))
        var h = lerp(bed, floorH, smoothstep(river - 2, river + 7, d))
        if d > w {
            // A cliff band with a ledge partway up.
            let s = min(1, (d - w) / 78)
            let k = 0.55 * smoothstep(0, 0.42, s) + 0.45 * smoothstep(0.52, 1, s)
            h = floorH + (max(P, floorH) - floorH) * k
        }
        return h
    }

    func height(_ x: Float, _ z: Float) -> Float {
        var (d1, d2) = valleyDistances(x, z)
        let (w1, w2) = valleyWidths(x, z)
        let river = riverHalf(x, z)
        // The cliff line meanders: spurs reach into the valley, alcoves cut back (the river keeps its course).
        let wiggle = 40 * Noise.perlin(x * 0.0045 + 1.7, z * 0.0045 - 6.2) + 15 * Noise.perlin(x * 0.014 - 2.2, z * 0.014 + 3.3)
        d1 += wiggle * smoothstep(river + 25, w1 * 0.75, d1)
        d2 += wiggle * smoothstep(river + 25, w2 * 0.75, d2 * 1.15)
        let P = plateau(x, z) + 9 * Noise.fbm(x * 0.004 + 9, z * 0.004 - 4, octaves: 2)
        let bumps = 2.4 * Noise.fbm(x * 0.008 - 3, z * 0.008 + 7, octaves: 2)
        var h = min(profile(d1, width: w1, river: river, plateau: P, bumps: bumps),
                    profile(d2 * 1.15, width: w2, river: river * 0.8, plateau: P, bumps: bumps))
        let (c, _) = cone(x, z)
        if c > 0 { h = max(h, 60 + c) }
        return h
    }

    func configure(ground: SCNMaterial, glow: SCNMaterial) { WorldShaders.triplanarGround(ground) }

    // MARK: Colour

    /// Forest density (> 0: groves of tree ferns and conifers; < 0: open meadow).
    @inline(__always) func forest(_ x: Float, _ z: Float) -> Float {
        Noise.fbm(x * 0.0042 + 50.3, z * 0.0042 - 21.7, octaves: 3)
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.018, z * 0.018) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.07 + 5, z * 0.07 - 3) * 0.5 + 0.5
        let mud = SIMD3<Float>(0.30, 0.29, 0.21), sand = SIMD3<Float>(0.64, 0.58, 0.42)
        let meadow = SIMD3<Float>(0.46, 0.60, 0.22), lush = SIMD3<Float>(0.31, 0.49, 0.16), shade = SIMD3<Float>(0.21, 0.32, 0.12)
        let rockA = SIMD3<Float>(0.76, 0.58, 0.40), rockB = SIMD3<Float>(0.58, 0.44, 0.33), rockC = SIMD3<Float>(0.84, 0.74, 0.58)
        let moss = SIMD3<Float>(0.32, 0.45, 0.17)
        if h < 0.3 { return simd_mix(mud, sand * 0.85, SIMD3(repeating: smoothstep(-3.5, 0.3, h))) }
        // Volcano flanks: black basalt and grey ash near the top.
        let (c, up) = cone(x, z)
        if c > 0 && h > 58 + c * 0.6 {
            let basalt = SIMD3<Float>(0.19, 0.17, 0.17), ash = SIMD3<Float>(0.44, 0.41, 0.39)
            var v = simd_mix(basalt, ash, SIMD3(repeating: smoothstep(0.5, 0.85, up) * (0.6 + 0.4 * n)))
            v = simd_mix(v, lush * 0.8, SIMD3(repeating: smoothstep(0.32, 0.12, up) * smoothstep(0.7, 0.85, ny)))
            return v
        }
        var g: SIMD3<Float>
        let f = forest(x, z)
        g = simd_mix(meadow, lush, SIMD3(repeating: smoothstep(-0.25, 0.1, f + n * 0.15)))
        g = simd_mix(g, shade, SIMD3(repeating: smoothstep(0.05, 0.3, f) * 0.8))
        // Drier, yellower meadows here and there, away from the groves.
        let dry = smoothstep(0.1, 0.5, Noise.perlin(x * 0.0025 + 7.7, z * 0.0025 - 1.3)) * smoothstep(0.05, -0.2, f)
        g = simd_mix(g, SIMD3(0.6, 0.62, 0.3), SIMD3(repeating: dry * 0.55))
        g *= 0.9 + 0.2 * n2
        // Plateau tops are jungle: darker, mossier.
        g = simd_mix(g, shade * 1.05, SIMD3(repeating: smoothstep(60, 110, h) * 0.75))
        // A narrow sandy strip along the water, then muddy grass.
        if h < 3.0 { g = simd_mix(sand, g * 0.85, SIMD3(repeating: smoothstep(0.6, 2.4, h + (n - 0.5) * 1.2))) }
        // Cliffs: layered rock (warm sandstone, darker bands, a pale band now and then), mossy on the ledges.
        let wob = n * 3.2 + Noise.perlin(x * 0.004, z * 0.004) * 4
        let band = sin(h * 0.21 + wob) * 0.5 + 0.5
        var rock = simd_mix(rockA, rockB, SIMD3(repeating: smoothstep(0.3, 0.7, band)))
        rock = simd_mix(rock, rockC, SIMD3(repeating: smoothstep(0.86, 0.97, sin(h * 0.067 + wob * 0.5) * 0.5 + 0.5)))
        rock *= 0.9 + 0.2 * n2
        rock = simd_mix(rock, moss, SIMD3(repeating: smoothstep(0.42, 0.72, ny) * 0.6))
        return simd_mix(rock, g, SIMD3(repeating: smoothstep(0.66, 0.8, ny)))
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        // Boulders and fallen logs ride in the ground mesh; the plants have their own nodes (extraNodes).
        var rng = cellRNG(key.x, key.z, 0xD0_B0)
        for _ in 0..<22 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let h = height(x, z)
            guard h > 2.5 else { continue }
            let slope = abs(height(x + 2, z) - h) + abs(height(x, z + 2) - h)
            if slope > 2.4 {
                if rng.float() < 0.5 { m.boulder(at: SIMD3(lx, h, lz), radius: rng.float(1.5, 4), color: SIMD3(0.5, 0.42, 0.34), &rng) }
            } else if rng.float() < 0.35 && h < 60 {
                // A fallen trunk, mossy on top.
                let a = rng.float(0, 6.28), len = rng.float(8, 16)
                let d = SIMD3(cos(a), 0, sin(a)) * len / 2
                let a0 = SIMD3(lx, h + 0.5, lz) - d, a1 = SIMD3(lx, h + 0.6, lz) + d
                m.tube(a0, a1, r0: 0.75, r1: 0.55, sides: 6, SIMD3(0.36, 0.28, 0.2), cap: true)
                m.tube(a0 + SIMD3(0, 0.25, 0), a1 + SIMD3(0, 0.2, 0), r0: 0.62, r1: 0.45, sides: 5, SIMD3(0.28, 0.42, 0.15))
            } else {
                m.boulder(at: SIMD3(lx, h + 0.3, lz), radius: rng.float(0.9, 2.2), color: SIMD3(0.5, 0.45, 0.38), grass: SIMD3(0.3, 0.45, 0.16), &rng)
            }
        }
        // The lava pool in a volcano's crater.
        if let v = nearestVolcano(ox + chunkSize / 2, oz + chunkSize / 2), v.x >= ox, v.x < ox + chunkSize, v.y >= oz, v.y < oz + chunkSize {
            let c = SIMD3(v.x - ox, craterFloor(v) + 1.5, v.y - oz)
            glow.ellipsoid(c, SIMD3(v.z * 0.075, 1.2, v.z * 0.075), SIMD3(1, 0.42, 0.08), rings: 3, sides: 14)
        }
    }

    // MARK: Plants

    private static let plantMaterial: SCNMaterial = WorldMaterials.vertexColor(rough: 0.9, doubleSided: true)

    /// Plants for a chunk. The same placements every time (seeded per chunk); `detail` decides whether the close-up
    /// meshes are built or just the far stand-ins.
    private func plants(key: ChunkKey, ox: Float, oz: Float, detail: Bool) -> (near: MeshBuilder, small: MeshBuilder, far: MeshBuilder) {
        var near = MeshBuilder(), small = MeshBuilder(), far = MeshBuilder()
        near.disabled = !detail
        small.disabled = !detail
        var rng = cellRNG(key.x, key.z, 0xF3_A7)
        let spacing: Float = 11
        let n = Int(chunkSize / spacing)
        for j in 0..<n {
            for i in 0..<n {
                let lx = (Float(i) + rng.float(0.1, 0.9)) * spacing, lz = (Float(j) + rng.float(0.1, 0.9)) * spacing
                let x = ox + lx, z = oz + lz
                let h = height(x, z)
                let roll = rng.float()
                guard h > 1.6 else { continue }
                let sx = height(x + 2.5, z) - h, sz = height(x, z + 2.5) - h
                let slope = sqrt(sx * sx + sz * sz) / 2.5
                guard slope < 0.6 else { continue }
                let p = SIMD3(lx, h - 0.2, lz)
                let (c, _) = cone(x, z)
                if c > 0 && h > 58 + c * 0.45 { continue }   // bare volcano slopes
                let f = forest(x, z)
                if h > 55 {
                    // Jungle on the plateau: dense, tall.
                    guard roll < 0.9 - slope * 0.6 else { continue }
                    let kind = rng.float()
                    if kind < 0.4 {
                        let ht = rng.float(20, 32)
                        near.araucaria(at: p, height: ht, &rng)
                        far.farConifer(at: p, height: ht)
                    } else {
                        let ht = rng.float(12, 19)
                        near.jungleTree(at: p, height: ht, &rng)
                        far.farBroadleaf(at: p, height: ht)
                    }
                } else if h < 3.6 {
                    // Horsetails and reeds along the banks.
                    if roll < 0.32 { small.horsetails(at: p, &rng) }
                } else if f > 0.04 {
                    // Fern forest groves on the valley floor.
                    guard roll < 0.5 + f else { continue }
                    let kind = rng.float()
                    if kind < 0.35 {
                        near.treeFern(at: p, height: rng.float(3.5, 7.5), &rng)
                    } else if kind < 0.55 {
                        let ht = rng.float(18, 28)
                        near.araucaria(at: p, height: ht, &rng)
                        far.farConifer(at: p, height: ht)
                    } else if kind < 0.75 {
                        small.cycad(at: p, &rng)
                    } else {
                        let ht = rng.float(10, 16)
                        near.jungleTree(at: p, height: ht, &rng)
                        far.farBroadleaf(at: p, height: ht)
                    }
                } else {
                    // Open meadow: a lone cycad or tree fern now and then, ferns in the grass.
                    if roll < 0.035 { near.treeFern(at: p, height: rng.float(3, 6), &rng) }
                    else if roll < 0.07 { small.cycad(at: p, &rng) }
                    else if roll < 0.2 { small.groundFern(at: p, &rng) }
                }
            }
        }
        return (near, small, far)
    }

    /// Every loaded chunk keeps simple stand-in trees (out to the haze) and its landmarks.
    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var out = landmarkNodes(key: key, ox: ox, oz: oz)
        let (_, _, far) = plants(key: key, ox: ox, oz: oz, detail: false)
        guard !far.isEmpty else { return out }
        let g = far.geometry()
        g.materials = [DinoTerrain.plantMaterial]
        g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 2600)]
        let n = SCNNode(geometry: g)
        n.name = "swap:trees"
        n.castsShadow = true
        out.append(n)
        return out
    }

    /// Near the bird: the real trees (handing over to the stand-ins further out) and the small plants.
    var detailDistance: Float { 600 }

    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        let (near, small, far) = plants(key: key, ox: ox, oz: oz, detail: true)
        var out: [SCNNode] = []
        if !near.isEmpty || !far.isEmpty {
            let g = (near.isEmpty ? far : near).geometry()
            g.materials = [DinoTerrain.plantMaterial]
            var lods: [SCNLevelOfDetail] = []
            if !near.isEmpty && !far.isEmpty {
                let low = far.geometry()
                low.materials = [DinoTerrain.plantMaterial]
                lods.append(SCNLevelOfDetail(geometry: low, worldSpaceDistance: 520))
            }
            lods.append(SCNLevelOfDetail(geometry: nil, worldSpaceDistance: near.isEmpty ? 2600 : (far.isEmpty ? 520 : 2600)))
            g.levelsOfDetail = lods
            let n = SCNNode(geometry: g)
            n.name = "trees"
            n.castsShadow = true
            out.append(n)
        }
        if !small.isEmpty {
            let g = small.geometry()
            g.materials = [DinoTerrain.plantMaterial]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 380)]
            let n = SCNNode(geometry: g)
            n.name = "small plants"
            n.castsShadow = false
            out.append(n)
        }
        return out
    }

    // MARK: Queries for the runtime

    /// Gentle valley floor (somewhere a dinosaur can walk).
    func walkable(_ x: Float, _ z: Float) -> Bool {
        let h = height(x, z)
        guard h > 1.8 && h < 40 else { return false }
        let sx = height(x + 3, z) - h, sz = height(x, z + 3) - h
        return sx * sx + sz * sz < 3.2
    }
}

// MARK: - Prehistoric plants

extension MeshBuilder {
    /// A monkey-puzzle conifer: a tall bare trunk, flat whorls of branches near the top and a domed crown.
    mutating func araucaria(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let bark = SIMD3<Float>(0.38, 0.29, 0.21)
        let leaf = SIMD3<Float>(0.15, 0.29, 0.12) * rng.float(0.85, 1.2)
        tube(p - SIMD3(0, 0.5, 0), p + SIMD3(0, h, 0), r0: h * 0.03, r1: h * 0.012, sides: 5, bark)
        for t in 0..<4 {
            let y = h * (0.6 + 0.1 * Float(t))
            let len = h * (0.25 - 0.045 * Float(t))
            let a0 = rng.float(0, 6.28)
            let base = p + SIMD3(0, y, 0)
            for k in 0..<5 {
                let a = a0 + Float(k) / 5 * 2 * .pi
                let out = SIMD3(cos(a), 0, sin(a)), side = SIMD3(-sin(a), 0, cos(a))
                let w = len * 0.2
                let tip = base + out * len + SIMD3(0, len * 0.12, 0)
                let mid = base + out * len * 0.55 + SIMD3(0, -len * 0.04, 0)
                // A drooping blade, slightly cupped.
                quad(base - side * w * 0.3, mid - side * w, mid + side * w, base + side * w * 0.3, leaf, facing: kUp)
                quad(mid - side * w, tip - side * w * 0.35, tip + side * w * 0.35, mid + side * w, leaf * 1.12, facing: kUp)
            }
        }
        ellipsoid(p + SIMD3(0, h * 0.98, 0), SIMD3(h * 0.09, h * 0.06, h * 0.09), leaf * 1.15, rings: 3, sides: 6)
    }

    /// A tree fern: a shaggy trunk and a crown of arching fronds.
    mutating func treeFern(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let trunk = SIMD3<Float>(0.33, 0.25, 0.17)
        let leaf = SIMD3<Float>(0.32, 0.55, 0.16) * rng.float(0.85, 1.15)
        let lean = SIMD3(rng.float(-0.1, 0.1), 1, rng.float(-0.1, 0.1))
        let top = p + simd_normalize(lean) * h
        tube(p - SIMD3(0, 0.3, 0), top, r0: 0.32, r1: 0.22, sides: 5, trunk)
        let fronds = 9
        let a0 = rng.float(0, 6.28)
        for k in 0..<fronds {
            let a = a0 + Float(k) / Float(fronds) * 2 * .pi + rng.float(-0.15, 0.15)
            let out = SIMD3(cos(a), 0, sin(a)), side = SIMD3(-sin(a), 0, cos(a))
            let L = h * rng.float(0.45, 0.6)
            let p0 = top
            let p1 = top + out * L * 0.4 + SIMD3(0, L * 0.28, 0)
            let p2 = top + out * L * 0.8 + SIMD3(0, L * 0.12, 0)
            let p3 = top + out * L * 1.05 - SIMD3(0, L * 0.25, 0)
            let w0: Float = 0.12, w1 = L * 0.16, w2 = L * 0.13, w3: Float = 0.05
            quad(p0 - side * w0, p1 - side * w1, p1 + side * w1, p0 + side * w0, leaf * 0.9, facing: kUp)
            quad(p1 - side * w1, p2 - side * w2, p2 + side * w2, p1 + side * w1, leaf, facing: kUp)
            quad(p2 - side * w2, p3 - side * w3, p3 + side * w3, p2 + side * w2, leaf * 1.1, facing: kUp)
        }
    }

    /// A cycad: a stubby scaly trunk with a stiff rosette of fronds.
    mutating func cycad(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        let h = rng.float(0.7, 2.2)
        let trunk = SIMD3<Float>(0.42, 0.34, 0.22)
        let leaf = SIMD3<Float>(0.24, 0.45, 0.14) * rng.float(0.85, 1.15)
        tube(p - SIMD3(0, 0.2, 0), p + SIMD3(0, h, 0), r0: 0.45, r1: 0.38, sides: 6, trunk)
        let top = p + SIMD3(0, h, 0)
        let a0 = rng.float(0, 6.28)
        for k in 0..<11 {
            let a = a0 + Float(k) / 11 * 2 * .pi
            let up: Float = k % 2 == 0 ? 0.55 : 0.25
            let dir = simd_normalize(SIMD3(cos(a), up, sin(a)))
            let side = SIMD3(-sin(a), 0, cos(a)) * 0.22
            let L = rng.float(1.4, 2.2)
            let mid = top + dir * L * 0.45
            quad(top, mid - side, top + dir * L, mid + side, leaf * (k % 2 == 0 ? 1.08 : 0.95), facing: kUp)
        }
    }

    /// A clump of ferns on the ground.
    mutating func groundFern(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        let leaf = SIMD3<Float>(0.34, 0.56, 0.18) * rng.float(0.85, 1.15)
        let a0 = rng.float(0, 6.28)
        for k in 0..<6 {
            let a = a0 + Float(k) / 6 * 2 * .pi
            let dir = simd_normalize(SIMD3(cos(a), 0.7, sin(a)))
            let side = SIMD3(-sin(a), 0, cos(a)) * 0.2
            let L = rng.float(1.0, 1.8)
            let mid = p + dir * L * 0.5 + SIMD3(0, 0.15, 0)
            quad(p, mid - side, p + dir * L + SIMD3(0, -L * 0.25, 0), mid + side, leaf, facing: kUp)
        }
    }

    /// Giant horsetails: a clump of jointed green stalks.
    mutating func horsetails(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        for _ in 0..<Int(rng.float(5, 9)) {
            let q = p + SIMD3(rng.float(-1.2, 1.2), 0, rng.float(-1.2, 1.2))
            let h = rng.float(1.6, 3.4)
            let top = q + SIMD3(rng.float(-0.25, 0.25), h, rng.float(-0.25, 0.25))
            tube(q - SIMD3(0, 0.2, 0), top, r0: 0.07, r1: 0.035, sides: 3, SIMD3(0.36, 0.52, 0.2) * rng.float(0.85, 1.1))
            tube(q + (top - q) * 0.5, q + (top - q) * 0.56, r0: 0.09, r1: 0.09, sides: 3, SIMD3(0.22, 0.3, 0.14))
        }
    }

    /// A broadleaf jungle tree: a straight trunk and a heap of leafy blobs.
    mutating func jungleTree(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let bark = SIMD3<Float>(0.40, 0.34, 0.27)
        let leaf = SIMD3<Float>(0.19, 0.36, 0.12) * rng.float(0.85, 1.2)
        tube(p - SIMD3(0, 0.5, 0), p + SIMD3(0, h * 0.8, 0), r0: h * 0.045, r1: h * 0.025, sides: 5, bark)
        let top = p + SIMD3(0, h * 0.78, 0)
        let r = h * 0.3
        ellipsoid(top + SIMD3(0, r * 0.3, 0), SIMD3(r, r * 0.62, r), leaf, rings: 4, sides: 7)
        for k in 0..<3 {
            let a = rng.float(0, 6.28) + Float(k) * 2.1
            let o = SIMD3(cos(a) * r * 0.75, rng.float(-0.15, 0.25) * r, sin(a) * r * 0.75)
            ellipsoid(top + o, SIMD3(r * 0.66, r * 0.48, r * 0.66), leaf * rng.float(0.85, 1.25), rings: 3, sides: 7)
        }
    }

    /// Far stand-ins: a pole with an umbrella, or a single blob.
    mutating func farConifer(at p: SIMD3<Float>, height h: Float) {
        tube(p, p + SIMD3(0, h * 0.9, 0), r0: h * 0.03, r1: h * 0.015, sides: 3, SIMD3(0.38, 0.29, 0.21))
        ellipsoid(p + SIMD3(0, h * 0.8, 0), SIMD3(h * 0.22, h * 0.14, h * 0.22), SIMD3(0.15, 0.29, 0.12), rings: 2, sides: 5)
    }

    mutating func farBroadleaf(at p: SIMD3<Float>, height h: Float) {
        ellipsoid(p + SIMD3(0, h * 0.82, 0), SIMD3(h * 0.38, h * 0.3, h * 0.38), SIMD3(0.19, 0.36, 0.12), rings: 2, sides: 5)
    }
}
