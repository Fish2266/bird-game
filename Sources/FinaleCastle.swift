import SceneKit
import simd

// The castle at the heart of The Finale, built once (it's the island's landmark, seen from everywhere): an octagon
// of crenellated walls with round towers under blue cone roofs, a gatehouse and drawbridge facing the village, a
// courtyard of hedges, fountains, tents and bunting, and the great hall — stained glass down both sides, columns,
// banners, chandeliers, a red carpet to the throne, and an open lantern in the roof shaped like a crown, through
// which a champion with a jetpack can leave. The Sky Tower rises behind it all.

enum FinaleShaders {
    /// Dressed stone: courses of blocks on walls, flagstones on floors and walkways, a little tone per block.
    static let stone: SCNMaterial = {
        let m = WorldMaterials.vertexColor(rough: 0.84)
        m.diffuse.contents = WorldMaterials.whitePixel
        m.shaderModifiers = [.surface: """
        #pragma body
        float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        float3 wn = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
        float k = 1.0;
        if (abs(wn.y) < 0.6) {
            float u = abs(wn.x) > abs(wn.z) ? wp.z : wp.x;
            float row = floor(wp.y / 0.85);
            float bu = u / 1.7 + fmod(abs(row), 2.0) * 0.5;
            float fy = fract(wp.y / 0.85), fu = fract(bu);
            float mortar = max(1.0 - smoothstep(0.0, 0.06, fy) * smoothstep(1.0, 0.94, fy), 1.0 - smoothstep(0.0, 0.03, fu) * smoothstep(1.0, 0.97, fu));
            float tone = fract(sin(dot(float2(floor(bu), row), float2(12.9898, 78.233))) * 43758.5453);
            k = (0.9 + 0.14 * tone) * (1.0 - 0.3 * mortar);
        } else {
            float2 g = wp.xz / 2.1;
            float2 f = fract(g);
            float mortar = max(1.0 - smoothstep(0.0, 0.035, f.x) * smoothstep(1.0, 0.965, f.x), 1.0 - smoothstep(0.0, 0.035, f.y) * smoothstep(1.0, 0.965, f.y));
            float tone = fract(sin(dot(floor(g), float2(39.346, 11.135))) * 43758.5453);
            k = (0.9 + 0.14 * tone) * (1.0 - 0.24 * mortar);
        }
        _surface.diffuse.rgb *= k;
        """]
        return m
    }()

    /// Roofs (glossy slate), gold (metal) and wood/plaster (matte), picked per vertex by uv.x like `finishes`.
    static let trim: SCNMaterial = WorldMaterials.finishes()

    /// Banners, flags and bunting: they ripple in the breeze. uv = (phase, how free the vertex is: 0 at the pole … 1).
    static let cloth: SCNMaterial = {
        let m = WorldMaterials.vertexColor(rough: 0.9, doubleSided: true)
        m.diffuse.contents = WorldMaterials.whitePixel
        m.shaderModifiers = [.geometry: """
        #pragma body
        float flex = _geometry.texcoords[0].y;
        float ph = _geometry.texcoords[0].x;
        // A phase of 100+ marks a banner hanging against a wall: it billows outward only (away from the stone).
        bool hanging = ph >= 100.0;
        if (hanging) { ph -= 100.0; }
        float t = scn_frame.time;
        float w = sin(t * 2.4 + ph + flex * 3.2) * 0.3 + sin(t * 4.3 + ph * 1.7 + flex * 6.0) * 0.1;
        if (hanging) { w = (w + 0.4) * 0.45; }
        _geometry.position.xyz += _geometry.normal * (w * flex);
        """]
        return m
    }()

    static let glow: SCNMaterial = WorldMaterials.glow(1.7)
}

/// Something solid in the castle, for collisions.
enum FinaleSolid {
    case box(OBox)
    case capsule(Capsule)
}

enum FinaleCastle {
    typealias L = FinaleLayout
    static let stoneC = SIMD3<Float>(0.86, 0.82, 0.74)
    static let stoneDark = SIMD3<Float>(0.74, 0.70, 0.63)
    static let slate = SIMD3<Float>(0.20, 0.30, 0.62)
    static let gold = SIMD3<Float>(1.0, 0.78, 0.32)
    static let red = SIMD3<Float>(0.70, 0.08, 0.10)
    static let royalBlue = SIMD3<Float>(0.14, 0.24, 0.62)
    static let gloss = SIMD2<Float>(1, 0), metal = SIMD2<Float>(3, 0), matte = SIMD2<Float>(0, 0)

    private struct Builders {
        var stone = MeshBuilder()
        var trim = MeshBuilder()
        var cloth = MeshBuilder()
        var glow = MeshBuilder()
    }

