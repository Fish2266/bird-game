import SceneKit
import simd

// Frontier towns: a dusty main street with false-front buildings on raised boardwalks, painted signs, a church with a
// steeple at one end, the station by the tracks with the town's name on it, a water tower, a windpump, a corral — and
// the saloon, whose swinging doors are wide enough to fly through (and whose back door is open too).

struct WestBuilding {
    enum Kind: Int { case saloon, store, bank, hotel, sheriff, barber, livery, assay, post, gunsmith, drygoods, blacksmith, telegraph, house, church, station }
    var kind: Kind
    /// Footprint corners and the wall height (eaves); the false front rises to `front`.
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    var frontTop: Float
    /// Which way the front faces along z (+1 north, −1 south).
    var facing: Float
    var paint: SIMD3<Float>
    var trim: SIMD3<Float>
    var sign: Int
    var stories: Int
    var center: SIMD3<Float> { (lo + hi) * 0.5 }
    /// The front wall's z.
    var frontZ: Float { facing > 0 ? hi.z : lo.z }
}

struct WestTownPlan {
    let town: WestLayout.Town
    var buildings: [WestBuilding] = []
    var saloon: WestBuilding?
    var waterTower = SIMD3<Float>.zero
    var windpump = SIMD3<Float>.zero
    var corral: (SIMD3<Float>, SIMD2<Float>) = (.zero, .zero)
    var hitching: [(SIMD3<Float>, Float)] = []
    var porchLamps: [SIMD3<Float>] = []
}

enum WestTown {
    /// Sign atlas: shop names in the first 16 slots, town names after.
    static let signNames = ["SALOON", "GENERAL STORE", "BANK", "HOTEL", "SHERIFF", "BARBER", "LIVERY", "ASSAY OFFICE", "POST OFFICE",
                            "GUNSMITH", "DRY GOODS", "BLACKSMITH", "TELEGRAPH", "BOARDING", "CHAPEL", "STATION"]
    static func signIndex(_ k: WestBuilding.Kind) -> Int { k.rawValue }
    /// The saloon's doorways (front and back): half-width and height. Wide enough to fly through — just.
    static let doorHalf: Float = 2.3
    static let doorHeight: Float = 4.4
    static func townSign(_ name: Int) -> Int { 16 + name }

    private static let lock = NSLock()
    private static var plans: [Int64: WestTownPlan] = [:]

