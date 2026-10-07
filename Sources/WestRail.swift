import SceneKit
import simd

// The railroad: rails on a ballast bed across the plateau and, wherever a line meets a canyon, a timber trestle
// striding across on bents tall enough to fly between — plus the telegraph line alongside.

enum WestRail {
    static let gauge: Float = 1.5
    static let bentSpacing: Float = 14
    /// Where the ground falls this far below the rails, a trestle carries them.
    static let trestleGap: Float = 4

    /// Ground under the rails at x on line k, and the rail height.
    @inline(__always) static func profile(_ x: Float, line k: Int, _ t: WestTerrain) -> (ground: Float, rail: Float) {
        (t.height(x, WestLayout.lineZ(k)), WestLayout.trackY(x, line: k))
    }

    /// A trestle bent's legs (bottom left/right, top left/right) and brace levels.
    struct Bent {
        let x: Float
        let ground: Float
        let deck: Float
        let z: Float
        var height: Float { deck - ground }
        /// Half the spread of the legs at the foot and at the cap.
        var footHalf: Float { 3 + height * 0.07 }
        let capHalf: Float = 2.4
    }

    /// The bents of any trestles on line k between x0 and x1.
    static func bents(line k: Int, from x0: Float, to x1: Float, _ t: WestTerrain) -> [Bent] {
        var out: [Bent] = []
        var x = (x0 / bentSpacing).rounded(.down) * bentSpacing
        let z = WestLayout.lineZ(k)
        while x < x1 {
            if x >= x0 {
                let (g, r) = profile(x, line: k, t)
                if g < r - trestleGap {
                    out.append(Bent(x: x, ground: max(g, -1.5) - 1, deck: r - 0.9, z: z))
                }
            }
            x += bentSpacing
        }
        return out
    }

    /// Collision for trestles near a point: the legs and braces as capsules, the deck as boxes.
    static func solids(near p: SIMD3<Float>, radius r: Float, _ t: WestTerrain) -> (caps: [Capsule], boxes: [OBox]) {
        let (k, dl) = WestLayout.nearestLine(p.z)
        guard dl < r + 10 else { return ([], []) }
        var caps: [Capsule] = [], boxes: [OBox] = []
        let bs = bents(line: k, from: p.x - r, to: p.x + r, t)
        for b in bs {
            guard b.deck > p.y - r && b.ground < p.y + r else { continue }
            for s: Float in [-1, 1] {
                caps.append(Capsule(a: SIMD3(b.x, b.ground, b.z + s * b.footHalf), b: SIMD3(b.x, b.deck, b.z + s * b.capHalf), r: 0.55))
            }
            var y = b.deck - 9
            while y > b.ground + 2 {
                let wy = b.footHalf + (b.capHalf - b.footHalf) * (y - b.ground) / max(b.height, 1)
                caps.append(Capsule(a: SIMD3(b.x, y, b.z - wy), b: SIMD3(b.x, y, b.z + wy), r: 0.4))
                y -= 9
            }
        }
        if let first = bs.first, let last = bs.last {
            let y = (first.deck + last.deck) / 2
            boxes.append(OBox(center: SIMD3((first.x + last.x) / 2, y + 0.6, first.z), rot: simd_quatf(angle: 0, axis: kUp),
                              half: SIMD3((last.x - first.x) / 2 + bentSpacing, 0.9, 2.8)))
        }
        return (caps, boxes)
    }
}

extension WestTerrain {
    /// Lines that cross a chunk.
    private func lines(_ oz: Float) -> [Int] {
        let k0 = Int(floor((oz - 20 - WestLayout.lineOffset) / WestLayout.lineSpacing)), k1 = Int(ceil((oz + chunkSize + 20 - WestLayout.lineOffset) / WestLayout.lineSpacing))
        return (k0...k1).filter { let z = WestLayout.lineZ($0); return z >= oz && z < oz + chunkSize }
    }

