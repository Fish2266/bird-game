import SceneKit
import simd

/// Skyline City's ground and everything built on it. The ground is an ordinary height field painted with streets by
/// the ground shader; buildings, street furniture, bridges and the elevated railway are extra meshes per chunk.
final class CityTerrain: WorldTerrain {
    let waterLevel: Float = 0
    let chunkSize: Float = 256
    let cells = 64
    let lowCells: Int? = 16
    let lodDistance: Float = 650
    let radius = 7
    private(set) var groundMaterial: SCNMaterial?
    private var glowMaterial = WorldMaterials.glow(2.2)
    private let props = WorldMaterials.finishes()

    static let elHeight: Float = 14.5

    func height(_ x: Float, _ z: Float) -> Float { CityLayout.ground(x, z) }

    func configure(ground: SCNMaterial, glow: SCNMaterial) {
        CityShaders.configureGround(ground)
        groundMaterial = ground
        glowMaterial = glow
    }

    func color(h: Float, ny: Float, x: Float, z: Float) -> SIMD3<Float> {
        let n = Noise.perlin(x * 0.05, z * 0.05) * 0.5 + 0.5
        if h < 1 { return simd_mix(SIMD3(0.24, 0.26, 0.23), SIMD3(0.30, 0.30, 0.27), SIMD3(repeating: n)) }
        if ny < 0.7 { return SIMD3(0.56, 0.53, 0.48) * (0.9 + 0.15 * n) }   // quay walls
        // Under the street paint too, so a block's colour runs right up to its edge instead of blurring.
        let (bi, bj) = CityLayout.blockIndex(x, z)
        let b = CityLayout.block(bi, bj)
        switch b.kind {
        case .park, .waterfront:
            let n2 = Noise.perlin(x * 0.013 + 4, z * 0.013) * 0.5 + 0.5
            return simd_mix(SIMD3(0.25, 0.38, 0.16), SIMD3(0.36, 0.46, 0.21), SIMD3(repeating: n * 0.6 + n2 * 0.4))
        case .plaza: return SIMD3(0.68, 0.655, 0.62) * (0.96 + 0.06 * n)
        case .parking: return SIMD3(0.30, 0.30, 0.31)
        case .construction: return simd_mix(SIMD3(0.50, 0.40, 0.29), SIMD3(0.58, 0.50, 0.38), SIMD3(repeating: n))
        default: return SIMD3(0.60, 0.595, 0.58) * (0.96 + 0.06 * n)
        }
    }

    func decorate(_ m: inout MeshBuilder, glow: inout MeshBuilder, key: ChunkKey, ox: Float, oz: Float) {}

    func isHole(_ x: Float, _ z: Float) -> Bool { CitySubway.isHole(x, z) }
    func tunnelFloor(_ x: Float, _ z: Float, _ y: Float) -> Float? { CitySubway.floorUnder(SIMD3(x, y, z)) }

    private func node(_ name: String, _ m: MeshBuilder, _ mat: SCNMaterial, shadow: Bool, lods: [(MeshBuilder?, Float)] = []) -> SCNNode? {
        guard !m.isEmpty else { return nil }
        let g = m.geometry()
        g.materials = [mat]
        if !lods.isEmpty {
            g.levelsOfDetail = lods.map { (low, d) in
                let lg = low.map { b -> SCNGeometry in let x = b.geometry(); x.materials = [mat]; return x }
                return SCNLevelOfDetail(geometry: lg, worldSpaceDistance: CGFloat(d))
            }
        }
        let n = SCNNode(geometry: g)
        n.name = name
        n.castsShadow = shadow
        n.categoryBitMask = 1 | 2
        return n
    }

    /// Kept for every loaded chunk: the buildings and everything big enough to see from afar.
    func extraNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var c = CityChunk(origin: SIMD3(ox, 0, oz), size: chunkSize, part: .base)
        c.build()
        var out: [SCNNode?] = []
        out.append(node("buildings", c.buildings, CityShaders.facade, shadow: true))
        // Simple trees, standing in for the detailed ones until the chunk's close-up detail arrives.
        out.append(node("swap:trees", c.midLow, props, shadow: true, lods: [(nil, 1250)]))
        out.append(node("farProps", c.farProps, props, shadow: true))
        out.append(node("glow", c.glow, CityShaders.signals, shadow: false, lods: [(nil, 1100)]))
        out.append(node("screens", c.screens, CityShaders.screens, shadow: false, lods: [(nil, 1000)]))
        if let gm = groundMaterial { out.append(node("decks", c.decks, gm, shadow: true)) }
        for (m, at) in c.craneTops where !m.isEmpty {
            let g = m.geometry()
            g.materials = [CityShaders.craneTop]
            let n = SCNNode(geometry: g)
            n.name = "craneTop"
            n.simdPosition = at
            n.castsShadow = true
            out.append(n)
        }
        return out.compactMap { $0 }
    }

    /// Street furniture, cars, detailed trees and the subway: only for chunks near the bird.
    var detailDistance: Float { 520 }

    func detailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        var c = CityChunk(origin: SIMD3(ox, 0, oz), size: chunkSize, part: .detail)
        c.build()
        return [node("props", c.props, props, shadow: true, lods: [(nil, 480)]),
                node("trees", c.mid, props, shadow: true, lods: [(c.midLow, 430), (nil, 1250)]),
                node("subway", c.subway, CityShaders.subway, shadow: false, lods: [(nil, 420)]),
                node("signs", c.signs, CityShaders.subwaySigns, shadow: false, lods: [(nil, 300)])].compactMap { $0 }
    }
}

/// Builds one chunk's city meshes (chunk-local coordinates).
struct CityChunk {
    let origin: SIMD3<Float>
    let size: Float
    var buildings = MeshBuilder()
    /// Street furniture, cars, trees: hidden far away.
    var props = MeshBuilder()
    /// Trees: visible from a good way off (and a cheaper copy for beyond a few hundred metres).
    var mid = MeshBuilder()
    var midLow = MeshBuilder()
    /// Big things that stay visible from afar: bridges, the railway, spires, cranes, water towers.
    var farProps = MeshBuilder()
    var glow = MeshBuilder()
    var screens = MeshBuilder()
    var decks = MeshBuilder()
    /// The subway: tunnels, stations and stairwells (self-lit), and the station name signs.
    var subway = MeshBuilder()
    var signs = MeshBuilder()
    var craneTops: [(MeshBuilder, SIMD3<Float>)] = []

    private let G = CityLayout.pitch
    private let matte = SIMD2<Float>(0, 0), paintUV = SIMD2<Float>(1, 0), glassUV = SIMD2<Float>(2, 0), chromeUV = SIMD2<Float>(3, 0)

    /// Which parts to build: everything, the parts kept for every loaded chunk, or the close-up detail.
    enum Part { case all, base, detail }

    init(origin: SIMD3<Float>, size: Float, part: Part = .all) {
        self.origin = origin; self.size = size
        switch part {
        case .base:
            props.disabled = true; mid.disabled = true; subway.disabled = true; signs.disabled = true
        case .detail:
            buildings.disabled = true; farProps.disabled = true; glow.disabled = true; screens.disabled = true; decks.disabled = true
        case .all: break
        }
    }

