import SceneKit
import Metal
import simd

// Shared building blocks for the 0.4 worlds (Skyline City, Dino Valley, Wild West): integer hashes that match the
// shaders, a batched mesh that's rewritten every frame (hundreds of cars or walkers in one draw call), mesh templates
// and a few solid primitives with texture coordinates.

// MARK: - Hashes

/// Integer hash (the same arithmetic is used in the Metal shaders, so CPU and GPU agree on layouts).
@inline(__always) func ihash(_ a: Int, _ b: Int, _ salt: UInt32 = 0) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: a) &* 0x8DA6_B343
    h ^= UInt32(truncatingIfNeeded: b) &* 0xD816_3841
    h ^= salt &* 0xCB1A_B31F
    h ^= h >> 16; h = h &* 0x7FEB_352D
    h ^= h >> 15; h = h &* 0x846C_A68B
    h ^= h >> 16
    return h
}

/// 0…1 from a hash.
@inline(__always) func hfloat(_ a: Int, _ b: Int, _ salt: UInt32 = 0) -> Float { Float(ihash(a, b, salt) >> 8) / 16_777_216 }

/// Floor division / modulo that work for negative numbers.
@inline(__always) func fdiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
@inline(__always) func fmodi(_ a: Int, _ b: Int) -> Int { let m = a % b; return m < 0 ? m + b : m }

// MARK: - Mesh templates

/// A small mesh kept on the CPU (linear vertex colours) that a `DynamicMesh` stamps out many times a frame.
struct MeshTemplate {
    var pos: [SIMD3<Float>] = []
    var nrm: [SIMD3<Float>] = []
    var col: [SIMD3<Float>] = []
    var uv: [SIMD2<Float>] = []
    var idx: [UInt32] = []

    init() {}
    /// From a MeshBuilder (its colours are already linear).
    init(_ m: MeshBuilder) {
        let n = m.pos.count / 3
        pos.reserveCapacity(n); nrm.reserveCapacity(n); col.reserveCapacity(n); uv.reserveCapacity(n)
        for i in 0..<n {
            pos.append(SIMD3(m.pos[i * 3], m.pos[i * 3 + 1], m.pos[i * 3 + 2]))
            nrm.append(SIMD3(m.nrm[i * 3], m.nrm[i * 3 + 1], m.nrm[i * 3 + 2]))
            col.append(SIMD3(m.col[i * 3], m.col[i * 3 + 1], m.col[i * 3 + 2]))
            uv.append(SIMD2(m.uv[i * 2], m.uv[i * 2 + 1]))
        }
        idx = m.idx
    }
    var vertexCount: Int { pos.count }
    var triangleCount: Int { idx.count / 3 }
    var isEmpty: Bool { idx.isEmpty }
}

// MARK: - Dynamic mesh

/// One geometry whose vertices the CPU rewrites every frame: draw lots of moving things (traffic, crowds, flocks) in a
/// single draw call. Triple-buffered so the GPU never reads a buffer while it's being written.
final class DynamicMesh {
    let node = SCNNode()
    let maxVertices: Int
    let maxTriangles: Int
    private struct BufferSet {
        let pos: MTLBuffer, nrm: MTLBuffer, col: MTLBuffer, uv: MTLBuffer, idx: MTLBuffer
        let geometry: SCNGeometry
        let element: SCNGeometryElement
    }
    private var sets: [BufferSet] = []
    private var current = 0
    private var pPos: UnsafeMutablePointer<Float>!
    private var pNrm: UnsafeMutablePointer<Float>!
    private var pCol: UnsafeMutablePointer<Float>!
    private var pUV: UnsafeMutablePointer<Float>!
    private var pIdx: UnsafeMutablePointer<UInt32>!
    private(set) var vertexCount = 0
    private(set) var indexCount = 0
    private var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    /// Instances that didn't fit this frame (tests watch this).
    private(set) var dropped = 0