    /// Rails, ballast, trestles and telegraph poles for a chunk (kept for every loaded chunk).
    func railNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var rails = MeshBuilder(), timber = MeshBuilder()
        let origin = SIMD3(ox, 0, oz)
        func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }
        let steel = SIMD3<Float>(0.32, 0.3, 0.3), ballast = SIMD3<Float>(0.42, 0.36, 0.31)
        let wood = SIMD3<Float>(0.42, 0.32, 0.23), woodDark = SIMD3<Float>(0.34, 0.26, 0.19)
        for k in lines(oz) {
            let z = WestLayout.lineZ(k)
            var x = ox
            while x < ox + chunkSize - 0.01 {
                let x2 = min(x + 8, ox + chunkSize)
                let (g0, r0) = WestRail.profile(x, line: k, self), (g1, r1) = WestRail.profile(x2, line: k, self)
                for s: Float in [-1, 1] {
                    let a = SIMD3(x, r0, z + s * WestRail.gauge / 2), b = SIMD3(x2, r1, z + s * WestRail.gauge / 2)
                    rails.quad(L(a + SIMD3(0, 0.16, -0.05)), L(b + SIMD3(0, 0.16, -0.05)), L(b + SIMD3(0, 0.16, 0.05)), L(a + SIMD3(0, 0.16, 0.05)), steel * 1.4,
                               facing: kUp)
                    rails.quad(L(a + SIMD3(0, 0, s * 0.05)), L(b + SIMD3(0, 0, s * 0.05)), L(b + SIMD3(0, 0.16, s * 0.05)), L(a + SIMD3(0, 0.16, s * 0.05)),
                               steel, facing: SIMD3(0, 0, s))
                }
                // Ballast on the ground; the deck where it's a trestle.
                let onGround = g0 > r0 - WestRail.trestleGap && g1 > r1 - WestRail.trestleGap
                if onGround {
                    rails.quad(L(SIMD3(x, r0 - 0.15, z - 2.2)), L(SIMD3(x, r0 - 0.15, z + 2.2)), L(SIMD3(x2, r1 - 0.15, z + 2.2)), L(SIMD3(x2, r1 - 0.15, z - 2.2)),
                               ballast, facing: kUp)
                } else {
                    timber.boxAA(L(SIMD3(x, min(r0, r1) - 0.9, z - 2.6)), L(SIMD3(x2, max(r0, r1) - 0.25, z + 2.6)), woodDark)
                }
                x = x2
            }
            // Trestle bents.
            for b in WestRail.bents(line: k, from: ox, to: ox + chunkSize, self) {
                for s: Float in [-1, 1] {
                    timber.tube(L(SIMD3(b.x, b.ground, z + s * b.footHalf)), L(SIMD3(b.x, b.deck, z + s * b.capHalf)), r0: 0.42, r1: 0.34, sides: 5, wood)
                    // Inner posts, straighter.
                    timber.tube(L(SIMD3(b.x, b.ground, z + s * b.footHalf * 0.35)), L(SIMD3(b.x, b.deck, z + s * 0.8)), r0: 0.36, r1: 0.3, sides: 5, wood * 0.95)
                }
                timber.boxAA(L(SIMD3(b.x - 0.35, b.deck - 0.5, z - 2.9)), L(SIMD3(b.x + 0.35, b.deck, z + 2.9)), woodDark)
                var y = b.deck - 9
                var flip = false
                while y > b.ground + 2 {
                    let w0 = b.footHalf + (b.capHalf - b.footHalf) * (y - b.ground) / max(b.height, 1)
                    let w1 = b.footHalf + (b.capHalf - b.footHalf) * (y + 9 - b.ground) / max(b.height, 1)
                    timber.boxAA(L(SIMD3(b.x - 0.2, y - 0.2, z - w0)), L(SIMD3(b.x + 0.2, y + 0.2, z + w0)), woodDark)
                    // Cross bracing.
                    let a = SIMD3(b.x, y, z + (flip ? w0 : -w0)), c = SIMD3(b.x, min(y + 9, b.deck - 0.5), z + (flip ? -w1 : w1))
                    timber.tube(L(a), L(c), r0: 0.16, r1: 0.16, sides: 4, wood * 1.05)
                    flip.toggle()
                    y -= 9
                }
                // Struts tying each bent to the next along the line, now and then.
                if Int((b.x / WestRail.bentSpacing).rounded()) % 2 == 0 {
                    var yy = b.deck - 18
                    while yy > b.ground + 4 {
                        timber.boxAA(L(SIMD3(b.x, yy - 0.15, z - 0.15)), L(SIMD3(b.x + WestRail.bentSpacing, yy + 0.15, z + 0.15)), woodDark)
                        yy -= 18
                    }
                }
            }
            // Telegraph poles along the north side.
            var px = (ox / 45).rounded(.up) * 45
            while px < ox + chunkSize {
                let pz = z + 7
                let gp = height(px, pz)
                let (gl, rl) = WestRail.profile(px, line: k, self)
                if gl > rl - 2 && gp > rl - 4 {
                    timber.tube(L(SIMD3(px, gp - 0.3, pz)), L(SIMD3(px, gp + 7.5, pz)), r0: 0.13, r1: 0.1, sides: 4, wood)
                    timber.boxAA(L(SIMD3(px - 0.08, gp + 6.9, pz - 0.9)), L(SIMD3(px + 0.08, gp + 7.05, pz + 0.9)), woodDark)
                    // Wire to the next pole.
                    let nx = px + 45, ng = height(nx, pz)
                    if ng > WestLayout.trackY(nx, line: k) - 6 {
                        for s: Float in [-0.7, 0.7] {
                            rails.tube(L(SIMD3(px, gp + 7.1, pz + s)), L(SIMD3(nx, ng + 7.1, pz + s)), r0: 0.025, r1: 0.025, sides: 3, SIMD3(0.12, 0.12, 0.12))
                        }
                    }
                }
                px += 45
            }
        }
        var out: [SCNNode] = []
        for (name, m, mat) in [("rails", rails, WestTerrain.townProps), ("trestle", timber, WestTown.wood)] as [(String, MeshBuilder, SCNMaterial)] where !m.isEmpty {
            let g = m.geometry()
            g.materials = [mat]
            if name == "rails" { g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 1300)] }
            let n = SCNNode(geometry: g)
            n.name = name
            n.castsShadow = true
            out.append(n)
        }
        return out
    }

    /// The ties under the rails (close up only).
    func railDetailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var ties = MeshBuilder()
        let origin = SIMD3(ox, 0, oz)
        for k in lines(oz) {
            let z = WestLayout.lineZ(k)
            var x = (ox / 0.9).rounded(.up) * 0.9
            while x < ox + chunkSize {
                let r = WestLayout.trackY(x, line: k)
                ties.boxAA(SIMD3(x - 0.13, r - 0.18, z - 1.25) - origin, SIMD3(x + 0.13, r - 0.02, z + 1.25) - origin, SIMD3(0.3, 0.22, 0.16))
                x += 0.9
            }
        }
        guard !ties.isEmpty else { return [] }
        let g = ties.geometry()
        g.materials = [WestTerrain.townProps]
        g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 380)]
        let n = SCNNode(geometry: g)
        n.name = "ties"
        return [n]
    }
}
