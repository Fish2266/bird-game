import SceneKit
import simd

// Creatures as a hierarchy of rigid bones, each carrying a small mesh, posed every frame on the CPU and stamped into
// one dynamic mesh (all the dinosaurs in a couple of draw calls). Meshes are built in each bone's own frame: the joint
// at the origin, −z forward, +y up, +x to the creature's right.

struct RigBone {
    var parent: Int
    /// Where the joint sits in the parent bone's frame (rest pose).
    var offset: SIMD3<Float>
    /// Rest rotation relative to the parent (the pose's rotation is applied after it).
    var rest: simd_quatf
}

/// A body plan: bones, and a near and a far mesh per bone.
final class Rig {
    var bones: [RigBone] = []
    var near: [MeshTemplate] = []
    var far: [MeshTemplate] = []
    var names: [String: Int] = [:]

    @discardableResult
    func add(_ name: String, parent: Int, at offset: SIMD3<Float>, rest: simd_quatf = simd_quatf(angle: 0, axis: kUp),
             near n: MeshBuilder = MeshBuilder(), far f: MeshBuilder? = nil) -> Int {
        bones.append(RigBone(parent: parent, offset: offset, rest: rest))
        near.append(MeshTemplate(n))
        far.append(MeshTemplate(f ?? MeshBuilder()))
        names[name] = bones.count - 1
        return bones.count - 1
    }

    subscript(_ name: String) -> Int { names[name] ?? -1 }

    var nearVertices: Int { near.reduce(0) { $0 + $1.vertexCount } }
    var farVertices: Int { far.reduce(0) { $0 + $1.vertexCount } }

    /// World matrices of every bone for a root transform and per-bone pose rotations.
    func solve(root: simd_float4x4, pose: [simd_quatf], into out: inout [simd_float4x4]) {
        if out.count != bones.count { out = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count) }
        for i in 0..<bones.count {
            let b = bones[i]
            var local = simd_float4x4(b.rest * pose[i])
            local.columns.3 = SIMD4(b.offset, 1)
            out[i] = b.parent < 0 ? root * local : out[b.parent] * local
        }
    }

    /// `paint` recolours the parts that are pure white in the mesh (a horse's coat).
    func draw(_ mats: [simd_float4x4], into mesh: DynamicMesh, far useFar: Bool, tint: Float = 1, paint: SIMD3<Float>? = nil) {
        let t = useFar ? far : near
        for i in 0..<mats.count where !t[i].isEmpty { mesh.add(t[i], mats[i], paint: paint, tint: tint) }
    }
}

extension simd_float4x4 {
    @inline(__always) func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    @inline(__always) func vector(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p, 0)
        return SIMD3(v.x, v.y, v.z)
    }
    var origin: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}

@inline(__always) func rotX(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }
@inline(__always) func rotY(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
@inline(__always) func rotZ(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 0, 1)) }

// MARK: - Organic shapes

/// A creature's skin: colour on the back, on the belly, and how it's patterned.
struct Skin {
    var back: SIMD3<Float>
    var belly: SIMD3<Float>
    /// Darker stripes or blotches across the back (0 = none).
    var stripes: Float = 0
    var stripeColor = SIMD3<Float>(0, 0, 0)
    var stripeFreq: Float = 1.6
    var seed: Float = 0

    func color(along s: Float, up: Float, side: Float) -> SIMD3<Float> {
        // Countershading: dark back, pale belly.
        var c = simd_mix(belly, back, SIMD3(repeating: smoothstep(-0.45, 0.35, up)))
        if stripes > 0 {
            let band = sin(s * stripeFreq * 2 * .pi + seed + side * 0.6) * 0.5 + 0.5
            let k = smoothstep(0.62, 0.85, band) * stripes * smoothstep(-0.1, 0.5, up)
            c = simd_mix(c, stripeColor, SIMD3(repeating: k))
        }
        return c
    }
}

