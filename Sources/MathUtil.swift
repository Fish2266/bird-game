import Foundation
import simd

// MARK: - Scalar helpers

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
/// Frame-rate independent exponential approach factor.
@inline(__always) func approach(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }
@inline(__always) func wrapAngle(_ a: Float) -> Float {
    var x = a
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}

// MARK: - RNG

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func float(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * float() }
}

// MARK: - Perlin noise

enum Noise {
    private static let perm: UnsafeMutablePointer<Int32> = {
        var p = (0..<256).map { Int32($0) }
        var rng = SplitMix64(seed: 90210)
        p.shuffle(using: &rng)
        let ptr = UnsafeMutablePointer<Int32>.allocate(capacity: 512)
        for i in 0..<512 { ptr[i] = p[i & 255] }
        return ptr
    }()

    @inline(__always) private static func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
    @inline(__always) private static func grad(_ h: Int32, _ x: Float, _ y: Float) -> Float {
        switch h & 7 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x
        case 5: return -x
        case 6: return y
        default: return -y
        }
    }

    /// Classic 2D Perlin noise, roughly in [-1, 1].
    static func perlin(_ x: Float, _ y: Float) -> Float {
        let xf = floor(x), yf = floor(y)
        let xi = Int(Int32(truncatingIfNeeded: Int(xf)) & 255)
        let yi = Int(Int32(truncatingIfNeeded: Int(yf)) & 255)
        let x0 = x - xf, y0 = y - yf
        let u = fade(x0), v = fade(y0)
        let p = perm
        let aa = p[Int(p[xi]) + yi], ab = p[Int(p[xi]) + yi + 1]
        let ba = p[Int(p[xi + 1]) + yi], bb = p[Int(p[xi + 1]) + yi + 1]
        let x1 = lerp(grad(aa, x0, y0), grad(ba, x0 - 1, y0), u)
        let x2 = lerp(grad(ab, x0, y0 - 1), grad(bb, x0 - 1, y0 - 1), u)
        return lerp(x1, x2, v)
    }

    static func fbm(_ x: Float, _ y: Float, octaves: Int, lacunarity: Float = 2.03, gain: Float = 0.5) -> Float {
        var sum: Float = 0, amp: Float = 1, freq: Float = 1, norm: Float = 0
        for i in 0..<octaves {
            let o = Float(i) * 17.31
            sum += perlin(x * freq + o, y * freq - o) * amp
            norm += amp
            amp *= gain
            freq *= lacunarity
        }
        return sum / norm
    }

    /// Ridged multifractal in [0, 1] — sharp mountain crests.
    static func ridged(_ x: Float, _ y: Float, octaves: Int) -> Float {
        var sum: Float = 0, amp: Float = 0.5, freq: Float = 1, weight: Float = 1, norm: Float = 0
        for i in 0..<octaves {
            let o = Float(i) * 31.7
            var n = 1 - abs(perlin(x * freq + o, y * freq + o))
            n *= n
            n *= weight
            weight = clamp(n * 1.6, 0, 1)
            sum += n * amp
            norm += amp
            amp *= 0.5
            freq *= 2.1
        }
        return sum / norm
    }
}

// MARK: - One Euro filter (low-latency jitter removal for pose keypoints)

struct OneEuroFilter {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float = 1.0
    private var x: Float?
    private var dx: Float = 0
    private var lastT: Double = 0

    init(minCutoff: Float, beta: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func alpha(_ dt: Float, _ cutoff: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() { x = nil; dx = 0 }

    mutating func filter(_ v: Float, t: Double) -> Float {
        guard let prev = x else { x = v; lastT = t; dx = 0; return v }
        let dt = Float(max(t - lastT, 1.0 / 240.0))
        lastT = t
        let d = (v - prev) / dt
        dx += alpha(dt, dCutoff) * (d - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + alpha(dt, cutoff) * (v - prev)
        x = out
        return out
    }
}

// MARK: - Quaternion helpers

extension simd_quatf {
    static func axis(_ angle: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: angle, axis: axis) }
}

let kUp = SIMD3<Float>(0, 1, 0)

/// The app's version, read from Info.plist (CFBundleShortVersionString) so the UI always matches the build.
enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var display: String { "Version \(short)" + (build.map { " (\($0))" } ?? "") }
}
