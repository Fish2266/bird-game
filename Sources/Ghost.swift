import SceneKit
import simd

/// A recorded race: the bird's pose 10 times a second plus the time at each gate.
struct GhostRun {
    static let rate: Float = 10
    /// Per sample: position (3), orientation quaternion (4), wing elevation L/R, fold.
    var samples: [Float] = []
    var splits: [Double] = []
    var bird = "gull"
    static let stride = 10

    var duration: Float { Float(samples.count / GhostRun.stride) / GhostRun.rate }

    mutating func record(pos: SIMD3<Float>, rot: simd_quatf, wings: SIMD3<Float>) {
        let v = rot.vector
        samples += [pos.x, pos.y, pos.z, v.x, v.y, v.z, v.w, wings.x, wings.y, wings.z]
    }

    /// Interpolated pose at time `t` (seconds since the start).
    func pose(at t: Float) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>)? {
        let n = samples.count / GhostRun.stride
        guard n > 1 else { return nil }
        let f = clamp(t * GhostRun.rate, 0, Float(n - 1))
        let i = min(Int(f), n - 2), k = f - Float(i)
        func at(_ j: Int, _ o: Int) -> Float { samples[j * GhostRun.stride + o] }
        let p0 = SIMD3(at(i, 0), at(i, 1), at(i, 2)), p1 = SIMD3(at(i + 1, 0), at(i + 1, 1), at(i + 1, 2))
        let q0 = simd_quatf(vector: SIMD4(at(i, 3), at(i, 4), at(i, 5), at(i, 6)))
        let q1 = simd_quatf(vector: SIMD4(at(i + 1, 3), at(i + 1, 4), at(i + 1, 5), at(i + 1, 6)))
        let w0 = SIMD3(at(i, 7), at(i, 8), at(i, 9)), w1 = SIMD3(at(i + 1, 7), at(i + 1, 8), at(i + 1, 9))
        return (p0 + (p1 - p0) * k, simd_slerp(q0, q1, k), w0 + (w1 - w0) * k)
    }

    // Binary format: "GHS1", bird id (length-prefixed), split count, splits (Float64), sample count, samples (Float32).
    func encoded() -> Data {
        var d = Data("GHS1".utf8)
        let b = Data(bird.utf8)
        var n = UInt32(b.count); d.append(Data(bytes: &n, count: 4)); d.append(b)
        var sc = UInt32(splits.count); d.append(Data(bytes: &sc, count: 4))
        for var s in splits { d.append(Data(bytes: &s, count: 8)) }
        var c = UInt32(samples.count); d.append(Data(bytes: &c, count: 4))
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    init() {}

    init?(data: Data) {
        guard data.count > 8, data.prefix(4) == Data("GHS1".utf8) else { return nil }
        var o = 4
        func u32() -> Int? {
            guard o + 4 <= data.count else { return nil }
            let v = data.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            o += 4
            return Int(v)
        }
        guard let bl = u32(), o + bl <= data.count else { return nil }
        bird = String(decoding: data.subdata(in: o..<(o + bl)), as: UTF8.self); o += bl
        guard let sc = u32(), o + sc * 8 <= data.count else { return nil }
        for _ in 0..<sc {
            splits.append(data.subdata(in: o..<(o + 8)).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }); o += 8
        }
        guard let c = u32(), o + c * 4 <= data.count else { return nil }
        samples = data.subdata(in: o..<(o + c * 4)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Best-run ghosts saved in Application Support.
enum Ghosts {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BirdGame/ghosts", isDirectory: true)
    }
    private static func url(_ mode: GameMode, _ world: WorldID) -> URL { dir.appendingPathComponent("\(mode.rawValue)-\(world.rawValue).ghost") }

    static func load(_ mode: GameMode, _ world: WorldID) -> GhostRun? {
        guard let d = try? Data(contentsOf: url(mode, world)) else { return nil }
        return GhostRun(data: d)
    }

    static func save(_ run: GhostRun, _ mode: GameMode, _ world: WorldID) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? run.encoded().write(to: url(mode, world))
    }

    static func deleteAll() { try? FileManager.default.removeItem(at: dir) }
}

/// A see-through bird replaying the best run.
final class GhostBird {
    let run: GhostRun
    let bird: BirdNode
    init(run: GhostRun) {
        self.run = run
        bird = BirdNode(look: Catalog.species(run.bird).look)
        bird.node.opacity = 0.38
        bird.node.enumerateHierarchy { n, _ in
            n.castsShadow = false
            n.geometry?.materials.forEach { $0.writesToDepthBuffer = false; $0.emission.contents = NSColor(white: 0.35, alpha: 1) }
        }
        bird.node.renderingOrder = 30
    }

    func update(time: Float, dt: Float) {
        guard let (p, q, w) = run.pose(at: time) else { bird.node.isHidden = true; return }
        bird.node.isHidden = time > run.duration + 1
        bird.node.simdPosition = p
        bird.node.simdOrientation = q
        bird.pose(left: WingPose(elevation: w.x, bend: 0), right: WingPose(elevation: w.y, bend: 0), fold: w.z,
                  pitchIn: 0, rollIn: 0, dt: dt)
    }
}