    static func plan(_ t: WestLayout.Town) -> WestTownPlan {
        let key = (Int64(t.line) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: t.index)))
        lock.lock()
        if let p = plans[key] { lock.unlock(); return p }
        lock.unlock()
        let p = makePlan(t)
        lock.lock()
        if plans.count > 200 { plans.removeAll(keepingCapacity: true) }
        plans[key] = p
        lock.unlock()
        return p
    }

    private static let paints: [SIMD3<Float>] = [SIMD3(0.62, 0.28, 0.2), SIMD3(0.78, 0.62, 0.36), SIMD3(0.42, 0.52, 0.56), SIMD3(0.86, 0.82, 0.72),
                                                 SIMD3(0.55, 0.42, 0.3), SIMD3(0.48, 0.55, 0.38), SIMD3(0.7, 0.5, 0.38), SIMD3(0.62, 0.58, 0.52)]

    private static func makePlan(_ t: WestLayout.Town) -> WestTownPlan {
        var p = WestTownPlan(town: t)
        var rng = cellRNG(t.line, t.index, 0x5_A10)
        let cx = t.center.x, cz = t.center.y, g = t.ground
        let hw = WestLayout.streetHalfWidth, L = WestLayout.streetHalfLength
        let walk: Float = 3.2
        // North side (facing south onto the street): the saloon near the middle.
        var kinds: [WestBuilding.Kind] = [.store, .bank, .hotel, .sheriff, .barber, .assay, .post, .gunsmith, .drygoods, .telegraph, .house, .house, .blacksmith]
        for i in stride(from: kinds.count - 1, to: 0, by: -1) { kinds.swapAt(i, Int(rng.float(0, Float(i) + 0.999))) }
        var next = 0
        for side: Float in [1, -1] {
            var x = cx - L + 6
            let saloonAt = cx + rng.float(-30, 10)
            var placedSaloon = false
            while x < cx + L - 8 {
                var kind: WestBuilding.Kind
                if side > 0 && !placedSaloon && x > saloonAt - 4 { kind = .saloon; placedSaloon = true }
                else { kind = kinds[next % kinds.count]; next += 1 }
                let w: Float = kind == .saloon ? 18 : (kind == .hotel ? rng.float(14, 17) : rng.float(9, 13))
                let d: Float = kind == .saloon ? 22 : rng.float(12, 18)
                let stories = kind == .saloon || kind == .hotel ? 2 : (rng.float() < 0.25 ? 2 : 1)
                let eave: Float = stories == 2 ? 9.5 : 4.8
                let z0 = side > 0 ? cz + hw + walk : cz - hw - walk - d
                let lo = SIMD3(x, g, z0), hi = SIMD3(x + w, g + eave, z0 + d)
                let paint = kind == .saloon ? SIMD3<Float>(0.58, 0.22, 0.16) : paints[Int(rng.float(0, Float(paints.count) - 0.001))]
                let trim: SIMD3<Float> = rng.float() < 0.5 ? SIMD3(0.92, 0.88, 0.78) : SIMD3(0.32, 0.24, 0.18)
                let b = WestBuilding(kind: kind, lo: lo, hi: hi, frontTop: g + eave + (kind == .saloon ? 3.4 : rng.float(1.6, 3.2)),
                                     facing: -side, paint: paint, trim: trim, sign: kind == .house ? -1 : signIndex(kind), stories: stories)
                p.buildings.append(b)
                if kind == .saloon { p.saloon = b }
                // Lamps on the porch, hitching rails in front of some.
                if rng.float() < 0.5 { p.porchLamps.append(SIMD3(x + w / 2, g + 3.0, side > 0 ? cz + hw + walk - 0.3 : cz - hw - walk + 0.3)) }
                if rng.float() < 0.45 { p.hitching.append((SIMD3(x + w / 2, g, cz + side * (hw - 1.2)), 0)) }
                x += w + rng.float(1, 3.5)
            }
        }
        // The church closes the east end of the street; the station sits by the tracks to the south.
        p.buildings.append(WestBuilding(kind: .church, lo: SIMD3(cx + L + 4, g, cz - 7), hi: SIMD3(cx + L + 26, g + 7, cz + 7), frontTop: g + 7,
                                        facing: 0, paint: SIMD3(0.92, 0.9, 0.84), trim: SIMD3(0.4, 0.3, 0.22), sign: -1, stories: 1))
        let lz = WestLayout.lineZ(t.line)
        p.buildings.append(WestBuilding(kind: .station, lo: SIMD3(cx - 16, g, lz + 6), hi: SIMD3(cx + 16, g + 5.2, lz + 16), frontTop: g + 7.6,
                                        facing: -1, paint: SIMD3(0.78, 0.62, 0.38), trim: SIMD3(0.36, 0.22, 0.16), sign: townSign(t.name), stories: 1))
        p.waterTower = SIMD3(cx + 30, g, lz + 22)
        p.windpump = SIMD3(cx - L - 18, g, cz + 26)
        p.corral = (SIMD3(cx - L - 30, g, cz - 30), SIMD2(26, 20))
        return p
    }

    // MARK: Looks

    /// Weathered planks: horizontal boards with dark seams and a little colour from board to board.
    static let wood: SCNMaterial = {
        let m = WorldMaterials.vertexColor(rough: 0.85)
        m.diffuse.contents = WorldMaterials.whitePixel
        m.shaderModifiers = [.surface: """
        #pragma body
        float2 uv = _surface.diffuseTexcoord;
        if (uv.x > -900.0) {
            float row = floor(uv.y / 0.24);
            float f = fract(uv.y / 0.24);
            float joint = floor(uv.x / 3.1 + fract(row * 0.37) * 3.0);
            float h = fract(sin(row * 12.9898 + joint * 78.233) * 43758.5453);
            float seam = 1.0 - smoothstep(0.0, 0.09, min(f, 1.0 - f));
            float vj = 1.0 - smoothstep(0.0, 0.02, abs(fract(uv.x / 3.1 + fract(row * 0.37) * 3.0) - 0.5) - 0.48);
            _surface.diffuse.rgb *= (0.86 + 0.2 * h) * (1.0 - 0.45 * max(seam, vj));
        }
        """]
        return m
    }()

    static let signs: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.8
        let cols = 4, rows = 8
        let w: CGFloat = 512, h: CGFloat = 128
        let names = signNames + WestLayout.townNames.map { $0.uppercased() }
        m.diffuse.contents = NSImage(size: NSSize(width: w * CGFloat(cols), height: h * CGFloat(rows)), flipped: true) { _ in
            for (k, name) in names.enumerated() where k < cols * rows {
                let r = NSRect(x: CGFloat(k % cols) * w, y: CGFloat(k / cols) * h, width: w, height: h)
                // Painted board with a border; serif lettering.
                let bg: NSColor = k == 0 ? NSColor(srgbRed: 0.18, green: 0.1, blue: 0.08, alpha: 1)
                    : (k >= 16 ? NSColor(srgbRed: 0.2, green: 0.24, blue: 0.2, alpha: 1) : NSColor(srgbRed: 0.88, green: 0.82, blue: 0.68, alpha: 1))
                bg.setFill(); NSBezierPath(rect: r).fill()
                let ink: NSColor = k == 0 ? NSColor(srgbRed: 0.98, green: 0.82, blue: 0.3, alpha: 1)
                    : (k >= 16 ? NSColor(srgbRed: 0.95, green: 0.92, blue: 0.82, alpha: 1) : NSColor(srgbRed: 0.22, green: 0.14, blue: 0.1, alpha: 1))
                ink.setStroke()
                let b = NSBezierPath(rect: r.insetBy(dx: 7, dy: 7)); b.lineWidth = 4; b.stroke()
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let size: CGFloat = name.count > 11 ? 50 : 66
                let font = NSFont(name: "Rockwell-Bold", size: size) ?? NSFont(name: "AmericanTypewriter-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: para, .kern: 3]
                let s = NSAttributedString(string: name, attributes: attrs)
                let sh = s.size().height
                s.draw(in: NSRect(x: r.minX + 10, y: r.midY - sh / 2, width: r.width - 20, height: sh))
            }
            return true
        }
        m.diffuse.mipFilter = .linear
        return m
    }()

    static func signUV(_ k: Int) -> (SIMD2<Float>, SIMD2<Float>) {
        let col = Float(k % 4), row = Float(k / 4)
        return (SIMD2(col / 4, row / 8), SIMD2((col + 1) / 4, (row + 1) / 8))
    }
}

/// Builds a town's meshes in chunk-local coordinates.
struct WestTownMesh {
    let origin: SIMD3<Float>
    var wood = MeshBuilder()
    var signs = MeshBuilder()
    var glow = MeshBuilder()
    var props = MeshBuilder()
    /// The windpump's wheel (turns).
    var wheels: [(MeshBuilder, SIMD3<Float>)] = []

    init(origin: SIMD3<Float>) { self.origin = origin }

    @inline(__always) private func L(_ p: SIMD3<Float>) -> SIMD3<Float> { p - origin }