    init?(maxVertices: Int, maxTriangles: Int, material: SCNMaterial, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.maxVertices = maxVertices
        self.maxTriangles = maxTriangles
        for _ in 0..<3 {
            guard let pos = device.makeBuffer(length: maxVertices * 12, options: .storageModeShared),
                  let nrm = device.makeBuffer(length: maxVertices * 12, options: .storageModeShared),
                  let col = device.makeBuffer(length: maxVertices * 12, options: .storageModeShared),
                  let uv = device.makeBuffer(length: maxVertices * 8, options: .storageModeShared),
                  let idx = device.makeBuffer(length: maxTriangles * 12, options: .storageModeShared) else { return nil }
            memset(idx.contents(), 0, idx.length)
            memset(pos.contents(), 0, pos.length)
            let sources = [
                SCNGeometrySource(buffer: pos, vertexFormat: .float3, semantic: .vertex, vertexCount: maxVertices, dataOffset: 0, dataStride: 12),
                SCNGeometrySource(buffer: nrm, vertexFormat: .float3, semantic: .normal, vertexCount: maxVertices, dataOffset: 0, dataStride: 12),
                SCNGeometrySource(buffer: col, vertexFormat: .float3, semantic: .color, vertexCount: maxVertices, dataOffset: 0, dataStride: 12),
                SCNGeometrySource(buffer: uv, vertexFormat: .float2, semantic: .texcoord, vertexCount: maxVertices, dataOffset: 0, dataStride: 8),
            ]
            let el = SCNGeometryElement(buffer: idx, primitiveType: .triangles, primitiveCount: maxTriangles, bytesPerIndex: 4)
            el.primitiveRange = NSRange(location: 0, length: 0)
            let g = SCNGeometry(sources: sources, elements: [el])
            g.materials = [material]
            sets.append(BufferSet(pos: pos, nrm: nrm, col: col, uv: uv, idx: idx, geometry: g, element: el))
        }
        node.geometry = sets[0].geometry
        bind()
    }

    private func bind() {
        let s = sets[current]
        pPos = s.pos.contents().assumingMemoryBound(to: Float.self)
        pNrm = s.nrm.contents().assumingMemoryBound(to: Float.self)
        pCol = s.col.contents().assumingMemoryBound(to: Float.self)
        pUV = s.uv.contents().assumingMemoryBound(to: Float.self)
        pIdx = s.idx.contents().assumingMemoryBound(to: UInt32.self)
    }

    /// Start a frame: switch to the next buffer set and forget last frame's instances.
    func begin() {
        current = (current + 1) % sets.count
        bind()
        vertexCount = 0
        indexCount = 0
        dropped = 0
        lo = SIMD3(repeating: .greatestFiniteMagnitude)
        hi = SIMD3(repeating: -.greatestFiniteMagnitude)
    }

    func canFit(_ t: MeshTemplate) -> Bool {
        vertexCount + t.vertexCount <= maxVertices && indexCount + t.idx.count <= maxTriangles * 3
    }

    /// Stamp a template with a rigid transform (rotation + translation, optional uniform scale) and an optional
    /// colour multiplier / override for vertices whose colour is pure white in the template (`paint`).
    func add(_ t: MeshTemplate, _ m: simd_float4x4, paint: SIMD3<Float>? = nil, tint: Float = 1) {
        guard canFit(t) else { dropped += 1; return }
        let base = UInt32(vertexCount)
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let tr = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var v = vertexCount * 3
        var w = vertexCount * 2
        for i in 0..<t.pos.count {
            let p = r * t.pos[i] + tr
            let n = simd_normalize(r * t.nrm[i])
            pPos[v] = p.x; pPos[v + 1] = p.y; pPos[v + 2] = p.z
            pNrm[v] = n.x; pNrm[v + 1] = n.y; pNrm[v + 2] = n.z
            var c = t.col[i]
            if let paint, c.x > 0.99 && c.y > 0.99 && c.z > 0.99 { c = paint }
            c *= tint
            pCol[v] = c.x; pCol[v + 1] = c.y; pCol[v + 2] = c.z
            pUV[w] = t.uv[i].x; pUV[w + 1] = t.uv[i].y
            lo = simd_min(lo, p); hi = simd_max(hi, p)
            v += 3; w += 2
        }
        vertexCount += t.pos.count
        for k in 0..<t.idx.count { pIdx[indexCount + k] = t.idx[k] &+ base }
        indexCount += t.idx.count
    }

