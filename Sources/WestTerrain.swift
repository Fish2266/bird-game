import SceneKit
import simd

// The Wild West's land: a high desert plateau cut by a winding canyon a couple of hundred metres deep — stepped walls
// of red, buff and cream rock, a green river at the bottom, buttes standing in the canyon and mesas on the plateau —
// with the railroad's beds and the towns' ground levelled into it.

final class WestTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 720
    let radius = 7
    static let butteCell: Float = 700
    static let mesaCell: Float = 1150

    // MARK: Shape

    /// River half-width at a point.
    @inline(__always) func riverHalf(_ x: Float, _ z: Float) -> Float { 26 + 10 * Noise.perlin(x * 0.002 + 4.4, z * 0.002 - 1.7) }

    /// Steps up the canyon wall: cliffs (steep) and benches (gentle), 0…1 from the inner gorge to the rim. `span` is
    /// the wall's width in metres: no cliff is squeezed into less than ~9 m (a narrower one breaks up on the mesh).
    @inline(__always) private func terrace(_ t: Float, span: Float) -> Float {
        let steps: [(Float, Float, Float)] = [(0.02, 0.05, 0.26), (0.32, 0.045, 0.2), (0.58, 0.045, 0.2), (0.86, 0.05, 0.24)]
        let minW = 9 / max(span, 1)
        var v: Float = 0.1 * min(t / 0.92, 1)
        for (a, w, h) in steps { v += h * smoothstep(a, a + max(w, minW), t) }
        return min(v, 1)
    }

    /// One canyon network's ground at distance `d` from its middle.
    @inline(__always) private func profile(_ d: Float, width W: Float, river R: Float, top P: Float) -> Float {
        let gorgeTop: Float = 34
        let G = R + 42
        if d < R {
            let u = d / R
            return -1.4 - 2.6 * (1 - u * u)
        }
        if d < G {
            let u = (d - R) / (G - R)
            return lerp(-1.4, gorgeTop, pow(smoothstep(0, 1, u), 0.75))
        }
        guard d < W else { return P }
        let t = (d - G) / max(W - G, 1)
        return gorgeTop + (P - gorgeTop) * terrace(t, span: W - G)
    }

    /// The butte in a cell, if any: (x, z, radius, top). Only inside the great canyon.
    func butte(_ i: Int, _ j: Int) -> SIMD4<Float>? {
        var rng = cellRNG(i, j, 0xB0_77)
        guard rng.float() < 0.42 else { return nil }
        let c = Self.butteCell
        let x = (Float(i) + rng.float(0.2, 0.8)) * c, z = (Float(j) + rng.float(0.2, 0.8)) * c
        let (d1, _) = WestLayout.canyonDistances(x, z)
        let (w1, _) = WestLayout.canyonWidths(x, z)
        let r = rng.float(42, 105)
        guard d1 > riverHalf(x, z) + r * 0.7 + 30, d1 < w1 - r * 0.9 - 40 else { return nil }
        return SIMD4(x, z, r, WestLayout.rim - rng.float(12, 70))
    }

    /// The mesa in a cell, if any: (x, z, radius, height above the plateau). On the plateau, clear of the railroad.
    func mesa(_ i: Int, _ j: Int) -> SIMD4<Float>? {
        var rng = cellRNG(i, j, 0x3E_5A)
        guard rng.float() < 0.38 else { return nil }
        let c = Self.mesaCell
        let x = (Float(i) + rng.float(0.2, 0.8)) * c, z = (Float(j) + rng.float(0.2, 0.8)) * c
        let r = rng.float(110, 240)
        let (_, dl) = WestLayout.nearestLine(z)
        guard dl > r + 160 else { return nil }
        let (d1, d2) = WestLayout.canyonDistances(x, z)
        let (w1, w2) = WestLayout.canyonWidths(x, z)
        guard d1 > w1 + r + 60, d2 * 1.1 > w2 + r * 0.6 else { return nil }
        return SIMD4(x, z, r, rng.float(70, 165))
    }

    /// Rock standing above the canyon floor or the plateau here (buttes and mesas), 0 where there's none.
    @inline(__always) private func rocks(_ x: Float, _ z: Float, plateau P: Float) -> Float {
        var best: Float = -1e9
        let bc = Self.butteCell
        let bi = Int(floor(x / bc)), bj = Int(floor(z / bc))
        for dj in -1...1 {
            for di in -1...1 {
                guard let b = butte(bi + di, bj + dj) else { continue }
                let d = simd_length(SIMD2(x - b.x, z - b.y))
                guard d < b.z + 40 else { continue }
                // Two tiers: a broad base, a narrower tower on top; ragged outline.
                let wob = 1 + 0.12 * Noise.perlin(atan2(z - b.y, x - b.x) * 2.5 + b.x * 0.01, d * 0.02)
                let r = b.z * wob
                let lower = (b.w - 60) * smoothstep(r + 30, r, d)
                let upper = b.w * smoothstep(r * 0.72, r * 0.64, d)
                best = max(best, max(lower, upper))
            }
        }
        let mc = Self.mesaCell
        let mi = Int(floor(x / mc)), mj = Int(floor(z / mc))
        for dj in -1...1 {
            for di in -1...1 {
                guard let m = mesa(mi + di, mj + dj) else { continue }
                let d = simd_length(SIMD2(x - m.x, z - m.y))
                guard d < m.z + 60 else { continue }
                let wob = 1 + 0.18 * Noise.perlin(atan2(z - m.y, x - m.x) * 1.8 + m.x * 0.003, 3.7)
                let r = m.z * wob
                // A talus slope at the foot, a sheer wall, a cap rock.
                let t = smoothstep(r + 55, r + 5, d) * 0.22 + smoothstep(r + 6, r - 6, d) * 0.78
                best = max(best, P + m.w * t)
            }
        }
        return best
    }

    func height(_ x: Float, _ z: Float) -> Float {
        var (d1, d2) = WestLayout.canyonDistances(x, z, steady: true)
        let (w1, w2) = WestLayout.canyonWidths(x, z)
        let river = riverHalf(x, z)
        // Spurs and amphitheatres along the walls (the river keeps its line). They fade in over a long enough stretch
        // that distance never runs backwards (which would fold the wall over into a ridge).
        let wig = 75 * Noise.perlin(x * 0.0032 + 1.1, z * 0.0032 - 7.4) + 28 * Noise.perlin(x * 0.011 - 3.3, z * 0.011 + 2.2)
        d1 += wig * smoothstep(river + 50, river + 230, d1)
        d2 += wig * 0.55 * smoothstep(river * 0.6 + 25, river * 0.6 + 125, d2 * 1.15)
        let P = WestLayout.plateau(x, z) + 3 * Noise.fbm(x * 0.01 + 4, z * 0.01 - 9, octaves: 2)
        var h = min(profile(d1, width: w1, river: river, top: P), profile(d2 * 1.15, width: w2, river: river * 0.6, top: P))
        h = max(h, rocks(x, z, plateau: P))
        // The railroad's bed, where it runs on the plateau.
        let (k, dl) = WestLayout.nearestLine(z)
        if dl < 14 {
            let bed = WestLayout.trackY(x, line: k) - 1.25
            if abs(h - bed) < 9 { h = lerp(h, bed, smoothstep(14, 6, dl)) }
        }
        // Towns stand on level ground.
        if let (t, k) = WestLayout.townBlend(x, z) { h = lerp(h, t.ground, k) }
        return h
    }

    // MARK: Colour

    func configure(ground: SCNMaterial, glow: SCNMaterial) { WorldShaders.triplanarGround(ground, extra: WestTerrain.strataShader) }

    /// Rock faces coloured per pixel from the same strata table, so the layers stay crisp and level however coarse the
    /// mesh is (per-vertex colour smears them into spikes down a steep wall).
    private static let strataShader: String = {
        let s = strata
        // The table is in sRGB like the vertex colours (which SceneKit linearises); the shader works in linear light.
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let hs = s.map { String(format: "%.1f", $0.0) }.joined(separator: ", ")
        let cs = s.map { String(format: "float3(%.4f, %.4f, %.4f)", lin($0.1.x), lin($0.1.y), lin($0.1.z)) }.joined(separator: ", ")
        return """
        float steepK = 1.0 - smoothstep(0.55, 0.78, wn.y);
        if (steepK > 0.001 && wp.y > 0.6) {
            const float sh[\(s.count)] = { \(hs) };
            const float3 sc[\(s.count)] = { \(cs) };
            float hh = wp.y + 6.0 * sin(wp.x * 0.0031 + 2.0 * sin(wp.z * 0.0023)) * cos(wp.z * 0.0029 - 1.1) + 1.5 * (ty - 0.5);
            float3 rock = sc[\(s.count - 1)];
            if (hh <= sh[0]) { rock = sc[0]; }
            else {
                for (int k = 1; k < \(s.count); k++) {
                    if (hh < sh[k]) { rock = mix(sc[k - 1], sc[k], smoothstep(0.65, 1.0, (hh - sh[k - 1]) / (sh[k] - sh[k - 1]))); break; }
                }
            }
            float fine = smoothstep(0.95, 0.995, sin(hh * 0.55) * 0.5 + 0.5);
            rock *= (1.0 - 0.18 * fine) * 1.25;
            _surface.diffuse.rgb = mix(_surface.diffuse.rgb, rock * (tx * bw.x + ty * bw.y + tz * bw.z), steepK);
        }
        """
    }()

    /// The rock layers, from the river up to the rim.
    private static let strata: [(Float, SIMD3<Float>)] = [
        (0, SIMD3(0.27, 0.24, 0.24)),       // dark schist in the inner gorge
        (22, SIMD3(0.36, 0.28, 0.24)),
        (36, SIMD3(0.50, 0.36, 0.26)),      // brown sandstone ledges
        (52, SIMD3(0.56, 0.54, 0.44)),      // grey-green slopes
        (72, SIMD3(0.66, 0.34, 0.25)),      // the great red wall
        (96, SIMD3(0.70, 0.40, 0.27)),      // red-brown steps
        (118, SIMD3(0.74, 0.44, 0.29)),
        (134, SIMD3(0.70, 0.36, 0.24)),     // red shale
        (148, SIMD3(0.90, 0.80, 0.62)),     // pale sandstone cliff
        (164, SIMD3(0.84, 0.70, 0.52)),     // buff
        (176, SIMD3(0.88, 0.84, 0.74)),     // cream rim rock
        // Up the mesas and the tall buttes: red and buff layers under a pale cap rock.
        (194, SIMD3(0.74, 0.40, 0.27)),
        (214, SIMD3(0.80, 0.50, 0.33)),
        (236, SIMD3(0.70, 0.36, 0.24)),
        (262, SIMD3(0.84, 0.64, 0.46)),
        (290, SIMD3(0.72, 0.39, 0.26)),
        (318, SIMD3(0.80, 0.55, 0.38)),
        (342, SIMD3(0.90, 0.84, 0.72)),
    ]

    @inline(__always) private func stratum(_ h: Float) -> SIMD3<Float> {
        let s = WestTerrain.strata
        if h <= s[0].0 { return s[0].1 }
        for k in 1..<s.count where h < s[k].0 {
            let (h0, c0) = s[k - 1], (h1, c1) = s[k]
            // Mostly flat bands with quick changes, a thin line now and then.
            let t = smoothstep(0.65, 1, (h - h0) / (h1 - h0))
            return simd_mix(c0, c1, SIMD3(repeating: t))
        }
        return s[s.count - 1].1
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.02, z * 0.02) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.08 + 3, z * 0.08 - 5) * 0.5 + 0.5
        if h < 0.4 { return simd_mix(SIMD3(0.36, 0.34, 0.26), SIMD3(0.6, 0.52, 0.38), SIMD3(repeating: smoothstep(-3, 0.4, h))) }
        // Rock layers, wobbling a little so the bands aren't ruler-straight; fine lines between them.
        let hh = h + 6 * Noise.perlin(x * 0.0035, z * 0.0035) + 1.5 * (n - 0.5)
        var rock = stratum(hh)
        let line = smoothstep(0.92, 0.99, sin(hh * 0.9) * 0.5 + 0.5)
        rock *= (1 - 0.12 * line) * (0.9 + 0.18 * n2)
        // Flat ground: desert sand and sage up top, scrubby benches in the canyon, a green strip by the river.
        let flat = smoothstep(0.72, 0.86, ny)
        // Desert: red sand, sage-grey scrubby patches, darker stony ground here and there.
        let patch = Noise.perlin(x * 0.006 + 2.2, z * 0.006 - 6.6) * 0.5 + 0.5
        var ground = simd_mix(SIMD3(0.80, 0.60, 0.42), SIMD3(0.62, 0.60, 0.44), SIMD3(repeating: smoothstep(0.35, 0.75, n) * 0.6))
        ground = simd_mix(ground, SIMD3(0.6, 0.44, 0.33), SIMD3(repeating: smoothstep(0.62, 0.8, patch) * 0.6))
        if h < WestLayout.rim - 30 { ground = simd_mix(rock * 1.05, SIMD3(0.58, 0.56, 0.40), SIMD3(repeating: 0.35 + 0.25 * n)) }
        if h < 4 { ground = simd_mix(SIMD3(0.40, 0.48, 0.26), SIMD3(0.62, 0.55, 0.40), SIMD3(repeating: smoothstep(1.5, 4, h + (n - 0.5) * 2))) }
        ground *= 0.92 + 0.14 * n2
        // Towns: packed dirt.
        if let (_, k) = WestLayout.townBlend(x, z) { ground = simd_mix(ground, SIMD3(0.70, 0.56, 0.40) * (0.95 + 0.1 * n2), SIMD3(repeating: k)) }
        return simd_mix(rock, ground, SIMD3(repeating: flat))
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        // Fallen rocks at the feet of the cliffs.
        var rng = cellRNG(key.x, key.z, 0xD0_E5)
        for _ in 0..<26 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let h = height(x, z)
            guard h > 1 else { continue }
            let slope = abs(height(x + 2, z) - h) + abs(height(x, z + 2) - h)
            guard slope < 3 else { continue }
            let c = stratum(h + 20) * 0.9
            m.boulder(at: SIMD3(lx, h + 0.4, lz), radius: rng.float(1, 3.6), color: c, &rng)
        }
    }

    // MARK: Plants

    private static let plantMaterial: SCNMaterial = WorldMaterials.vertexColor(rough: 0.9, doubleSided: true)

    private func plants(key: ChunkKey, ox: Float, oz: Float, detail: Bool) -> (near: MeshBuilder, far: MeshBuilder) {
        var near = MeshBuilder(), far = MeshBuilder()
        near.disabled = !detail
        var rng = cellRNG(key.x, key.z, 0x5A_6E)
        let spacing: Float = 13
        let n = Int(chunkSize / spacing)
        for j in 0..<n {
            for i in 0..<n {
                let lx = (Float(i) + rng.float(0.1, 0.9)) * spacing, lz = (Float(j) + rng.float(0.1, 0.9)) * spacing
                let x = ox + lx, z = oz + lz
                let roll = rng.float(), kind = rng.float()
                let h = height(x, z)
                guard h > 0.8 else { continue }
                let sx = height(x + 2.5, z) - h, sz = height(x, z + 2.5) - h
                guard sx * sx + sz * sz < 2.2 else { continue }
                if let (_, k) = WestLayout.townBlend(x, z), k > 0.2 { continue }
                let (_, dl) = WestLayout.nearestLine(z)
                if dl < 9 { continue }
                let p = SIMD3(lx, h - 0.15, lz)
                if h < 4.5 {
                    // Cottonwoods and reeds along the river.
                    if roll < 0.2 {
                        let ht = rng.float(9, 15)
                        near.cottonwood(at: p, height: ht, &rng)
                        far.farBlob(at: p, height: ht, color: SIMD3(0.36, 0.5, 0.2))
                    } else if roll < 0.4 { near.horsetails(at: p, &rng) }
                } else if h > WestLayout.rim - 25 {
                    // The plateau: sage everywhere, junipers, saguaros standing tall, prickly pear.
                    if roll < 0.04 {
                        let ht = rng.float(6, 11)
                        near.saguaro(at: p, height: ht, &rng)
                        far.farCactus(at: p, height: ht)
                    } else if roll < 0.11 {
                        let ht = rng.float(3.5, 6)
                        near.juniper(at: p, height: ht, &rng)
                        far.farBlob(at: p, height: ht, color: SIMD3(0.24, 0.32, 0.2))
                    } else if roll < 0.14 {
                        near.pricklyPear(at: p, &rng)
                    } else if roll < 0.52 && kind < 0.92 {
                        near.sagebrush(at: p, &rng)
                    }
                } else {
                    // Benches in the canyon: the odd juniper, scrub.
                    if roll < 0.035 {
                        let ht = rng.float(3, 5)
                        near.juniper(at: p, height: ht, &rng)
                        far.farBlob(at: p, height: ht, color: SIMD3(0.24, 0.32, 0.2))
                    } else if roll < 0.12 { near.sagebrush(at: p, &rng) }
                }
            }
        }
        return (near, far)
    }

    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var out = westNodes(key: key, ox: ox, oz: oz)
        let (_, far) = plants(key: key, ox: ox, oz: oz, detail: false)
        if !far.isEmpty {
            let g = far.geometry()
            g.materials = [WestTerrain.plantMaterial]
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1800)]
            let n = SCNNode(geometry: g)
            n.name = "swap:plants"
            n.castsShadow = true
            out.append(n)
        }
        return out
    }

    var detailDistance: Float { 560 }

    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var out = westDetailNodes(key: key, ox: ox, oz: oz)
        let (near, far) = plants(key: key, ox: ox, oz: oz, detail: true)
        if !near.isEmpty {
            let g = near.geometry()
            g.materials = [WestTerrain.plantMaterial]
            var lods: [SCNLevelOfDetail] = []
            if !far.isEmpty {
                let low = far.geometry()
                low.materials = [WestTerrain.plantMaterial]
                lods.append(SCNLevelOfDetail(geometry: low, worldSpaceDistance: 480))
            }
            lods.append(SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1800))
            g.levelsOfDetail = lods
            let n = SCNNode(geometry: g)
            n.name = "plants"
            n.castsShadow = true
            out.append(n)
        }
        return out
    }

    // MARK: Underground (the old mine)

    func isHole(_ x: Float, _ z: Float) -> Bool { WestMine.isHole(x, z, self) }
    func tunnelFloor(_ x: Float, _ z: Float, _ y: Float) -> Float? { WestMine.floorUnder(SIMD3(x, y, z), self) }

    /// Somewhere a cart or a rider can go (level desert, not in town).
    func open(_ x: Float, _ z: Float) -> Bool {
        let h = height(x, z)
        guard h > WestLayout.rim - 25 else { return false }
        let sx = height(x + 3, z) - h, sz = height(x, z + 3) - h
        return sx * sx + sz * sz < 2
    }
}