    private func inChunk(_ x: Float, _ z: Float) -> Bool {
        x >= origin.x && x < origin.x + size && z >= origin.z && z < origin.z + size
    }
    func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }

    mutating func build() {
        let i0 = Int(floor((origin.x - 20) / G)), i1 = Int(floor((origin.x + size + 20) / G))
        let j0 = Int(floor((origin.z - 20) / G)), j1 = Int(floor((origin.z + size + 20) / G))
        // Blocks whose centre is in the chunk
        for bj in (j0 - 1)...j1 {
            for bi in (i0 - 1)...i1 {
                let b = CityLayout.block(bi, bj)
                let c = b.center
                guard inChunk(c.x, c.y) else { continue }
                addBlock(b)
            }
        }
        // Streets: furniture along each line, intersections, bridges, the elevated railway
        for i in i0...i1 {
            let x = Float(i) * G
            guard x >= origin.x && x < origin.x + size else { continue }
            addLineFurniture(alongX: false, index: i)
            if CityLayout.lineX(i).el { addElevated(i) }
        }
        for j in j0...j1 {
            let z = Float(j) * G
            guard z >= origin.z && z < origin.z + size else { continue }
            addLineFurniture(alongX: true, index: j)
        }
        for j in j0...j1 {
            for i in i0...i1 {
                let p = CityLayout.nodePosition(i, j)
                guard inChunk(p.x, p.y) else { continue }
                if CityLayout.nodeExists(i, j) { addIntersection(i, j) }
            }
        }
        addSubway()
        for j in (j0 - 1)...j1 {
            for i in (i0 - 1)...i1 {
                for alongX in [true, false] {
                    guard let e = CityLayout.edge(alongX: alongX, i, j), let br = e.bridge else { continue }
                    let mid = e.start + e.dir * ((br.s0 + br.s1) / 2)
                    guard inChunk(mid.x, mid.y) else { continue }
                    addBridge(e)
                }
            }
        }
    }

    // MARK: Buildings

    private static func roofColor(_ seed: Int, brick: Bool) -> SIMD3<Float> {
        brick ? SIMD3(0.30, 0.29, 0.29) : [SIMD3<Float>(0.46, 0.46, 0.47), SIMD3(0.55, 0.53, 0.50), SIMD3(0.40, 0.41, 0.43), SIMD3(0.60, 0.60, 0.58)][seed % 4]
    }

    private mutating func addBlock(_ b: CityBlock) {
        for bld in b.buildings { addBuilding(bld, block: b) }
        for s in b.skybridges {
            let p = CityPart(shape: .box, lo: s.lo, hi: s.hi, style: 0, color: s.color)
            addPart(p, seed: 3, base: s.lo.y - 1)
            // Frame lines along the walkway.
            for y in [s.lo.y, s.hi.y] {
                let along = s.hi.x - s.lo.x > s.hi.z - s.lo.z
                for side in [0, 1] {
                    let lo = along ? SIMD3(s.lo.x, y - 0.12, side == 0 ? s.lo.z - 0.05 : s.hi.z - 0.15)
                                   : SIMD3(side == 0 ? s.lo.x - 0.05 : s.hi.x - 0.15, y - 0.12, s.lo.z)
                    let hi = along ? SIMD3(s.hi.x, y + 0.12, side == 0 ? s.lo.z + 0.15 : s.hi.z + 0.05)
                                   : SIMD3(side == 0 ? s.lo.x + 0.15 : s.hi.x + 0.05, y + 0.12, s.hi.z)
                    farProps.boxAA(L(lo), L(hi), SIMD3(0.75, 0.76, 0.78), uv: chromeUV)
                }
            }
        }
        var rng = SplitMix64(seed: UInt64(ihash(b.bi, b.bj, 0xB10C)) | 1)
        switch b.kind {
        case .park, .waterfront: addPark(b, &rng)
        case .plaza: addPlaza(b, &rng)
        case .parking: addParking(b, &rng)
        case .construction: addConstruction(b, &rng)
        default:
            // Trees and benches in the gaps around towers.
            if b.kind == .towers { addPlazaTrees(b, &rng) }
        }
    }

    private mutating func addBuilding(_ bld: CityBuilding, block: CityBlock) {
        if bld.kind == .frame { addFrame(bld); return }
        var rng = SplitMix64(seed: UInt64(ihash(Int(bld.lot.lo.x * 10), Int(bld.lot.lo.y * 10), 0xFACE)) | 1)
        for p in bld.parts {
            addPart(p, seed: bld.seed, base: bld.base, roof: p.roof, brick: bld.kind == .brick || bld.kind == .townhouses)
            // Cornices on brick and stone tops, parapets on the rest (not glass).
            if p.shape == .box && p.yaw == 0 {
                let topOfPart = !bld.parts.contains { ($0.lo != p.lo || $0.hi != p.hi) && $0.lo.y >= p.hi.y - 0.5 && overlaps($0, p) && covers($0, p) }
                if topOfPart {
                    if p.style == 3 || p.style == 4 {
                        let lo = p.lo - SIMD3(0.45, 0, 0.45), hi = p.hi + SIMD3(0.45, 0, 0.45)
                        buildings.boxAA(L(SIMD3(lo.x, p.hi.y - 0.8, lo.z)), L(SIMD3(hi.x, p.hi.y + 0.25, hi.z)), p.color * 1.15,
                                        bottom: true, uv: SIMD2(CityShaders.facadeU(7, bld.seed, 1), 1))
                    } else if p.style != 0 && p.style != 7 {
                        addParapet(p, seed: bld.seed)
                    } else if p.style == 0 {
                        // A slim metal cap on glass towers.
                        let lo = p.lo - SIMD3(0.12, 0, 0.12), hi = p.hi + SIMD3(0.12, 0, 0.12)
                        farProps.boxAA(L(SIMD3(lo.x, p.hi.y - 0.2, lo.z)), L(SIMD3(hi.x, p.hi.y + 0.5, hi.z)), SIMD3(0.7, 0.72, 0.75),
                                       uv: chromeUV)
                    }
                }
            }
        }
        if let crown = bld.crown, let tp = bld.parts.last { addCrown(crown, on: tp, seed: bld.seed, base: bld.base) }
        if bld.storefront { addAwnings(bld, block: block, &rng) }
        if bld.kind == .brick && rng.float() < 0.6 { addFireEscape(bld, block: block, &rng) }
        for item in bld.roof { addRoofItem(item, &rng) }
        if let s = bld.spire {
            farProps.tube(L(s.base), L(s.base + SIMD3(0, s.height, 0)), r0: max(0.9, s.height * 0.035), r1: 0.12, sides: 8,
                          SIMD3(0.78, 0.8, 0.84), uv: chromeUV)
            beacon(s.base + SIMD3(0, s.height + 0.3, 0), r: 0.5)
        }
        if bld.kind == .landmark || (bld.kind == .glass && bld.top - bld.base > 150) {
            // A lit crown band near the top of very tall towers.
            if let tp = bld.parts.max(by: { $0.hi.y < $1.hi.y }), tp.shape == .box {
                let y = tp.hi.y - 2.2
                let e: Float = 0.08
                glow.boxAA(L(SIMD3(tp.lo.x - e, y, tp.lo.z - e)), L(SIMD3(tp.hi.x + e, y + 0.5, tp.hi.z + e)), SIMD3(1, 0.86, 0.6), top: false)
            }
        }
    }

    /// A sloped glass top: a wedge rising toward one side, or a pyramid.
    private mutating func addCrown(_ crown: CityBuilding.Crown, on p: CityPart, seed: Int, base: Float) {
        let y = p.hi.y
        let x0 = p.lo.x, x1 = p.hi.x, z0 = p.lo.z, z1 = p.hi.z
        func U(_ m: Float) -> Float { CityShaders.facadeU(p.style, seed, m) }
        let v0 = y - base
        switch crown {
        case .wedge(let alongX, let h):
            // High side at +x (alongX) or +z.
            let A = SIMD3(x0, y, z0), B = SIMD3(x1, y, z0), C = SIMD3(x1, y, z1), D = SIMD3(x0, y, z1)
            let up = SIMD3<Float>(0, h, 0)
            if alongX {
                let slope = simd_length(SIMD2(x1 - x0, h))
                buildings.quadUV(L(A), L(D), L(C + up), L(B + up), p.color, SIMD2(U(0), v0), SIMD2(U(z1 - z0), v0),
                                 SIMD2(U(z1 - z0), v0 + slope), SIMD2(U(0), v0 + slope), facing: simd_normalize(SIMD3(-h, x1 - x0, 0)))
                buildings.quadUV(L(B), L(C), L(C + up), L(B + up), p.color, SIMD2(U(0), v0), SIMD2(U(z1 - z0), v0),
                                 SIMD2(U(z1 - z0), v0 + h), SIMD2(U(0), v0 + h), facing: SIMD3(1, 0, 0))
                for (a, b, n) in [(A, B, SIMD3<Float>(0, 0, -1)), (D, C, SIMD3<Float>(0, 0, 1))] {
                    let i = buildings.vertexCount
                    buildings.vertex(L(a), n, p.color, uv: SIMD2(U(0), v0)); buildings.vertex(L(b), n, p.color, uv: SIMD2(U(x1 - x0), v0))
                    buildings.vertex(L(b + up), n, p.color, uv: SIMD2(U(x1 - x0), v0 + h))
                    if n.z < 0 { buildings.tri(i, i + 2, i + 1) } else { buildings.tri(i, i + 1, i + 2) }
                }
            } else {
                let slope = simd_length(SIMD2(z1 - z0, h))
                buildings.quadUV(L(A), L(B), L(C + up), L(D + up), p.color, SIMD2(U(0), v0), SIMD2(U(x1 - x0), v0),
                                 SIMD2(U(x1 - x0), v0 + slope), SIMD2(U(0), v0 + slope), facing: simd_normalize(SIMD3(0, z1 - z0, -h)))
                buildings.quadUV(L(D), L(C), L(C + up), L(D + up), p.color, SIMD2(U(0), v0), SIMD2(U(x1 - x0), v0),
                                 SIMD2(U(x1 - x0), v0 + h), SIMD2(U(0), v0 + h), facing: SIMD3(0, 0, 1))
                for (a, b, n) in [(A, D, SIMD3<Float>(-1, 0, 0)), (B, C, SIMD3<Float>(1, 0, 0))] {
                    let i = buildings.vertexCount
                    buildings.vertex(L(a), n, p.color, uv: SIMD2(U(0), v0)); buildings.vertex(L(b), n, p.color, uv: SIMD2(U(z1 - z0), v0))
                    buildings.vertex(L(b + up), n, p.color, uv: SIMD2(U(z1 - z0), v0 + h))
                    if n.x > 0 { buildings.tri(i, i + 2, i + 1) } else { buildings.tri(i, i + 1, i + 2) }
                }
            }
        case .pyramid(let h):
            let apex = SIMD3((x0 + x1) / 2, y + h, (z0 + z1) / 2)
            let ring = [SIMD3(x1, y, z0), SIMD3(x0, y, z0), SIMD3(x0, y, z1), SIMD3(x1, y, z1)]
            for k in 0..<4 {
                let a = ring[k], b = ring[(k + 1) % 4]
                let mid = (a + b) / 2
                let len = simd_distance(a, b)
                let slope = simd_distance(mid, apex)
                var n = simd_normalize(simd_cross(b - a, apex - a))
                let outward = SIMD3(mid.x - apex.x, 0, mid.z - apex.z)
                if simd_dot(n, outward) < 0 { n = -n }
                let i = buildings.vertexCount
                buildings.vertex(L(a), n, p.color, uv: SIMD2(U(0), v0))
                buildings.vertex(L(b), n, p.color, uv: SIMD2(U(len), v0))
                buildings.vertex(L(apex), n, p.color, uv: SIMD2(U(len / 2), v0 + slope))
                if simd_dot(simd_cross(b - a, apex - a), n) > 0 { buildings.tri(i, i + 1, i + 2) } else { buildings.tri(i, i + 2, i + 1) }
            }
            beacon(apex + SIMD3(0, 0.4, 0), r: 0.4)
        }
    }

    private func overlaps(_ a: CityPart, _ b: CityPart) -> Bool {
        a.lo.x < b.hi.x && a.hi.x > b.lo.x && a.lo.z < b.hi.z && a.hi.z > b.lo.z
    }
    /// True when `a` covers most of `b`'s roof (so `b` has no exposed top edge for a parapet).
    private func covers(_ a: CityPart, _ b: CityPart) -> Bool {
        (a.hi.x - a.lo.x) * (a.hi.z - a.lo.z) > (b.hi.x - b.lo.x) * (b.hi.z - b.lo.z) * 0.92
    }

    /// Walls (and roof) of one building volume, with facade uvs.
    private mutating func addPart(_ p: CityPart, seed: Int, base: Float, roof: Bool = true, brick: Bool = false) {
        let v0 = p.lo.y - base, v1 = p.hi.y - base
        func U(_ m: Float) -> Float { CityShaders.facadeU(p.style, seed, m) }
        switch p.shape {
        case .box:
            let c = p.center, h = p.half
            let q = simd_quatf(angle: p.yaw, axis: kUp)
            let corners = [SIMD2<Float>(-h.x, -h.z), SIMD2(h.x, -h.z), SIMD2(h.x, h.z), SIMD2(-h.x, h.z)].map { v -> SIMD2<Float> in
                let r = q.act(SIMD3(v.x, 0, v.y))
                return SIMD2(c.x + r.x, c.z + r.z)
            }
            let u: Float = 0
            for k in 0..<4 {
                let a = corners[k], b = corners[(k + 1) % 4]
                let len = simd_length(b - a)
                let out = simd_normalize(SIMD3(b.y - a.y, 0, a.x - b.x))
                // u runs left to right as seen from outside.
                let pa = SIMD3(a.x, p.lo.y, a.y), pb = SIMD3(b.x, p.lo.y, b.y)
                buildings.quadUV(L(pb), L(pa), L(SIMD3(a.x, p.hi.y, a.y)), L(SIMD3(b.x, p.hi.y, b.y)), p.color,
                                 SIMD2(U(u), v0), SIMD2(U(u + len), v0), SIMD2(U(u + len), v1), SIMD2(U(u), v1), facing: out)
                // u restarts on every wall, so shop windows line up with the awnings.
            }
            if roof {
                let rc = CityChunk.roofColor(seed, brick: brick || p.style == 3)
                let ru = SIMD2(CityShaders.facadeU(7, seed, abs(c.x).truncatingRemainder(dividingBy: 900)), c.z)
                buildings.quad(L(SIMD3(corners[0].x, p.hi.y, corners[0].y)), L(SIMD3(corners[1].x, p.hi.y, corners[1].y)),
                               L(SIMD3(corners[2].x, p.hi.y, corners[2].y)), L(SIMD3(corners[3].x, p.hi.y, corners[3].y)), rc, uv: ru, facing: kUp)
            }
        case .octagon:
            let c = p.center, h = p.half
            let ch = min(h.x, h.z) * 0.36
            let fp: [SIMD2<Float>] = [SIMD2(-h.x + ch, -h.z), SIMD2(h.x - ch, -h.z), SIMD2(h.x, -h.z + ch), SIMD2(h.x, h.z - ch),
                                      SIMD2(h.x - ch, h.z), SIMD2(-h.x + ch, h.z), SIMD2(-h.x, h.z - ch), SIMD2(-h.x, -h.z + ch)]
                .map { SIMD2(c.x + $0.x, c.z + $0.y) }
            for k in 0..<8 {
                let a = fp[k], b = fp[(k + 1) % 8]
                let len = simd_length(b - a)
                let out = simd_normalize(SIMD3(b.y - a.y, 0, a.x - b.x))
                buildings.quadUV(L(SIMD3(b.x, p.lo.y, b.y)), L(SIMD3(a.x, p.lo.y, a.y)), L(SIMD3(a.x, p.hi.y, a.y)), L(SIMD3(b.x, p.hi.y, b.y)),
                                 p.color, SIMD2(U(0), v0), SIMD2(U(len), v0), SIMD2(U(len), v1), SIMD2(U(0), v1), facing: out)
            }
            if roof {
                let rc = CityChunk.roofColor(seed, brick: false)
                let ru = SIMD2(CityShaders.facadeU(7, seed, abs(c.x).truncatingRemainder(dividingBy: 900)), c.z)
                let ci = buildings.vertexCount
                buildings.vertex(L(SIMD3(c.x, p.hi.y, c.z)), kUp, rc, uv: ru)
                for q in fp { buildings.vertex(L(SIMD3(q.x, p.hi.y, q.y)), kUp, rc, uv: ru) }
                for k in 0..<UInt32(8) { buildings.tri(ci, ci + 1 + (k + 1) % 8, ci + 1 + k) }
            }
        case .cylinder:
            let c = p.center, r = p.radius
            let sides = 28
            let base = buildings.vertexCount
            let circ = 2 * Float.pi * r
            for k in 0...sides {
                let a = Float(k) / Float(sides) * 2 * .pi
                let d = SIMD3(cos(a), 0, sin(a))
                let u = circ * (1 - Float(k) / Float(sides))
                buildings.vertex(L(SIMD3(c.x, p.lo.y, c.z) + d * r), d, p.color, uv: SIMD2(U(u), v0))
                buildings.vertex(L(SIMD3(c.x, p.hi.y, c.z) + d * r), d, p.color, uv: SIMD2(U(u), v1))
            }
            for k in 0..<UInt32(sides) {
                let a = base + k * 2
                buildings.tri(a, a + 1, a + 2); buildings.tri(a + 1, a + 3, a + 2)
            }
            if roof {
                let rc = CityChunk.roofColor(seed, brick: false)
                let ru = SIMD2(CityShaders.facadeU(7, seed, 10), 0)
                buildings.cylinder(L(SIMD3(c.x, p.hi.y - 0.01, c.z)), r0: r, r1: r, y0: 0, y1: 0.02, sides: sides, rc, uv: ru)
                farProps.cylinder(L(SIMD3(c.x, p.hi.y, c.z)), r0: r + 0.15, r1: r + 0.15, y0: -0.2, y1: 0.6, sides: sides,
                                  SIMD3(0.72, 0.74, 0.77), top: false, uv: chromeUV)
            }
        }
    }

    private mutating func addParapet(_ p: CityPart, seed: Int) {
        let t: Float = 0.35, h: Float = 1.0
        let u = SIMD2(CityShaders.facadeU(7, seed, 3), 2)
        let col = p.color * 0.92
        let y0 = p.hi.y, y1 = p.hi.y + h
        buildings.boxAA(L(SIMD3(p.lo.x, y0, p.lo.z)), L(SIMD3(p.hi.x, y1, p.lo.z + t)), col, uv: u)
        buildings.boxAA(L(SIMD3(p.lo.x, y0, p.hi.z - t)), L(SIMD3(p.hi.x, y1, p.hi.z)), col, uv: u)
        buildings.boxAA(L(SIMD3(p.lo.x, y0, p.lo.z + t)), L(SIMD3(p.lo.x + t, y1, p.hi.z - t)), col, uv: u)
        buildings.boxAA(L(SIMD3(p.hi.x - t, y0, p.lo.z + t)), L(SIMD3(p.hi.x, y1, p.hi.z - t)), col, uv: u)
    }

    /// Which sides of a building's lot face a street (0 -z, 1 +x, 2 +z, 3 -x).
    private func streetSides(_ bld: CityBuilding, _ b: CityBlock) -> [Int] {
        var s: [Int] = []
        if abs(bld.lot.lo.y - b.lo.y) < 0.5 { s.append(0) }
        if abs(bld.lot.hi.x - b.hi.x) < 0.5 { s.append(1) }
        if abs(bld.lot.hi.y - b.hi.y) < 0.5 { s.append(2) }
        if abs(bld.lot.lo.x - b.lo.x) < 0.5 { s.append(3) }
        return s
    }

    private mutating func addAwnings(_ bld: CityBuilding, block: CityBlock, _ rng: inout SplitMix64) {
        guard let p = bld.parts.first, p.shape == .box, p.yaw == 0 else { return }
        let awn = [SIMD3<Float>(0.70, 0.12, 0.12), SIMD3(0.12, 0.40, 0.25), SIMD3(0.15, 0.25, 0.55), SIMD3(0.85, 0.55, 0.15),
                   SIMD3(0.25, 0.25, 0.27), SIMD3(0.75, 0.30, 0.45)]
        for side in streetSides(bld, block) {
            let col = awn[Int(rng.float(0, 5.99))]
            let (a, b, out) = wallEdge(p, side)
            let len = simd_length(b - a)
            let dir = (b - a) / len
            var u: Float = 0.3
            while u + 3.4 < len {
                if rng.float() < 0.55 {
                    let s0 = a + dir * u, s1 = a + dir * (u + 3.6)
                    let y = bld.base + 3.6
                    let o3 = SIMD3(out.x, 0, out.y)
                    let p0 = SIMD3(s0.x, y, s0.y), p1 = SIMD3(s1.x, y, s1.y)
                    let q0 = p0 + o3 * 1.5 - SIMD3(0, 0.75, 0), q1 = p1 + o3 * 1.5 - SIMD3(0, 0.75, 0)
                    props.quad(L(p0), L(p1), L(q1), L(q0), col, uv: matte, facing: o3 + kUp)
                    props.quad(L(q0), L(q1), L(q1 - SIMD3(0, 0.3, 0)), L(q0 - SIMD3(0, 0.3, 0)), col * 0.85, uv: matte, facing: o3)
                }
                u += 4.2
            }
        }
    }

    /// The bottom edge of a wall (2D endpoints, counter-clockwise from outside) and its outward direction.
    private func wallEdge(_ p: CityPart, _ side: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        switch side {
        case 0: return (SIMD2(p.hi.x, p.lo.z), SIMD2(p.lo.x, p.lo.z), SIMD2(0, -1))
        case 1: return (SIMD2(p.hi.x, p.hi.z), SIMD2(p.hi.x, p.lo.z), SIMD2(1, 0))
        case 2: return (SIMD2(p.lo.x, p.hi.z), SIMD2(p.hi.x, p.hi.z), SIMD2(0, 1))
        default: return (SIMD2(p.lo.x, p.lo.z), SIMD2(p.lo.x, p.hi.z), SIMD2(-1, 0))
        }
    }

    private mutating func addFireEscape(_ bld: CityBuilding, block: CityBlock, _ rng: inout SplitMix64) {
        guard let p = bld.parts.first, p.shape == .box, let side = streetSides(bld, block).first else { return }
        let (a, b, out) = wallEdge(p, side)
        let len = simd_length(b - a)
        guard len > 10 else { return }
        let dir = (b - a) / len
        let at = rng.float(2, len - 8)
        let iron = SIMD3<Float>(0.07, 0.07, 0.08)
        let o3 = SIMD3(out.x, 0, out.y), d3 = SIMD3(dir.x, 0, dir.y)
        let rot = simd_quatf(from: SIMD3(1, 0, 0), to: d3)
        var y = bld.base + 6.2
        var flip = false
        while y < p.hi.y - 2.5 {
            let wall = SIMD3(a.x, y, a.y) + d3 * (at + 2.4)
            let c = wall + o3 * 0.62
            // Landing grate, an outer rail with posts, and end rails.
            props.box(L(c), SIMD3(2.4, 0.03, 0.6), iron, rot: rot, uv: matte)
            props.box(L(c + o3 * 0.58 + SIMD3(0, 0.95, 0)), SIMD3(2.4, 0.02, 0.02), iron, rot: rot, uv: matte)
            for k in -2...2 {
                let post = c + o3 * 0.58 + d3 * (Float(k) * 1.18)
                props.tube(L(post), L(post + SIMD3(0, 0.95, 0)), r0: 0.02, r1: 0.02, sides: 3, iron, uv: matte)
            }
            for e: Float in [-1, 1] {
                props.box(L(c + d3 * (2.4 * e) + SIMD3(0, 0.95, 0)), SIMD3(0.02, 0.02, 0.6), iron, rot: rot, uv: matte)
            }
            // A steep stair flight down to the landing below: two stringers and treads.
            if y > bld.base + 7 {
                let top = c + d3 * (flip ? -1.9 : 1.9) + o3 * 0.1
                let bottom = c + d3 * (flip ? 0.7 : -0.7) + o3 * 0.1 - SIMD3(0, 3.1, 0)
                for w: Float in [-0.22, 0.22] {
                    props.tube(L(top + o3 * w), L(bottom + o3 * w), r0: 0.025, r1: 0.025, sides: 3, iron, uv: matte)
                }
                for k in 1..<7 {
                    let q = top + (bottom - top) * (Float(k) / 7)
                    props.box(L(q), SIMD3(0.06, 0.012, 0.22), iron, rot: rot, uv: matte)
                }
            }
            y += 3.1
            flip.toggle()
        }
    }

    private mutating func addRoofItem(_ item: RoofItem, _ rng: inout SplitMix64) {
        switch item {
        case .unit(let c, let h):
            props.box(L(c + SIMD3(0, h.y, 0)), h, SIMD3(0.70, 0.71, 0.72), uv: matte, topColor: SIMD3(0.62, 0.63, 0.64))
            props.cylinder(L(c + SIMD3(0, h.y * 2, 0)), r0: min(h.x, h.z) * 0.6, r1: min(h.x, h.z) * 0.6, y0: 0, y1: 0.12, sides: 8,
                           SIMD3(0.25, 0.26, 0.27), uv: matte)
        case .waterTower(let c, let r):
            let wood = SIMD3<Float>(0.45, 0.32, 0.22)
            for k in 0..<4 {
                let a = Float(k) * .pi / 2 + .pi / 4
                let foot = c + SIMD3(cos(a), 0, sin(a)) * r * 0.85
                farProps.tube(L(foot), L(foot + SIMD3(0, 4.2, 0) - SIMD3(cos(a), 0, sin(a)) * r * 0.15), r0: 0.12, r1: 0.12, sides: 4,
                              SIMD3(0.12, 0.12, 0.12), uv: matte)
            }
            farProps.cylinder(L(c + SIMD3(0, 4, 0)), r0: r, r1: r * 0.97, y0: 0, y1: 4.6, sides: 12, wood, top: false, uv: matte)
            farProps.cylinder(L(c + SIMD3(0, 8.6, 0)), r0: r * 1.05, r1: 0.15, y0: 0, y1: 2.0, sides: 12, SIMD3(0.28, 0.25, 0.23), uv: matte)
            for y: Float in [5.0, 6.6, 8.0] {
                farProps.cylinder(L(c + SIMD3(0, y, 0)), r0: r + 0.04, r1: r + 0.04, y0: 0, y1: 0.12, sides: 12, SIMD3(0.15, 0.15, 0.15),
                                  top: false, uv: matte)
            }
        case .antenna(let c, let h):
            farProps.tube(L(c), L(c + SIMD3(0, h, 0)), r0: 0.18, r1: 0.06, sides: 4, SIMD3(0.6, 0.6, 0.62), uv: chromeUV)
            props.tube(L(c + SIMD3(0, h * 0.4, 0)), L(c + SIMD3(0.8, h * 0.45, 0)), r0: 0.05, r1: 0.05, sides: 3, SIMD3(0.6, 0.6, 0.62), uv: matte)
            beacon(c + SIMD3(0, h + 0.15, 0), r: 0.28)
        case .helipad(let c, let r):
            props.cylinder(L(c), r0: r, r1: r, y0: 0, y1: 0.18, sides: 20, SIMD3(0.25, 0.27, 0.27), uv: matte)
            props.cylinder(L(c), r0: r * 0.82, r1: r * 0.82, y0: 0.18, y1: 0.2, sides: 20, SIMD3(0.95, 0.75, 0.12), top: true, uv: matte,
                           topColor: SIMD3(0.95, 0.75, 0.12))
            props.cylinder(L(c), r0: r * 0.74, r1: r * 0.74, y0: 0.2, y1: 0.22, sides: 20, SIMD3(0.25, 0.27, 0.27), uv: matte,
                           topColor: SIMD3(0.25, 0.27, 0.27))
            let w = SIMD3<Float>(0.95, 0.95, 0.95)
            props.boxAA(L(c + SIMD3(-2.2, 0.22, -2.6)), L(c + SIMD3(-1.4, 0.26, 2.6)), w, uv: matte)
            props.boxAA(L(c + SIMD3(1.4, 0.22, -2.6)), L(c + SIMD3(2.2, 0.26, 2.6)), w, uv: matte)
            props.boxAA(L(c + SIMD3(-1.4, 0.22, -0.4)), L(c + SIMD3(1.4, 0.26, 0.4)), w, uv: matte)
            for k in 0..<8 {
                let a = Float(k) / 8 * 2 * .pi
                glow.box(L(c + SIMD3(cos(a) * r, 0.3, sin(a) * r)), SIMD3(0.15, 0.1, 0.15), SIMD3(0.4, 1, 0.5))
            }
        case .garden(let c, let h):
            props.boxAA(L(c + SIMD3(-h.x, 0, -h.y)), L(c + SIMD3(h.x, 0.5, h.y)), SIMD3(0.30, 0.48, 0.20), uv: matte)
            for _ in 0..<Int(rng.float(3, 7)) {
                let p = c + SIMD3(rng.float(-h.x * 0.8, h.x * 0.8), 0.5, rng.float(-h.y * 0.8, h.y * 0.8))
                CityChunk.addTree(&mid, &midLow, at: L(p), height: rng.float(3, 5), &rng)
            }
        case .pool(let c, let h):
            props.boxAA(L(c + SIMD3(-h.x - 1, 0, -h.y - 1)), L(c + SIMD3(h.x + 1, 0.4, h.y + 1)), SIMD3(0.88, 0.86, 0.82), uv: matte)
            props.quad(L(c + SIMD3(-h.x, 0.42, h.y)), L(c + SIMD3(h.x, 0.42, h.y)), L(c + SIMD3(h.x, 0.42, -h.y)), L(c + SIMD3(-h.x, 0.42, -h.y)),
                       SIMD3(0.15, 0.62, 0.78), uv: glassUV, facing: kUp)
            for k in 0..<3 {
                let p = c + SIMD3(-h.x + 1 + Float(k) * 1.6, 0.4, h.y + 0.5)
                props.boxAA(L(p), L(p + SIMD3(0.8, 0.35, 1.9)), SIMD3(0.95, 0.95, 0.95), uv: matte)
            }
        case .billboard(let c, let w, let yaw, let ad):
            let q = simd_quatf(angle: yaw, axis: kUp)
            let hgt = w * 0.5
            for s: Float in [-1, 1] {
                let post = c + q.act(SIMD3(s * w * 0.35, 0, 0))
                props.tube(L(post), L(post + SIMD3(0, 3 + hgt, 0)), r0: 0.2, r1: 0.2, sides: 4, SIMD3(0.3, 0.3, 0.32), uv: matte)
            }
            let ctr = c + SIMD3(0, 3 + hgt / 2, 0)
            props.box(L(ctr), SIMD3(w / 2 + 0.25, hgt / 2 + 0.25, 0.2), SIMD3(0.18, 0.18, 0.2), rot: q, uv: matte)
            for s: Float in [-1, 1] {
                let n = q.act(SIMD3(0, 0, s))
                let r = q.act(SIMD3(1, 0, 0)) * (w / 2)
                let u = q.act(SIMD3(0, 1, 0)) * (hgt / 2)
                let f = ctr + n * 0.22
                let seedV = Float(ad) * 10
                screens.quadUV(L(f - r - u), L(f + r - u), L(f + r + u), L(f - r + u), SIMD3(1, 1, 1),
                               SIMD2(0, seedV), SIMD2(1, seedV), SIMD2(1, seedV + 1), SIMD2(0, seedV + 1), facing: n)
            }
        }
    }

    /// A red aircraft-warning light (blinks).
    private mutating func beacon(_ p: SIMD3<Float>, r: Float) {
        let ph = hfloat(Int(p.x), Int(p.z), 0xBEAC)
        glow.ellipsoid(L(p), SIMD3(repeating: r), SIMD3(1, 0.08, 0.05), rings: 3, sides: 6, uv: SIMD2(130, ph))
    }

    // MARK: Trees, parks, plazas

    private static func addTree(_ m: inout MeshBuilder, _ low: inout MeshBuilder, at p: SIMD3<Float>, height h: Float, _ rng: inout SplitMix64,
                                kind: Int? = nil) {
        let k = kind ?? (rng.float() < 0.82 ? 0 : (rng.float() < 0.5 ? 1 : 2))
        // The far copy: a crown and a stub of trunk, a handful of triangles.
        let lowCol: SIMD3<Float> = k == 2 ? SIMD3(0.8, 0.5, 0.3) : (k == 1 ? SIMD3(0.14, 0.3, 0.16) : SIMD3(0.24, 0.4, 0.16))
        low.cylinder(p, r0: h * 0.05, r1: h * 0.04, y0: -0.3, y1: h * 0.4, sides: 3, SIMD3(0.32, 0.24, 0.17), top: false)
        if k == 1 {
            low.cylinder(p, r0: h * 0.36, r1: 0, y0: h * 0.2, y1: h * 1.2, sides: 5, lowCol)
        } else {
            low.ellipsoid(p + SIMD3(0, h * 0.62, 0), SIMD3(h * 0.34, h * 0.32, h * 0.34), lowCol, rings: 2, sides: 5)
        }
        let trunk = SIMD3<Float>(0.32, 0.24, 0.17)
        let greens: [SIMD3<Float>] = [SIMD3(0.20, 0.38, 0.14), SIMD3(0.27, 0.45, 0.17), SIMD3(0.17, 0.33, 0.15), SIMD3(0.33, 0.48, 0.18)]
        switch k {
        case 1:  // conifer
            TerrainManager.addPine(&m, base: p - SIMD3(0, 0.3, 0), height: h * 1.2, radius: h * 0.32, foliage: SIMD3(0.14, 0.3, 0.16),
                                   yaw: rng.float(0, 6))
        case 2:  // flowering or autumn
            m.tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h * 0.45, 0), r0: h * 0.05, r1: h * 0.035, sides: 5, trunk)
            let col = [SIMD3<Float>(0.86, 0.52, 0.66), SIMD3(0.82, 0.40, 0.14), SIMD3(0.86, 0.66, 0.16)][Int(rng.float(0, 2.99))]
            m.ellipsoid(p + SIMD3(0, h * 0.62, 0), SIMD3(h * 0.36, h * 0.3, h * 0.36), col, rings: 4, sides: 7) { u in col * (0.8 + 0.25 * u.y) }
        default:
            m.tube(p - SIMD3(0, 0.3, 0), p + SIMD3(0, h * 0.5, 0), r0: h * 0.05, r1: h * 0.035, sides: 5, trunk)
            let g = greens[Int(rng.float(0, 3.99))]
            m.ellipsoid(p + SIMD3(0, h * 0.62, 0), SIMD3(h * 0.34, h * 0.32, h * 0.34), g, rings: 4, sides: 7) { u in g * (0.78 + 0.3 * u.y) }
            if h > 7 {
                m.ellipsoid(p + SIMD3(h * 0.12, h * 0.82, -h * 0.08), SIMD3(h * 0.22, h * 0.2, h * 0.22), g * 1.08, rings: 3, sides: 6)
            }
        }
    }

    private mutating func bench(_ p: SIMD3<Float>, yaw: Float) {
        let q = simd_quatf(angle: yaw, axis: kUp)
        let wood = SIMD3<Float>(0.45, 0.30, 0.18), iron = SIMD3<Float>(0.12, 0.12, 0.13)
        props.box(L(p + q.act(SIMD3(0, 0.45, 0))), SIMD3(0.9, 0.04, 0.22), wood, rot: q, uv: matte)
        props.box(L(p + q.act(SIMD3(0, 0.75, 0.2))), SIMD3(0.9, 0.18, 0.03), wood, rot: q, uv: matte)
        for s: Float in [-0.8, 0.8] { props.box(L(p + q.act(SIMD3(s, 0.22, 0))), SIMD3(0.04, 0.22, 0.2), iron, rot: q, uv: matte) }
    }

    private mutating func parkLamp(_ p: SIMD3<Float>) {
        props.tube(L(p), L(p + SIMD3(0, 4.2, 0)), r0: 0.09, r1: 0.06, sides: 6, SIMD3(0.1, 0.12, 0.11), uv: matte)
        glow.ellipsoid(L(p + SIMD3(0, 4.45, 0)), SIMD3(repeating: 0.32), SIMD3(1, 0.86, 0.6), rings: 3, sides: 6)
    }

    private mutating func addPark(_ b: CityBlock, _ rng: inout SplitMix64) {
        let lo = b.lo, hi = b.hi, c = b.center
        let water = b.kind == .waterfront
        func g(_ x: Float, _ z: Float) -> Float { CityLayout.ground(x, z) }
        func land(_ x: Float, _ z: Float) -> Bool { CityLayout.riverDistance(x, z) > CityLayout.riverHalf + 6 && g(x, z) > 4 }
        // Paths: a cross through the middle (and a loop around the pond).
        let gravel = SIMD3<Float>(0.70, 0.64, 0.52)
        func path(_ a: SIMD2<Float>, _ z: SIMD2<Float>, w: Float) {
            let len = simd_length(z - a)
            let d = (z - a) / len
            let side = SIMD2(-d.y, d.x) * (w / 2)
            var s: Float = 0
            while s < len {
                let s1 = min(s + 4, len)
                let p0 = a + d * s, p1 = a + d * s1
                guard land(p0.x, p0.y), land(p1.x, p1.y) else { s = s1; continue }
                let q = [p0 - side, p0 + side, p1 + side, p1 - side]
                let v = q.map { SIMD3($0.x, g($0.x, $0.y) + 0.07, $0.y) }
                props.quad(L(v[0]), L(v[1]), L(v[2]), L(v[3]), gravel, uv: matte, facing: kUp)
                s = s1
            }
        }
        if !water {
            path(SIMD2(lo.x, c.y), SIMD2(hi.x, c.y), w: 3.2)
            path(SIMD2(c.x, lo.y), SIMD2(c.x, hi.y), w: 3.2)
        } else {
            // A promenade along the river side of the block.
            path(SIMD2(lo.x + 3, lo.y + 3), SIMD2(hi.x - 3, lo.y + 3), w: 4)
            path(SIMD2(lo.x + 3, hi.y - 3), SIMD2(hi.x - 3, hi.y - 3), w: 4)
            path(SIMD2(lo.x + 3, lo.y + 3), SIMD2(lo.x + 3, hi.y - 3), w: 4)
            path(SIMD2(hi.x - 3, lo.y + 3), SIMD2(hi.x - 3, hi.y - 3), w: 4)
        }
        if let pond = b.pond {
            let y = g(pond.c.x, pond.c.y)
            props.cylinder(L(SIMD3(pond.c.x, y - 0.2, pond.c.y)), r0: pond.r + 1.2, r1: pond.r + 1.2, y0: 0, y1: 0.45, sides: 20,
                           SIMD3(0.62, 0.6, 0.56), uv: matte)
            props.cylinder(L(SIMD3(pond.c.x, y + 0.26, pond.c.y)), r0: pond.r, r1: pond.r, y0: 0, y1: 0.01, sides: 20,
                           SIMD3(0.10, 0.28, 0.30), uv: glassUV)
            // Lily pads
            for _ in 0..<6 {
                let a = rng.float(0, 6.28), d = rng.float(0.3, 0.85) * pond.r
                let p = SIMD3(pond.c.x + cos(a) * d, y + 0.29, pond.c.y + sin(a) * d)
                props.cylinder(L(p), r0: 0.5, r1: 0.5, y0: 0, y1: 0.01, sides: 6, SIMD3(0.25, 0.5, 0.2), uv: matte)
            }
        }
        if let f = b.fountain { addFountain(f, r: 4.5) }
        // Trees, scattered (clear of paths, pond and fountain).
        let n = Int((hi.x - lo.x) * (hi.y - lo.y) / 140)
        for _ in 0..<n {
            let x = rng.float(lo.x + 2, hi.x - 2), z = rng.float(lo.y + 2, hi.y - 2)
            guard land(x, z) else { continue }
            if !water && (abs(x - c.x) < 3.5 || abs(z - c.y) < 3.5) { continue }
            if let pond = b.pond, simd_distance(SIMD2(x, z), pond.c) < pond.r + 3 { continue }
            if let f = b.fountain, simd_length(SIMD2(x - f.x, z - f.z)) < 9 { continue }
            if water && (x < lo.x + 6 || x > hi.x - 6 || z < lo.y + 6 || z > hi.y - 6) && rng.float() < 0.7 { continue }
            CityChunk.addTree(&mid, &midLow, at: L(SIMD3(x, g(x, z), z)), height: rng.float(7, 13), &rng)
        }
        // Benches and lamps along the paths.
        if !water {
            for k in 0..<6 {
                let t = Float(k + 1) / 7
                let p = SIMD2(lo.x + (hi.x - lo.x) * t, c.y + 2.6)
                if land(p.x, p.y) { bench(SIMD3(p.x, g(p.x, p.y), p.y), yaw: .pi) }
                if k % 2 == 0, land(p.x, p.y - 5.2) { parkLamp(SIMD3(p.x, g(p.x, p.y - 5.2), p.y - 5.2)) }
            }
        } else {
            var s: Float = 6
            while s < hi.x - lo.x - 6 {
                for z in [lo.y + 0.6, hi.y - 0.6] where land(lo.x + s, z) {
                    if fmodi(Int(s), 24) < 12 { parkLamp(SIMD3(lo.x + s, g(lo.x + s, z), z)) } else { bench(SIMD3(lo.x + s, g(lo.x + s, z), z), yaw: z < c.y ? 0 : .pi) }
                }
                s += 12
            }
        }
    }

    private mutating func addFountain(_ f: SIMD3<Float>, r: Float) {
        let stone = SIMD3<Float>(0.78, 0.75, 0.70)
        props.cylinder(L(f), r0: r, r1: r, y0: -0.2, y1: 0.7, sides: 20, stone, uv: matte)
        props.cylinder(L(f + SIMD3(0, 0.71, 0)), r0: r - 0.35, r1: r - 0.35, y0: 0, y1: 0.01, sides: 20, SIMD3(0.25, 0.55, 0.62), uv: glassUV)
        props.cylinder(L(f), r0: 0.7, r1: 0.5, y0: 0.5, y1: 2.6, sides: 10, stone, uv: matte)
        props.cylinder(L(f + SIMD3(0, 2.6, 0)), r0: 1.8, r1: 1.9, y0: 0, y1: 0.35, sides: 14, stone, uv: matte)
        props.cylinder(L(f + SIMD3(0, 2.96, 0)), r0: 1.6, r1: 1.6, y0: 0, y1: 0.01, sides: 14, SIMD3(0.3, 0.6, 0.68), uv: glassUV)
        // A white "spray" cone (the runtime adds real droplets when you're close).
        props.cylinder(L(f + SIMD3(0, 2.9, 0)), r0: 0.5, r1: 0.05, y0: 0, y1: 2.2, sides: 8, SIMD3(0.85, 0.92, 0.95), uv: glassUV)
    }

    private mutating func addPlaza(_ b: CityBlock, _ rng: inout SplitMix64) {
        if let f = b.fountain {
            addFountain(f, r: 7)
            for k in 0..<8 {
                let a = Float(k) / 8 * 2 * .pi
                let p = SIMD3(f.x + cos(a) * 11, f.y, f.z + sin(a) * 11)
                if k % 2 == 0 { bench(p, yaw: -a + .pi / 2) } else {
                    props.cylinder(L(p), r0: 1.1, r1: 1.2, y0: 0, y1: 0.8, sides: 10, SIMD3(0.5, 0.48, 0.45), uv: matte)
                    CityChunk.addTree(&mid, &midLow, at: L(p + SIMD3(0, 0.8, 0)), height: 5.5, &rng, kind: 0)
                }
            }
            // A big screen on the tower, facing the fountain.
            if let t = b.buildings.first, let p = t.parts.first, p.shape == .box {
                let toF = SIMD2(f.x - p.center.x, f.z - p.center.z)
                let side: Int = abs(toF.x) > abs(toF.y) ? (toF.x > 0 ? 1 : 3) : (toF.y > 0 ? 2 : 0)
                let (a, e, out) = wallEdge(p, side)
                let mid = (a + e) / 2, dir = simd_normalize(e - a)
                let w = min(simd_length(e - a) * 0.6, 22), h = w * 0.5
                let o3 = SIMD3(out.x, 0, out.y), d3 = SIMD3(dir.x, 0, dir.y)
                let ctr = SIMD3(mid.x, t.base + 14 + h / 2, mid.y) + o3 * 0.35
                farProps.box(L(ctr - o3 * 0.15), SIMD3(w / 2 + 0.4, h / 2 + 0.4, 0.2), SIMD3(0.1, 0.1, 0.11),
                             rot: simd_quatf(from: SIMD3(1, 0, 0), to: d3), uv: matte)
                let seedV = Float(Int(rng.float(0, 7.99))) * 10
                screens.quadUV(L(ctr - d3 * (w / 2) - kUp * (h / 2) + o3 * 0.1), L(ctr + d3 * (w / 2) - kUp * (h / 2) + o3 * 0.1),
                               L(ctr + d3 * (w / 2) + kUp * (h / 2) + o3 * 0.1), L(ctr - d3 * (w / 2) + kUp * (h / 2) + o3 * 0.1),
                               SIMD3(1, 1, 1), SIMD2(0, seedV), SIMD2(1, seedV), SIMD2(1, seedV + 1), SIMD2(0, seedV + 1), facing: o3)
            }
        }
    }

    private mutating func addPlazaTrees(_ b: CityBlock, _ rng: inout SplitMix64) {
        // Trees in planters along the open edges of the block (where towers are set back).
        for _ in 0..<14 {
            let x = rng.float(b.lo.x + 2, b.hi.x - 2), z = rng.float(b.lo.y + 2, b.hi.y - 2)
            let inside = b.buildings.contains { bld in bld.parts.contains { $0.lo.x - 2.5 < x && x < $0.hi.x + 2.5 && $0.lo.z - 2.5 < z && z < $0.hi.z + 2.5 } }
            guard !inside else { continue }
            let g = CityLayout.ground(x, z)
            props.cylinder(L(SIMD3(x, g, z)), r0: 1.0, r1: 1.0, y0: 0, y1: 0.6, sides: 8, SIMD3(0.55, 0.53, 0.5), uv: matte)
            CityChunk.addTree(&mid, &midLow, at: L(SIMD3(x, g + 0.6, z)), height: rng.float(5, 7.5), &rng, kind: 0)
        }
    }

    private mutating func addParking(_ b: CityBlock, _ rng: inout SplitMix64) {
        let lo = b.lo + 3, hi = b.hi - 3
        var z = lo.y + 3
        let white = SIMD3<Float>(0.85, 0.85, 0.82)
        while z < hi.y - 3 {
            var x = lo.x + 1.5
            while x < hi.x - 1.5 {
                let g = CityLayout.ground(x, z)
                props.quad(L(SIMD3(x - 0.06, g + 0.06, z - 2.6)), L(SIMD3(x + 0.06, g + 0.06, z - 2.6)),
                           L(SIMD3(x + 0.06, g + 0.06, z + 2.6)), L(SIMD3(x - 0.06, g + 0.06, z + 2.6)), white, uv: matte, facing: kUp)
                if rng.float() < 0.7 {
                    parkedCar(SIMD3(x + 1.3, g, z), yaw: rng.float() < 0.5 ? 0 : .pi, &rng)
                }
                x += 2.6
            }
            z += 13
        }
        // A light pole or two
        for k in 0..<2 {
            let p = SIMD2(lo.x + (hi.x - lo.x) * (0.3 + 0.4 * Float(k)), (lo.y + hi.y) / 2)
            let g = CityLayout.ground(p.x, p.y)
            props.tube(L(SIMD3(p.x, g, p.y)), L(SIMD3(p.x, g + 9, p.y)), r0: 0.15, r1: 0.1, sides: 6, SIMD3(0.5, 0.5, 0.52), uv: matte)
            glow.box(L(SIMD3(p.x, g + 9, p.y)), SIMD3(0.6, 0.12, 0.3), SIMD3(1, 0.9, 0.7))
        }
    }

    private mutating func parkedCar(_ p: SIMD3<Float>, yaw: Float, _ rng: inout SplitMix64) {
        let kinds: [CarKind] = [.sedan, .sedan, .compact, .suv, .van, .taxi]
        let k = kinds[Int(rng.float(0, Float(kinds.count) - 0.01))]
        var m = CityVehicles.body(k)
        let paint = k == .taxi ? CityVehicles.taxiYellow : CityVehicles.paints[Int(rng.float(0, Float(CityVehicles.paints.count) - 0.01))]
        m.paintWhite(paint)
        props.append(m, trs(L(p), simd_quatf(angle: yaw, axis: kUp)))
    }

    private mutating func addConstruction(_ b: CityBlock, _ rng: inout SplitMix64) {
        if let c = b.crane { addCrane(c) }
        // Site fence (chain link panels) around the block edge.
        let lo = b.lo + 1, hi = b.hi - 1
        let fence = SIMD3<Float>(0.55, 0.57, 0.58)
        for (a, z) in [(SIMD2(lo.x, lo.y), SIMD2(hi.x, lo.y)), (SIMD2(hi.x, lo.y), SIMD2(hi.x, hi.y)),
                       (SIMD2(hi.x, hi.y), SIMD2(lo.x, hi.y)), (SIMD2(lo.x, hi.y), SIMD2(lo.x, lo.y))] {
            let len = simd_length(z - a), d = (z - a) / len
            var s: Float = 0
            while s < len {
                let p0 = a + d * s, p1 = a + d * min(s + 6, len)
                let g0 = CityLayout.ground(p0.x, p0.y), g1 = CityLayout.ground(p1.x, p1.y)
                props.quad(L(SIMD3(p0.x, g0, p0.y)), L(SIMD3(p1.x, g1, p1.y)), L(SIMD3(p1.x, g1 + 2.2, p1.y)), L(SIMD3(p0.x, g0 + 2.2, p0.y)),
                           fence * 0.8, uv: matte)
                props.quad(L(SIMD3(p1.x, g1, p1.y)), L(SIMD3(p0.x, g0, p0.y)), L(SIMD3(p0.x, g0 + 2.2, p0.y)), L(SIMD3(p1.x, g1 + 2.2, p1.y)),
                           fence * 0.8, uv: matte)
                props.tube(L(SIMD3(p0.x, g0, p0.y)), L(SIMD3(p0.x, g0 + 2.4, p0.y)), r0: 0.06, r1: 0.06, sides: 4, fence, uv: matte)
                s += 6
            }
        }
        // Materials piles: pipes, beams, a container.
        let x = rng.float(lo.x + 6, hi.x - 12), z = rng.float(lo.y + 6, hi.y - 12)
        let g = CityLayout.ground(x, z)
        props.box(L(SIMD3(x + 3, g + 1.3, z + 6)), SIMD3(1.2, 1.3, 3), SIMD3(0.75, 0.30, 0.15), uv: matte)
        for k in 0..<4 { props.box(L(SIMD3(x, g + 0.2 + Float(k) * 0.42, z)), SIMD3(3.5, 0.2, 0.2), SIMD3(0.6, 0.22, 0.12), uv: matte) }
    }

    /// Steel frame of an unfinished building around its concrete core.
    private mutating func addFrame(_ bld: CityBuilding) {
        if let core = bld.parts.first { addPart(core, seed: 0, base: bld.base) }
        let steel = SIMD3<Float>(0.64, 0.24, 0.14)
        let lo = bld.lot.lo, hi = bld.lot.hi
        let floors = Int((bld.top - bld.base) / 4)
        let nx = max(2, Int((hi.x - lo.x) / 8)), nz = max(2, Int((hi.y - lo.y) / 8))
        var rng = SplitMix64(seed: UInt64(ihash(Int(lo.x), Int(lo.y), 0xF4A)) | 1)
        for f in 0...floors {
            let y = bld.base + Float(f) * 4
            let full = f < floors - 1 || rng.float() < 0.5
            // Columns up to the next floor
            for a in 0...nx {
                for b in 0...nz where a == 0 || a == nx || b == 0 || b == nz {
                    let x = lo.x + (hi.x - lo.x) * Float(a) / Float(nx), z = lo.y + (hi.y - lo.y) * Float(b) / Float(nz)
                    if f < floors && (full || (a + b) % 2 == 0) {
                        farProps.boxAA(L(SIMD3(x - 0.2, y, z - 0.2)), L(SIMD3(x + 0.2, y + 4, z + 0.2)), steel, uv: matte)
                    }
                }
            }
            // Edge beams and a concrete floor slab
            if f > 0 {
                let t: Float = 0.18
                farProps.boxAA(L(SIMD3(lo.x, y - 0.35, lo.y - t)), L(SIMD3(hi.x, y, lo.y + t)), steel, uv: matte)
                farProps.boxAA(L(SIMD3(lo.x, y - 0.35, hi.y - t)), L(SIMD3(hi.x, y, hi.y + t)), steel, uv: matte)
                farProps.boxAA(L(SIMD3(lo.x - t, y - 0.35, lo.y)), L(SIMD3(lo.x + t, y, hi.y)), steel, uv: matte)
                farProps.boxAA(L(SIMD3(hi.x - t, y - 0.35, lo.y)), L(SIMD3(hi.x + t, y, hi.y)), steel, uv: matte)
                if f < floors - 2 {
                    farProps.boxAA(L(SIMD3(lo.x + 0.3, y - 0.3, lo.y + 0.3)), L(SIMD3(hi.x - 0.3, y - 0.05, hi.y - 0.3)),
                                   SIMD3(0.62, 0.61, 0.58), uv: matte)
                }
            }
        }
    }

    private mutating func addCrane(_ c: CityCrane) {
        let yellow = SIMD3<Float>(0.95, 0.72, 0.10)
        let top = c.mast + SIMD3(0, c.height, 0)
        // Lattice mast: four legs with cross braces.
        let h: Float = 1.1
        for (dx, dz) in [(-h, -h), (h, -h), (h, h), (-h, h)] as [(Float, Float)] {
            farProps.boxAA(L(c.mast + SIMD3(dx - 0.12, 0, dz - 0.12)), L(top + SIMD3(dx + 0.12, 0, dz + 0.12)), yellow, uv: matte)
        }
        var y: Float = 0
        while y < c.height - 2 {
            for k in 0..<4 {
                let a = [SIMD2<Float>(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]
                let p0 = a[k], p1 = a[(k + 1) % 4]
                farProps.tube(L(c.mast + SIMD3(p0.x, y, p0.y)), L(c.mast + SIMD3(p1.x, y + 2.2, p1.y)), r0: 0.07, r1: 0.07, sides: 3, yellow, uv: matte)
            }
            y += 2.2
        }
        farProps.boxAA(L(c.mast + SIMD3(-3, 0, -3)), L(c.mast + SIMD3(3, 1.2, 3)), SIMD3(0.55, 0.55, 0.52), uv: matte)
        // The turning top (cab, jib, counter-jib with weights, trolley and hook), around the mast top.
        var m = MeshBuilder()
        let ph = SIMD2<Float>(0, c.phase)
        m.box(SIMD3(0, 1.0, 0), SIMD3(1.4, 1.0, 1.4), yellow, uv: ph)
        m.box(SIMD3(1.6, 1.2, -1.2), SIMD3(0.9, 1.0, 1.0), SIMD3(0.9, 0.9, 0.88), uv: ph)
        m.box(SIMD3(0, 4.0, 0), SIMD3(0.5, 2.6, 0.5), yellow, uv: ph)   // the peak
        // Jib along -z (triangular truss: two bottom chords and a top chord)
        let jl = c.jib
        for x: Float in [-0.7, 0.7] { m.box(SIMD3(x, 2.2, -jl / 2), SIMD3(0.1, 0.1, jl / 2), yellow, uv: ph) }
        m.box(SIMD3(0, 3.4, -jl / 2), SIMD3(0.1, 0.1, jl / 2), yellow, uv: ph)
        var z: Float = -2
        while z > -jl {
            for x: Float in [-0.7, 0.7] { m.tube(SIMD3(x, 2.2, z), SIMD3(0, 3.4, z - 1.5), r0: 0.06, r1: 0.06, sides: 3, yellow, uv: ph) }
            z -= 3
        }
        // Tie cables from the peak to the jib and counter-jib.
        m.tube(SIMD3(0, 6.5, 0), SIMD3(0, 3.4, -jl * 0.65), r0: 0.05, r1: 0.05, sides: 3, SIMD3(0.2, 0.2, 0.2), uv: ph)
        m.tube(SIMD3(0, 6.5, 0), SIMD3(0, 3.0, 14), r0: 0.05, r1: 0.05, sides: 3, SIMD3(0.2, 0.2, 0.2), uv: ph)
        // Counter-jib with concrete blocks.
        m.box(SIMD3(0, 2.4, 8), SIMD3(0.8, 0.25, 7), yellow, uv: ph)
        m.box(SIMD3(0, 1.4, 13), SIMD3(1.3, 1.2, 1.6), SIMD3(0.6, 0.59, 0.56), uv: ph)
        // Trolley, hook cable and a hanging steel beam.
        let tz = -jl * 0.6
        m.box(SIMD3(0, 1.8, tz), SIMD3(0.8, 0.3, 0.8), SIMD3(0.3, 0.3, 0.3), uv: ph)
        let drop = min(c.height * 0.55, 40)
        m.tube(SIMD3(0, 1.6, tz), SIMD3(0, 1.6 - drop, tz), r0: 0.04, r1: 0.04, sides: 3, SIMD3(0.15, 0.15, 0.15), uv: ph)
        m.box(SIMD3(0, 1.0 - drop, tz), SIMD3(0.25, 0.35, 0.25), yellow, uv: ph)
        m.box(SIMD3(0, 0.3 - drop, tz), SIMD3(3.5, 0.2, 0.25), SIMD3(0.64, 0.24, 0.14), uv: ph)
        craneTops.append((m, L(top)))
        beaconTop(top + SIMD3(0, 6.7, 0))
    }

    private mutating func beaconTop(_ p: SIMD3<Float>) { beacon(p, r: 0.35) }

    // MARK: Streets

    /// Lamps, trees and parked cars along one street line, inside this chunk.
    private mutating func addLineFurniture(alongX: Bool, index: Int) {
        let line = alongX ? CityLayout.lineZ(index) : CityLayout.lineX(index)
        let c0 = alongX ? origin.x : origin.z
        let fixed = Float(index) * G
        var rng = SplitMix64(seed: UInt64(ihash(index, alongX ? 1 : 2, 0x57EE7)) | 1)
        func P(_ s: Float, _ off: Float, _ y: Float = 0) -> SIMD3<Float> {
            alongX ? SIMD3(s, y, fixed + off) : SIMD3(fixed + off, y, s)
        }
        func crossHalf(_ s: Float) -> (Float, Float) {
            // Distance to the nearest crossing line and its half width.
            let k = Int((s / G).rounded())
            let cl = alongX ? CityLayout.lineX(k) : CityLayout.lineZ(k)
            return (abs(s - Float(k) * G), cl.halfWidth)
        }
        func edgeAt(_ s: Float) -> CityEdge? {
            let k = Int(floor(s / G))
            return alongX ? CityLayout.edge(alongX: true, k, index) : CityLayout.edge(alongX: false, index, k)
        }
        func onBridge(_ s: Float) -> Bool {
            guard let e = edgeAt(s), let b = e.bridge else { return false }
            let local = s - Float(Int(floor(s / G))) * G
            return local > b.s0 - 3 && local < b.s1 + 3
        }
        func exists(_ s: Float) -> Bool { edgeAt(s) != nil }
        let dirs: [Float] = [1, -1]
        // Street lamps every 30 m on both sides.
        var s = (floor(c0 / 30)) * 30 + 7
        while s < c0 + size {
            if s >= c0 {
                let (d, hw) = crossHalf(s)
                if d > hw + 3 && exists(s) && !onBridge(s) {
                    for side in dirs where !CityChunk.nearSubwayOpening(P(s, side * (line.halfRoad + 0.6))) {
                        let off = side * (line.halfRoad + 0.6)
                        let g = CityLayout.ground(P(s, off).x, P(s, off).z)
                        streetLamp(P(s, off, g), toward: alongX ? SIMD3(0, 0, -side) : SIMD3(-side, 0, 0), avenue: line.avenue)
                    }
                }
            }
            s += 30
        }
        // Street trees (not on the busiest avenues), offset from the lamps.
        let D = CityLayout.district(alongX ? c0 + size / 2 : fixed, alongX ? fixed : c0 + size / 2)
        if !line.avenue || D < 0.55 {
            s = floor(c0 / 15) * 15 + 1
            while s < c0 + size {
                if s >= c0 {
                    let (d, hw) = crossHalf(s)
                    if d > hw + 6 && exists(s) && !onBridge(s) {
                        for side in dirs where rng.float() < 0.85 && !CityChunk.nearSubwayOpening(P(s, side * (line.halfWidth - 1.6))) {
                            let off = side * (line.halfWidth - 1.6)
                            let p = P(s, off)
                            let g = CityLayout.ground(p.x, p.z)
                            props.quad(L(SIMD3(p.x - 0.8, g + 0.03, p.z - 0.8)), L(SIMD3(p.x + 0.8, g + 0.03, p.z - 0.8)),
                                       L(SIMD3(p.x + 0.8, g + 0.03, p.z + 0.8)), L(SIMD3(p.x - 0.8, g + 0.03, p.z + 0.8)),
                                       SIMD3(0.24, 0.18, 0.12), uv: matte, facing: kUp)
                            CityChunk.addTree(&mid, &midLow, at: L(SIMD3(p.x, g, p.z)), height: rng.float(6.5, 9.5), &rng, kind: rng.float() < 0.12 ? 2 : 0)
                        }
                    }
                }
                s += 15
            }
        }
        // Parked cars along the streets' parking lanes.
        if let park = line.parking {
            s = floor(c0 / 6.4) * 6.4
            while s < c0 + size {
                if s >= c0 {
                    let (d, hw) = crossHalf(s)
                    if d > hw + 9 && exists(s) && !onBridge(s) {
                        for side in dirs where rng.float() < 0.62 {
                            // Right-hand traffic: the parking lane on the right of each direction.
                            let travel: Float = alongX ? side : -side
                            let off = side * park
                            let p = P(s, off)
                            let g = CityLayout.ground(p.x, p.z)
                            let dir = alongX ? SIMD2(travel, 0) : SIMD2(0, travel)
                            parkedCar(SIMD3(p.x, g, p.z), yaw: atan2(-dir.x, -dir.y), &rng)
                        }
                    }
                }
                s += 6.4
            }
        }
        // Bus shelters on avenues, once per block (sometimes).
        if line.avenue {
            var k = Int(floor(c0 / G))
            while Float(k) * G < c0 + size {
                let mid = (Float(k) + 0.5) * G
                let side: Float = hfloat(k, index, 0x51DE) < 0.5 ? 1 : -1
                if mid >= c0 && mid < c0 + size && hfloat(k, index, alongX ? 0x8055 : 0x8056) < 0.45 && exists(mid) && !onBridge(mid)
                    && !CityChunk.nearSubwayOpening(P(mid + 12, side * (line.halfRoad + 2.6)), margin: 4) {
                    let p = P(mid + 12, side * (line.halfRoad + 2.6))
                    let g = CityLayout.ground(p.x, p.z)
                    busShelter(SIMD3(p.x, g, p.z), facing: alongX ? SIMD3(0, 0, -side) : SIMD3(-side, 0, 0))
                }
                k += 1
            }
        }
    }

    /// Close to a subway stair opening (keep lamps, trees and shelters out of the hole).
    static func nearSubwayOpening(_ p: SIMD3<Float>, margin: Float = 2.2) -> Bool {
        guard CitySubway.nearLine(p.x, p.z) else { return false }
        for dx in [-margin, 0, margin] { for dz in [-margin, 0, margin] where CitySubway.isHole(p.x + dx, p.z + dz) { return true } }
        return false
    }

    private mutating func streetLamp(_ p: SIMD3<Float>, toward: SIMD3<Float>, avenue: Bool) {
        let pole = SIMD3<Float>(0.22, 0.24, 0.25)
        if avenue {
            props.tube(L(p), L(p + SIMD3(0, 8.5, 0)), r0: 0.14, r1: 0.09, sides: 6, pole, uv: matte)
            props.tube(L(p + SIMD3(0, 8.3, 0)), L(p + SIMD3(0, 8.7, 0) + toward * 2.6), r0: 0.07, r1: 0.06, sides: 4, pole, uv: matte)
            let head = p + SIMD3(0, 8.6, 0) + toward * 2.8
            props.box(L(head + SIMD3(0, 0.12, 0)), SIMD3(0.35, 0.1, 0.22), pole, rot: simd_quatf(from: SIMD3(1, 0, 0), to: toward), uv: matte)
            glow.box(L(head), SIMD3(0.28, 0.04, 0.16), SIMD3(1, 0.88, 0.66), rot: simd_quatf(from: SIMD3(1, 0, 0), to: toward), top: false, bottom: true)
        } else {
            props.tube(L(p), L(p + SIMD3(0, 4.6, 0)), r0: 0.12, r1: 0.07, sides: 6, SIMD3(0.1, 0.12, 0.11), uv: matte)
            props.cylinder(L(p), r0: 0.22, r1: 0.16, y0: 0, y1: 0.7, sides: 6, SIMD3(0.1, 0.12, 0.11), uv: matte)
            glow.ellipsoid(L(p + SIMD3(0, 4.9, 0)), SIMD3(0.3, 0.38, 0.3), SIMD3(1, 0.88, 0.62), rings: 3, sides: 6)
        }
    }

    private mutating func busShelter(_ p: SIMD3<Float>, facing: SIMD3<Float>) {
        let q = simd_quatf(from: SIMD3(0, 0, 1), to: facing)
        func W(_ v: SIMD3<Float>) -> SIMD3<Float> { L(p + q.act(v)) }
        let frame = SIMD3<Float>(0.3, 0.32, 0.35)
        props.box(W(SIMD3(0, 2.5, 0)), SIMD3(2.2, 0.08, 0.9), frame, rot: q, uv: matte)
        for x: Float in [-2.1, 2.1] { props.box(W(SIMD3(x, 1.25, -0.8)), SIMD3(0.05, 1.25, 0.05), frame, rot: q, uv: matte) }
        props.box(W(SIMD3(0, 1.3, -0.82)), SIMD3(2.1, 1.1, 0.02), SIMD3(0.5, 0.6, 0.65), rot: q, uv: glassUV)
        props.box(W(SIMD3(0, 0.45, -0.5)), SIMD3(1.4, 0.04, 0.22), SIMD3(0.4, 0.4, 0.42), rot: q, uv: matte)
        // Lit advert panel at one end.
        glow.box(W(SIMD3(2.15, 1.3, 0)), SIMD3(0.04, 0.9, 0.6), SIMD3(0.95, 0.85, 0.7), rot: q)
    }

    /// Traffic lights on the near-right corner of every approach, hydrants, bins and subway entrances.
    private mutating func addIntersection(_ i: Int, _ j: Int) {
        let p2 = CityLayout.nodePosition(i, j)
        let g = CityLayout.ground(p2.x, p2.y)
        let node = SIMD3(p2.x, g, p2.y)
        let lx = CityLayout.lineX(i), lz = CityLayout.lineZ(j)
        let phase = Float(fmodi(i * 7 + j * 11, 26))
        let approaches: [(SIMD2<Float>, Bool)] = [
            (SIMD2(1, 0), CityLayout.edge(alongX: true, i - 1, j) != nil), (SIMD2(-1, 0), CityLayout.edge(alongX: true, i, j) != nil),
            (SIMD2(0, 1), CityLayout.edge(alongX: false, i, j - 1) != nil), (SIMD2(0, -1), CityLayout.edge(alongX: false, i, j) != nil),
        ]
        let pole = SIMD3<Float>(0.16, 0.17, 0.18)
        for (d, has) in approaches where has {
            let axis = d.x != 0 ? 0 : 1
            let along = axis == 0 ? lz : lx      // the line this traffic drives on
            let cross = axis == 0 ? lx : lz
            let d3 = SIMD3(d.x, 0, d.y)
            let right = SIMD3(-d.y, 0, d.x)
            let corner = node - d3 * (cross.halfRoad + 1.3) + right * (along.halfRoad + 1.2)
            props.tube(L(corner), L(corner + SIMD3(0, 6.4, 0)), r0: 0.16, r1: 0.12, sides: 6, pole, uv: matte)
            let armLen = along.halfRoad + 0.6
            props.tube(L(corner + SIMD3(0, 6.1, 0)), L(corner + SIMD3(0, 6.2, 0) - right * armLen), r0: 0.09, r1: 0.07, sides: 4, pole, uv: matte)
            for lane in along.lanes {
                let headAt = corner + SIMD3(0, 5.4, 0) - right * (along.halfRoad + 1.2 - lane)
                let q = simd_quatf(from: SIMD3(0, 0, 1), to: -d3)
                props.box(L(headAt), SIMD3(0.24, 0.62, 0.16), SIMD3(0.12, 0.12, 0.08), rot: q, uv: matte)
                for (k, dy) in [Float(0.38), 0, -0.38].enumerated() {
                    let lamp = headAt + SIMD3(0, dy, 0) - d3 * 0.17
                    let col: SIMD3<Float> = [SIMD3(1, 0.1, 0.06), SIMD3(1, 0.7, 0.05), SIMD3(0.1, 1, 0.45)][k]
                    let uvLamp = SIMD2(100 + Float(k) + 10 * Float(axis), phase)
                    let r = right * 0.15, up = SIMD3<Float>(0, 0.15, 0)
                    glow.quadUV(L(lamp - r - up), L(lamp + r - up), L(lamp + r + up), L(lamp - r + up), col,
                                   uvLamp, uvLamp, uvLamp, uvLamp, facing: -d3)
                }
            }
        }
        // Corner bits: a hydrant, a bin, newspaper boxes, sometimes a subway entrance.
        var rng = SplitMix64(seed: UInt64(ihash(i, j, 0xC0E2)) | 1)
        for (sx, sz) in [(Float(1), Float(1)), (-1, 1), (1, -1), (-1, -1)] {
            let c = node + SIMD3(sx * (lx.halfRoad + 2.2), 0, sz * (lz.halfRoad + 2.2))
            let r = CityChunk.nearSubwayOpening(c) ? 1 : rng.float()
            if r < 0.3 {
                props.cylinder(L(c), r0: 0.18, r1: 0.16, y0: 0, y1: 0.6, sides: 6, SIMD3(0.8, 0.12, 0.08), uv: matte)
                props.ellipsoid(L(c + SIMD3(0, 0.62, 0)), SIMD3(0.17, 0.12, 0.17), SIMD3(0.8, 0.12, 0.08), rings: 3, sides: 6)
            } else if r < 0.55 {
                props.cylinder(L(c), r0: 0.3, r1: 0.32, y0: 0, y1: 0.95, sides: 8, SIMD3(0.18, 0.32, 0.22), uv: matte)
            } else if r < 0.75 {
                for k in 0..<3 {
                    let col = [SIMD3<Float>(0.15, 0.3, 0.7), SIMD3(0.75, 0.15, 0.1), SIMD3(0.9, 0.8, 0.2)][k]
                    props.boxAA(L(c + SIMD3(Float(k) * 0.55 - 0.55, 0, -0.25)), L(c + SIMD3(Float(k) * 0.55 - 0.1, 1.0, 0.2)), col, uv: matte)
                }
            }
        }

    }

    private mutating func subwayEntrance(_ p: SIMD3<Float>) {
        let green = SIMD3<Float>(0.12, 0.30, 0.20)
        props.quad(L(p + SIMD3(-0.9, 0.04, -2.4)), L(p + SIMD3(0.9, 0.04, -2.4)), L(p + SIMD3(0.9, 0.04, 2.4)), L(p + SIMD3(-0.9, 0.04, 2.4)),
                   SIMD3(0.03, 0.03, 0.035), uv: matte, facing: kUp)
        for x: Float in [-1.0, 1.0] {
            props.box(L(p + SIMD3(x, 0.55, 0)), SIMD3(0.04, 0.55, 2.4), green, uv: matte)
        }
        props.box(L(p + SIMD3(0, 0.55, 2.4)), SIMD3(1.0, 0.55, 0.04), green, uv: matte)
        for x: Float in [-1.0, 1.0] {
            props.tube(L(p + SIMD3(x, 0, -2.4)), L(p + SIMD3(x, 2.4, -2.4)), r0: 0.06, r1: 0.06, sides: 4, green, uv: matte)
            glow.ellipsoid(L(p + SIMD3(x, 2.6, -2.4)), SIMD3(repeating: 0.25), SIMD3(0.4, 1, 0.55), rings: 3, sides: 6)
        }
    }

    // MARK: Bridges

    private mutating func addBridge(_ e: CityEdge) {
        guard let br = e.bridge else { return }
        let line = e.line
        let a = e.start + e.dir * br.s0, b = e.start + e.dir * br.s1
        let d3 = SIMD3(e.dir.x, 0, e.dir.y)
        let side = SIMD3(-e.dir.y, 0, e.dir.x)
        let hw = line.halfWidth
        let y = br.deck
        let A = SIMD3(a.x, y, a.y), B = SIMD3(b.x, y, b.y)
        // Deck top (painted by the ground shader), slab and sidewalk railings.
        decks.quad(L(A - side * hw), L(B - side * hw), L(B + side * hw), L(A + side * hw), SIMD3(0.5, 0.5, 0.49), facing: kUp)
        let slab = SIMD3<Float>(0.58, 0.57, 0.55)
        farProps.quad(L(A - side * hw - SIMD3(0, 1.6, 0)), L(A + side * hw - SIMD3(0, 1.6, 0)), L(B + side * hw - SIMD3(0, 1.6, 0)),
                      L(B - side * hw - SIMD3(0, 1.6, 0)), slab * 0.7, uv: matte, facing: -kUp)
        for s: Float in [-1, 1] {
            let o = side * hw * s
            farProps.quad(L(A + o - SIMD3(0, 1.6, 0)), L(B + o - SIMD3(0, 1.6, 0)), L(B + o + SIMD3(0, 0.02, 0)), L(A + o + SIMD3(0, 0.02, 0)),
                          slab, uv: matte, facing: side * s)
            // Railing: posts and a top rail.
            props.box(L((A + B) / 2 + o - side * s * 0.1 + SIMD3(0, 1.05, 0)), SIMD3(0.06, 0.06, simd_distance(A, B) / 2),
                      SIMD3(0.3, 0.32, 0.34), rot: simd_quatf(from: SIMD3(0, 0, 1), to: d3), uv: matte)
            var t: Float = 0
            while t < simd_distance(A, B) {
                let p = A + d3 * t + o - side * s * 0.1
                props.tube(L(p), L(p + SIMD3(0, 1.05, 0)), r0: 0.05, r1: 0.05, sides: 3, SIMD3(0.3, 0.32, 0.34), uv: matte)
                if fmodi(Int(t), 24) < 3 {
                    streetLamp(p + side * s * 0.0, toward: -side * s, avenue: line.avenue)
                }
                t += 3
            }
        }
        let span = br.s1 - br.s0
        let suspension = line.avenue && span > 55
        // Piers in the water.
        let pierStep: Float = suspension ? span : 24
        var t: Float = pierStep * 0.5
        while t < span - 4 {
            let p = A + d3 * t
            for s: Float in [-0.6, 0.6] {
                farProps.cylinder(L(SIMD3(p.x, -7, p.z) + side * hw * s), r0: 1.6, r1: 1.4, y0: 0, y1: y - 1.6 + 7, sides: 10, slab, uv: matte)
            }
            t += pierStep
        }
        if suspension {
            let orange = hfloat(e.i, e.j, 0xB21D) < 0.6 ? SIMD3<Float>(0.74, 0.24, 0.12) : SIMD3<Float>(0.42, 0.50, 0.58)
            let towerH: Float = 42 + min(span, 110) * 0.15
            let t0 = A + d3 * 6, t1 = B - d3 * 6
            for tp in [t0, t1] {
                for s: Float in [-1, 1] {
                    let leg = tp + side * (hw + 1.4) * s
                    farProps.box(L(SIMD3(leg.x, (y - 8 + y + towerH) / 2, leg.z)), SIMD3(1.1, (towerH + 8) / 2, 1.4), orange,
                                 rot: simd_quatf(from: SIMD3(0, 0, 1), to: d3), uv: paintUV)
                }
                for hy in [towerH - 1.5, towerH * 0.55] {
                    farProps.box(L(tp + SIMD3(0, hy, 0)), SIMD3(hw + 2.4, 1.0, 1.1), orange, rot: simd_quatf(from: SIMD3(1, 0, 0), to: side), uv: paintUV)
                }
                beacon(tp + side * (hw + 1.4) + SIMD3(0, towerH + 0.4, 0), r: 0.45)
                beacon(tp - side * (hw + 1.4) + SIMD3(0, towerH + 0.4, 0), r: 0.45)
            }
            // Main cables: tower tops sag to near the deck mid-span, and run down to anchors on the banks.
            for s: Float in [-1, 1] {
                let o = side * (hw + 1.4) * s
                let top0 = t0 + o + SIMD3(0, towerH, 0), top1 = t1 + o + SIMD3(0, towerH, 0)
                var pts: [SIMD3<Float>] = []
                let n = 16
                for k in 0...n {
                    let u = Float(k) / Float(n)
                    var p = top0 + (top1 - top0) * u
                    p.y -= (towerH - 4) * 4 * u * (1 - u)
                    pts.append(p)
                }
                for k in 0..<n { farProps.tube(L(pts[k]), L(pts[k + 1]), r0: 0.35, r1: 0.35, sides: 5, orange * 0.9, uv: paintUV) }
                farProps.tube(L(top0), L(t0 - d3 * 34 + o + SIMD3(0, 1, 0)), r0: 0.35, r1: 0.35, sides: 5, orange * 0.9, uv: paintUV)
                farProps.tube(L(top1), L(t1 + d3 * 34 + o + SIMD3(0, 1, 0)), r0: 0.35, r1: 0.35, sides: 5, orange * 0.9, uv: paintUV)
                // Suspenders
                for k in 1..<n where k % 1 == 0 {
                    let p = pts[k]
                    farProps.tube(L(SIMD3(p.x, y + 0.5, p.z)), L(p), r0: 0.05, r1: 0.05, sides: 3, SIMD3(0.25, 0.25, 0.26), uv: matte)
                }
            }
        } else {
            // Steel girders along the sides.
            let girder = hfloat(e.i, e.j, 0x61D) < 0.5 ? SIMD3<Float>(0.22, 0.34, 0.30) : SIMD3<Float>(0.30, 0.34, 0.42)
            for s: Float in [-1, 1] {
                let o = side * (hw + 0.25) * s
                farProps.box(L((A + B) / 2 + o - SIMD3(0, 0.9, 0)), SIMD3(0.25, 1.0, simd_distance(A, B) / 2), girder,
                             rot: simd_quatf(from: SIMD3(0, 0, 1), to: d3), uv: paintUV)
            }
        }
    }

    // MARK: Elevated railway

    /// Guideway over the median of an el avenue: columns, a twin-track beam and stations.
    private mutating func addElevated(_ i: Int) {
        let x = Float(i) * G
        let concrete = SIMD3<Float>(0.62, 0.61, 0.58)
        var z = floor(origin.z / 25) * 25
        while z < origin.z + size {
            if z >= origin.z {
                let y = CityTerrain.trackY(x, z)
                let g = CityLayout.ground(x, z)
                farProps.box(L(SIMD3(x, (g - 6 + y - 1.4) / 2, z)), SIMD3(0.75, (y - 1.4 - g + 6) / 2, 0.75), concrete, uv: matte)
                farProps.box(L(SIMD3(x, y - 1.25, z)), SIMD3(3.6, 0.3, 0.9), concrete, uv: matte)
                // Beam segment to the next column.
                let y2 = CityTerrain.trackY(x, z + 25)
                let mid = SIMD3(x, (y + y2) / 2 - 0.55, z + 12.5)
                let q = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(SIMD3(0, y2 - y, 25)))
                farProps.box(L(mid), SIMD3(3.6, 0.55, 12.6), concrete * 0.95, rot: q, uv: matte)
                for rail: Float in [-2.4, -1.0, 1.0, 2.4] {
                    props.box(L(mid + SIMD3(rail, 0.62, 0)), SIMD3(0.06, 0.08, 12.6), SIMD3(0.45, 0.42, 0.4), rot: q, uv: chromeUV)
                }
                // Stations: platforms with a canopy every five blocks.
                let blockZ = Int(floor(z / G))
                let inBlock = z - Float(blockZ) * G
                if fmodi(blockZ, 5) == 2 && inBlock > 30 && inBlock < 90 {
                    for s: Float in [-1, 1] {
                        props.box(L(SIMD3(x + s * 5.3, y - 0.2, z + 12.5)), SIMD3(1.7, 0.25, 12.6), SIMD3(0.7, 0.68, 0.64), uv: matte)
                        props.box(L(SIMD3(x + s * 5.3, y + 3.6, z + 12.5)), SIMD3(2.0, 0.12, 12.6), SIMD3(0.25, 0.42, 0.62), uv: paintUV)
                        props.tube(L(SIMD3(x + s * 6.6, y, z + 12.5)), L(SIMD3(x + s * 6.6, y + 3.6, z + 12.5)), r0: 0.1, r1: 0.1,
                                   sides: 4, SIMD3(0.3, 0.3, 0.32), uv: matte)
                        glow.box(L(SIMD3(x + s * 5.3, y + 3.45, z + 12.5)), SIMD3(0.12, 0.04, 10), SIMD3(1, 0.95, 0.85), top: false, bottom: true)
                    }
                }
            }
            z += 25
        }
    }
}

extension CityTerrain {
    /// Rail height of the elevated railway at (x, z).
    static func trackY(_ x: Float, _ z: Float) -> Float {
        max(CityLayout.ground(x, z), CityLayout.quayTop) + elHeight
    }
}