    /// Finish the frame: draw what was added.
    func end() {
        let s = sets[current]
        s.element.primitiveRange = NSRange(location: 0, length: indexCount / 3)
        if indexCount > 0 {
            s.geometry.boundingBox = (SCNVector3(lo - 1), SCNVector3(hi + 1))
        }
        if node.geometry !== s.geometry { node.geometry = s.geometry }
    }
}

extension SCNVector3 {
    init(_ v: SIMD3<Float>) { self.init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)) }
}

// MARK: - Transforms

@inline(__always) func trs(_ p: SIMD3<Float>, _ q: simd_quatf, _ s: Float = 1) -> simd_float4x4 {
    var m = simd_float4x4(q)
    if s != 1 { m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s; m.columns.0.w = 0; m.columns.1.w = 0; m.columns.2.w = 0 }
    m.columns.3 = SIMD4(p, 1)
    return m
}

@inline(__always) func yawQuat(_ yaw: Float) -> simd_quatf { simd_quatf(angle: yaw, axis: kUp) }

// MARK: - Solid primitives (with texture coordinates, for templates and chunk meshes)

extension MeshBuilder {
    /// A quad a b c d (counter-clockwise from the front) with its own normal and uvs. With `facing`, the winding is
    /// flipped if needed so the front faces that way.
    mutating func quadUV(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD3<Float>,
                         _ ua: SIMD2<Float>, _ ub: SIMD2<Float>, _ uc: SIMD2<Float>, _ ud: SIMD2<Float>, facing: SIMD3<Float>? = nil) {
        var n = simd_cross(b - a, d - a)
        let l = simd_length(n)
        guard l > 1e-7 else { return }
        n /= l
        if let facing, simd_dot(n, facing) < 0 {
            quadUV(a, d, c, b, col, ua, ud, uc, ub)
            return
        }
        let i = vertexCount
        vertex(a, n, col, uv: ua); vertex(b, n, col, uv: ub); vertex(c, n, col, uv: uc); vertex(d, n, col, uv: ud)
        tri(i, i + 1, i + 2); tri(i, i + 2, i + 3)
    }

    /// A quad with a colour per corner (baked lighting that changes across it).
    mutating func quadColors(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                             _ ca: SIMD3<Float>, _ cb: SIMD3<Float>, _ cc: SIMD3<Float>, _ cd: SIMD3<Float>,
                             uv: SIMD2<Float> = .zero, facing: SIMD3<Float>? = nil) {
        var n = simd_cross(b - a, d - a)
        let l = simd_length(n)
        guard l > 1e-7 else { return }
        n /= l
        if let facing, simd_dot(n, facing) < 0 {
            quadColors(a, d, c, b, ca, cd, cc, cb, uv: uv)
            return
        }
        let i = vertexCount
        vertex(a, n, ca, uv: uv); vertex(b, n, cb, uv: uv); vertex(c, n, cc, uv: uv); vertex(d, n, cd, uv: uv)
        tri(i, i + 1, i + 2); tri(i, i + 2, i + 3)
    }

