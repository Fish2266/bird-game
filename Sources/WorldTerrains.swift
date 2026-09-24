import SceneKit
import simd

@inline(__always) func cellRNG(_ i: Int, _ j: Int, _ salt: UInt64) -> SplitMix64 {
    SplitMix64(seed: UInt64(bitPattern: Int64(i &* 73856093 ^ j &* 19349663)) ^ salt)
}

private func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    simd_mix(a, b, SIMD3(repeating: clamp(t, 0, 1)))
}

// MARK: - Volcano

final class VolcanoTerrain: WorldTerrain {
    let waterLevel: Float = 0          // lava
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 700
    let radius = 6
    static let coneCell: Float = 1300

    func height(_ x: Float, _ z: Float) -> Float {
        let wx = x + 160 * Noise.perlin(x * 0.0007 + 3.3, z * 0.0007 - 1.1)
        let wz = z + 160 * Noise.perlin(x * 0.0007 - 6.2, z * 0.0007 + 4.4)
        var h = Noise.fbm(wx * 0.0006, wz * 0.0006, octaves: 4) * 110 + 12
        let r = Noise.ridged(wx * 0.0018, wz * 0.0018, octaves: 4)
        h += r * r * 55
        h = max(h, h * 0.35 + cones(x, z))
        h += Noise.fbm(x * 0.012, z * 0.012, octaves: 2) * 2.5
        return h
    }

    /// Big volcanic cones with craters, one per grid cell (most cells).
    func cones(_ x: Float, _ z: Float) -> Float {
        let c = Self.coneCell
        let ci = Int(floor(x / c)), cj = Int(floor(z / c))
        var best: Float = -1e9
        for dj in -1...1 {
            for di in -1...1 {
                guard let v = cone(ci + di, cj + dj) else { continue }
                let d = simd_length(SIMD2(x - v.x, z - v.y))
                guard d < v.z else { continue }
                let t = 1 - d / v.z
                var hgt = v.w * pow(t, 1.7)
                let crater = v.z * 0.16
                if d < crater { hgt -= v.w * 0.3 * smoothstep(crater, crater * 0.35, d) }
                best = max(best, hgt)
            }
        }
        return best
    }

    /// (x, z, radius, height) of the cone in a cell, if any.
    func cone(_ i: Int, _ j: Int) -> SIMD4<Float>? {
        var rng = cellRNG(i, j, 0xC0FE)
        guard rng.float() < 0.72 else { return nil }
        let c = Self.coneCell
        return SIMD4((Float(i) + rng.float(0.25, 0.75)) * c, (Float(j) + rng.float(0.25, 0.75)) * c,
                     rng.float(420, 620), rng.float(230, 420))
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.02, z * 0.02) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.09 + 5, z * 0.09) * 0.5 + 0.5
        let basalt = SIMD3<Float>(0.17, 0.15, 0.15)
        let rock = SIMD3<Float>(0.30, 0.27, 0.26)
        let ash = SIMD3<Float>(0.46, 0.43, 0.41)
        let scorched = SIMD3<Float>(0.46, 0.18, 0.08)
        if h < 0.5 { return SIMD3(0.20, 0.07, 0.04) }
        var c = mix3(basalt, rock, n * 0.8 + n2 * 0.2)
        c = mix3(c, ash, smoothstep(0.78, 0.92, ny) * smoothstep(60, 160, h + n * 40))
        c = mix3(c, basalt * 0.8, smoothstep(0.7, 0.5, ny))
        c = mix3(c, scorched, smoothstep(12, 1.5, h + n2 * 3))
        return c
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        var rng = cellRNG(key.x, key.z, 0xBEEF)
        for _ in 0..<60 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let h = height(x, z)
            let kind = rng.float()
            if h > 1.5 && h < 9 && kind < 0.18 {
                // Little glowing lava vents along the shores.
                TerrainManager.cone(&glow, base: SIMD3(lx, h - 0.3, lz), height: rng.float(0.8, 1.8), radius: rng.float(0.8, 1.6),
                                    top: 0.3, sides: 6, color: SIMD3(1.0, 0.42, 0.08), yaw: rng.float(0, 6))
            } else if h > 5 && h < 140 && kind < 0.55 {
                // Charred dead trees
                let t = rng.float(4, 9)
                TerrainManager.cone(&m, base: SIMD3(lx, h - 0.5, lz), height: t, radius: 0.35, top: 0.05, sides: 5,
                                    color: SIMD3(0.12, 0.10, 0.10), yaw: rng.float(0, 6))
                TerrainManager.cone(&m, base: SIMD3(lx, h + t * 0.55, lz), height: t * 0.35, radius: 0.12, top: 0.02, sides: 4,
                                    color: SIMD3(0.14, 0.11, 0.10), yaw: rng.float(0, 6))
            } else if h > 2 && kind < 0.85 {
                // Boulders
                let r = rng.float(1.2, 3.5)
                TerrainManager.cone(&m, base: SIMD3(lx, h - r * 0.4, lz), height: r * 1.1, radius: r, top: r * 0.35, sides: 5,
                                    color: SIMD3(0.20, 0.18, 0.18), yaw: rng.float(0, 6))
            }
        }
    }
}

