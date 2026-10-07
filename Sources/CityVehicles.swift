import SceneKit
import simd

/// Car, taxi, bus and truck shapes for Skyline City, built once and stamped into the traffic mesh (and the parked cars
/// in the chunk meshes). Local space: forward = -Z, up = +Y, the wheels touch y = 0. Pure white vertices are the paint,
/// replaced per car. uv.x is the finish (see `WorldMaterials.finishes`): 0 matte, 1 paint, 2 glass, 3 chrome, 4 glowing.
enum CarKind: Int, CaseIterable {
    case sedan, compact, suv, taxi, van, bus, truck, police

    /// How often each appears in traffic.
    static let mix: [(CarKind, Float)] = [(.sedan, 0.3), (.compact, 0.16), (.suv, 0.17), (.taxi, 0.13), (.van, 0.07),
                                          (.bus, 0.06), (.truck, 0.06), (.police, 0.02)]
    var length: Float { [4.6, 3.9, 4.8, 4.6, 5.2, 12, 8.5, 4.7][rawValue] }
    var width: Float { [1.82, 1.72, 1.95, 1.82, 2.0, 2.55, 2.45, 1.85][rawValue] }
    var height: Float { [1.45, 1.42, 1.75, 1.45, 2.3, 3.15, 3.4, 1.5][rawValue] }
    var cruise: Float { self == .bus || self == .truck ? 0.82 : (self == .police ? 1.2 : 1) }
}

enum CityVehicles {
    static let paints: [SIMD3<Float>] = [
        SIMD3(0.92, 0.92, 0.92), SIMD3(0.08, 0.08, 0.09), SIMD3(0.62, 0.64, 0.67), SIMD3(0.70, 0.08, 0.08),
        SIMD3(0.10, 0.22, 0.55), SIMD3(0.30, 0.33, 0.36), SIMD3(0.12, 0.30, 0.18), SIMD3(0.78, 0.70, 0.55),
        SIMD3(0.20, 0.45, 0.75), SIMD3(0.85, 0.45, 0.10), SIMD3(0.45, 0.10, 0.16), SIMD3(0.95, 0.80, 0.20),
    ]
    static let busPaints: [SIMD3<Float>] = [SIMD3(0.12, 0.35, 0.75), SIMD3(0.75, 0.12, 0.12), SIMD3(0.15, 0.55, 0.30), SIMD3(0.92, 0.92, 0.9)]
    static let taxiYellow = SIMD3<Float>(1.0, 0.76, 0.05)

    private static let white = SIMD3<Float>(1, 1, 1)
    private static let glassC = SIMD3<Float>(0.06, 0.08, 0.1)
    private static let trim = SIMD3<Float>(0.06, 0.06, 0.065)
    private static let chrome = SIMD3<Float>(0.75, 0.76, 0.78)
    private static let paint = SIMD2<Float>(1, 0), glassUV = SIMD2<Float>(2, 0), matte = SIMD2<Float>(0, 0), chromeUV = SIMD2<Float>(3, 0)

    /// A box with chamfered vertical edges (car bodies). y from y0 to y1.
    static func chamferBox(_ m: inout MeshBuilder, hx: Float, z0: Float, z1: Float, y0: Float, y1: Float, ch: Float,
                           _ col: SIMD3<Float>, uv: SIMD2<Float>, top: SIMD3<Float>? = nil) {
        let fp: [SIMD2<Float>] = [SIMD2(-hx + ch, z0), SIMD2(hx - ch, z0), SIMD2(hx, z0 + ch), SIMD2(hx, z1 - ch),
                                  SIMD2(hx - ch, z1), SIMD2(-hx + ch, z1), SIMD2(-hx, z1 - ch), SIMD2(-hx, z0 + ch)]
        for k in 0..<fp.count {
            let a = fp[k], b = fp[(k + 1) % fp.count]
            m.quad(SIMD3(b.x, y0, b.y), SIMD3(a.x, y0, a.y), SIMD3(a.x, y1, a.y), SIMD3(b.x, y1, b.y), col, uv: uv)
        }
        let c = m.vertexCount
        let tc = top ?? col
        m.vertex(SIMD3(0, y1, (z0 + z1) / 2), kUp, tc, uv: uv)
        for p in fp { m.vertex(SIMD3(p.x, y1, p.y), kUp, tc, uv: uv) }
        for k in 0..<UInt32(fp.count) { m.tri(c, c + 1 + (k + 1) % UInt32(fp.count), c + 1 + k) }
    }