    /// A plank wall quad: uv in metres along the wall and up it.
    private mutating func wall(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ y0: Float, _ y1: Float, _ c: SIMD3<Float>, facing: SIMD3<Float>) {
        let len = simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
        wood.quadUV(L(SIMD3(a.x, y0, a.z)), L(SIMD3(b.x, y0, b.z)), L(SIMD3(b.x, y1, b.z)), L(SIMD3(a.x, y1, a.z)), c,
                    SIMD2(0, y0), SIMD2(len, y0), SIMD2(len, y1), SIMD2(0, y1), facing: facing)
    }

    private mutating func plain(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ c: SIMD3<Float>) {
        wood.boxAA(L(lo), L(hi), c, uv: SIMD2(-1000, 0))
    }

    mutating func add(_ plan: WestTownPlan) {
        for b in plan.buildings {
            switch b.kind {
            case .church: church(b)
            case .station: station(b)
            default: storefront(b)
            }
        }
        waterTower(plan.waterTower)
        windpump(plan.windpump)
        corral(plan.corral.0, plan.corral.1)
        for p in plan.porchLamps {
            glow.ellipsoid(L(p), SIMD3(repeating: 0.16), SIMD3(1, 0.78, 0.45), rings: 2, sides: 6)
            props.boxAA(L(p + SIMD3(-0.12, 0.15, -0.12)), L(p + SIMD3(0.12, 0.35, 0.12)), SIMD3(0.15, 0.12, 0.1))
        }
        for (p, _) in plan.hitching {
            for s: Float in [-1.6, 1.6] { props.boxAA(L(p + SIMD3(s - 0.08, 0, -0.08)), L(p + SIMD3(s + 0.08, 1.1, 0.08)), SIMD3(0.4, 0.3, 0.2)) }
            props.boxAA(L(p + SIMD3(-1.75, 0.95, -0.06)), L(p + SIMD3(1.75, 1.08, 0.06)), SIMD3(0.42, 0.32, 0.22))
            // A water trough beside it.
            props.boxAA(L(p + SIMD3(-1.2, 0, 0.6)), L(p + SIMD3(1.2, 0.6, 1.3)), SIMD3(0.45, 0.34, 0.24))
        }
    }

    // MARK: Buildings