    /// Flat-coloured quad, uv = (0,0) unless given.
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD3<Float>, uv: SIMD2<Float> = .zero,
                       facing: SIMD3<Float>? = nil) {
        quadUV(a, b, c, d, col, uv, uv, uv, uv, facing: facing)
    }

    /// An oriented box: centre, half sizes, rotation. `top`/`bottom` = false leaves those faces out.
    mutating func box(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ col: SIMD3<Float>, rot: simd_quatf = simd_quatf(angle: 0, axis: kUp),
                      top: Bool = true, bottom: Bool = false, sideShade: Float = 1, uv: SIMD2<Float> = .zero, topColor: SIMD3<Float>? = nil) {
        func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { c + rot.act(SIMD3(x * h.x, y * h.y, z * h.z)) }
        let s = col * sideShade
        quad(P(-1, -1, 1), P(1, -1, 1), P(1, 1, 1), P(-1, 1, 1), s, uv: uv)       // +z
        quad(P(1, -1, -1), P(-1, -1, -1), P(-1, 1, -1), P(1, 1, -1), s, uv: uv)   // -z
        quad(P(1, -1, 1), P(1, -1, -1), P(1, 1, -1), P(1, 1, 1), col * (sideShade * 0.94), uv: uv)  // +x
        quad(P(-1, -1, -1), P(-1, -1, 1), P(-1, 1, 1), P(-1, 1, -1), col * (sideShade * 0.94), uv: uv)  // -x
        if top { quad(P(-1, 1, 1), P(1, 1, 1), P(1, 1, -1), P(-1, 1, -1), topColor ?? col, uv: uv) }
        if bottom { quad(P(-1, -1, -1), P(1, -1, -1), P(1, -1, 1), P(-1, -1, 1), col * 0.7, uv: uv) }
    }

    /// Axis-aligned box from two corners.
    mutating func boxAA(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ col: SIMD3<Float>, top: Bool = true, bottom: Bool = false,
                        uv: SIMD2<Float> = .zero, topColor: SIMD3<Float>? = nil) {
        box((lo + hi) * 0.5, (hi - lo) * 0.5, col, top: top, bottom: bottom, uv: uv, topColor: topColor)
    }

    /// A vertical cylinder / cone frustum with smooth sides from y0 to y1.
    mutating func cylinder(_ c: SIMD3<Float>, r0: Float, r1: Float, y0: Float, y1: Float, sides: Int, _ col: SIMD3<Float>,
                           top: Bool = true, uv: SIMD2<Float> = .zero, topColor: SIMD3<Float>? = nil, yaw: Float = 0) {
        let slope = (r0 - r1) / max(y1 - y0, 1e-3)
        let base = vertexCount
        for k in 0...sides {
            let a = yaw + Float(k) / Float(sides) * 2 * .pi
            let d = SIMD3(cos(a), 0, sin(a))
            let n = simd_normalize(SIMD3(d.x, slope, d.z))
            vertex(c + d * r0 + SIMD3(0, y0, 0), n, col, uv: uv)
            vertex(c + d * r1 + SIMD3(0, y1, 0), n, col, uv: uv)
        }
        for k in 0..<UInt32(sides) {
            let a = base + k * 2
            tri(a, a + 1, a + 2); tri(a + 1, a + 3, a + 2)
        }
        if top && r1 > 1e-4 {
            let ci = vertexCount
            let tc = topColor ?? col
            vertex(c + SIMD3(0, y1, 0), kUp, tc, uv: uv)
            for k in 0...sides {
                let a = yaw + Float(k) / Float(sides) * 2 * .pi
                vertex(c + SIMD3(cos(a) * r1, y1, sin(a) * r1), kUp, tc, uv: uv)
            }
            for k in 0..<UInt32(sides) { tri(ci, ci + 2 + k, ci + 1 + k) }
        }
    }

    /// An ellipsoid (lat-long), for bodies and heads.
    mutating func ellipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, _ col: SIMD3<Float>, rings: Int = 5, sides: Int = 8,
                            rot: simd_quatf = simd_quatf(angle: 0, axis: kUp), uv: SIMD2<Float> = .zero,
                            shade: ((SIMD3<Float>) -> SIMD3<Float>)? = nil) {
        let base = vertexCount
        for i in 0...rings {
            let th = Float(i) / Float(rings) * .pi
            for k in 0...sides {
                let ph = Float(k) / Float(sides) * 2 * .pi
                let unit = SIMD3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
                let p = c + rot.act(unit * r)
                let n = simd_normalize(rot.act(unit / r))
                vertex(p, n, shade?(unit) ?? col, uv: uv)
            }
        }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(rings) {
            for k in 0..<UInt32(sides) {
                let a = base + i * row + k, b = a + row
                tri(a, a + 1, b); tri(a + 1, b + 1, b)
            }
        }
    }

    /// A tapered tube between two points (legs, poles, necks) with smooth sides; `col1` grades the colour towards `b`.
    mutating func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r0: Float, r1: Float, sides: Int, _ col: SIMD3<Float>,
                       uv: SIMD2<Float> = .zero, cap: Bool = false, col1: SIMD3<Float>? = nil) {
        let colB = col1 ?? col
        let axis = b - a
        let len = simd_length(axis)
        guard len > 1e-5 else { return }
        let d = axis / len
        var side = simd_cross(d, abs(d.y) < 0.95 ? kUp : SIMD3(1, 0, 0))
        side = simd_normalize(side)
        let up = simd_cross(side, d)
        let slope = (r0 - r1) / len
        let base = vertexCount
        for k in 0...sides {
            let ang = Float(k) / Float(sides) * 2 * .pi
            let rd = side * cos(ang) + up * sin(ang)
            let n = simd_normalize(rd + d * slope)
            vertex(a + rd * r0, n, col, uv: uv)
            vertex(b + rd * r1, n, colB, uv: uv)
        }
        for k in 0..<UInt32(sides) {
            let i = base + k * 2
            tri(i, i + 1, i + 2); tri(i + 1, i + 3, i + 2)
        }
        if cap && r1 > 1e-4 {
            let ci = vertexCount
            vertex(b, d, colB, uv: uv)
            for k in 0...sides {
                let ang = Float(k) / Float(sides) * 2 * .pi
                vertex(b + (side * cos(ang) + up * sin(ang)) * r1, d, colB, uv: uv)
            }
            for k in 0..<UInt32(sides) { tri(ci, ci + 2 + k, ci + 1 + k) }
        }
    }

    /// Append another builder's geometry, transformed.
    mutating func append(_ o: MeshBuilder, _ m: simd_float4x4 = matrix_identity_float4x4) {
        let base = vertexCount
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let n = o.pos.count / 3
        pos.reserveCapacity(pos.count + n * 3)
        for i in 0..<n {
            let p = r * SIMD3(o.pos[i * 3], o.pos[i * 3 + 1], o.pos[i * 3 + 2]) + t
            let q = simd_normalize(r * SIMD3(o.nrm[i * 3], o.nrm[i * 3 + 1], o.nrm[i * 3 + 2]))
            pos += [p.x, p.y, p.z]; nrm += [q.x, q.y, q.z]
            col += [o.col[i * 3], o.col[i * 3 + 1], o.col[i * 3 + 2]]
            uv += [o.uv[i * 2], o.uv[i * 2 + 1]]
        }
        idx += o.idx.map { $0 + base }
    }

    /// Recolour vertices whose (linear) colour is pure white with `c` (sRGB) — for painting shared shapes.
    mutating func paintWhite(_ c: SIMD3<Float>) {
        let lin = SIMD3(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2))
        for i in stride(from: 0, to: col.count, by: 3) where col[i] > 0.99 && col[i + 1] > 0.99 && col[i + 2] > 0.99 {
            col[i] = lin.x; col[i + 1] = lin.y; col[i + 2] = lin.z
        }
    }
}