    /// The glass "greenhouse": a trapezoid prism from y0 (bottom footprint) to y1 (roof).
    static func cabin(_ m: inout MeshBuilder, wb: Float, zb0: Float, zb1: Float, wt: Float, zt0: Float, zt1: Float, y0: Float, y1: Float,
                      roof: SIMD3<Float>) {
        let b0 = SIMD3(-wb, y0, zb0), b1 = SIMD3(wb, y0, zb0), b2 = SIMD3(wb, y0, zb1), b3 = SIMD3(-wb, y0, zb1)
        let t0 = SIMD3(-wt, y1, zt0), t1 = SIMD3(wt, y1, zt0), t2 = SIMD3(wt, y1, zt1), t3 = SIMD3(-wt, y1, zt1)
        m.quad(b0, b1, t1, t0, glassC, uv: glassUV, facing: SIMD3(0, 0.3, -1))     // windshield (front, -z)
        m.quad(b2, b3, t3, t2, glassC, uv: glassUV, facing: SIMD3(0, 0.3, 1))      // rear window
        m.quad(b1, b2, t2, t1, glassC, uv: glassUV, facing: SIMD3(1, 0, 0))        // right side
        m.quad(b3, b0, t0, t3, glassC, uv: glassUV, facing: SIMD3(-1, 0, 0))       // left side
        m.quad(t0, t1, t2, t3, roof, uv: paint, facing: kUp)                      // roof
        // Pillars between the side windows, in the body colour.
        let midB = (zb0 + zb1) * 0.5, midT = (zt0 + zt1) * 0.5
        for s: Float in [-1, 1] {
            let o = s * 0.012
            m.quad(SIMD3(s * wb + o, y0, midB - 0.06), SIMD3(s * wb + o, y0, midB + 0.06), SIMD3(s * wt + o, y1, midT + 0.06),
                   SIMD3(s * wt + o, y1, midT - 0.06), roof, uv: paint, facing: SIMD3(s, 0, 0))
        }
    }

    static func wheels(_ m: inout MeshBuilder, hx: Float, zs: [Float], r: Float = 0.33, w: Float = 0.24) {
        for z in zs {
            for s: Float in [-1, 1] {
                let c = SIMD3(s * (hx - w * 0.3), r, z)
                // A short cylinder along x.
                m.tube(c - SIMD3(w / 2, 0, 0), c + SIMD3(w / 2, 0, 0), r0: r, r1: r, sides: 8, trim, cap: false)
                let cap = c + SIMD3(s * w / 2, 0, 0)
                m.cylinderX(cap, r: r * 0.55, s: s, chrome, uv: chromeUV)
            }
        }
    }