// MARK: - Glow caves

/// Tunnels are the zero-crossings of a noise field, so they wind forever without dead ends.
/// Floor and ceiling are two height sheets that meet at the tunnel walls.
final class CaveTerrain: WorldTerrain {
    let waterLevel: Float = -1e9
    let chunkSize: Float = 128
    let cells = 64
    let lowCells: Int? = nil
    let lodDistance: Float = 0
    let radius = 3

    struct Sample {
        var n: Float          // tunnel field (0 = tunnel center line)
        var w: Float          // half width in field units
        var wide: Float       // 0 = tight tunnel, 1 = big cavern
        var open: Float       // 1 at the center, 0 at the walls
        var center: Float
        var floor: Float
        var ceiling: Float
    }

    @inline(__always) func field(_ x: Float, _ z: Float) -> Float {
        let wx = x + 40 * Noise.perlin(x * 0.003 + 3.1, z * 0.003 - 7.3)
        let wz = z + 40 * Noise.perlin(x * 0.003 - 5.7, z * 0.003 + 2.2)
        return Noise.perlin(wx * 0.0045, wz * 0.0045)
    }

    func sample(_ x: Float, _ z: Float) -> Sample {
        let n = field(x, z)
        let wide = smoothstep(0.35, 0.8, Noise.perlin(x * 0.0011 + 21.5, z * 0.0011 - 8.3) * 0.5 + 0.5)
        let w: Float = 0.035 + 0.10 * wide
        let a = abs(n) / w
        let p = max(0, 1 - a * a)
        let sp = p.squareRoot()
        let c = 42 + 36 * Noise.perlin(x * 0.0014 + 4.2, z * 0.0014 + 9.1) + 9 * Noise.perlin(x * 0.0055, z * 0.0055 + 3)
        let hh = 7 + 20 * wide + 3 * Noise.perlin(x * 0.02, z * 0.02)
        var floor: Float, ceil: Float
        if p > 0 {
            floor = c - hh * 0.8 * sp + 1.2 * Noise.perlin(x * 0.08, z * 0.08) * sp
            ceil = c + hh * sp - 2.2 * max(0, Noise.perlin(x * 0.12 + 9, z * 0.12)) * sp
        } else {
            let o = smoothstep(1, 1.3, a)
            floor = c + 1.5 * o
            ceil = c - 1.5 * o
        }
        return Sample(n: n, w: w, wide: wide, open: p, center: c, floor: floor, ceiling: ceil)
    }

    func height(_ x: Float, _ z: Float) -> Float { sample(x, z).floor }
    func ceiling(_ x: Float, _ z: Float) -> Float? { sample(x, z).ceiling }