// MARK: - Materials

enum WorldMaterials {
    /// Plain vertex-coloured PBR (props, vehicles, creatures). `gloss` lowers the roughness.
    static func vertexColor(rough: CGFloat = 0.8, metal: CGFloat = 0, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor.white
        m.roughness.contents = rough
        m.metalness.contents = metal
        m.isDoubleSided = doubleSided
        return m
    }

    /// Vertex-coloured PBR where uv.x picks the finish: 0 matte, 1 glossy paint, 2 glass, 3 chrome, 4 glowing.
    static func finishes() -> SCNMaterial {
        let m = vertexColor(rough: 0.8)
        m.diffuse.contents = whitePixel
        m.shaderModifiers = [.surface: """
        #pragma body
        float k = _surface.diffuseTexcoord.x;
        if (k > 0.5 && k < 1.5) { _surface.roughness = 0.28; _surface.metalness = 0.25; }
        else if (k > 1.5 && k < 2.5) { _surface.roughness = 0.06; _surface.metalness = 0.85; }
        else if (k > 2.5 && k < 3.5) { _surface.roughness = 0.12; _surface.metalness = 1.0; }
        else if (k > 3.5) { _surface.emission = float4(_surface.diffuse.rgb * 1.7, 1.0); }
        """]
        return m
    }