    /// Body (paint = white), glass, trim and wheels. Lights come separately.
    static func body(_ kind: CarKind) -> MeshBuilder {
        var m = MeshBuilder()
        let hx = kind.width / 2, L = kind.length
        switch kind {
        case .sedan, .taxi, .police, .compact:
            let compact = kind == .compact
            let z0 = -L / 2, z1 = L / 2
            chamferBox(&m, hx: hx, z0: z0, z1: z1, y0: 0.28, y1: 0.86, ch: 0.28, white, uv: paint)
            // Hood and trunk slope a touch: a thin wedge on the front.
            cabin(&m, wb: hx - 0.08, zb0: z0 + (compact ? 1.0 : 1.35), zb1: z1 - (compact ? 0.5 : 0.95), wt: hx - 0.24,
                  zt0: z0 + (compact ? 1.65 : 2.05), zt1: z1 - (compact ? 0.8 : 1.45), y0: 0.86, y1: kind.height, roof: white)
            // Bumpers and grille
            m.box(SIMD3(0, 0.42, z0 + 0.04), SIMD3(hx - 0.1, 0.12, 0.06), trim, uv: matte)
            m.box(SIMD3(0, 0.42, z1 - 0.04), SIMD3(hx - 0.1, 0.12, 0.06), trim, uv: matte)
            wheels(&m, hx: hx, zs: [z0 + (compact ? 0.75 : 0.85), z1 - (compact ? 0.7 : 0.85)])
            if kind == .taxi {
                m.box(SIMD3(0, kind.height + 0.12, 0.25), SIMD3(0.32, 0.12, 0.12), SIMD3(1, 0.98, 0.9), uv: SIMD2(4, 0))
                // Checker stripe along the doors.
                for k in 0..<10 {
                    let z = -1.2 + Float(k) * 0.26
                    for s: Float in [-1, 1] where k % 2 == 0 {
                        m.quad(SIMD3(s * (hx + 0.005), 0.66, z + (s > 0 ? 0.26 : 0)), SIMD3(s * (hx + 0.005), 0.66, z + (s > 0 ? 0 : 0.26)),
                               SIMD3(s * (hx + 0.005), 0.78, z + (s > 0 ? 0 : 0.26)), SIMD3(s * (hx + 0.005), 0.78, z + (s > 0 ? 0.26 : 0)),
                               trim, uv: matte, facing: SIMD3(s, 0, 0))
                    }
                }
            }
            if kind == .police {
                // Black doors on the white car, and a light bar (lit by the lights mesh).
                for s: Float in [-1, 1] {
                    m.quad(SIMD3(s * (hx + 0.005), 0.3, s > 0 ? 0.9 : -1.1), SIMD3(s * (hx + 0.005), 0.3, s > 0 ? -1.1 : 0.9),
                           SIMD3(s * (hx + 0.005), 0.85, s > 0 ? -1.1 : 0.9), SIMD3(s * (hx + 0.005), 0.85, s > 0 ? 0.9 : -1.1), trim, uv: paint, facing: SIMD3(s, 0, 0))
                }
                m.box(SIMD3(0, kind.height + 0.08, -0.1), SIMD3(0.62, 0.08, 0.16), trim, uv: matte)
            }
        case .suv:
            let z0 = -L / 2, z1 = L / 2
            chamferBox(&m, hx: hx, z0: z0, z1: z1, y0: 0.36, y1: 1.05, ch: 0.25, white, uv: paint)
            cabin(&m, wb: hx - 0.06, zb0: z0 + 1.2, zb1: z1 - 0.25, wt: hx - 0.16, zt0: z0 + 1.6, zt1: z1 - 0.35, y0: 1.05, y1: kind.height,
                  roof: white)
            m.box(SIMD3(0, 0.5, z0 + 0.04), SIMD3(hx - 0.08, 0.15, 0.07), trim, uv: matte)
            m.box(SIMD3(0, 0.5, z1 - 0.04), SIMD3(hx - 0.08, 0.15, 0.07), trim, uv: matte)
            // Roof rails
            for s: Float in [-1, 1] { m.box(SIMD3(s * (hx - 0.3), kind.height + 0.05, 0.4), SIMD3(0.04, 0.05, 1.1), trim, uv: matte) }
            wheels(&m, hx: hx, zs: [z0 + 0.95, z1 - 0.95], r: 0.38)
        case .van:
            let z0 = -L / 2, z1 = L / 2
            chamferBox(&m, hx: hx, z0: z0 + 0.6, z1: z1, y0: 0.35, y1: kind.height, ch: 0.2, white, uv: paint)
            chamferBox(&m, hx: hx - 0.02, z0: z0, z1: z0 + 0.7, y0: 0.35, y1: 1.05, ch: 0.25, white, uv: paint)
            m.quad(SIMD3(-hx + 0.1, 1.08, z0 + 0.6), SIMD3(hx - 0.1, 1.08, z0 + 0.6), SIMD3(hx - 0.12, kind.height - 0.15, z0 + 0.75),
                   SIMD3(-hx + 0.12, kind.height - 0.15, z0 + 0.75), glassC, uv: glassUV, facing: SIMD3(0, 0.2, -1))
            for s: Float in [-1, 1] {
                m.quad(SIMD3(s * (hx + 0.01), 1.2, s > 0 ? z0 + 1.9 : z0 + 0.75), SIMD3(s * (hx + 0.01), 1.2, s > 0 ? z0 + 0.75 : z0 + 1.9),
                       SIMD3(s * (hx + 0.01), 1.95, s > 0 ? z0 + 0.75 : z0 + 1.9), SIMD3(s * (hx + 0.01), 1.95, s > 0 ? z0 + 1.9 : z0 + 0.75),
                       glassC, uv: glassUV, facing: SIMD3(s, 0, 0))
            }
            wheels(&m, hx: hx, zs: [z0 + 0.95, z1 - 0.9], r: 0.36)
        case .bus:
            let z0 = -L / 2, z1 = L / 2
            chamferBox(&m, hx: hx, z0: z0, z1: z1, y0: 0.35, y1: kind.height, ch: 0.25, white, uv: paint, top: SIMD3(0.85, 0.85, 0.85))
            // Window band down both sides, windshield and rear window.
            for s: Float in [-1, 1] {
                let x = s * (hx + 0.01)
                m.quad(SIMD3(x, 1.35, s > 0 ? z1 - 0.8 : z0 + 0.4), SIMD3(x, 1.35, s > 0 ? z0 + 0.4 : z1 - 0.8),
                       SIMD3(x, 2.65, s > 0 ? z0 + 0.4 : z1 - 0.8), SIMD3(x, 2.65, s > 0 ? z1 - 0.8 : z0 + 0.4), glassC, uv: glassUV, facing: SIMD3(s, 0, 0))
                // Pillars
                var z = z0 + 1.6
                while z < z1 - 1 {
                    m.quad(SIMD3(x * 1.001, 1.35, z + (s > 0 ? 0.08 : -0.08)), SIMD3(x * 1.001, 1.35, z + (s > 0 ? -0.08 : 0.08)),
                           SIMD3(x * 1.001, 2.65, z + (s > 0 ? -0.08 : 0.08)), SIMD3(x * 1.001, 2.65, z + (s > 0 ? 0.08 : -0.08)), white, uv: paint, facing: SIMD3(s, 0, 0))
                    z += 1.5
                }
            }
            m.quad(SIMD3(-hx + 0.15, 1.0, z0 - 0.01), SIMD3(hx - 0.15, 1.0, z0 - 0.01), SIMD3(hx - 0.15, 2.7, z0 - 0.01),
                   SIMD3(-hx + 0.15, 2.7, z0 - 0.01), glassC, uv: glassUV, facing: SIMD3(0, 0, -1))
            m.quad(SIMD3(hx - 0.25, 1.6, z1 + 0.01), SIMD3(-hx + 0.25, 1.6, z1 + 0.01), SIMD3(-hx + 0.25, 2.6, z1 + 0.01),
                   SIMD3(hx - 0.25, 2.6, z1 + 0.01), glassC, uv: glassUV, facing: SIMD3(0, 0, 1))
            // Destination sign
            m.quad(SIMD3(-hx + 0.4, 2.78, z0 - 0.02), SIMD3(hx - 0.4, 2.78, z0 - 0.02), SIMD3(hx - 0.4, 3.0, z0 - 0.02),
                   SIMD3(-hx + 0.4, 3.0, z0 - 0.02), SIMD3(1, 0.62, 0.1), uv: SIMD2(4, 0), facing: SIMD3(0, 0, -1))
            // Roof unit
            m.box(SIMD3(0, kind.height + 0.15, 1.5), SIMD3(0.8, 0.15, 1.2), SIMD3(0.8, 0.8, 0.8), uv: matte)
            wheels(&m, hx: hx, zs: [z0 + 2.3, z1 - 2.6], r: 0.5, w: 0.3)
        case .truck:
            let z0 = -L / 2, z1 = L / 2
            // Cab (paint) and a box (white panel with a stripe).
            chamferBox(&m, hx: hx - 0.05, z0: z0, z1: z0 + 2.2, y0: 0.45, y1: 2.6, ch: 0.25, white, uv: paint)
            m.quad(SIMD3(-hx + 0.2, 1.6, z0 - 0.01), SIMD3(hx - 0.2, 1.6, z0 - 0.01), SIMD3(hx - 0.25, 2.4, z0 - 0.01),
                   SIMD3(-hx + 0.25, 2.4, z0 - 0.01), glassC, uv: glassUV, facing: SIMD3(0, 0, -1))
            m.box(SIMD3(0, 2.05, z0 + 2.3 + (L - 2.4) / 2), SIMD3(hx, 1.35, (L - 2.4) / 2), SIMD3(0.92, 0.92, 0.9), uv: matte)
            for s: Float in [-1, 1] {
                m.quad(SIMD3(s * (hx + 0.01), 1.4, s > 0 ? z1 - 0.2 : z0 + 2.6), SIMD3(s * (hx + 0.01), 1.4, s > 0 ? z0 + 2.6 : z1 - 0.2),
                       SIMD3(s * (hx + 0.01), 1.75, s > 0 ? z0 + 2.6 : z1 - 0.2), SIMD3(s * (hx + 0.01), 1.75, s > 0 ? z1 - 0.2 : z0 + 2.6),
                       white, uv: paint, facing: SIMD3(s, 0, 0))
            }
            wheels(&m, hx: hx, zs: [z0 + 1.1, z1 - 2.2, z1 - 1.1], r: 0.5, w: 0.32)
        }
        return m
    }