    private mutating func storefront(_ b: WestBuilding) {
        let f = b.facing
        let zF = b.frontZ, zB = f > 0 ? b.lo.z : b.hi.z
        let out = SIMD3<Float>(0, 0, f)
        let g = b.lo.y, eave = b.hi.y
        let x0 = b.lo.x, x1 = b.hi.x
        let saloon = b.kind == .saloon
        // Walls (the saloon's front and back walls leave a doorway to fly through).
        let door: Float = saloon ? WestTown.doorHalf : 0, doorTop: Float = saloon ? g + WestTown.doorHeight : g
        let mid = (x0 + x1) / 2
        func endWall(_ z: Float, _ facing: SIMD3<Float>) {
            if saloon {
                wall(SIMD3(x0, 0, z), SIMD3(mid - door, 0, z), g, eave, b.paint, facing: facing)
                wall(SIMD3(mid + door, 0, z), SIMD3(x1, 0, z), g, eave, b.paint, facing: facing)
                wall(SIMD3(mid - door, 0, z), SIMD3(mid + door, 0, z), doorTop, eave, b.paint, facing: facing)
            } else {
                wall(SIMD3(x0, 0, z), SIMD3(x1, 0, z), g, eave, b.paint, facing: facing)
            }
        }
        endWall(zF, out)
        endWall(zB, -out)
        wall(SIMD3(x0, 0, b.lo.z), SIMD3(x0, 0, b.hi.z), g, eave, b.paint * 0.92, facing: SIMD3(-1, 0, 0))
        wall(SIMD3(x1, 0, b.lo.z), SIMD3(x1, 0, b.hi.z), g, eave, b.paint * 0.92, facing: SIMD3(1, 0, 0))
        // A pitched roof behind the false front (ridge running back from the street).
        let ridge = eave + (x1 - x0) * 0.28
        let roof = SIMD3<Float>(0.32, 0.27, 0.23)
        wood.quadUV(L(SIMD3(x0 - 0.3, eave, b.lo.z)), L(SIMD3(x0 - 0.3, eave, b.hi.z)), L(SIMD3(mid, ridge, b.hi.z)), L(SIMD3(mid, ridge, b.lo.z)), roof,
                    SIMD2(0, 0), SIMD2(b.hi.z - b.lo.z, 0), SIMD2(b.hi.z - b.lo.z, 4), SIMD2(0, 4), facing: SIMD3(-1, 1, 0))
        wood.quadUV(L(SIMD3(x1 + 0.3, eave, b.lo.z)), L(SIMD3(x1 + 0.3, eave, b.hi.z)), L(SIMD3(mid, ridge, b.hi.z)), L(SIMD3(mid, ridge, b.lo.z)), roof,
                    SIMD2(0, 0), SIMD2(b.hi.z - b.lo.z, 0), SIMD2(b.hi.z - b.lo.z, 4), SIMD2(0, 4), facing: SIMD3(1, 1, 0))
        for z in [zB] {
            let n = SIMD3<Float>(0, 0, z == b.lo.z ? -1 : 1)
            wood.quadUV(L(SIMD3(x0, eave, z)), L(SIMD3(x1, eave, z)), L(SIMD3(mid, ridge, z)), L(SIMD3(mid, ridge, z)), b.paint * 0.9,
                        SIMD2(0, eave), SIMD2(x1 - x0, eave), SIMD2((x1 - x0) / 2, ridge), SIMD2((x1 - x0) / 2, ridge), facing: n)
        }
        // The false front: a tall board facade with a stepped top and a cornice.
        let fz = zF + f * 0.05
        let shoulder = b.frontTop - (b.kind == .saloon ? 1.4 : 0.9)
        wall(SIMD3(x0 - 0.2, 0, fz), SIMD3(x1 + 0.2, 0, fz), eave, shoulder, b.paint, facing: out)
        wall(SIMD3(x0 + (x1 - x0) * 0.22, 0, fz), SIMD3(x1 - (x1 - x0) * 0.22, 0, fz), shoulder, b.frontTop, b.paint, facing: out)
        wood.quadUV(L(SIMD3(x0 - 0.2, eave, fz - f * 0.15)), L(SIMD3(x1 + 0.2, eave, fz - f * 0.15)), L(SIMD3(x1 + 0.2, b.frontTop, fz - f * 0.15)),
                    L(SIMD3(x0 - 0.2, b.frontTop, fz - f * 0.15)), b.paint * 0.8, SIMD2(-1000, 0), SIMD2(-1000, 0), SIMD2(-1000, 0), SIMD2(-1000, 0), facing: -out)
        plain(SIMD3(x0 - 0.45, shoulder - 0.25, min(fz, fz + f * 0.5)), SIMD3(x1 + 0.45, shoulder, max(fz, fz + f * 0.5)), b.trim)
        plain(SIMD3(x0 + (x1 - x0) * 0.2, b.frontTop - 0.25, min(fz, fz + f * 0.5)), SIMD3(x1 - (x1 - x0) * 0.2, b.frontTop + 0.05, max(fz, fz + f * 0.5)), b.trim)
        // The sign board.
        if b.sign >= 0 {
            let (uv0, uv1) = WestTown.signUV(b.sign)
            let sw = min((x1 - x0) * 0.42, 6), sy = eave + (b.stories == 2 ? 0.9 : 0.45), sh = sw / 4
            let z = fz + f * 0.08
            let a = SIMD3(mid - sw, sy, z), c = SIMD3(mid + sw, sy + sh * 2, z)
            signs.quadUV(L(f > 0 ? a : SIMD3(c.x, a.y, z)), L(f > 0 ? SIMD3(c.x, a.y, z) : a), L(f > 0 ? c : SIMD3(a.x, c.y, z)),
                         L(f > 0 ? SIMD3(a.x, c.y, z) : c), SIMD3(1, 1, 1), SIMD2(uv0.x, uv1.y), SIMD2(uv1.x, uv1.y), SIMD2(uv1.x, uv0.y), SIMD2(uv0.x, uv0.y),
                         facing: out)
        }
        // Windows and the door on the street side.
        let glass = SIMD3<Float>(0.1, 0.11, 0.13)
        let wz = zF + f * 0.06
        func window(_ cx: Float, _ y0: Float, _ y1: Float, _ hw: Float) {
            props.boxAA(L(SIMD3(cx - hw - 0.12, y0 - 0.12, min(wz, wz + f * 0.12))), L(SIMD3(cx + hw + 0.12, y1 + 0.12, max(wz, wz + f * 0.12))), b.trim)
            props.boxAA(L(SIMD3(cx - hw, y0, min(wz, wz + f * 0.16))), L(SIMD3(cx + hw, y1, max(wz, wz + f * 0.16))), glass)
        }
        let span = x1 - x0
        if !saloon {
            window(x0 + span * 0.22, g + 1.0, g + 3.0, span * 0.12)
            window(x1 - span * 0.22, g + 1.0, g + 3.0, span * 0.12)
            props.boxAA(L(SIMD3(mid - 0.65, g, min(wz, wz + f * 0.1))), L(SIMD3(mid + 0.65, g + 2.6, max(wz, wz + f * 0.1))), SIMD3(0.24, 0.17, 0.12))
        } else {
            window(x0 + span * 0.18, g + 1.2, g + 3.4, 1.4)
            window(x1 - span * 0.18, g + 1.2, g + 3.4, 1.4)
        }
        if b.stories == 2 {
            for k in 0..<3 { window(x0 + span * (0.2 + 0.3 * Float(k)), g + 6.0, g + 8.2, 0.75) }
        }
        // Boardwalk and porch roof on posts (the saloon's is a balcony with a railing).
        let walkOut = zF + f * 3.2
        let zw0 = min(zF, walkOut), zw1 = max(zF, walkOut)
        plain(SIMD3(x0 - 0.5, g - 0.3, zw0), SIMD3(x1 + 0.5, g + 0.35, zw1), SIMD3(0.52, 0.4, 0.28))
        let porchY = saloon ? g + 4.6 : g + 3.3
        plain(SIMD3(x0 - 0.5, porchY, zw0), SIMD3(x1 + 0.5, porchY + 0.22, zw1), SIMD3(0.38, 0.3, 0.22))
        var px = x0 - 0.3
        while px <= x1 + 0.4 {
            plain(SIMD3(px - 0.11, g + 0.35, walkOut - f * 0.25 - 0.11), SIMD3(px + 0.11, porchY, walkOut - f * 0.25 + 0.11), b.trim)
            px += (x1 - x0 + 0.6) / max(1, ((x1 - x0) / 3.2).rounded())
        }
        if saloon {
            // Balcony railing on the porch roof, and the swinging doors' frame.
            plain(SIMD3(x0 - 0.5, porchY + 0.22, walkOut - f * 0.12 - 0.05), SIMD3(x1 + 0.5, porchY + 1.25, walkOut - f * 0.12 + 0.05), b.trim)
            for side: Float in [-1, 1] {
                plain(SIMD3(mid + side * door - 0.15, g, zF - 0.2), SIMD3(mid + side * door + 0.15, doorTop, zF + 0.2), b.trim)
                plain(SIMD3(mid + side * door - 0.15, g, zB - 0.2), SIMD3(mid + side * door + 0.15, doorTop, zB + 0.2), b.trim)
            }
            plain(SIMD3(mid - door - 0.15, doorTop - 0.2, zF - 0.2), SIMD3(mid + door + 0.15, doorTop + 0.15, zF + 0.2), b.trim)
            plain(SIMD3(mid - door - 0.15, doorTop - 0.2, zB - 0.2), SIMD3(mid + door + 0.15, doorTop + 0.15, zB + 0.2), b.trim)
            saloonInside(b)
        }
    }

