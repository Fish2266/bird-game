import SceneKit
import simd

/// The city never ends: past the loaded chunks, a ring of hazy skyline silhouettes stands on a flat "far ground", both
/// following the bird, so the horizon is more city instead of open water.
final class CityHorizon {
    let node = SCNNode()
    private let ring: SCNNode
    private let ground: SCNNode
    static let radius: Float = 2350

    init() {
        let h: CGFloat = 520
        let cyl = SCNCylinder(radius: CGFloat(CityHorizon.radius), height: h)
        cyl.radialSegmentCount = 96
        cyl.heightSegmentCount = 1
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = CityHorizon.texture()
        m.diffuse.wrapS = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 1, 1)
        m.diffuse.mipFilter = .linear
        m.cullMode = .front
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        let clear = SCNMaterial()
        clear.transparency = 0
        clear.writesToDepthBuffer = false
        cyl.materials = [m, clear, clear]
        ring = SCNNode(geometry: cyl)
        ring.simdPosition = SIMD3(0, Float(h) / 2 - 2, 0)
        ring.castsShadow = false
        ring.renderingOrder = -5
        node.addChildNode(ring)
        // A flat annulus a little under street level, hidden under the loaded city but covering the water beyond it.
        var b = MeshBuilder()
        let n = 72, r0: Float = 1600, r1 = CityHorizon.radius + 50
        for k in 0...n {
            let a = Float(k) / Float(n) * 2 * .pi
            let d = SIMD3(cos(a), 0, sin(a))
            b.vertex(d * r0, kUp, SIMD3(1, 1, 1), uv: SIMD2(d.x * r0, d.z * r0) / CityHorizon.tile)
            b.vertex(d * r1, kUp, SIMD3(1, 1, 1), uv: SIMD2(d.x * r1, d.z * r1) / CityHorizon.tile)
        }
        for k in 0..<UInt32(n) {
            let i = k * 2
            b.tri(i, i + 2, i + 1); b.tri(i + 1, i + 2, i + 3)
        }
        let g = b.geometry()
        let gm = WorldMaterials.vertexColor(rough: 0.95)
        gm.diffuse.contents = CityHorizon.blocksTexture()
        gm.diffuse.wrapS = .repeat
        gm.diffuse.wrapT = .repeat
        gm.diffuse.mipFilter = .linear
        g.materials = [gm]
        ground = SCNNode(geometry: g)
        ground.simdPosition = SIMD3(0, 10.5, 0)
        ground.castsShadow = false
        node.addChildNode(ground)
    }

    /// One texture tile: four blocks by four.
    static let tile: Float = CityLayout.pitch * 4

    func follow(_ p: SIMD3<Float>) {
        // Snapped to whole tiles so the painted streets line up with the real ones.
        let t = CityHorizon.tile
        node.simdPosition = SIMD3((p.x / t).rounded() * t, 0, (p.z / t).rounded() * t)
    }

    /// The city seen from far above: streets on the grid lines and blocks of roofs in many colours.
    private static func blocksTexture() -> CGImage {
        let n = 512
        let px = Float(n) / 4          // pixels per block pitch
        var rng = SplitMix64(seed: 77)
        let roofs: [SIMD3<Float>] = [SIMD3(0.46, 0.46, 0.47), SIMD3(0.55, 0.53, 0.50), SIMD3(0.36, 0.37, 0.39), SIMD3(0.52, 0.32, 0.26),
                                     SIMD3(0.60, 0.58, 0.55), SIMD3(0.30, 0.32, 0.36), SIMD3(0.44, 0.50, 0.58), SIMD3(0.32, 0.42, 0.24)]
        var cells: [[SIMD3<Float>]] = []
        for _ in 0..<64 { cells.append((0..<16).map { _ in roofs[Int(rng.float(0, 7.99))] * rng.float(0.85, 1.12) }) }
        return makeImage(width: n, height: n) { x, y in
            let fx = Float(x) / px, fy = Float(y) / px
            let lx = fx - fx.rounded(), ly = fy - fy.rounded()   // distance to the nearest street line, in blocks
            let street = abs(lx) < 0.09 || abs(ly) < 0.09
            if street { return SIMD4(0.24, 0.24, 0.25, 1) }
            if abs(lx) < 0.12 || abs(ly) < 0.12 { return SIMD4(0.5, 0.5, 0.49, 1) }
            let bx = Int(floor(fx)) & 3, by = Int(floor(fy)) & 3
            let block = cells[(by * 4 + bx) % 64]
            let sx = Int((fx - floor(fx)) * 4) & 3, sy = Int((fy - floor(fy)) * 4) & 3
            let c = block[sy * 4 + sx]
            return SIMD4(c, 1)
        }
    }

    /// Skyline silhouettes: towers in clusters (downtowns) over a carpet of low blocks, with a few lit windows.
    private static func texture() -> CGImage {
        let w = 2048, h = 256
        var rng = SplitMix64(seed: 2026)
        var heights = [Float](repeating: 0, count: w)
        var shade = [Float](repeating: 0, count: w)
        var x = 0
        while x < w {
            let width = Int(rng.float(8, 26))
            let cluster = max(0, sin(Float(x) / Float(w) * 2 * .pi * 2 + 1.3) * sin(Float(x) / Float(w) * 2 * .pi * 5 + 0.4))
            var hgt = rng.float(10, 30)
            if rng.float() < 0.12 + 0.6 * cluster { hgt = rng.float(28, 50 + 110 * cluster) }
            let s = rng.float(0.8, 1.1)
            for k in x..<min(w, x + width) { heights[k] = hgt; shade[k] = s }
            x += width
        }
        let groundRows: Float = 18
        return makeImage(width: w, height: h) { px, py in
            let fromBottom = Float(h - 1 - py)
            if fromBottom < groundRows { return SIMD4(0.40, 0.40, 0.41, 1) }
            let top = heights[px] + groundRows
            guard fromBottom < top else { return SIMD4(0, 0, 0, 0) }
            var c = SIMD3<Float>(0.40, 0.42, 0.48) * shade[px]
            // A faint warm sunlit edge and sparse windows.
            if fromBottom > top - 2 { c *= 1.12 }
            if (px % 3 == 0) && (Int(fromBottom) % 4 == 1) && hfloat(px, Int(fromBottom), 77) > 0.86 { c = simd_mix(c, SIMD3(1, 0.86, 0.6), SIMD3(repeating: 0.5)) }
            return SIMD4(c, 1)
        }
    }
}