    /// A cheap version for cars far away: the body and the glass, no wheels or trim.
    static func simpleBody(_ kind: CarKind) -> MeshBuilder {
        var m = MeshBuilder()
        let hx = kind.width / 2, L = kind.length
        switch kind {
        case .bus, .van:
            chamferBox(&m, hx: hx, z0: -L / 2, z1: L / 2, y0: 0.2, y1: kind.height, ch: 0.3, white, uv: paint)
        case .truck:
            chamferBox(&m, hx: hx, z0: -L / 2, z1: -L / 2 + 2.2, y0: 0.2, y1: 2.6, ch: 0.3, white, uv: paint)
            m.box(SIMD3(0, 2.0, -L / 2 + 2.3 + (L - 2.4) / 2), SIMD3(hx, 1.4, (L - 2.4) / 2), SIMD3(0.92, 0.92, 0.9), uv: matte)
        default:
            let suv = kind == .suv
            chamferBox(&m, hx: hx, z0: -L / 2, z1: L / 2, y0: 0.2, y1: suv ? 1.05 : 0.86, ch: 0.3, white, uv: paint)
            m.box(SIMD3(0, (suv ? 1.05 : 0.86) + (kind.height - (suv ? 1.05 : 0.86)) / 2, 0.1),
                  SIMD3(hx - 0.15, (kind.height - (suv ? 1.05 : 0.86)) / 2, L * 0.24), glassC, uv: glassUV, topColor: white)
        }
        return m
    }