extension MeshBuilder {
    /// A smooth body through `pts` with elliptical cross-sections (`radii` = half-width, half-height), shaded with a
    /// skin. `s0` offsets the pattern so neighbouring pieces line up. Ends are capped when `capStart`/`capEnd`.
    mutating func loft(_ pts: [SIMD3<Float>], _ radii: [SIMD2<Float>], skin: Skin, sides: Int, s0: Float = 0,
                       capStart: Bool = true, capEnd: Bool = true, drop: [Float]? = nil) {
        let n = pts.count
        guard n >= 2 else { return }
        // Frames carried along the curve (parallel transport), so a section never flips over and twists the skin.
        var frames: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        var prevRight: SIMD3<Float>?
        for i in 0..<n {
            let t = simd_normalize(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
            var right: SIMD3<Float>
            if let pr = prevRight {
                right = pr - t * simd_dot(pr, t)
                if simd_length(right) < 1e-4 { right = pr }
            } else {
                right = simd_cross(t, kUp)
                if simd_length(right) < 1e-3 { right = SIMD3(1, 0, 0) - t * t.x }
            }
            right = simd_normalize(right)
            prevRight = right
            let up = simd_normalize(simd_cross(right, t))
            frames.append((t, right, up))
        }
        var along: [Float] = [s0]
        for i in 1..<n { along.append(along[i - 1] + simd_distance(pts[i], pts[i - 1])) }
        let base = vertexCount
        for i in 0..<n {
            let (_, right, up) = frames[i]
            let r = radii[i]
            let dy = drop?[i] ?? 0
            for k in 0...sides {
                let a = Float(k) / Float(sides) * 2 * .pi
                let cx = sin(a), cy = cos(a)
                // Flatter belly: the lower half sags a little less round.
                let yy = cy < 0 ? cy * (1 - 0.12) - dy * cy * cy : cy
                let p = pts[i] + right * (cx * r.x) + up * (yy * r.y)
                let nrm = simd_normalize(right * (cx / max(r.x, 1e-3)) + up * (yy / max(r.y, 1e-3)))
                vertex(p, nrm, skin.color(along: along[i], up: cy, side: cx))
            }
        }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(n - 1) {
            for k in 0..<UInt32(sides) {
                let a = base + i * row + k, b = a + row
                tri(a, a + 1, b); tri(a + 1, b + 1, b)
            }
        }
        func cap(_ i: Int, _ dir: Float) {
            let (t, _, _) = frames[i]
            let c = vertexCount
            let col = skin.color(along: along[i], up: 0, side: 0)
            vertex(pts[i] + t * dir * min(radii[i].x, radii[i].y) * 0.35, t * dir, col)
            let ring = base + UInt32(i) * row
            for k in 0..<UInt32(sides) {
                if dir > 0 { tri(c, ring + k, ring + k + 1) } else { tri(c, ring + k + 1, ring + k) }
            }
        }
        if capStart { cap(0, -1) }
        if capEnd { cap(n - 1, 1) }
    }

    /// A pointed horn, spike or claw from `a` toward `b`.
    mutating func horn(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float, _ col: SIMD3<Float>, tip: SIMD3<Float>? = nil, sides: Int = 6) {
        limb(from: a, to: b, r0: r, r1: 0, sides: sides, color: col, tipColor: tip ?? col)
    }

    /// A flat plate (stegosaur plates, frills, crests): a kite shape in the plane spanned by `up` and `fwd`, given a
    /// little thickness so it reads from both sides.
    mutating func plate(base: SIMD3<Float>, up: SIMD3<Float>, fwd: SIMD3<Float>, height h: Float, length l: Float,
                        thick: Float, _ col: SIMD3<Float>, rim: SIMD3<Float>) {
        let side = simd_normalize(simd_cross(fwd, up)) * thick
        let a = base - fwd * l * 0.5, b = base + fwd * l * 0.5, top = base + up * h + fwd * l * 0.08
        let mid0 = base + up * h * 0.55 - fwd * l * 0.42, mid1 = base + up * h * 0.55 + fwd * l * 0.38
        for s: Float in [-1, 1] {
            let o = side * s
            let n = simd_normalize(side * s)
            let i = vertexCount
            vertex(a + o * 0.5, n, col); vertex(mid0 + o, n, col * 1.05); vertex(top + o * 0.3, n, rim)
            vertex(mid1 + o, n, col * 1.05); vertex(b + o * 0.5, n, col)
            if s < 0 { tri(i, i + 1, i + 2); tri(i, i + 2, i + 3); tri(i, i + 3, i + 4) }
            else { tri(i, i + 2, i + 1); tri(i, i + 3, i + 2); tri(i, i + 4, i + 3) }
        }
    }
}