    /// Unlit glow (vertex colour × intensity), blooms when bright.
    static func glow(_ intensity: CGFloat = 2.2) -> SCNMaterial {
        let g = SCNMaterial()
        g.lightingModel = .constant
        g.diffuse.contents = NSColor.white
        g.diffuse.intensity = intensity
        return g
    }

    /// A 2×2 white texture: materials need a texture for SceneKit to hand texture coordinates to shader modifiers.
    static let whitePixel: CGImage = makeImage(width: 2, height: 2) { _, _ in SIMD4(1, 1, 1, 1) }
}

/// Text on a sign board, as an image (saloon signs, shop signs, billboards).
func signImage(_ text: String, width: CGFloat = 512, height: CGFloat = 128, background: NSColor, color: NSColor,
               font: NSFont? = nil, border: NSColor? = nil, kern: CGFloat = 2) -> NSImage {
    NSImage(size: NSSize(width: width, height: height), flipped: false) { r in
        background.setFill()
        NSBezierPath(rect: r).fill()
        if let border {
            border.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 7, dy: 7))
            p.lineWidth = 6
            p.stroke()
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let f = font ?? NSFont(name: "Georgia-Bold", size: height * 0.58) ?? NSFont.boldSystemFont(ofSize: height * 0.58)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para, .kern: kern]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(in: NSRect(x: r.minX, y: r.midY - size.height / 2 - height * 0.02, width: r.width, height: size.height))
        return true
    }
}

// MARK: - Bumping into things

enum Collide {
    /// After the bird's been pushed out of something along `n`: skid along a top (following its slope), duck under a
    /// ceiling, or turn to slide along a wall. Returns how hard it hit (m/s into the surface).
    static func response(_ flight: FlightModel, _ n: SIMD3<Float>) -> Float {
        let v = flight.velocity
        if n.y > 0.7 {
            let slope = atan(-(n.x * -sin(flight.yaw) + n.z * -cos(flight.yaw)) / n.y)
            let into = max(0, -simd_dot(v, n))
            if flight.pitch < slope + 0.08 {
                flight.pitch = max(flight.pitch, slope + 0.12)
                flight.speed *= into > 6 ? 0.75 : 0.985
            }
            return into
        }
        if n.y < -0.7 {
            flight.pitch = min(flight.pitch, -0.1)
            return max(0, v.y)
        }
        let flatN = simd_normalize(SIMD2(n.x, n.z))
        var fwd = SIMD2(flight.forward.x, flight.forward.z)
        if simd_length(fwd) < 1e-3 { fwd = -flatN }
        fwd = simd_normalize(fwd)
        let dot = simd_dot(fwd, flatN)
        let into = max(0, -dot) * flight.speed
        if dot < 0 {
            var slide = fwd - flatN * dot * 1.3
            if simd_length(slide) < 0.05 { slide = SIMD2(-flatN.y, flatN.x) }
            slide = simd_normalize(slide)
            flight.yaw = atan2(-slide.x, -slide.y)
            flight.speed *= into > 6 ? 0.82 : 0.97
        }
        return into
    }

    /// Push a sphere out of a capsule; returns the push (nil if not touching).
    @inline(__always) static func capsule(_ p: SIMD3<Float>, _ r: Float, a: SIMD3<Float>, b: SIMD3<Float>, radius: Float) -> SIMD3<Float>? {
        let ab = b - a
        let t = simd_clamp(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-6), 0, 1)
        let q = a + ab * t
        let d = p - q
        let l = simd_length(d)
        let need = radius + r
        guard l < need else { return nil }
        let n = l > 1e-4 ? d / l : SIMD3<Float>(0, 1, 0)
        return n * (need - l)
    }
}