    /// Head and tail lights (glow mesh): white/amber at the front, red at the back.
    static func lights(_ kind: CarKind) -> (head: MeshBuilder, tail: MeshBuilder) {
        var h = MeshBuilder(), t = MeshBuilder()
        let hx = kind.width / 2, L = kind.length
        let y: Float = kind == .bus ? 0.75 : (kind == .truck ? 0.8 : (kind == .suv ? 0.85 : 0.68))
        let w: Float = kind == .bus ? 0.32 : 0.26
        for s: Float in [-1, 1] {
            let x = s * (hx - 0.32)
            h.quad(SIMD3(x - w / 2, y - 0.07, -L / 2 - 0.02), SIMD3(x + w / 2, y - 0.07, -L / 2 - 0.02), SIMD3(x + w / 2, y + 0.07, -L / 2 - 0.02),
                   SIMD3(x - w / 2, y + 0.07, -L / 2 - 0.02), SIMD3(1, 0.96, 0.85), facing: SIMD3(0, 0, -1))
            t.quad(SIMD3(x + w / 2, y - 0.07, L / 2 + 0.02), SIMD3(x - w / 2, y - 0.07, L / 2 + 0.02), SIMD3(x - w / 2, y + 0.08, L / 2 + 0.02),
                   SIMD3(x + w / 2, y + 0.08, L / 2 + 0.02), SIMD3(1, 0.1, 0.06), facing: SIMD3(0, 0, 1))
        }
        return (h, t)
    }

    /// The two halves of a police light bar (flashed alternately).
    static let policeRed: MeshTemplate = {
        var m = MeshBuilder()
        m.box(SIMD3(-0.33, CarKind.police.height + 0.2, -0.1), SIMD3(0.27, 0.07, 0.14), SIMD3(1, 0.1, 0.1))
        return MeshTemplate(m)
    }()
    static let policeBlue: MeshTemplate = {
        var m = MeshBuilder()
        m.box(SIMD3(0.33, CarKind.police.height + 0.2, -0.1), SIMD3(0.27, 0.07, 0.14), SIMD3(0.15, 0.35, 1))
        return MeshTemplate(m)
    }()
}

extension MeshBuilder {
    /// A flat disc facing ±x (hubcaps).
    mutating func cylinderX(_ c: SIMD3<Float>, r: Float, s: Float, _ col: SIMD3<Float>, uv: SIMD2<Float>) {
        let n = SIMD3<Float>(s, 0, 0)
        let ci = vertexCount
        vertex(c + n * 0.01, n, col, uv: uv)
        for k in 0...8 {
            let a = Float(k) / 8 * 2 * .pi
            vertex(c + n * 0.01 + SIMD3(0, sin(a) * r, cos(a) * r), n, col, uv: uv)
        }
        for k in 0..<UInt32(8) { if s > 0 { tri(ci, ci + 2 + k, ci + 1 + k) } else { tri(ci, ci + 1 + k, ci + 2 + k) } }
    }
}