    /// Inside the saloon: a bar with bottles, tables, a piano, a chandelier — and a ceiling under the upstairs rooms.
    private mutating func saloonInside(_ b: WestBuilding) {
        let g = b.lo.y, x0 = b.lo.x, x1 = b.hi.x, z0 = b.lo.z, z1 = b.hi.z
        let floorC = SIMD3<Float>(0.45, 0.33, 0.22), dark = SIMD3<Float>(0.28, 0.18, 0.12)
        // Floor and ceiling (from inside).
        wood.quadUV(L(SIMD3(x0, g + 0.02, z0)), L(SIMD3(x1, g + 0.02, z0)), L(SIMD3(x1, g + 0.02, z1)), L(SIMD3(x0, g + 0.02, z1)), floorC,
                    SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, z1 - z0), SIMD2(0, z1 - z0), facing: kUp)
        wood.quadUV(L(SIMD3(x0, g + 5.5, z0)), L(SIMD3(x1, g + 5.5, z0)), L(SIMD3(x1, g + 5.5, z1)), L(SIMD3(x0, g + 5.5, z1)), dark,
                    SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, z1 - z0), SIMD2(0, z1 - z0), facing: -kUp)
        // Inner faces of the walls.
        let wallC = SIMD3<Float>(0.62, 0.42, 0.3)
        wall(SIMD3(x0 + 0.1, 0, z1), SIMD3(x0 + 0.1, 0, z0), g, g + 5.5, wallC, facing: SIMD3(1, 0, 0))
        wall(SIMD3(x1 - 0.1, 0, z0), SIMD3(x1 - 0.1, 0, z1), g, g + 5.5, wallC, facing: SIMD3(-1, 0, 0))
        let mid = (x0 + x1) / 2
        for (z, n) in [(z0 + 0.1, Float(1)), (z1 - 0.1, Float(-1))] {
            let dh = WestTown.doorHalf
            wall(SIMD3(x0, 0, z), SIMD3(mid - dh, 0, z), g, g + 5.5, wallC, facing: SIMD3(0, 0, n))
            wall(SIMD3(mid + dh, 0, z), SIMD3(x1, 0, z), g, g + 5.5, wallC, facing: SIMD3(0, 0, n))
            wall(SIMD3(mid - dh, 0, z), SIMD3(mid + dh, 0, z), g + WestTown.doorHeight, g + 5.5, wallC, facing: SIMD3(0, 0, n))
        }
        // The bar along the west wall, bottles glowing on the shelves behind it.
        plain(SIMD3(x0 + 2.2, g, z0 + 4), SIMD3(x0 + 3.2, g + 1.2, z1 - 4), dark)
        plain(SIMD3(x0 + 2.0, g + 1.2, z0 + 3.8), SIMD3(x0 + 3.4, g + 1.35, z1 - 3.8), SIMD3(0.5, 0.36, 0.24))
        plain(SIMD3(x0 + 0.1, g + 1.6, z0 + 5), SIMD3(x0 + 0.6, g + 1.7, z1 - 5), dark)
        plain(SIMD3(x0 + 0.1, g + 2.4, z0 + 5), SIMD3(x0 + 0.6, g + 2.5, z1 - 5), dark)
        var bz = z0 + 5.4
        while bz < z1 - 5.4 {
            for y: Float in [1.7, 2.5] {
                glow.boxAA(L(SIMD3(x0 + 0.25, g + y, bz - 0.06)), L(SIMD3(x0 + 0.4, g + y + 0.38, bz + 0.06)),
                           [SIMD3<Float>(0.5, 0.75, 0.3), SIMD3(0.75, 0.45, 0.15), SIMD3(0.55, 0.3, 0.2)][Int(bz * 3) % 3] * 0.7)
            }
            bz += 0.45
        }
        // Tables with chairs.
        for (tx, tz) in [(mid + 2.5, z0 + 6), (mid + 5.5, z0 + 11), (mid + 2.5, z1 - 6), (mid - 1.5, z1 - 10)] as [(Float, Float)] {
            props.cylinder(L(SIMD3(tx, g, tz)), r0: 0.12, r1: 0.12, y0: 0, y1: 0.9, sides: 6, dark)
            props.cylinder(L(SIMD3(tx, g, tz)), r0: 0.9, r1: 0.9, y0: 0.9, y1: 1.0, sides: 10, SIMD3(0.5, 0.36, 0.24))
            for a in [0, 1.57, 3.14, 4.71] as [Float] {
                let c = SIMD3(tx + cos(a) * 1.3, g, tz + sin(a) * 1.3)
                props.boxAA(L(c - SIMD3(0.25, 0, 0.25)), L(c + SIMD3(0.25, 0.55, 0.25)), dark)
            }
        }
        // The piano on the east wall.
        props.boxAA(L(SIMD3(x1 - 1.6, g, z0 + 7)), L(SIMD3(x1 - 0.2, g + 1.5, z0 + 9.2)), SIMD3(0.16, 0.1, 0.08))
        props.boxAA(L(SIMD3(x1 - 1.9, g + 0.8, z0 + 7.1)), L(SIMD3(x1 - 1.55, g + 0.86, z0 + 9.1)), SIMD3(0.95, 0.94, 0.9))
        // A chandelier.
        let ch = SIMD3(mid, g + 4.6, (z0 + z1) / 2)
        props.cylinder(L(ch), r0: 1.3, r1: 1.3, y0: 0, y1: 0.12, sides: 12, SIMD3(0.35, 0.28, 0.15))
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            glow.ellipsoid(L(ch + SIMD3(cos(a) * 1.2, 0.3, sin(a) * 1.2)), SIMD3(repeating: 0.12), SIMD3(1, 0.8, 0.45), rings: 2, sides: 5)
        }
        props.tube(L(ch + SIMD3(0, 0.1, 0)), L(SIMD3(ch.x, g + 5.5, ch.z)), r0: 0.03, r1: 0.03, sides: 4, SIMD3(0.2, 0.18, 0.15))
    }

    private mutating func church(_ b: WestBuilding) {
        let g = b.lo.y, eave = b.hi.y, x0 = b.lo.x, x1 = b.hi.x, z0 = b.lo.z, z1 = b.hi.z
        let white = b.paint, roofC = SIMD3<Float>(0.3, 0.28, 0.27)
        // Walls; the door end faces west along the street.
        wall(SIMD3(x0, 0, z1), SIMD3(x0, 0, z0), g, eave, white, facing: SIMD3(-1, 0, 0))
        wall(SIMD3(x1, 0, z0), SIMD3(x1, 0, z1), g, eave, white, facing: SIMD3(1, 0, 0))
        wall(SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), g, eave, white * 0.95, facing: SIMD3(0, 0, -1))
        wall(SIMD3(x1, 0, z1), SIMD3(x0, 0, z1), g, eave, white * 0.95, facing: SIMD3(0, 0, 1))
        let midZ = (z0 + z1) / 2, ridge = eave + (z1 - z0) * 0.45
        wood.quadUV(L(SIMD3(x0 - 0.4, eave, z0 - 0.4)), L(SIMD3(x1 + 0.4, eave, z0 - 0.4)), L(SIMD3(x1 + 0.4, ridge, midZ)), L(SIMD3(x0 - 0.4, ridge, midZ)), roofC,
                    SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, 5), SIMD2(0, 5), facing: SIMD3(0, 1, -1))
        wood.quadUV(L(SIMD3(x0 - 0.4, eave, z1 + 0.4)), L(SIMD3(x1 + 0.4, eave, z1 + 0.4)), L(SIMD3(x1 + 0.4, ridge, midZ)), L(SIMD3(x0 - 0.4, ridge, midZ)), roofC,
                    SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, 5), SIMD2(0, 5), facing: SIMD3(0, 1, 1))
        for x in [x0, x1] {
            let n = SIMD3<Float>(x == x0 ? -1 : 1, 0, 0)
            wood.quadUV(L(SIMD3(x, eave, z0)), L(SIMD3(x, eave, z1)), L(SIMD3(x, ridge, midZ)), L(SIMD3(x, ridge, midZ)), white,
                        SIMD2(0, eave), SIMD2(z1 - z0, eave), SIMD2((z1 - z0) / 2, ridge), SIMD2((z1 - z0) / 2, ridge), facing: n)
        }
        // Tall windows, the door, and the steeple over the door with its bell.
        for k in 0..<3 {
            let x = x0 + 5 + Float(k) * 6
            for z in [z0 - 0.06, z1 + 0.06] {
                props.boxAA(L(SIMD3(x - 0.7, g + 1.6, z - 0.06)), L(SIMD3(x + 0.7, g + 5, z + 0.06)), SIMD3(0.35, 0.5, 0.62))
            }
        }
        props.boxAA(L(SIMD3(x0 - 0.1, g, midZ - 1.1)), L(SIMD3(x0 + 0.05, g + 3.2, midZ + 1.1)), SIMD3(0.4, 0.26, 0.16))
        let tower = SIMD3(x0 + 2.4, g, midZ)
        plain(tower + SIMD3(-2, 0, -2), tower + SIMD3(2, ridge - g + 4, 2), white)
        plain(tower + SIMD3(-2.3, ridge - g + 4, -2.3), tower + SIMD3(2.3, ridge - g + 4.3, 2.3), b.trim)
        plain(tower + SIMD3(-1.8, ridge - g + 4.3, -1.8), tower + SIMD3(1.8, ridge - g + 7.3, 1.8), white * 0.97)
        props.ellipsoid(L(tower + SIMD3(0, ridge - g + 5.4, 0)), SIMD3(0.7, 0.8, 0.7), SIMD3(0.7, 0.55, 0.2), rings: 3, sides: 8)
        props.cylinder(L(tower + SIMD3(0, ridge - g + 7.3, 0)), r0: 2.2, r1: 0.05, y0: 0, y1: 7, sides: 4, roofC, yaw: .pi / 4)
        props.boxAA(L(tower + SIMD3(-0.08, ridge - g + 14.3, -0.08)), L(tower + SIMD3(0.08, ridge - g + 16.5, 0.08)), SIMD3(0.2, 0.18, 0.15))
        props.boxAA(L(tower + SIMD3(-0.08, ridge - g + 15.5, -0.6)), L(tower + SIMD3(0.08, ridge - g + 15.7, 0.6)), SIMD3(0.2, 0.18, 0.15))
    }

    private mutating func station(_ b: WestBuilding) {
        let g = b.lo.y, eave = b.hi.y, x0 = b.lo.x, x1 = b.hi.x, z0 = b.lo.z, z1 = b.hi.z
        wall(SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), g, eave, b.paint, facing: SIMD3(0, 0, -1))
        wall(SIMD3(x1, 0, z1), SIMD3(x0, 0, z1), g, eave, b.paint, facing: SIMD3(0, 0, 1))
        wall(SIMD3(x0, 0, z1), SIMD3(x0, 0, z0), g, eave, b.paint * 0.93, facing: SIMD3(-1, 0, 0))
        wall(SIMD3(x1, 0, z0), SIMD3(x1, 0, z1), g, eave, b.paint * 0.93, facing: SIMD3(1, 0, 0))
        // A long low roof overhanging the platform on the track side.
        let roofC = SIMD3<Float>(0.45, 0.24, 0.18)
        let midZ = (z0 + z1) / 2
        wood.quadUV(L(SIMD3(x0 - 1, eave, z0 - 4.5)), L(SIMD3(x1 + 1, eave, z0 - 4.5)), L(SIMD3(x1 + 1, eave + 2.6, midZ)), L(SIMD3(x0 - 1, eave + 2.6, midZ)),
                    roofC, SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, 4), SIMD2(0, 4), facing: SIMD3(0, 1, -1))
        wood.quadUV(L(SIMD3(x0 - 1, eave, z1 + 1)), L(SIMD3(x1 + 1, eave, z1 + 1)), L(SIMD3(x1 + 1, eave + 2.6, midZ)), L(SIMD3(x0 - 1, eave + 2.6, midZ)),
                    roofC, SIMD2(0, 0), SIMD2(x1 - x0, 0), SIMD2(x1 - x0, 4), SIMD2(0, 4), facing: SIMD3(0, 1, 1))
        // The platform along the tracks, posts holding the roof.
        plain(SIMD3(x0 - 6, g - 0.5, z0 - 4.6), SIMD3(x1 + 6, g + 0.6, z0), SIMD3(0.5, 0.4, 0.3))
        var px = x0
        while px <= x1 + 0.1 {
            plain(SIMD3(px - 0.12, g + 0.6, z0 - 4.2), SIMD3(px + 0.12, eave, z0 - 3.96), b.trim)
            px += 4
        }
        // The town's name on a board on the roof, both sides.
        let (uv0, uv1) = WestTown.signUV(b.sign)
        let mid = (x0 + x1) / 2, sw: Float = 8, sh: Float = 2
        for (z, face) in [(z0 - 4.6, Float(-1)), (z1 + 1.1, Float(1))] {
            let y0 = eave + 2.7
            let a = SIMD3(mid - sw, y0, z), c = SIMD3(mid + sw, y0 + sh * 2, z)
            if face < 0 {
                signs.quadUV(L(SIMD3(c.x, a.y, z)), L(a), L(SIMD3(a.x, c.y, z)), L(c), SIMD3(1, 1, 1),
                             SIMD2(uv0.x, uv1.y), SIMD2(uv1.x, uv1.y), SIMD2(uv1.x, uv0.y), SIMD2(uv0.x, uv0.y), facing: SIMD3(0, 0, -1))
            } else {
                signs.quadUV(L(a), L(SIMD3(c.x, a.y, z)), L(c), L(SIMD3(a.x, c.y, z)), SIMD3(1, 1, 1),
                             SIMD2(uv0.x, uv1.y), SIMD2(uv1.x, uv1.y), SIMD2(uv1.x, uv0.y), SIMD2(uv0.x, uv0.y), facing: SIMD3(0, 0, 1))
            }
            plain(SIMD3(mid - sw - 0.3, y0 - 0.3, z - 0.1), SIMD3(mid - sw + 0.0, y0 + sh * 2 + 0.3, z + 0.1), b.trim)
            plain(SIMD3(mid + sw, y0 - 0.3, z - 0.1), SIMD3(mid + sw + 0.3, y0 + sh * 2 + 0.3, z + 0.1), b.trim)
        }
    }

    // MARK: Fixtures

    private mutating func waterTower(_ p: SIMD3<Float>) {
        let wood = SIMD3<Float>(0.5, 0.38, 0.26)
        for (sx, sz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            props.tube(L(p + SIMD3(sx * 2.6, 0, sz * 2.6)), L(p + SIMD3(sx * 2.0, 9, sz * 2.0)), r0: 0.2, r1: 0.18, sides: 5, wood)
        }
        for y: Float in [3, 6] {
            props.boxAA(L(p + SIMD3(-2.5, y, -2.5)), L(p + SIMD3(2.5, y + 0.2, -2.3)), wood)
            props.boxAA(L(p + SIMD3(-2.5, y, 2.3)), L(p + SIMD3(2.5, y + 0.2, 2.5)), wood)
        }
        props.cylinder(L(p + SIMD3(0, 9, 0)), r0: 3.3, r1: 3.3, y0: 0, y1: 4.8, sides: 14, SIMD3(0.55, 0.42, 0.3))
        for y: Float in [0.6, 2.3, 4.1] { props.cylinder(L(p + SIMD3(0, 9 + y, 0)), r0: 3.38, r1: 3.38, y0: 0, y1: 0.18, sides: 14, SIMD3(0.22, 0.2, 0.2), top: false) }
        props.cylinder(L(p + SIMD3(0, 13.8, 0)), r0: 3.6, r1: 0.2, y0: 0, y1: 2.2, sides: 14, SIMD3(0.42, 0.25, 0.2))
        props.tube(L(p + SIMD3(3.2, 10, 0)), L(p + SIMD3(5.0, 7.5, 0)), r0: 0.18, r1: 0.18, sides: 5, SIMD3(0.25, 0.22, 0.2))
    }

    private mutating func windpump(_ p: SIMD3<Float>) {
        let steel = SIMD3<Float>(0.5, 0.5, 0.52)
        let top = p + SIMD3(0, 11, 0)
        for (sx, sz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            props.tube(L(p + SIMD3(sx * 1.8, 0, sz * 1.8)), L(top + SIMD3(sx * 0.3, 0, sz * 0.3)), r0: 0.08, r1: 0.06, sides: 4, steel)
        }
        for y: Float in [3, 6.5, 9] {
            let w = 1.8 * (1 - y / 11) + 0.3 * y / 11
            props.boxAA(L(p + SIMD3(-w, y, -w)), L(p + SIMD3(w, y + 0.08, -w + 0.08)), steel)
            props.boxAA(L(p + SIMD3(-w, y, w - 0.08)), L(p + SIMD3(w, y + 0.08, w)), steel)
        }
        // The tail vane, and a trough at the foot.
        props.boxAA(L(top + SIMD3(-0.05, -0.4, 0.4)), L(top + SIMD3(0.05, 0.6, 2.8)), SIMD3(0.75, 0.2, 0.15))
        props.boxAA(L(p + SIMD3(1.5, 0, -1)), L(p + SIMD3(4.5, 0.7, 0.4)), SIMD3(0.45, 0.34, 0.24))
        // The wheel: a ring of blades (turned by the game).
        var wheel = MeshBuilder()
        for k in 0..<14 {
            let a = Float(k) / 14 * 2 * .pi
            let d = SIMD3(cos(a), sin(a), 0)
            let side = SIMD3(-sin(a), cos(a), 0)
            wheel.quad(d * 0.4 - side * 0.1, d * 2.3 - side * 0.28, d * 2.3 + side * 0.28, d * 0.4 + side * 0.1, SIMD3(0.82, 0.8, 0.76),
                       facing: SIMD3(0, 0, -1))
            wheel.quad(d * 0.4 + side * 0.1, d * 2.3 + side * 0.28, d * 2.3 - side * 0.28, d * 0.4 - side * 0.1, SIMD3(0.7, 0.68, 0.64),
                       facing: SIMD3(0, 0, 1))
        }
        wheel.cylinder(SIMD3(0, 0, -0.1), r0: 0.35, r1: 0.35, y0: 0, y1: 0.3, sides: 8, steel)
        wheels.append((wheel, L(top + SIMD3(0, 0, -0.3))))
    }

    private mutating func corral(_ c: SIMD3<Float>, _ size: SIMD2<Float>) {
        let wood = SIMD3<Float>(0.48, 0.36, 0.25)
        let corners = [SIMD2(-size.x, -size.y), SIMD2(size.x, -size.y), SIMD2(size.x, size.y), SIMD2(-size.x, size.y)].map { $0 * 0.5 }
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let len = simd_distance(a, b)
            let n = Int(len / 3)
            for i in 0...n {
                let q = a + (b - a) * (Float(i) / Float(n))
                props.boxAA(L(c + SIMD3(q.x - 0.1, 0, q.y - 0.1)), L(c + SIMD3(q.x + 0.1, 1.5, q.y + 0.1)), wood)
            }
            for y: Float in [0.6, 1.25] {
                let pa = c + SIMD3(a.x, y, a.y), pb = c + SIMD3(b.x, y, b.y)
                props.tube(L(pa), L(pb), r0: 0.07, r1: 0.07, sides: 4, wood)
            }
        }
        // A barn-red stable along one side.
        let s0 = c + SIMD3(-size.x * 0.5, 0, size.y * 0.5 + 0.5), s1 = c + SIMD3(-size.x * 0.5 + 14, 4.5, size.y * 0.5 + 9)
        plain(s0, s1, SIMD3(0.55, 0.22, 0.16))
        plain(SIMD3(s0.x - 0.4, 4.5, s0.z - 0.4), SIMD3(s1.x + 0.4, 5.2, s1.z + 0.4), SIMD3(0.3, 0.26, 0.22))
    }
}