    /// The whole castle, its banners and its lights.
    static func build() -> SCNNode {
        var b = Builders()
        walls(&b)
        gatehouse(&b)
        hall(&b)
        skyTower(&b)
        courtyard(&b)
        let root = SCNNode()
        root.name = "castle"
        for (name, mesh, mat, shadow) in [("castle stone", b.stone, FinaleShaders.stone, true), ("castle trim", b.trim, FinaleShaders.trim, true),
                                          ("castle cloth", b.cloth, FinaleShaders.cloth, true), ("castle glow", b.glow, FinaleShaders.glow, false)]
            as [(String, MeshBuilder, SCNMaterial, Bool)] where !mesh.isEmpty {
            let g = mesh.geometry()
            g.materials = [mat]
            let n = SCNNode(geometry: g)
            n.name = name
            n.castsShadow = shadow
            root.addChildNode(n)
        }
        // Warm light inside the great hall (the sun can't reach in): the chandeliers and the dais.
        for (z, i) in [(Float(-20), CGFloat(900)), (-38, 900), (-56, 1000), (-71, 700)] {
            let l = SCNLight()
            l.type = .omni
            l.color = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.6, alpha: 1)
            l.intensity = i
            l.attenuationStartDistance = 4
            l.attenuationEndDistance = 46
            l.attenuationFalloffExponent = 1.6
            l.castsShadow = false
            let n = SCNNode()
            n.light = l
            n.simdPosition = SIMD3(0, L.ground + 15, z)
            root.addChildNode(n)
        }
        return root
    }

    // MARK: Pieces

    /// A box running from a to b (on the ground plan) between heights y0 and y1, `thick` wide.
    private static func run(_ m: inout MeshBuilder, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ y0: Float, _ y1: Float, _ thick: Float,
                            _ col: SIMD3<Float>, top: Bool = true, uv: SIMD2<Float> = .zero) {
        let d = b - a
        let len = simd_length(d)
        guard len > 0.01 else { return }
        let c = (a + b) / 2
        m.box(SIMD3(c.x, (y0 + y1) / 2, c.y), SIMD3(len / 2, (y1 - y0) / 2, thick / 2), col, rot: yawQuat(atan2(-d.y, d.x)), top: top, uv: uv)
    }

    /// Merlons along the outer edge of a wall top from a to b (outward = the side facing out).
    private static func crenellate(_ m: inout MeshBuilder, _ a: SIMD2<Float>, _ b: SIMD2<Float>, y: Float, out: SIMD2<Float>, thick: Float) {
        let d = b - a
        let len = simd_length(d)
        guard len > 2 else { return }
        let dir = d / len
        let n = Int(len / 3)
        for k in 0..<n {
            let s = (Float(k) + 0.5) * len / Float(n)
            let p = a + dir * s + out * (thick / 2 - 0.4)
            m.box(SIMD3(p.x, y + 0.7, p.y), SIMD3(0.75, 0.7, 0.4), stoneC, rot: yawQuat(atan2(-dir.y, dir.x)))
        }
    }

    /// A pennant on a pole: a long triangle that ripples.
    private static func pennant(_ c: inout MeshBuilder, _ trim: inout MeshBuilder, at p: SIMD3<Float>, pole: Float, length: Float, color: SIMD3<Float>, phase: Float) {
        trim.tube(p, p + SIMD3(0, pole, 0), r0: 0.12, r1: 0.08, sides: 5, SIMD3(0.35, 0.3, 0.26), uv: matte)
        trim.ellipsoid(p + SIMD3(0, pole + 0.2, 0), SIMD3(repeating: 0.28), gold, rings: 3, sides: 6, uv: metal)
        let top = p + SIMD3(0, pole - 0.2, 0), bot = p + SIMD3(0, pole - length * 0.32, 0)
        let tip = p + SIMD3(length, pole - length * 0.2, 0)
        // Front and back are the same triangle (the material is double-sided); uv.y = how far from the pole.
        c.vertex(top, SIMD3(0, 0, 1), color, uv: SIMD2(phase, 0))
        c.vertex(bot, SIMD3(0, 0, 1), color, uv: SIMD2(phase, 0))
        c.vertex(tip, SIMD3(0, 0, 1), color * 0.95, uv: SIMD2(phase, 1))
        let i = c.vertexCount - 3
        c.tri(i, i + 1, i + 2)
    }

    /// A hanging banner (top edge fixed): rectangle with a pointed foot, an emblem in the middle.
    private static func banner(_ c: inout MeshBuilder, top: SIMD3<Float>, right: SIMD3<Float>, width: Float, height: Float,
                               color: SIMD3<Float>, emblem: SIMD3<Float>, phase: Float, facing: SIMD3<Float>) {
        let rows = 6
        let half = right * (width / 2)
        for r in 0..<rows {
            let t0 = Float(r) / Float(rows), t1 = Float(r + 1) / Float(rows)
            let y0 = -height * t0, y1 = -height * t1
            let a = top - half + SIMD3(0, y0, 0), b = top + half + SIMD3(0, y0, 0)
            var d = top + half + SIMD3(0, y1, 0), e = top - half + SIMD3(0, y1, 0)
            if r == rows - 1 { d = top + right * (width * 0.08) + SIMD3(0, y1 - height * 0.08, 0); e = top - right * (width * 0.08) + SIMD3(0, y1 - height * 0.08, 0) }
            let f0 = t0 * 0.6, f1 = t1 * 0.6
            let n = facing
            let phase = phase + 100   // hangs against a wall: billows outward only (see FinaleShaders.cloth)
            let i = c.vertexCount
            let mid = r == 2 || r == 3
            let col = mid ? emblem : color
            c.vertex(a, n, col, uv: SIMD2(phase, f0)); c.vertex(b, n, col, uv: SIMD2(phase, f0))
            c.vertex(d, n, col, uv: SIMD2(phase, f1)); c.vertex(e, n, col, uv: SIMD2(phase, f1))
            c.tri(i, i + 2, i + 1); c.tri(i, i + 3, i + 2)
        }
    }

    /// A round tower: drum, a corbelled crown with merlons, a slit window or two, the cone roof and its pennant.
    private static func tower(_ b: inout Builders, at p: SIMD3<Float>, r: Float, h: Float, roof: Float, phase: Float, flag: SIMD3<Float>) {
        b.stone.cylinder(p, r0: r, r1: r * 0.97, y0: -1, y1: h, sides: 22, stoneC, top: false)
        b.stone.cylinder(p, r0: r * 1.14, r1: r * 1.14, y0: h - 0.2, y1: h + 1.4, sides: 22, stoneDark)
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * .pi
            let q = p + SIMD3(cos(a) * r * 1.08, h + 2.1, sin(a) * r * 1.08)
            b.stone.box(q, SIMD3(0.8, 0.7, 0.45), stoneC, rot: yawQuat(-a + .pi / 2))
        }
        // Slit windows, lit from inside.
        for k in 0..<3 {
            let a = Float(k) * 2.1 + phase
            let q = p + SIMD3(cos(a) * (r + 0.05), h * (0.35 + 0.2 * Float(k)), sin(a) * (r + 0.05))
            let side = SIMD3(-sin(a), 0, cos(a)) * 0.45
            b.glow.quad(q - side, q + side, q + side + SIMD3(0, 2.4, 0), q - side + SIMD3(0, 2.4, 0), SIMD3(1, 0.78, 0.45), facing: SIMD3(cos(a), 0, sin(a)))
        }
        b.trim.cylinder(p + SIMD3(0, h + 1.4, 0), r0: r * 1.22, r1: 0.12, y0: 0, y1: roof, sides: 22, slate, top: false, uv: gloss)
        b.trim.cylinder(p + SIMD3(0, h + 1.35, 0), r0: r * 1.24, r1: r * 1.24, y0: 0, y1: 0.35, sides: 22, gold, uv: metal)
        pennant(&b.cloth, &b.trim, at: p + SIMD3(0, h + 1.4 + roof - 0.3, 0), pole: 5, length: 6.5, color: flag, phase: phase)
    }

    /// The curtain wall: eight sides between eight towers, the south side broken by the gatehouse.
    private static func walls(_ b: inout Builders) {
        let cs = L.corners
        let top = L.ground + L.wallHeight
        for k in 0..<8 {
            let A = SIMD2(cs[k].x, cs[k].z), B = SIMD2(cs[(k + 1) % 8].x, cs[(k + 1) % 8].z)
            let dir = simd_normalize(B - A)
            var mid = (A + B) / 2
            mid = simd_normalize(mid)
            let out = mid
            let a = A + dir * (L.towerRadius - 1), e = B - dir * (L.towerRadius - 1)
            // The south side: wall up to the gatehouse on each side.
            let gx = L.gateHalf + 9.5
            let pieces: [(SIMD2<Float>, SIMD2<Float>)] = abs(out.y - 1) < 0.01
                ? [(a, SIMD2(a.x > 0 ? gx : -gx, L.gateZ)), (SIMD2(e.x > 0 ? gx : -gx, L.gateZ), e)] : [(a, e)]
            for (p0, p1) in pieces {
                run(&b.stone, p0, p1, L.ground - 2, top, L.wallThick, stoneC)
                crenellate(&b.stone, p0, p1, y: top, out: out, thick: L.wallThick)
                // A banner hanging on the inside face, every other side.
                if k % 2 == 1 {
                    let c2 = (p0 + p1) / 2 - out * (L.wallThick / 2 + 0.1)
                    let along = simd_normalize(p1 - p0)
                    banner(&b.cloth, top: SIMD3(c2.x, top - 1.2, c2.y), right: SIMD3(along.x, 0, along.y), width: 5, height: 9,
                           color: k % 4 == 1 ? red : royalBlue, emblem: gold, phase: Float(k), facing: SIMD3(-out.x, 0, -out.y))
                }
            }
        }
        let flags: [SIMD3<Float>] = [red, gold, royalBlue, SIMD3(0.95, 0.95, 0.95)]
        for (k, c) in cs.enumerated() {
            tower(&b, at: c, r: L.towerRadius, h: L.towerHeight, roof: 15, phase: Float(k) * 1.3, flag: flags[k % flags.count])
        }
    }

    /// Two square towers either side of an arched gate, a portcullis drawn up, the royal banner, the drawbridge.
    private static func gatehouse(_ b: inout Builders) {
        let g = L.ground, z = L.gateZ, half = L.gateHalf
        let top = g + 33
        for s: Float in [-1, 1] {
            let cx = s * (half + 5)
            b.stone.boxAA(SIMD3(cx - 4.5, g - 2, z - 7), SIMD3(cx + 4.5, top, z + 7), stoneC)
            for k in 0..<4 {
                // Merlons round the top.
                let t = Float(k) / 3
                for (dx, dz) in [(-4.2 + 8.4 * t, -6.7), (-4.2 + 8.4 * t, 6.7), (-4.2, -6.7 + 13.4 * t), (4.2, -6.7 + 13.4 * t)] as [(Float, Float)] {
                    b.stone.box(SIMD3(cx + dx, top + 0.7, z + dz), SIMD3(0.7, 0.7, 0.7), stoneC)
                }
            }
            // Arrow slits, lit.
            for y in [g + 14, g + 22] {
                b.glow.quad(SIMD3(cx - 0.4, y, z + 7.05), SIMD3(cx + 0.4, y, z + 7.05), SIMD3(cx + 0.4, y + 2.6, z + 7.05), SIMD3(cx - 0.4, y + 2.6, z + 7.05),
                            SIMD3(1, 0.8, 0.5), facing: SIMD3(0, 0, 1))
            }
            pennant(&b.cloth, &b.trim, at: SIMD3(cx, top + 0.1, z), pole: 7, length: 8, color: s < 0 ? red : royalBlue, phase: s * 2)
        }
        // The block over the passage, with a pointed arch cut by stepping the lintel.
        b.stone.boxAA(SIMD3(-half, g + L.gateHeight + 1.5, z - 6), SIMD3(half, top - 2, z + 6), stoneC)
        for k in 0..<5 {
            let t = Float(k) / 4
            let w = half * (1 - t * t * 0.85)
            b.stone.boxAA(SIMD3(-half, g + L.gateHeight - 2 + Float(k) * 0.9, z - 6), SIMD3(-w, g + L.gateHeight - 1.1 + Float(k) * 0.9, z + 6), stoneDark)
            b.stone.boxAA(SIMD3(w, g + L.gateHeight - 2 + Float(k) * 0.9, z - 6), SIMD3(half, g + L.gateHeight - 1.1 + Float(k) * 0.9, z + 6), stoneDark)
        }
        // The portcullis, drawn up into the arch: an iron grid.
        for k in 0..<9 {
            let x = -half + 0.6 + Float(k) * (half * 2 - 1.2) / 8
            b.trim.boxAA(SIMD3(x - 0.08, g + L.gateHeight - 1.4, z - 0.12), SIMD3(x + 0.08, g + L.gateHeight + 1.4, z + 0.12), SIMD3(0.18, 0.18, 0.2), uv: metal)
        }
        // The royal banner over the gate: blue with a gold sun.
        banner(&b.cloth, top: SIMD3(0, top - 2.5, z + 6.2), right: SIMD3(1, 0, 0), width: 7, height: 12, color: royalBlue, emblem: gold, phase: 0.4,
               facing: SIMD3(0, 0, 1))
        // The drawbridge: heavy planks across the ditch between two curbs, with iron bands along it (its chains are
        // wound up out of sight, so nothing crosses the way in).
        let deckY = g + 0.25
        let z0 = z + 6, z1 = L.ditchOut + 4
        var wood = MeshBuilder()
        // The dark beams underneath, showing in the gaps between the planks.
        wood.boxAA(SIMD3(-4.8, deckY - 0.5, z0), SIMD3(4.8, deckY - 0.1, z1), SIMD3(0.24, 0.16, 0.1))
        let shades: [Float] = [1, 0.9, 1.06, 0.86, 0.97, 1.03, 0.92]
        var pz = z0, k = 0
        while pz < z1 - 0.2 {
            let next = min(pz + 0.8, z1)
            wood.boxAA(SIMD3(-4.7, deckY - 0.16, pz + 0.05), SIMD3(4.7, deckY, next - 0.05), SIMD3(0.55, 0.4, 0.25) * shades[k % shades.count])
            pz = next; k += 1
        }
        for s: Float in [-1, 1] {
            wood.boxAA(SIMD3(s * 5 - 0.35, deckY - 0.7, z0), SIMD3(s * 5 + 0.35, deckY + 0.5, z1), SIMD3(0.4, 0.28, 0.18))
            b.trim.boxAA(SIMD3(s * 3.4 - 0.14, deckY, z0), SIMD3(s * 3.4 + 0.14, deckY + 0.03, z1), SIMD3(0.16, 0.16, 0.18), uv: metal)
        }
        b.trim.append(wood)
    }

    /// The great hall: walls with stained glass, the doors and the rose window, the roof with the Crown Lantern, and
    /// inside: floor, carpet, columns, arches, banners, chandeliers, the dais and the throne.
    private static func hall(_ b: inout Builders) {
        let g = L.ground, W = L.hallHalfW, S = L.hallSouth, N = L.hallNorth
        let eave = g + L.hallWall, ridge = g + L.hallRidge
        let t: Float = 1.4
        // Side walls with buttresses outside.
        for s: Float in [-1, 1] {
            b.stone.boxAA(SIMD3(s * W - t / 2, g - 1, N), SIMD3(s * W + t / 2, eave, S), stoneC)
            var z = S - 3
            while z > N + 2 {
                b.stone.boxAA(SIMD3(s * (W + t / 2), g - 1, z - 0.8), SIMD3(s * (W + t / 2 + 1.6), eave - 3, z + 0.8), stoneDark)
                b.stone.boxAA(SIMD3(s * (W + t / 2), eave - 3, z - 0.8), SIMD3(s * (W + t / 2 + 0.9), eave + 1.5, z + 0.8), stoneDark)
                z -= 12
            }
            // Stained glass between the buttresses, on both faces.
            for wz in stride(from: S - 9, to: N + 6, by: -12) {
                for face: Float in [1, -1] {
                    let x = s * W + face * s * (t / 2 + 0.03)
                    stainedGlass(&b.glow, center: SIMD3(x, g + 13, wz), right: SIMD3(0, 0, 1), width: 3.6, height: 12,
                                 facing: SIMD3(face * s, 0, 0), seed: Int(wz) * 7 + Int(s * 3))
                }
            }
        }
        // The south front: the door opening, the gable, the rose window.
        let doorTop = g + L.doorHeight
        b.stone.boxAA(SIMD3(-W - t / 2, g - 1, S - t / 2), SIMD3(-L.doorHalf, eave, S + t / 2), stoneC)
        b.stone.boxAA(SIMD3(L.doorHalf, g - 1, S - t / 2), SIMD3(W + t / 2, eave, S + t / 2), stoneC)
        b.stone.boxAA(SIMD3(-L.doorHalf, doorTop, S - t / 2), SIMD3(L.doorHalf, eave, S + t / 2), stoneC)
        gable(&b.stone, z: S, from: eave, to: ridge, halfW: W + t / 2, thick: t)
        gable(&b.stone, z: N, from: eave, to: ridge, halfW: W + t / 2, thick: t)
        b.stone.boxAA(SIMD3(-W - t / 2, g - 1, N - t / 2), SIMD3(W + t / 2, eave, N + t / 2), stoneC)
        // A carved surround for the doors, and the doors themselves standing open, swung inward.
        for s: Float in [-1, 1] {
            b.stone.boxAA(SIMD3(s * L.doorHalf - 0.9, g - 1, S + t / 2), SIMD3(s * L.doorHalf + 0.9, doorTop + 1.2, S + t / 2 + 0.8), stoneDark)
            var door = MeshBuilder()
            door.box(SIMD3(s * (L.doorHalf - 0.2), g + L.doorHeight / 2 - 0.4, S - 3.4), SIMD3(0.25, L.doorHeight / 2 - 0.4, 3.0), SIMD3(0.46, 0.28, 0.16),
                     rot: yawQuat(s * 0.12))
            b.trim.append(door)
        }
        b.stone.boxAA(SIMD3(-L.doorHalf - 0.9, doorTop + 0.4, S + t / 2), SIMD3(L.doorHalf + 0.9, doorTop + 1.6, S + t / 2 + 0.8), stoneDark)
        roseWindow(&b.glow, center: SIMD3(0, eave + 6.5, S + t / 2 + 0.04), r: 4.6, facing: SIMD3(0, 0, 1))
        roseWindow(&b.glow, center: SIMD3(0, eave + 6.5, S - t / 2 - 0.04), r: 4.6, facing: SIMD3(0, 0, -1))
        // The roof: two slopes of slate, leaving the lantern's opening over the dais.
        let lz0 = L.lanternZ - L.lanternOpening, lz1 = L.lanternZ + L.lanternOpening
        for s: Float in [-1, 1] {
            let eaveP = SIMD3<Float>(s * (W + 1.6), eave - 0.4, 0), ridgeP = SIMD3<Float>(0, ridge, 0)
            func slope(_ za: Float, _ zb: Float, inner: Float) {
                // inner: how far up the slope (0 eave … 1 ridge) this strip reaches.
                let top = simd_mix(eaveP, ridgeP, SIMD3(repeating: inner))
                b.trim.quad(SIMD3(eaveP.x, eaveP.y, za), SIMD3(eaveP.x, eaveP.y, zb), SIMD3(top.x, top.y, zb), SIMD3(top.x, top.y, za), slate, uv: gloss,
                            facing: SIMD3(s, 1.2, 0))
                b.trim.quad(SIMD3(eaveP.x, eaveP.y - 0.5, za), SIMD3(eaveP.x, eaveP.y - 0.5, zb), SIMD3(top.x, top.y - 0.5, zb), SIMD3(top.x, top.y - 0.5, za),
                            stoneDark * 0.8, uv: matte, facing: SIMD3(-s, -1.2, 0))
            }
            let openTo = 1 - L.lanternOpening / (W + 1.6)
            slope(S + 1.5, lz1, inner: 1)
            slope(lz1, lz0, inner: openTo)
            slope(lz0, N - 1.5, inner: 1)
            // Gold cresting along the ridge.
            b.trim.boxAA(SIMD3(-0.25, ridge - 0.1, lz1), SIMD3(0.25, ridge + 0.6, S + 1.5), gold, uv: metal)
            b.trim.boxAA(SIMD3(-0.25, ridge - 0.1, N - 1.5), SIMD3(0.25, ridge + 0.6, lz0), gold, uv: metal)
            _ = s
        }
        crownLantern(&b, center: SIMD3(0, 0, L.lanternZ))
        // Inside: the floor (flagstones), the carpet, the dais, the throne.
        b.stone.boxAA(SIMD3(-W + t / 2, g - 0.4, N + t / 2), SIMD3(W - t / 2, g + 0.12, S - t / 2), SIMD3(0.78, 0.74, 0.68))
        let carpet = SIMD3<Float>(0.66, 0.07, 0.10)
        b.trim.boxAA(SIMD3(-2.6, g + 0.12, L.daisFront + 2.4), SIMD3(2.6, g + 0.18, S - t / 2), carpet, uv: matte)
        b.trim.boxAA(SIMD3(-2.8, g + 0.12, L.daisFront + 2.4), SIMD3(-2.6, g + 0.2, S - t / 2), gold, uv: metal)
        b.trim.boxAA(SIMD3(2.6, g + 0.12, L.daisFront + 2.4), SIMD3(2.8, g + 0.2, S - t / 2), gold, uv: metal)
        dais(&b)
        columns(&b)
        chandeliers(&b)
        // Torches on the walls between the windows.
        for s: Float in [-1, 1] {
            for z in stride(from: S - 15, to: N + 4, by: -12) {
                let p = SIMD3<Float>(s * (W - t / 2 - 0.25), g + 6, z)
                b.trim.boxAA(p - SIMD3(0.12, 0.6, 0.12), p + SIMD3(0.12, 0.2, 0.12), SIMD3(0.2, 0.2, 0.22), uv: metal)
                b.glow.ellipsoid(p + SIMD3(0, 0.6, 0), SIMD3(0.26, 0.48, 0.26), SIMD3(1, 0.62, 0.25), rings: 3, sides: 6)
            }
        }
    }

    private static func gable(_ m: inout MeshBuilder, z: Float, from eave: Float, to ridge: Float, halfW: Float, thick: Float) {
        // A stack of thinning boxes makes the triangle (the roof covers the steps).
        let steps = 8
        for k in 0..<steps {
            let y0 = eave + (ridge - eave) * Float(k) / Float(steps), y1 = eave + (ridge - eave) * Float(k + 1) / Float(steps)
            let w = halfW * (1 - Float(k) / Float(steps)) - 0.3
            m.boxAA(SIMD3(-w, y0, z - thick / 2), SIMD3(w, y1, z + thick / 2), stoneC)
        }
    }

    private static let glassColors: [SIMD3<Float>] = [SIMD3(0.85, 0.12, 0.16), SIMD3(0.16, 0.32, 0.92), SIMD3(0.98, 0.78, 0.18), SIMD3(0.16, 0.66, 0.32),
                                                      SIMD3(0.62, 0.22, 0.86), SIMD3(0.98, 0.52, 0.16)]

    /// A tall pointed window of coloured panes in lead.
    private static func stainedGlass(_ m: inout MeshBuilder, center: SIMD3<Float>, right: SIMD3<Float>, width: Float, height: Float,
                                     facing: SIMD3<Float>, seed: Int) {
        let cols = 3, rows = 9
        let pw = width / Float(cols), ph = height / Float(rows)
        let base = center - right * (width / 2) - SIMD3(0, height / 2, 0)
        for r in 0..<rows {
            for c in 0..<cols {
                // The pointed top: the outer panes of the top row drop out.
                if r == rows - 1 && c != 1 { continue }
                let h = Int(ihash(seed + r * 7, c, 0x51A5) % UInt32(glassColors.count))
                let col = glassColors[h] * (r % 2 == c % 2 ? 1.0 : 0.85)
                let p = base + right * (Float(c) * pw + 0.06) + SIMD3(0, Float(r) * ph + 0.06, 0)
                let dx = right * (pw - 0.12), dy = SIMD3<Float>(0, ph - 0.12, 0)
                m.quad(p, p + dx, p + dx + dy, p + dy, col, facing: facing)
            }
        }
    }

    /// A round window: rings of coloured petals round a gold centre.
    private static func roseWindow(_ m: inout MeshBuilder, center c: SIMD3<Float>, r: Float, facing: SIMD3<Float>) {
        let right = simd_normalize(simd_cross(kUp, facing)), up = kUp
        let rings: [(Float, Float, Int)] = [(0, 0.22, 1), (0.25, 0.55, 8), (0.58, 0.95, 16)]
        for (ri, (r0, r1, n)) in rings.enumerated() {
            for k in 0..<max(n, 1) {
                let a0 = Float(k) / Float(max(n, 1)) * 2 * .pi + 0.04, a1 = Float(k + 1) / Float(max(n, 1)) * 2 * .pi - 0.04
                let col = ri == 0 ? gold : glassColors[(k + ri * 3) % glassColors.count]
                func pt(_ a: Float, _ rr: Float) -> SIMD3<Float> { c + (right * cos(a) + up * sin(a)) * rr * r }
                if n == 1 {
                    m.ellipsoid(c, SIMD3(r * r1, r * r1, 0.06), col, rings: 3, sides: 12)
                } else {
                    m.quad(pt(a0, r0), pt(a1, r0), pt(a1, r1), pt(a0, r1), col, facing: facing)
                }
            }
        }
    }

    /// Over the throne: an octagonal drum standing up through the roof round the opening (open to the sky), gold pillars
    /// on top and a ring of crown points and jewels.
    private static func crownLantern(_ b: inout Builders, center c: SIMD3<Float>) {
        let r = L.lanternRadius
        let drumBottom = L.roofY(r) - 2.5, base = L.lanternTop
        let pillarTop = base + 9
        for k in 0..<8 {
            let a0 = Float(k) / 8 * 2 * .pi + .pi / 8, a1 = Float(k + 1) / 8 * 2 * .pi + .pi / 8
            let p0 = SIMD2(c.x + cos(a0) * r, c.z + sin(a0) * r), p1 = SIMD2(c.x + cos(a1) * r, c.z + sin(a1) * r)
            run(&b.stone, p0, p1, drumBottom, base, 1.2, stoneC)
            // A lit window in each face of the drum.
            let mid2 = (p0 + p1) / 2, outward = simd_normalize(mid2 - SIMD2(c.x, c.z))
            let wc = SIMD3(mid2.x + outward.x * 0.65, base - 4.5, mid2.y + outward.y * 0.65)
            let side = SIMD3(-outward.y, 0, outward.x) * 0.9
            b.glow.quad(wc - side, wc + side, wc + side + SIMD3(0, 2.6, 0), wc - side + SIMD3(0, 2.6, 0), glassColors[k % glassColors.count],
                        facing: SIMD3(outward.x, 0, outward.y))
            b.trim.boxAA(SIMD3(min(p0.x, p1.x) - 0.7, base - 0.1, min(p0.y, p1.y) - 0.7), SIMD3(max(p0.x, p1.x) + 0.7, base + 0.5, max(p0.y, p1.y) + 0.7),
                         gold, uv: metal)
            let p = SIMD3(p0.x, base + 0.5, p0.y)
            b.trim.tube(p, SIMD3(p.x, pillarTop, p.z), r0: 0.55, r1: 0.45, sides: 8, gold, uv: metal, cap: true)
            // The ring and the crown's points.
            let q0 = SIMD3(p0.x, pillarTop, p0.y), q1 = SIMD3(p1.x, pillarTop, p1.y)
            b.trim.tube(q0, q1, r0: 0.5, r1: 0.5, sides: 6, gold, uv: metal)
            let mid = (q0 + q1) / 2
            b.trim.tube(q0, q0 + SIMD3(0, 3.4, 0), r0: 0.5, r1: 0.06, sides: 6, gold, uv: metal)
            b.trim.tube(mid, mid + SIMD3(0, 1.8, 0), r0: 0.4, r1: 0.06, sides: 6, gold, uv: metal)
            b.glow.ellipsoid(q0 + SIMD3(0, 3.7, 0), SIMD3(repeating: 0.45), glassColors[k % glassColors.count], rings: 3, sides: 6)
        }
    }

    private static func dais(_ b: inout Builders) {
        let g = L.ground, W = L.hallHalfW - 1, h = L.daisHeight
        for k in 0..<3 {
            let y = g + h * Float(k + 1) / 3
            let z = L.daisFront - Float(2 - k) * 0.8
            b.stone.boxAA(SIMD3(-W, g, L.daisBack), SIMD3(W, y, z), SIMD3(0.8, 0.76, 0.7))
        }
        // The carpet runs up the steps and to the throne.
        b.trim.boxAA(SIMD3(-2.6, g + h, L.daisBack + 4), SIMD3(2.6, g + h + 0.06, L.daisFront), SIMD3(0.66, 0.07, 0.1), uv: matte)
        // The throne: gold frame, red velvet, a tall back with a golden sun.
        let tz: Float = -72.5, ty = g + h
        b.trim.boxAA(SIMD3(-1.6, ty, tz - 1.2), SIMD3(1.6, ty + 1.3, tz + 1.2), gold, uv: metal)
        b.trim.boxAA(SIMD3(-1.3, ty + 1.3, tz - 1.0), SIMD3(1.3, ty + 1.6, tz + 1.0), SIMD3(0.62, 0.06, 0.1), uv: matte)
        b.trim.boxAA(SIMD3(-1.6, ty, tz - 1.6), SIMD3(1.6, ty + 6.2, tz - 1.1), gold, uv: metal)
        b.trim.boxAA(SIMD3(-1.25, ty + 1.6, tz - 1.12), SIMD3(1.25, ty + 5.6, tz - 1.05), SIMD3(0.62, 0.06, 0.1), uv: matte)
        b.trim.cylinder(SIMD3(0, ty + 6.6, tz - 1.35), r0: 1.3, r1: 1.3, y0: -0.25, y1: 0.25, sides: 16, gold, uv: metal)
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * .pi
            let dir = SIMD3(cos(a), sin(a), 0)
            b.trim.tube(SIMD3(0, ty + 6.6, tz - 1.35) + dir * 1.2, SIMD3(0, ty + 6.6, tz - 1.35) + dir * 2.1, r0: 0.18, r1: 0.02, sides: 4, gold, uv: metal)
        }
        for s: Float in [-1, 1] {
            b.trim.boxAA(SIMD3(s * 1.6 - 0.25, ty, tz - 1.2), SIMD3(s * 1.6 + 0.25, ty + 2.4, tz + 1.2), gold, uv: metal)
            // The queen's seat beside it, a little smaller.
            let qx = s * 4.6
            b.trim.boxAA(SIMD3(qx - 1.1, ty, tz - 0.8), SIMD3(qx + 1.1, ty + 1.1, tz + 0.9), gold * 0.95, uv: metal)
            b.trim.boxAA(SIMD3(qx - 1.1, ty, tz - 1.2), SIMD3(qx + 1.1, ty + 4.2, tz - 0.8), gold * 0.95, uv: metal)
            b.trim.boxAA(SIMD3(qx - 0.85, ty + 1.1, tz - 0.8), SIMD3(qx + 0.85, ty + 1.3, tz + 0.7), royalBlue, uv: matte)
        }
        // The great tapestry on the north wall behind the throne.
        let tw: Float = 11, top = g + 21
        b.trim.boxAA(SIMD3(-tw / 2 - 0.4, top, L.hallNorth + 0.8), SIMD3(tw / 2 + 0.4, top + 0.6, L.hallNorth + 1.4), gold, uv: metal)
        banner(&b.cloth, top: SIMD3(0, top, L.hallNorth + 1.2), right: SIMD3(1, 0, 0), width: tw, height: 15, color: royalBlue, emblem: gold, phase: 2.2,
               facing: SIMD3(0, 0, 1))
    }

    private static func columns(_ b: inout Builders) {
        let g = L.ground, h: Float = 19
        for s: Float in [-1, 1] {
            for z in L.columnZs {
                let p = SIMD3<Float>(s * L.columnX, g, z)
                b.stone.cylinder(p, r0: 1.5, r1: 1.4, y0: 0, y1: 1.2, sides: 12, stoneDark)
                b.stone.cylinder(p, r0: 1.05, r1: 0.95, y0: 1.2, y1: h - 1.4, sides: 12, stoneC, top: false)
                b.stone.cylinder(p, r0: 1.0, r1: 1.5, y0: h - 1.4, y1: h, sides: 12, stoneDark)
            }
            // Pointed arches from column to column along the nave, and a beam on top.
            for k in 0..<(L.columnZs.count - 1) {
                let z0 = L.columnZs[k], z1 = L.columnZs[k + 1]
                var prev: SIMD3<Float>?
                for j in 0...10 {
                    let u = Float(j) / 10
                    let z = lerp(z0, z1, u)
                    let lift = (1 - abs(u - 0.5) * 2)
                    let y = g + h + 3.2 * sqrt(max(lift, 0)) - 0.2
                    let p = SIMD3(s * L.columnX, y, z)
                    if let q = prev { b.stone.tube(q, p, r0: 0.55, r1: 0.55, sides: 6, stoneC) }
                    prev = p
                }
                // A banner hanging in each arch.
                let mz = (z0 + z1) / 2
                banner(&b.cloth, top: SIMD3(s * L.columnX, g + h + 1.6, mz), right: SIMD3(0, 0, 1), width: 2.6, height: 9,
                       color: k % 2 == 0 ? red : royalBlue, emblem: gold, phase: Float(k) * 0.9 + s, facing: SIMD3(-s, 0, 0))
            }
            b.stone.boxAA(SIMD3(s * L.columnX - 0.6, g + h + 3.2, L.columnZs.last! - 1), SIMD3(s * L.columnX + 0.6, g + h + 4, L.columnZs.first! + 1), stoneDark)
        }
    }

    private static func chandeliers(_ b: inout Builders) {
        let g = L.ground
        for z: Float in [-20, -38, -56] {
            let c = SIMD3<Float>(0, g + 15.5, z)
            var prev: SIMD3<Float>?
            for k in 0...16 {
                let a = Float(k) / 16 * 2 * .pi
                let p = c + SIMD3(cos(a) * 2.6, 0, sin(a) * 2.6)
                if let q = prev { b.trim.tube(q, p, r0: 0.12, r1: 0.12, sides: 5, gold, uv: metal) }
                prev = p
                if k < 16 && k % 2 == 0 {
                    b.trim.cylinder(p + SIMD3(0, 0.1, 0), r0: 0.09, r1: 0.09, y0: 0, y1: 0.45, sides: 5, SIMD3(0.98, 0.95, 0.88), uv: matte)
                    b.glow.ellipsoid(p + SIMD3(0, 0.75, 0), SIMD3(0.12, 0.24, 0.12), SIMD3(1, 0.75, 0.35), rings: 2, sides: 5)
                }
            }
            for k in 0..<4 {
                let a = Float(k) / 4 * 2 * .pi
                b.trim.tube(c + SIMD3(cos(a) * 2.6, 0, sin(a) * 2.6), c + SIMD3(0, 4, 0), r0: 0.05, r1: 0.05, sides: 4, gold, uv: metal)
            }
            b.trim.tube(c + SIMD3(0, 4, 0), SIMD3(0, L.roofY(0) - 1, z), r0: 0.07, r1: 0.07, sides: 4, SIMD3(0.25, 0.22, 0.2), uv: metal)
            b.glow.ellipsoid(c + SIMD3(0, -0.4, 0), SIMD3(repeating: 0.45), gold, rings: 3, sides: 8)
        }
    }

    /// The Sky Tower: a tall drum with lit windows, a balcony, the tallest cone roof and the great flag.
    private static func skyTower(_ b: inout Builders) {
        let p = SIMD3(L.skyTower.x, L.ground, L.skyTower.y)
        let r = L.skyTowerRadius, h = L.skyTowerHeight
        b.stone.cylinder(p, r0: r * 1.08, r1: r, y0: -2, y1: h, sides: 28, stoneC, top: false)
        for y in stride(from: Float(12), to: h, by: 12) {
            b.stone.cylinder(p, r0: r * 1.05, r1: r * 1.05, y0: y, y1: y + 0.7, sides: 28, stoneDark)
        }
        for k in 0..<12 {
            let a = Float(k) * 2.4
            let y = 14 + Float(k) * 6.6
            let q = p + SIMD3(cos(a) * (r + 0.06), y, sin(a) * (r + 0.06))
            let side = SIMD3(-sin(a), 0, cos(a)) * 0.6
            b.glow.quad(q - side, q + side, q + side + SIMD3(0, 2.8, 0), q - side + SIMD3(0, 2.8, 0), SIMD3(1, 0.8, 0.5), facing: SIMD3(cos(a), 0, sin(a)))
        }
        b.stone.cylinder(p, r0: r * 1.32, r1: r * 1.32, y0: h - 10, y1: h - 9, sides: 28, stoneDark)
        b.trim.cylinder(p, r0: r * 1.36, r1: r * 1.36, y0: h - 9, y1: h - 8.6, sides: 28, gold, uv: metal)
        b.trim.cylinder(p + SIMD3(0, h, 0), r0: r * 1.3, r1: 0.2, y0: 0, y1: 30, sides: 28, slate, top: false, uv: gloss)
        b.trim.cylinder(p + SIMD3(0, h - 0.05, 0), r0: r * 1.32, r1: r * 1.32, y0: 0, y1: 0.5, sides: 28, gold, uv: metal)
        b.trim.ellipsoid(p + SIMD3(0, h + 30.6, 0), SIMD3(repeating: 0.9), gold, rings: 4, sides: 8, uv: metal)
        pennant(&b.cloth, &b.trim, at: p + SIMD3(0, h + 31, 0), pole: 9, length: 14, color: royalBlue, phase: 3.3)
    }

    /// The courtyard: hedges along the path, two fountains, lamp posts, striped tents and bunting over the way in.
    private static func courtyard(_ b: inout Builders) {
        let g = L.ground
        var hedge = MeshBuilder()
        for s: Float in [-1, 1] {
            var z: Float = L.gateZ - 8
            while z > L.hallSouth + 8 {
                let z1 = max(z - 14, L.hallSouth + 8)
                if abs((z + z1) / 2 - 50) > 6 {
                    hedge.boxAA(SIMD3(s * 6.2 - 0.9, g, z1), SIMD3(s * 6.2 + 0.9, g + 1.5, z), SIMD3(0.18, 0.40, 0.16), topColor: SIMD3(0.24, 0.48, 0.2))
                    // Flower beds behind the hedges.
                    for k in 0..<Int((z - z1) / 1.6) {
                        let fz = z1 + 0.8 + Float(k) * 1.6
                        let col = glassColors[(k + (s > 0 ? 2 : 0)) % glassColors.count] * 0.9 + SIMD3(0.1, 0.1, 0.1)
                        hedge.ellipsoid(SIMD3(s * 8.4, g + 0.35, fz), SIMD3(0.55, 0.32, 0.55), col, rings: 2, sides: 6)
                    }
                }
                z = z1 - 4
            }
        }
        b.trim.append(hedge)
        // Two fountains, tiered, with water glowing a little in the low sun.
        for s: Float in [-1, 1] {
            let p = SIMD3<Float>(s * 30, g, 50)
            b.stone.cylinder(p, r0: 6, r1: 6, y0: 0, y1: 0.9, sides: 24, stoneDark, top: false)
            b.stone.cylinder(p, r0: 5.4, r1: 5.4, y0: 0, y1: 0.7, sides: 24, stoneC, top: false)
            b.glow.cylinder(p, r0: 5.5, r1: 5.5, y0: 0.6, y1: 0.62, sides: 24, SIMD3(0.35, 0.62, 0.78))
            b.stone.cylinder(p, r0: 0.8, r1: 0.6, y0: 0, y1: 3.4, sides: 10, stoneC)
            b.stone.cylinder(p + SIMD3(0, 3.4, 0), r0: 2.4, r1: 2.6, y0: 0, y1: 0.5, sides: 16, stoneC)
            b.glow.cylinder(p + SIMD3(0, 3.85, 0), r0: 2.3, r1: 2.3, y0: 0, y1: 0.03, sides: 16, SIMD3(0.4, 0.68, 0.84))
            b.trim.ellipsoid(p + SIMD3(0, 4.6, 0), SIMD3(0.5, 0.8, 0.5), gold, rings: 3, sides: 8, uv: metal)
        }
        // Lamp posts along the path.
        for s: Float in [-1, 1] {
            for z in stride(from: L.gateZ - 14, to: L.hallSouth + 10, by: -16) {
                let p = SIMD3<Float>(s * 4.6, g, z)
                b.trim.tube(p, p + SIMD3(0, 4.2, 0), r0: 0.11, r1: 0.08, sides: 5, SIMD3(0.16, 0.16, 0.18), uv: metal)
                b.glow.ellipsoid(p + SIMD3(0, 4.5, 0), SIMD3(0.3, 0.38, 0.3), SIMD3(1, 0.82, 0.5), rings: 3, sides: 6)
            }
        }
        // Striped tents for the celebration.
        for (i, p) in [SIMD3<Float>(-46, g, 22), SIMD3(46, g, 22), SIMD3(-48, g, 82), SIMD3(48, g, 82), SIMD3(-60, g, -30), SIMD3(60, g, -30)].enumerated() {
            let c1 = i % 2 == 0 ? red : royalBlue
            for k in 0..<12 {
                let a0 = Float(k) / 12 * 2 * .pi, a1 = Float(k + 1) / 12 * 2 * .pi
                let col = k % 2 == 0 ? c1 : SIMD3<Float>(0.96, 0.94, 0.9)
                let r: Float = 6
                b.trim.quad(p + SIMD3(cos(a0) * r, 0, sin(a0) * r), p + SIMD3(cos(a1) * r, 0, sin(a1) * r), p + SIMD3(cos(a1) * r, 4, sin(a1) * r),
                            p + SIMD3(cos(a0) * r, 4, sin(a0) * r), col, uv: matte, facing: SIMD3(cos((a0 + a1) / 2), 0, sin((a0 + a1) / 2)))
                b.trim.quad(p + SIMD3(cos(a0) * r * 1.08, 4, sin(a0) * r * 1.08), p + SIMD3(cos(a1) * r * 1.08, 4, sin(a1) * r * 1.08),
                            p + SIMD3(0, 8.5, 0), p + SIMD3(0, 8.5, 0), col, uv: matte, facing: SIMD3(cos((a0 + a1) / 2), 1, sin((a0 + a1) / 2)))
            }
            pennant(&b.cloth, &b.trim, at: p + SIMD3(0, 8.4, 0), pole: 2.6, length: 3, color: gold, phase: Float(i))
        }
        // Bunting across the path: strings of little flags.
        let bunting: [SIMD3<Float>] = [red, gold, royalBlue, SIMD3(0.18, 0.62, 0.3), SIMD3(0.95, 0.95, 0.95)]
        for (j, z) in stride(from: L.gateZ - 20, to: L.hallSouth + 12, by: -18).enumerated() {
            let a = SIMD3<Float>(-9, g + 7.5, z), e = SIMD3<Float>(9, g + 7.5, z)
            b.trim.tube(a - SIMD3(0, 7.5, 0), a + SIMD3(0, 0.3, 0), r0: 0.1, r1: 0.08, sides: 5, SIMD3(0.4, 0.3, 0.22), uv: matte)
            b.trim.tube(e - SIMD3(0, 7.5, 0), e + SIMD3(0, 0.3, 0), r0: 0.1, r1: 0.08, sides: 5, SIMD3(0.4, 0.3, 0.22), uv: matte)
            let n = 14
            for k in 0..<n {
                let u0 = Float(k) / Float(n), u1 = Float(k + 1) / Float(n)
                func sag(_ u: Float) -> SIMD3<Float> { simd_mix(a, e, SIMD3(repeating: u)) - SIMD3(0, 1.6 * 4 * u * (1 - u), 0) }
                let p0 = sag(u0 + 0.1 / Float(n)), p1 = sag(u1 - 0.1 / Float(n))
                let tip = (p0 + p1) / 2 - SIMD3(0, 1.0, 0)
                let i = b.cloth.vertexCount
                let col = bunting[(k + j) % bunting.count]
                b.cloth.vertex(p0, SIMD3(0, 0, 1), col, uv: SIMD2(Float(k), 0.05))
                b.cloth.vertex(p1, SIMD3(0, 0, 1), col, uv: SIMD2(Float(k), 0.05))
                b.cloth.vertex(tip, SIMD3(0, 0, 1), col, uv: SIMD2(Float(k), 0.5))
                b.cloth.tri(UInt32(i), UInt32(i + 1), UInt32(i + 2))
            }
        }
    }

    // MARK: Collisions

    /// Everything solid: walls, towers, the gatehouse (not its passage), the hall (not its doors or the lantern's
    /// opening), the columns, the dais and throne, the Sky Tower, the fountains.
    static let solids: [FinaleSolid] = {
        var out: [FinaleSolid] = []
        let id = simd_quatf(angle: 0, axis: kUp)
        func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) { out.append(.box(OBox(center: (lo + hi) / 2, rot: id, half: (hi - lo) / 2))) }
        let g = L.ground
        let cs = L.corners
        for k in 0..<8 {
            let A = SIMD2(cs[k].x, cs[k].z), B = SIMD2(cs[(k + 1) % 8].x, cs[(k + 1) % 8].z)
            let mid = simd_normalize((A + B) / 2)
            let gx = L.gateHalf + 9.5
            let pieces: [(SIMD2<Float>, SIMD2<Float>)] = abs(mid.y - 1) < 0.01
                ? [(A, SIMD2(A.x > 0 ? gx : -gx, L.gateZ)), (SIMD2(B.x > 0 ? gx : -gx, L.gateZ), B)] : [(A, B)]
            for (p0, p1) in pieces {
                let d = p1 - p0, len = simd_length(d), c = (p0 + p1) / 2
                out.append(.box(OBox(center: SIMD3(c.x, g + (L.wallHeight + 1.4) / 2 - 1, c.y), rot: yawQuat(atan2(-d.y, d.x)),
                                     half: SIMD3(len / 2, (L.wallHeight + 1.4) / 2 + 1, L.wallThick / 2))))
            }
            out.append(.capsule(Capsule(a: cs[k] - SIMD3(0, 2, 0), b: cs[k] + SIMD3(0, L.towerHeight + 6, 0), r: L.towerRadius * 1.1)))
            out.append(.capsule(Capsule(a: cs[k] + SIMD3(0, L.towerHeight + 6, 0), b: cs[k] + SIMD3(0, L.towerHeight + 14, 0), r: L.towerRadius * 0.55)))
        }
        // Gatehouse towers and the block over the passage.
        for s: Float in [-1, 1] {
            let cx = s * (L.gateHalf + 5)
            box(SIMD3(cx - 4.5, g - 2, L.gateZ - 7), SIMD3(cx + 4.5, g + 34.5, L.gateZ + 7))
        }
        box(SIMD3(-L.gateHalf, g + L.gateHeight - 0.6, L.gateZ - 6), SIMD3(L.gateHalf, g + 32, L.gateZ + 6))
        // The great hall's walls (the doorway left open), the roof (the lantern's opening left open).
        let W = L.hallHalfW, S = L.hallSouth, N = L.hallNorth, eave = g + L.hallWall
        for s: Float in [-1, 1] { box(SIMD3(s * W - 0.9, g - 1, N), SIMD3(s * W + 0.9, eave, S)) }
        box(SIMD3(-W - 0.9, g - 1, N - 0.9), SIMD3(W + 0.9, eave + 18, N + 0.9))
        box(SIMD3(-W - 0.9, g - 1, S - 0.9), SIMD3(-L.doorHalf, eave + 12, S + 0.9))
        box(SIMD3(L.doorHalf, g - 1, S - 0.9), SIMD3(W + 0.9, eave + 12, S + 0.9))
        box(SIMD3(-L.doorHalf, g + L.doorHeight, S - 0.9), SIMD3(L.doorHalf, eave + 16, S + 0.9))
        // The roof as stacked slabs following the pitch (outside the lantern's square).
        let lz0 = L.lanternZ - L.lanternOpening, lz1 = L.lanternZ + L.lanternOpening
        for k in 0..<6 {
            let x0 = Float(k) / 6 * (W + 1.6), x1 = Float(k + 1) / 6 * (W + 1.6)
            let yTop = L.roofY(x0) + 0.6, yBot = L.roofY(x1) - 1.4
            for s: Float in [-1, 1] {
                let lo = s < 0 ? -x1 : x0, hi = s < 0 ? -x0 : x1
                if x0 < L.lanternOpening {
                    box(SIMD3(lo, yBot, lz1), SIMD3(hi, yTop, S + 1.5))
                    box(SIMD3(lo, yBot, N - 1.5), SIMD3(hi, yTop, lz0))
                } else {
                    box(SIMD3(lo, yBot, N - 1.5), SIMD3(hi, yTop, S + 1.5))
                }
            }
        }
        // The lantern's drum (eight wall panels round the shaft) and its pillars.
        let lr = L.lanternRadius
        for k in 0..<8 {
            let a0 = Float(k) / 8 * 2 * .pi + .pi / 8, a1 = Float(k + 1) / 8 * 2 * .pi + .pi / 8
            let p0 = SIMD2(cos(a0) * lr, L.lanternZ + sin(a0) * lr), p1 = SIMD2(cos(a1) * lr, L.lanternZ + sin(a1) * lr)
            let d = p1 - p0, c = (p0 + p1) / 2
            let y0 = L.roofY(lr) - 2.5, y1 = L.lanternTop
            out.append(.box(OBox(center: SIMD3(c.x, (y0 + y1) / 2, c.y), rot: yawQuat(atan2(-d.y, d.x)), half: SIMD3(simd_length(d) / 2 + 0.4, (y1 - y0) / 2, 0.7))))
            out.append(.capsule(Capsule(a: SIMD3(p0.x, y1, p0.y), b: SIMD3(p0.x, y1 + 12, p0.y), r: 0.7)))
        }
        // Columns, the dais, the throne.
        for s: Float in [-1, 1] { for z in L.columnZs { out.append(.capsule(Capsule(a: SIMD3(s * L.columnX, g, z), b: SIMD3(s * L.columnX, g + 19, z), r: 1.3))) } }
        box(SIMD3(-W + 1, g, L.daisBack), SIMD3(W - 1, g + L.daisHeight, L.daisFront))
        box(SIMD3(-1.7, g + L.daisHeight, -74.2), SIMD3(1.7, g + L.daisHeight + 6.4, -71.2))
        // The Sky Tower.
        let st = SIMD3(L.skyTower.x, g, L.skyTower.y)
        out.append(.capsule(Capsule(a: st - SIMD3(0, 2, 0), b: st + SIMD3(0, L.skyTowerHeight, 0), r: L.skyTowerRadius * 1.1)))
        out.append(.capsule(Capsule(a: st + SIMD3(0, L.skyTowerHeight, 0), b: st + SIMD3(0, L.skyTowerHeight + 20, 0), r: L.skyTowerRadius * 0.6)))
        // Fountains.
        for s: Float in [-1, 1] { out.append(.capsule(Capsule(a: SIMD3(s * 30, g, 50), b: SIMD3(s * 30, g + 4.5, 50), r: 2.6))) }
        return out
    }()
}