// MARK: - Desert plants

extension MeshBuilder {
    /// A saguaro: a ribbed green column with a couple of upturned arms.
    mutating func saguaro(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let g = SIMD3<Float>(0.32, 0.47, 0.25) * rng.float(0.9, 1.1)
        let r = h * 0.06
        tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h, 0), r0: r, r1: r * 0.9, sides: 8, g)
        ellipsoid(p + SIMD3(0, h, 0), SIMD3(r * 0.9, r * 0.7, r * 0.9), g * 1.05, rings: 3, sides: 8)
        let arms = Int(rng.float(0, 2.99))
        let a0 = rng.float(0, 6.28)
        for k in 0..<arms {
            let a = a0 + Float(k) * .pi * rng.float(0.8, 1.2)
            let out = SIMD3(cos(a), 0, sin(a))
            let y0 = h * rng.float(0.35, 0.6)
            let elbow = p + SIMD3(0, y0, 0) + out * h * 0.18
            let top = elbow + SIMD3(0, h * rng.float(0.2, 0.35), 0)
            tube(p + SIMD3(0, y0, 0), elbow, r0: r * 0.62, r1: r * 0.62, sides: 6, g * 0.97)
            ellipsoid(elbow, SIMD3(repeating: r * 0.62), g * 0.97, rings: 3, sides: 6)
            tube(elbow, top, r0: r * 0.62, r1: r * 0.58, sides: 6, g * 0.97)
            ellipsoid(top, SIMD3(r * 0.58, r * 0.45, r * 0.58), g, rings: 2, sides: 6)
        }
    }

    /// A gnarled juniper: a twisted trunk and a lumpy dark crown.
    mutating func juniper(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        let bark = SIMD3<Float>(0.42, 0.34, 0.27), leaf = SIMD3<Float>(0.25, 0.33, 0.21) * rng.float(0.85, 1.15)
        let lean = SIMD3(rng.float(-0.3, 0.3), 1, rng.float(-0.3, 0.3))
        let top = p + simd_normalize(lean) * h * 0.55
        tube(p - SIMD3(0, 0.2, 0), top, r0: h * 0.07, r1: h * 0.04, sides: 5, bark)
        ellipsoid(top + SIMD3(0, h * 0.18, 0), SIMD3(h * 0.32, h * 0.26, h * 0.3), leaf, rings: 3, sides: 6)
        ellipsoid(top + SIMD3(h * 0.15, h * 0.05, -h * 0.1), SIMD3(h * 0.22, h * 0.18, h * 0.2), leaf * 0.9, rings: 2, sides: 6)
    }

    mutating func sagebrush(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        let c = SIMD3<Float>(0.56, 0.6, 0.48) * rng.float(0.85, 1.1)
        let s = rng.float(0.5, 1.1)
        ellipsoid(p + SIMD3(0, 0.35 * s, 0), SIMD3(0.75, 0.45, 0.7) * s, c, rings: 2, sides: 6)
        ellipsoid(p + SIMD3(0.4 * s, 0.3 * s, 0.2 * s), SIMD3(0.5, 0.35, 0.5) * s, c * 0.9, rings: 2, sides: 5)
    }

    mutating func pricklyPear(at p: SIMD3<Float>, _ rng: inout SplitMix64) {
        let g = SIMD3<Float>(0.4, 0.55, 0.3)
        var base = p
        for k in 0..<5 {
            let a = rng.float(0, 6.28)
            let c = base + SIMD3(cos(a) * 0.2, 0.35 + Float(k % 2) * 0.25, sin(a) * 0.2)
            ellipsoid(c, SIMD3(0.32, 0.38, 0.08), g * rng.float(0.9, 1.1), rings: 3, sides: 6, rot: yawQuat(a))
            if k == 1 { base = c }
        }
        ellipsoid(base + SIMD3(0, 0.5, 0), SIMD3(repeating: 0.08), SIMD3(0.85, 0.2, 0.45), rings: 2, sides: 4)
    }

    mutating func cottonwood(at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64) {
        tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h * 0.55, 0), r0: h * 0.06, r1: h * 0.04, sides: 6, SIMD3(0.48, 0.44, 0.38))
        let leaf = SIMD3<Float>(0.38, 0.52, 0.22) * rng.float(0.9, 1.15)
        for k in 0..<3 {
            let a = rng.float(0, 6.28) + Float(k) * 2
            ellipsoid(p + SIMD3(cos(a) * h * 0.18, h * (0.62 + 0.1 * Float(k)), sin(a) * h * 0.18), SIMD3(h * 0.3, h * 0.24, h * 0.3), leaf, rings: 3, sides: 7)
        }
    }

    mutating func farBlob(at p: SIMD3<Float>, height h: Float, color: SIMD3<Float>) {
        ellipsoid(p + SIMD3(0, h * 0.6, 0), SIMD3(h * 0.38, h * 0.38, h * 0.38), color, rings: 2, sides: 5)
    }

    mutating func farCactus(at p: SIMD3<Float>, height h: Float) {
        tube(p, p + SIMD3(0, h, 0), r0: h * 0.06, r1: h * 0.05, sides: 4, SIMD3(0.32, 0.47, 0.25))
    }
}