extension WestTerrain {
    /// Towns (their buildings, signs, lamps and fixtures) and the railroad, for a chunk: kept for every loaded chunk.
    func westNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        let origin = SIMD3(ox, 0, oz)
        var mesh = WestTownMesh(origin: origin)
        let mid = SIMD2(ox + chunkSize / 2, oz + chunkSize / 2)
        for t in WestLayout.towns(near: mid, radius: chunkSize) {
            // Each town is built by the chunk its street's middle falls in.
            guard t.center.x >= ox, t.center.x < ox + chunkSize, t.center.y >= oz, t.center.y < oz + chunkSize else { continue }
            mesh.add(WestTown.plan(t))
        }
        var out: [SCNNode] = []
        func node(_ name: String, _ m: MeshBuilder, _ mat: SCNMaterial, shadow: Bool, hide: Float?) {
            guard !m.isEmpty else { return }
            let g = m.geometry()
            g.materials = [mat]
            if let h = hide { g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: CGFloat(h))] }
            let n = SCNNode(geometry: g)
            n.name = name
            n.castsShadow = shadow
            out.append(n)
        }
        node("town", mesh.wood, WestTown.wood, shadow: true, hide: nil)
        node("signs", mesh.signs, WestTown.signs, shadow: false, hide: 900)
        node("town props", mesh.props, WestTerrain.townProps, shadow: true, hide: 1100)
        node("lamps", mesh.glow, WestTerrain.lampGlow, shadow: false, hide: 900)
        for (w, at) in mesh.wheels where !w.isEmpty {
            let g = w.geometry()
            g.materials = [WestTerrain.townProps]
            let n = SCNNode(geometry: g)
            n.simdPosition = at
            n.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 4.5)))
            n.castsShadow = true
            out.append(n)
        }
        out += railNodes(key: key, ox: ox, oz: oz)
        out += WestMine.nodes(key: key, ox: ox, oz: oz, self)
        return out
    }

    /// Close-up: the ties under the rails, barrels and crates, wagons.
    func westDetailNodes(key: ChunkKey, ox: Float, oz: Float) -> [SCNNode] {
        railDetailNodes(key: key, ox: ox, oz: oz)
    }

    static let townProps = WorldMaterials.vertexColor(rough: 0.8)
    static let lampGlow = WorldMaterials.glow(2.4)
}