    /// Gradient of the tunnel field (per meter).
    func gradient(_ x: Float, _ z: Float) -> SIMD2<Float> {
        let e: Float = 1
        return SIMD2(field(x + e, z) - field(x - e, z), field(x, z + e) - field(x, z - e)) / (2 * e)
    }

    /// Unit direction along the tunnel at (x, z), choosing the side closest to `prefer`.
    func tangent(_ x: Float, _ z: Float, prefer: SIMD2<Float>) -> SIMD2<Float> {
        let g = gradient(x, z)
        var t = SIMD2(-g.y, g.x)
        let l = simd_length(t)
        guard l > 1e-7 else { return simd_normalize(prefer) }
        t /= l
        return simd_dot(t, prefer) < 0 ? -t : t
    }

    /// Nudge a point onto the tunnel's center line.
    func recenter(_ p: SIMD2<Float>) -> SIMD2<Float> {
        var q = p
        for _ in 0..<3 {
            let n = field(q.x, q.y), g = gradient(q.x, q.y)
            let gg = simd_length_squared(g)
            guard gg > 1e-12 else { break }
            let step = g * (n / gg)
            q -= simd_length(step) > 6 ? simd_normalize(step) * 6 : step
        }
        return q
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.05, z * 0.05) * 0.5 + 0.5
        let n2 = Noise.perlin(x * 0.013 + 7, z * 0.013) * 0.5 + 0.5
        let moss = SIMD3<Float>(0.26, 0.50, 0.22)
        let rock = SIMD3<Float>(0.32, 0.34, 0.36)
        let glowMoss = SIMD3<Float>(0.32, 0.78, 0.66)
        var c = mix3(rock, moss, smoothstep(0.55, 0.85, ny) * (0.6 + 0.4 * n))
        c = mix3(c, glowMoss, smoothstep(0.62, 0.8, n2) * smoothstep(0.6, 0.85, ny))
        return c
    }

    func ceilingColor(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.04 + 3, z * 0.04) * 0.5 + 0.5
        return mix3(SIMD3(0.24, 0.25, 0.30), SIMD3(0.36, 0.30, 0.46), smoothstep(0.6, 0.85, n))
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        var rng = cellRNG(key.x, key.z, 0xCA7E)
        let capColors: [SIMD3<Float>] = [SIMD3(0.35, 1.0, 0.92), SIMD3(1.0, 0.50, 0.85), SIMD3(0.75, 1.0, 0.35)]
        // Mushroom clusters on the floor
        for _ in 0..<45 {
            let lx = rng.float(3, chunkSize - 3), lz = rng.float(3, chunkSize - 3)
            let s = sample(ox + lx, oz + lz)
            guard s.open > 0.25 else { continue }
            let cap = capColors[Int(rng.float(0, 2.99))]
            for _ in 0..<Int(rng.float(3, 7)) {
                let px = lx + rng.float(-2.5, 2.5), pz = lz + rng.float(-2.5, 2.5)
                let fy = height(ox + px, oz + pz)
                let stem = rng.float(0.4, 1.6)
                let r = stem * rng.float(0.35, 0.6)
                TerrainManager.cone(&m, base: SIMD3(px, fy - 0.2, pz), height: stem + 0.2, radius: 0.12, top: 0.08, sides: 5,
                                    color: SIMD3(0.85, 0.82, 0.72), yaw: 0)
                TerrainManager.cone(&glow, base: SIMD3(px, fy + stem - r * 0.15, pz), height: r * 0.55, radius: r, top: 0, sides: 8,
                                    color: cap, yaw: rng.float(0, 6))
            }
        }
        // Crystals and vines hanging from the ceiling
        for _ in 0..<55 {
            let lx = rng.float(3, chunkSize - 3), lz = rng.float(3, chunkSize - 3)
            let s = sample(ox + lx, oz + lz)
            guard s.open > 0.3 else { continue }
            let room = s.ceiling - s.floor
            if rng.float() < 0.35 {
                let len = min(rng.float(1.0, 3.0), room * 0.3)
                TerrainManager.cone(&glow, base: SIMD3(lx, s.ceiling + 0.3, lz), height: -len, radius: len * 0.3, top: 0, sides: 5,
                                    color: SIMD3(0.72, 0.50, 1.0), yaw: rng.float(0, 6))
            } else {
                let len = min(rng.float(2, 7), room * 0.45)
                TerrainManager.cone(&m, base: SIMD3(lx, s.ceiling + 0.3, lz), height: -len, radius: 0.1, top: 0.03, sides: 4,
                                    color: SIMD3(0.22, 0.48, 0.20), yaw: rng.float(0, 6))
            }
        }
    }
}

// MARK: - Farmland (Dogfight)

final class FarmTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 700
    let radius = 7

    func height(_ x: Float, _ z: Float) -> Float {
        var h = Noise.fbm(x * 0.0007 + 3, z * 0.0007 - 2, octaves: 4) * 90 + 28
        h += Noise.fbm(x * 0.003, z * 0.003 + 9, octaves: 2) * 9
        // Flatten the lowlands a little so fields look farmed.
        if h > 2 && h < 40 { h = lerp(h, 2 + (h - 2) * 0.6, 0.5) }
        return h
    }

    /// Field cell id and distance (m) to the nearest field edge.
    func field(_ x: Float, _ z: Float) -> (Int, Int, Float) {
        let wx = x + 22 * Noise.perlin(x * 0.006 + 1, z * 0.006)
        let wz = z + 22 * Noise.perlin(x * 0.006, z * 0.006 + 5)
        let sx: Float = 120, sz: Float = 90
        let fx = wx / sx, fz = wz / sz
        let ix = Int(floor(fx)), iz = Int(floor(fz))
        let ex = min(fx - floor(fx), 1 - (fx - floor(fx))) * sx
        let ez = min(fz - floor(fz), 1 - (fz - floor(fz))) * sz
        return (ix, iz, min(ex, ez))
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        if h < 0.5 { return SIMD3(0.45, 0.42, 0.32) }
        let palette: [SIMD3<Float>] = [SIMD3(0.86, 0.74, 0.38), SIMD3(0.44, 0.62, 0.28), SIMD3(0.56, 0.70, 0.32),
                                       SIMD3(0.50, 0.36, 0.24), SIMD3(0.38, 0.55, 0.24), SIMD3(0.74, 0.70, 0.40),
                                       SIMD3(0.60, 0.54, 0.74)]
        let (ix, iz, edge) = field(x, z)
        var rng = cellRNG(ix, iz, 0xF1E1D)
        let pick = rng.float()
        var c = palette[min(Int(pick * (pick < 0.97 ? 6 : 7)), 6)]
        // Plough / crop rows
        let rows = rng.float() < 0.5 ? x : z
        c *= 0.94 + 0.06 * sin(rows * 1.1)
        c = mix3(c, SIMD3(0.18, 0.32, 0.14), smoothstep(3.0, 1.5, edge))          // hedgerows
        c = mix3(c, SIMD3(0.40, 0.46, 0.26), smoothstep(0.82, 0.65, ny))          // steep banks
        c = mix3(c, SIMD3(0.70, 0.66, 0.50), smoothstep(3, 1, h))                 // muddy shores
        return c
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {
        var rng = cellRNG(key.x, key.z, 0xFA12)
        // Round trees along the hedgerows
        for _ in 0..<160 {
            let lx = rng.float(4, chunkSize - 4), lz = rng.float(4, chunkSize - 4)
            let x = ox + lx, z = oz + lz
            let (_, _, edge) = field(x, z)
            let h = height(x, z)
            guard edge < 2.5, h > 3, rng.float() < 0.45 else { continue }
            let t = rng.float(6, 11)
            let green = SIMD3<Float>(0.20 + rng.float(-0.04, 0.04), 0.38 + rng.float(-0.05, 0.05), 0.14)
            TerrainManager.cone(&m, base: SIMD3(lx, h - 0.5, lz), height: t * 0.45, radius: 0.35, top: 0.25, sides: 5,
                                color: SIMD3(0.33, 0.24, 0.16), yaw: 0)
            TerrainManager.cone(&m, base: SIMD3(lx, h + t * 0.25, lz), height: t * 0.45, radius: t * 0.32, top: t * 0.26, sides: 8,
                                color: green * 0.9, yaw: rng.float(0, 6))
            TerrainManager.cone(&m, base: SIMD3(lx, h + t * 0.7, lz), height: t * 0.3, radius: t * 0.26, top: 0, sides: 8,
                                color: green, yaw: rng.float(0, 6))
        }
        // A farmhouse or two
        for _ in 0..<2 where rng.float() < 0.6 {
            let lx = rng.float(20, chunkSize - 20), lz = rng.float(20, chunkSize - 20)
            let h = height(ox + lx, oz + lz)
            guard h > 4, TerrainShape.normal(ox + lx, oz + lz, e: 5).y > 0.95 else { continue }
            let yaw = rng.float(0, 3)
            farmhouse(&m, at: SIMD3(lx, h, lz), yaw: yaw, roof: rng.float() < 0.5 ? SIMD3(0.70, 0.22, 0.16) : SIMD3(0.40, 0.30, 0.24))
        }
    }

    private func farmhouse(_ m: inout MeshBuilder, at p: SIMD3<Float>, yaw: Float, roof: SIMD3<Float>) {
        let w: Float = 9, d: Float = 6, hgt: Float = 4.5, rh: Float = 3
        let q = simd_quatf(angle: yaw, axis: kUp)
        func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { p + q.act(SIMD3(x, y, z)) }
        let wall = SIMD3<Float>(0.90, 0.87, 0.78)
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD3<Float>) {
            let n = simd_normalize(simd_cross(b - a, d - a))
            let i = m.vertexCount
            m.vertex(a, n, col); m.vertex(b, n, col); m.vertex(c, n, col); m.vertex(d, n, col)
            m.tri(i, i + 1, i + 2); m.tri(i, i + 2, i + 3)
        }
        let x0 = -w / 2, x1 = w / 2, z0 = -d / 2, z1 = d / 2, y0: Float = -1, y1 = hgt
        quad(P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1), wall)
        quad(P(x1, y0, z0), P(x0, y0, z0), P(x0, y1, z0), P(x1, y1, z0), wall)
        quad(P(x1, y0, z1), P(x1, y0, z0), P(x1, y1, z0), P(x1, y1, z1), wall * 0.92)
        quad(P(x0, y0, z0), P(x0, y0, z1), P(x0, y1, z1), P(x0, y1, z0), wall * 0.92)
        // Gable ends
        for (zz, flip) in [(z1, false), (z0, true)] {
            let a = P(x0, y1, zz), b = P(x1, y1, zz), c = P(0, y1 + rh, zz)
            let n = simd_normalize(simd_cross(b - a, c - a)) * (flip ? -1 : 1)
            let i = m.vertexCount
            m.vertex(a, n, wall); m.vertex(b, n, wall); m.vertex(c, n, wall)
            if flip { m.tri(i, i + 2, i + 1) } else { m.tri(i, i + 1, i + 2) }
        }
        // Roof
        quad(P(x0 - 0.5, y1 - 0.3, z0 - 0.5), P(x0 - 0.5, y1 - 0.3, z1 + 0.5), P(0, y1 + rh, z1 + 0.5), P(0, y1 + rh, z0 - 0.5), roof)
        quad(P(x1 + 0.5, y1 - 0.3, z1 + 0.5), P(x1 + 0.5, y1 - 0.3, z0 - 0.5), P(0, y1 + rh, z0 - 0.5), P(0, y1 + rh, z1 + 0.5), roof * 0.9)
    }
}
