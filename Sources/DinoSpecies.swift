import SceneKit
import simd

// The dinosaurs of Dino Valley: their bodies (bones and meshes, a near and a far version), proportions and how they
// move. Lengths are in metres; a bird is about one.

enum DinoKind: Int, CaseIterable {
    case rex, longneck, trike, stego, para, ankylo, raptor, ptero
    // The Wild West's animals share the rig.
    case horse, steer, vulture

    var name: String {
        switch self {
        case .rex: return "T. rex"
        case .longneck: return "Brachiosaurus"
        case .trike: return "Triceratops"
        case .stego: return "Stegosaurus"
        case .para: return "Parasaurolophus"
        case .ankylo: return "Ankylosaurus"
        case .raptor: return "Raptor"
        case .ptero: return "Pteranodon"
        case .horse: return "Horse"
        case .steer: return "Longhorn"
        case .vulture: return "Vulture"
        }
    }

    var plural: String {
        switch self {
        case .rex: return "T. rexes"
        case .trike, .para: return name
        case .stego, .ankylo: return name + "es"
        default: return name + "s"
        }
    }
}

/// A leg: its bones from hip to toes, when it steps in the gait cycle, and whether it's a front leg.
struct DinoLeg {
    var thigh: Int, shin: Int, foot: Int, toes: Int
    var phase: Float
    var front: Bool
    /// How far the knee folds when the foot lifts (sign: which way the joint bends).
    var knee: Float
    /// From the toes joint down to the sole.
    var sole: Float
}

/// A collision capsule riding a bone (in the bone's frame).
struct DinoCapsule {
    var bone: Int
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var r: Float
}

final class DinoSpecies {
    let kind: DinoKind
    let rig = Rig()
    var legs: [DinoLeg] = []
    var neck: [Int] = []
    var tail: [Int] = []
    var arms: [Int] = []
    var head = -1, jaw = -1, chest = -1
    var wings: [Int] = []
    /// Height of the root (pelvis) above the ground when standing.
    var hip: Float = 1
    var walk: Float = 2, run: Float = 6
    /// Turn rate (rad/s) at walking pace.
    var turn: Float = 0.8
    var stride: Float = 0.45
    var bob: Float = 0.08
    var biped = false
    /// Snout tip in the head bone's frame; tail tip in the last tail bone's frame.
    var snout = SIMD3<Float>(0, 0, -1)
    var tailTip = SIMD3<Float>(0, 0, 1)
    var capsules: [DinoCapsule] = []
    /// Rough length nose to tail, and how tall the head is when standing (for spacing, rings, the camera).
    var length: Float = 5
    var headHeight: Float = 3
    /// Total neck pitch for grazing (head down) and reaching up / roaring.
    var neckDown: Float = -0.4
    var neckUp: Float = 0.3
    var jawOpen: Float = 0.6
    var scaleRange: ClosedRange<Float> = 0.9...1.1

    init(kind: DinoKind) { self.kind = kind }

    /// Work out the standing hip height from the rest pose (feet on the ground).
    func settle() {
        var mats: [simd_float4x4] = []
        let pose = [simd_quatf](repeating: simd_quatf(angle: 0, axis: kUp), count: rig.bones.count)
        rig.solve(root: matrix_identity_float4x4, pose: pose, into: &mats)
        var lowest: Float = 0
        for l in legs { lowest = min(lowest, mats[l.toes].origin.y - l.sole) }
        if !legs.isEmpty { hip = -lowest + 0.06 }
        if head >= 0 { headHeight = mats[head].origin.y + hip }
    }

    // MARK: Shared parts

    /// Mesh pieces for both levels of detail.
    fileprivate struct Parts {
        var near = MeshBuilder()
        var far = MeshBuilder()
    }

    fileprivate func bone(_ name: String, parent: Int, at o: SIMD3<Float>, rest: simd_quatf = simd_quatf(angle: 0, axis: kUp),
                          _ build: (inout MeshBuilder, Bool) -> Void) -> Int {
        var n = MeshBuilder(), f = MeshBuilder()
        build(&n, false)
        build(&f, true)
        return rig.add(name, parent: parent, at: o, rest: rest, near: n, far: f)
    }

    fileprivate func emptyBone(_ name: String, parent: Int, at o: SIMD3<Float>, rest: simd_quatf = simd_quatf(angle: 0, axis: kUp)) -> Int {
        rig.add(name, parent: parent, at: o, rest: rest)
    }

    /// A chain of tapering segments along −z (necks) or +z (tails).
    fileprivate func chain(_ name: String, parent: Int, at o: SIMD3<Float>, lengths: [Float], radii: [SIMD2<Float>], skin: Skin,
                           rests: [Float], backward: Bool, sides: Int = 9) -> [Int] {
        var out: [Int] = []
        var p = parent
        var at = o
        var s: Float = 0
        for (k, len) in lengths.enumerated() {
            let r0 = radii[k], r1 = radii[k + 1]
            let dir: Float = backward ? 1 : -1
            let s0 = s
            let last = k == lengths.count - 1
            let b = bone("\(name)\(k)", parent: p, at: at, rest: rotX(rests[k])) { m, far in
                let pts = [SIMD3<Float>(0, 0, -dir * min(r0.y, 0.4 * len)), SIMD3(0, 0, dir * len * 0.5), SIMD3(0, 0, dir * (len + min(r1.y, len) * 0.35))]
                let rr = [r0, (r0 + r1) * 0.5, r1]
                m.loft(pts, rr, skin: skin, sides: far ? max(5, sides / 2) : sides, s0: s0, capStart: k == 0, capEnd: last)
            }
            out.append(b)
            p = b
            at = SIMD3(0, 0, dir * len)
            s += len
        }
        return out
    }

    /// A leg: thigh, shin, foot and toes, hanging along −y with rest bends at each joint.
    fileprivate func leg(_ side: String, parent: Int, at o: SIMD3<Float>, lengths: (Float, Float, Float), radii: (Float, Float, Float),
                         rests: (Float, Float, Float), skin: Skin, phase: Float, front: Bool, knee: Float, sole: Float,
                         splay: Float = 0, toes: (inout MeshBuilder, Bool) -> Void) -> DinoLeg {
        let (l0, l1, l2) = lengths, (r0, r1, r2) = radii
        // (A pure-white skin is a paintable coat: keep the legs paintable too.)
        let paintable = skin.back == SIMD3(1, 1, 1) && skin.belly == SIMD3(1, 1, 1)
        let legSkin = paintable ? skin : Skin(back: skin.back * 0.92, belly: skin.belly * 0.95, stripes: skin.stripes * 0.5, stripeColor: skin.stripeColor,
                                              stripeFreq: skin.stripeFreq * 2, seed: skin.seed)
        let t = bone("thigh\(side)", parent: parent, at: o, rest: rotX(rests.0) * rotZ(splay)) { m, far in
            m.loft([SIMD3(0, r0 * 0.6, 0), SIMD3(0, -l0 * 0.3, -r0 * 0.08), SIMD3(0, -l0 - r1 * 0.3, 0)],
                   [SIMD2(r0 * 0.95, r0 * 1.15), SIMD2(r0, r0 * 1.1), SIMD2(r1 * 1.05, r1 * 1.1)], skin: legSkin, sides: far ? 5 : 8)
        }
        let s = bone("shin\(side)", parent: t, at: SIMD3(0, -l0, 0), rest: rotX(rests.1)) { m, far in
            m.loft([SIMD3(0, r1 * 0.5, 0), SIMD3(0, -l1, 0)], [SIMD2(r1, r1 * 1.05), SIMD2(r2 * 1.1, r2 * 1.1)], skin: legSkin, sides: far ? 5 : 7)
        }
        let f = bone("foot\(side)", parent: s, at: SIMD3(0, -l1, 0), rest: rotX(rests.2)) { m, far in
            m.loft([SIMD3(0, r2 * 0.5, 0), SIMD3(0, -l2, 0)], [SIMD2(r2 * 1.05, r2 * 1.05), SIMD2(r2 * 0.9, r2 * 0.85)], skin: legSkin,
                   sides: far ? 4 : 6)
        }
        // Toes level with the ground at rest.
        let level = -(rests.0 + rests.1 + rests.2)
        let toe = bone("toes\(side)", parent: f, at: SIMD3(0, -l2, 0), rest: rotX(level)) { m, far in toes(&m, far) }
        return DinoLeg(thigh: t, shin: s, foot: f, toes: toe, phase: phase, front: front, knee: knee, sole: sole)
    }

    fileprivate static func clawToes(_ m: inout MeshBuilder, far: Bool, width: Float, length: Float, r: Float, skin: SIMD3<Float>,
                                      claw: SIMD3<Float> = SIMD3(0.18, 0.16, 0.14)) {
        for k in -1...1 {
            let x = Float(k) * width
            let a = SIMD3<Float>(x * 0.4, 0, 0), b = SIMD3(x, -r * 0.6, -length * (k == 0 ? 1 : 0.82))
            m.tube(a, b, r0: r, r1: r * 0.7, sides: far ? 3 : 5, skin)
            if !far { m.horn(b, b + SIMD3(x * 0.1, -r * 0.6, -r * 2.2), r: r * 0.6, claw, sides: 4) }
        }
    }

    fileprivate static func padFoot(_ m: inout MeshBuilder, far: Bool, r: Float, skin: SIMD3<Float>) {
        m.ellipsoid(SIMD3(0, -r * 0.35, -r * 0.15), SIMD3(r * 1.15, r * 0.45, r * 1.25), skin, rings: far ? 2 : 3, sides: far ? 6 : 9)
        if !far {
            for k in -1...1 {
                m.ellipsoid(SIMD3(Float(k) * r * 0.55, -r * 0.55, -r * 1.1), SIMD3(r * 0.22, r * 0.2, r * 0.25), SIMD3(0.3, 0.28, 0.25), rings: 2, sides: 5)
            }
        }
    }

    fileprivate static func eyes(_ m: inout MeshBuilder, at p: SIMD3<Float>, r: Float, iris: SIMD3<Float> = SIMD3(0.85, 0.65, 0.15)) {
        for s: Float in [-1, 1] {
            let c = SIMD3(p.x * s, p.y, p.z)
            m.ellipsoid(c, SIMD3(r * 0.5, r, r), SIMD3(0.08, 0.06, 0.05), rings: 3, sides: 6)
            m.ellipsoid(c + SIMD3(s * r * 0.3, 0, 0), SIMD3(r * 0.35, r * 0.6, r * 0.6), iris, rings: 2, sides: 6)
            m.ellipsoid(c + SIMD3(s * r * 0.45, 0, 0), SIMD3(r * 0.2, r * 0.45, r * 0.18), SIMD3(0.02, 0.02, 0.02), rings: 2, sides: 5)
        }
    }

    fileprivate static func teeth(_ m: inout MeshBuilder, from z0: Float, to z1: Float, y: Float, x0: Float, x1: Float, count: Int,
                                   down: Bool, size: Float) {
        for s: Float in [-1, 1] {
            for k in 0..<count {
                let t = Float(k) / Float(max(count - 1, 1))
                let z = lerp(z0, z1, t), x = lerp(x0, x1, t) * s
                let a = SIMD3(x, y, z)
                m.horn(a, a + SIMD3(0, down ? -size : size, 0), r: size * 0.32, SIMD3(0.93, 0.9, 0.78), sides: 4)
            }
        }
    }

    // MARK: Species

    static let all: [DinoKind: DinoSpecies] = {
        var d: [DinoKind: DinoSpecies] = [:]
        for k in DinoKind.allCases { d[k] = make(k) }
        return d
    }()

    static func make(_ k: DinoKind) -> DinoSpecies {
        let s = DinoSpecies(kind: k)
        switch k {
        case .rex: s.buildRex()
        case .longneck: s.buildLongneck()
        case .trike: s.buildTrike()
        case .stego: s.buildStego()
        case .para: s.buildPara()
        case .ankylo: s.buildAnkylo()
        case .raptor: s.buildRaptor()
        case .ptero: s.buildPtero()
        case .horse: s.buildHorse()
        case .steer: s.buildSteer()
        case .vulture: s.buildVulture()
        }
        s.settle()
        return s
    }

    /// A horse. Its coat is pure white in the mesh so each one can be painted its own colour when drawn.
    private func buildHorse() {
        walk = 1.7; run = 9; turn = 1.6; stride = 0.5; bob = 0.05; length = 2.6
        scaleRange = 0.95...1.05
        let coat = Skin(back: SIMD3(1, 1, 1), belly: SIMD3(1, 1, 1))
        let mane = SIMD3<Float>(0.12, 0.09, 0.07)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.12, 1.0), SIMD3(0, 0.08, 0.6), SIMD3(0, -0.02, 0), SIMD3(0, 0.04, -0.6), SIMD3(0, 0.2, -0.95)],
                   [SIMD2(0.36, 0.4), SIMD2(0.42, 0.5), SIMD2(0.4, 0.52), SIMD2(0.36, 0.5), SIMD2(0.28, 0.4)], skin: coat, sides: far ? 7 : 11)
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 0.05, -0.85))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.3, -0.12), lengths: [0.8], radii: [SIMD2(0.24, 0.34), SIMD2(0.15, 0.2)],
                     skin: coat, rests: [0.9], backward: false, sides: 9)
        // The mane along the top of the neck.
        var maneMesh = MeshBuilder()
        maneMesh.plate(base: SIMD3(0, 0.22, -0.35), up: SIMD3(0, 1, 0.15), fwd: SIMD3(0, 0, -1), height: 0.16, length: 0.8, thick: 0.05, mane, rim: mane)
        rig.near[neck[0]] = MeshTemplate(appending: rig.near[neck[0]], maneMesh)
        rig.far[neck[0]] = MeshTemplate(appending: rig.far[neck[0]], maneMesh)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.72), rest: rotX(-1.6)) { m, far in
            m.loft([SIMD3(0, 0.02, 0.08), SIMD3(0, 0, -0.3), SIMD3(0, -0.04, -0.6)], [SIMD2(0.13, 0.17), SIMD2(0.11, 0.15), SIMD2(0.08, 0.1)],
                   skin: coat, sides: far ? 6 : 9)
            for s: Float in [-1, 1] { m.horn(SIMD3(0.06 * s, 0.14, 0.02), SIMD3(0.09 * s, 0.32, 0.06), r: 0.035, mane, sides: 4) }
            m.ellipsoid(SIMD3(0, -0.05, -0.62), SIMD3(0.08, 0.07, 0.05), SIMD3(0.15, 0.12, 0.11), rings: 2, sides: 6)
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.11, 0.05, -0.12), r: 0.03, iris: SIMD3(0.2, 0.12, 0.08)) }
        }
        snout = SIMD3(0, -0.05, -0.62)
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.22, 0.98), lengths: [0.35, 0.45],
                     radii: [SIMD2(0.07, 0.08), SIMD2(0.12, 0.13), SIMD2(0.06, 0.05)], skin: Skin(back: mane, belly: mane), rests: [1.05, 0.2],
                     backward: true, sides: 6)
        let hoof: (inout MeshBuilder, Bool) -> Void = { m, far in
            m.cylinder(SIMD3(0, -0.06, -0.02), r0: 0.07, r1: 0.06, y0: -0.06, y1: 0.06, sides: far ? 5 : 7, SIMD3(0.14, 0.12, 0.1))
        }
        for (side, x, ph) in [("HL", Float(-0.2), Float(0)), ("HR", Float(0.2), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.12, 0.65), lengths: (0.55, 0.52, 0.4), radii: (0.17, 0.08, 0.055),
                            rests: (0.12, -0.42, 0.32), skin: coat, phase: ph, front: false, knee: -0.7, sole: 0.12, toes: hoof))
        }
        for (side, x, ph) in [("FL", Float(-0.19), Float(0.25)), ("FR", Float(0.19), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.22, 0.02), lengths: (0.5, 0.46, 0.38), radii: (0.14, 0.07, 0.05),
                            rests: (-0.05, 0.08, -0.04), skin: coat, phase: ph, front: true, knee: -0.6, sole: 0.12, toes: hoof))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.05, 0.9), b: SIMD3(0, 0.05, -0.9), r: 0.5),
                    DinoCapsule(bone: neck[0], a: .zero, b: SIMD3(0, 0, -0.75), r: 0.25)]
        neckDown = -1.2; neckUp = 0.25; jawOpen = 0.3
    }

    /// A longhorn: a big rangy steer with horns wider than a bird's wings. Coat painted when drawn.
    private func buildSteer() {
        walk = 1.1; run = 6; turn = 1.0; stride = 0.42; bob = 0.04; length = 2.9
        scaleRange = 0.9...1.1
        let coat = Skin(back: SIMD3(1, 1, 1), belly: SIMD3(1, 1, 1))
        let horn = SIMD3<Float>(0.9, 0.86, 0.74)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.08, 1.05), SIMD3(0, 0.05, 0.6), SIMD3(0, -0.05, 0), SIMD3(0, -0.02, -0.65), SIMD3(0, 0.12, -1.05)],
                   [SIMD2(0.42, 0.45), SIMD2(0.5, 0.56), SIMD2(0.52, 0.6), SIMD2(0.46, 0.58), SIMD2(0.34, 0.48)], skin: coat, sides: far ? 7 : 11,
                   drop: [0, 0.05, 0.1, 0.05, 0])
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 0, -0.95))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.15, -0.15), lengths: [0.45], radii: [SIMD2(0.3, 0.36), SIMD2(0.24, 0.28)],
                     skin: coat, rests: [0.15], backward: false, sides: 9)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.4), rest: rotX(-0.75)) { m, far in
            m.loft([SIMD3(0, 0.02, 0.1), SIMD3(0, -0.02, -0.25), SIMD3(0, -0.06, -0.5)], [SIMD2(0.17, 0.2), SIMD2(0.15, 0.18), SIMD2(0.12, 0.12)],
                   skin: coat, sides: far ? 6 : 9)
            m.ellipsoid(SIMD3(0, -0.07, -0.52), SIMD3(0.12, 0.09, 0.06), SIMD3(0.55, 0.38, 0.35), rings: 2, sides: 6)
            // The horns: out, forward and up, a long way.
            for s: Float in [-1, 1] {
                let a = SIMD3<Float>(0.12 * s, 0.14, 0.05)
                m.tube(a, SIMD3(0.55 * s, 0.18, 0.0), r0: 0.06, r1: 0.045, sides: 5, horn)
                m.tube(SIMD3(0.55 * s, 0.18, 0.0), SIMD3(1.0 * s, 0.32, -0.12), r0: 0.045, r1: 0.03, sides: 5, horn)
                m.horn(SIMD3(1.0 * s, 0.32, -0.12), SIMD3(1.15 * s, 0.52, -0.2), r: 0.03, horn * 0.5, sides: 4)
                m.horn(SIMD3(0.13 * s, 0.1, 0.02), SIMD3(0.26 * s, 0.12, 0.12), r: 0.05, SIMD3(0.9, 0.9, 0.9) * 0.6, sides: 4)
            }
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.15, 0.05, -0.12), r: 0.03, iris: SIMD3(0.2, 0.12, 0.08)) }
        }
        snout = SIMD3(0, -0.07, -0.55)
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.18, 1.05), lengths: [0.4, 0.35], radii: [SIMD2(0.05, 0.05), SIMD2(0.04, 0.04), SIMD2(0.07, 0.07)],
                     skin: Skin(back: SIMD3(0.2, 0.14, 0.1), belly: SIMD3(0.2, 0.14, 0.1)), rests: [1.25, 0.15], backward: true, sides: 5)
        let hoof: (inout MeshBuilder, Bool) -> Void = { m, far in
            m.cylinder(SIMD3(0, -0.06, -0.02), r0: 0.08, r1: 0.07, y0: -0.06, y1: 0.06, sides: far ? 5 : 7, SIMD3(0.16, 0.13, 0.1))
        }
        for (side, x, ph) in [("HL", Float(-0.26), Float(0)), ("HR", Float(0.26), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.18, 0.7), lengths: (0.5, 0.46, 0.3), radii: (0.2, 0.09, 0.065),
                            rests: (0.1, -0.35, 0.25), skin: coat, phase: ph, front: false, knee: -0.6, sole: 0.12, toes: hoof))
        }
        for (side, x, ph) in [("FL", Float(-0.24), Float(0.25)), ("FR", Float(0.24), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.26, 0.05), lengths: (0.46, 0.42, 0.28), radii: (0.16, 0.08, 0.06),
                            rests: (-0.05, 0.08, -0.04), skin: coat, phase: ph, front: true, knee: -0.5, sole: 0.12, toes: hoof))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0, 0.9), b: SIMD3(0, 0, -1.0), r: 0.6)]
        neckDown = -0.7; neckUp = 0.2; jawOpen = 0.3
    }

    /// A turkey vulture: dark, broad fingered wings held in a shallow V, a bald red head.
    private func buildVulture() {
        walk = 0; run = 0; length = 1.6
        let dark = SIMD3<Float>(0.2, 0.16, 0.14), pale = SIMD3<Float>(0.5, 0.46, 0.42)
        let body = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0, 0.5), SIMD3(0, 0.02, 0.1), SIMD3(0, 0.03, -0.25), SIMD3(0, 0.05, -0.42)],
                   [SIMD2(0.08, 0.06), SIMD2(0.16, 0.15), SIMD2(0.15, 0.15), SIMD2(0.09, 0.09)], skin: Skin(back: dark, belly: dark * 1.1), sides: far ? 6 : 8)
            m.plate(base: SIMD3(0, 0, 0.55), up: SIMD3(0, 0, 1), fwd: SIMD3(1, 0, 0), height: 0.35, length: 0.32, thick: 0.02, dark, rim: dark * 0.8)
        }
        neck = chain("neck", parent: body, at: SIMD3(0, 0.06, -0.4), lengths: [0.16], radii: [SIMD2(0.06, 0.06), SIMD2(0.045, 0.045)],
                     skin: Skin(back: dark, belly: dark), rests: [0.1], backward: false, sides: 6)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.14)) { m, far in
            m.loft([SIMD3(0, 0, 0.03), SIMD3(0, -0.01, -0.1), SIMD3(0, -0.03, -0.18)], [SIMD2(0.05, 0.05), SIMD2(0.04, 0.04), SIMD2(0.015, 0.02)],
                   skin: Skin(back: SIMD3(0.78, 0.28, 0.24), belly: SIMD3(0.7, 0.24, 0.2)), sides: far ? 5 : 7)
        }
        snout = SIMD3(0, -0.03, -0.18)
        for (side, s) in [("L", Float(-1)), ("R", Float(1))] {
            let inner = bone("wing\(side)", parent: body, at: SIMD3(0.1 * s, 0.05, -0.15)) { m, far in
                for face: Float in [-1, 1] {
                    let n = SIMD3<Float>(0, face, 0)
                    let i = m.vertexCount, o = SIMD3<Float>(0, face * 0.008, 0)
                    m.vertex(SIMD3(0, 0, -0.05) + o, n, dark); m.vertex(SIMD3(0.85 * s, 0.03, -0.08) + o, n, dark)
                    m.vertex(SIMD3(0.85 * s, 0.02, 0.32) + o, n, face < 0 ? pale : dark); m.vertex(SIMD3(0.05 * s, 0, 0.42) + o, n, face < 0 ? pale : dark)
                    let flip = (face > 0) != (s > 0)
                    if flip { m.tri(i, i + 1, i + 2); m.tri(i, i + 2, i + 3) } else { m.tri(i, i + 2, i + 1); m.tri(i, i + 3, i + 2) }
                }
            }
            let outer = bone("tip\(side)", parent: inner, at: SIMD3(0.85 * s, 0.03, 0)) { m, far in
                // Separate primary feathers at the tip, like fingers.
                for k in 0..<5 {
                    let z0 = -0.06 + Float(k) * 0.08
                    let tip = SIMD3((0.75 - Float(k) * 0.05) * s, 0.04 + Float(k) * 0.01, z0 - 0.04)
                    for face: Float in [-1, 1] {
                        let n = SIMD3<Float>(0, face, 0)
                        let i = m.vertexCount, o = SIMD3<Float>(0, face * 0.006, 0)
                        m.vertex(SIMD3(0, 0, z0) + o, n, dark); m.vertex(tip + o, n, dark * 0.9); m.vertex(SIMD3(0, 0, z0 + 0.09) + o, n, face < 0 ? pale : dark)
                        let flip = (face > 0) != (s > 0)
                        if flip { m.tri(i, i + 1, i + 2) } else { m.tri(i, i + 2, i + 1) }
                    }
                }
            }
            wings += [inner, outer]
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0, 0.3), b: SIMD3(0, 0, -0.3), r: 0.3)]
        headHeight = 0
        hip = 0
    }

    private func buildRex() {
        biped = true
        walk = 2.6; run = 8.5; turn = 1.1; stride = 0.42; bob = 0.12; length = 12.5
        neckDown = -0.55; neckUp = 0.65; jawOpen = 0.75
        let skin = Skin(back: SIMD3(0.36, 0.33, 0.22), belly: SIMD3(0.76, 0.68, 0.52), stripes: 0.65,
                        stripeColor: SIMD3(0.2, 0.18, 0.13), stripeFreq: 0.5, seed: 1.3)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.3, 1.8), SIMD3(0, 0.35, 0.8), SIMD3(0, 0.05, -0.4), SIMD3(0, -0.02, -1.6), SIMD3(0, 0.12, -2.6), SIMD3(0, 0.45, -3.2)],
                   [SIMD2(0.72, 0.82), SIMD2(0.95, 1.15), SIMD2(1.05, 1.32), SIMD2(0.95, 1.28), SIMD2(0.74, 1.0), SIMD2(0.6, 0.78)],
                   skin: skin, sides: far ? 8 : 14, drop: [0, 0.05, 0.12, 0.1, 0.05, 0])
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 0.15, -2.6))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.35, -0.5), lengths: [0.85, 0.75],
                     radii: [SIMD2(0.62, 0.76), SIMD2(0.56, 0.68), SIMD2(0.52, 0.6)], skin: skin, rests: [0.55, -0.85], backward: false, sides: 12)
        let skullSkin = Skin(back: skin.back, belly: SIMD3(0.62, 0.32, 0.28), stripes: 0.5, stripeColor: skin.stripeColor, stripeFreq: 1.4, seed: 0.4)
        head = bone("head", parent: neck[1], at: SIMD3(0, 0, -0.7), rest: rotX(0.22)) { m, far in
            m.loft([SIMD3(0, 0.08, 0.2), SIMD3(0, 0.1, -0.35), SIMD3(0, 0.02, -0.85), SIMD3(0, -0.06, -1.3), SIMD3(0, -0.1, -1.62)],
                   [SIMD2(0.48, 0.58), SIMD2(0.52, 0.62), SIMD2(0.42, 0.46), SIMD2(0.32, 0.33), SIMD2(0.22, 0.22)],
                   skin: skullSkin, sides: far ? 7 : 12)
            if !far {
                DinoSpecies.eyes(&m, at: SIMD3(0.4, 0.26, -0.5), r: 0.1)
                for s: Float in [-1, 1] {
                    m.ellipsoid(SIMD3(0.3 * s, 0.45, -0.52), SIMD3(0.14, 0.09, 0.26), skin.back * 0.8, rings: 2, sides: 6)
                }
                DinoSpecies.teeth(&m, from: -0.55, to: -1.5, y: -0.36, x0: 0.36, x1: 0.18, count: 6, down: true, size: 0.13)
            }
        }
        snout = SIMD3(0, -0.15, -1.65)
        let jawSkin = Skin(back: SIMD3(0.58, 0.24, 0.22), belly: skin.belly * 0.95)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.3, -0.12)) { m, far in
            m.loft([SIMD3(0, 0, 0.1), SIMD3(0, -0.08, -0.6), SIMD3(0, -0.1, -1.3)], [SIMD2(0.42, 0.24), SIMD2(0.36, 0.2), SIMD2(0.2, 0.12)],
                   skin: jawSkin, sides: far ? 6 : 10)
            if !far { DinoSpecies.teeth(&m, from: -0.5, to: -1.2, y: 0.08, x0: 0.3, x1: 0.16, count: 5, down: false, size: 0.1) }
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.3, 1.65), lengths: [1.4, 1.3, 1.2, 1.1, 1.05],
                     radii: [SIMD2(0.7, 0.8), SIMD2(0.56, 0.64), SIMD2(0.42, 0.48), SIMD2(0.3, 0.33), SIMD2(0.18, 0.2), SIMD2(0.06, 0.07)],
                     skin: skin, rests: [0.06, -0.02, -0.02, -0.02, -0.02], backward: true, sides: 11)
        tailTip = SIMD3(0, 0, 1.05)
        for (side, x, ph) in [("L", Float(-0.8), Float(0)), ("R", Float(0.8), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.15, 0.25), lengths: (1.6, 1.45, 0.95), radii: (0.55, 0.3, 0.16),
                            rests: (0.32, -0.85, 0.75), skin: skin, phase: ph, front: false, knee: -1, sole: 0.1) { m, far in
                DinoSpecies.clawToes(&m, far: far, width: 0.2, length: 0.6, r: 0.11, skin: skin.back * 0.85)
            })
            let arm = bone("arm\(side)", parent: chest, at: SIMD3(x * 0.68, -0.55, -0.15), rest: rotX(0.7) * rotZ(x > 0 ? -0.25 : 0.25)) { m, far in
                m.loft([SIMD3(0, 0.05, 0), SIMD3(0, -0.5, 0)], [SIMD2(0.13, 0.14), SIMD2(0.09, 0.09)], skin: skin, sides: far ? 4 : 6)
            }
            let fore = bone("forearm\(side)", parent: arm, at: SIMD3(0, -0.5, 0), rest: rotX(-1.1)) { m, far in
                m.loft([SIMD3(0, 0.03, 0), SIMD3(0, -0.42, 0)], [SIMD2(0.08, 0.08), SIMD2(0.06, 0.06)], skin: skin, sides: far ? 4 : 5)
                if !far {
                    for s: Float in [-1, 1] { m.horn(SIMD3(s * 0.03, -0.42, 0), SIMD3(s * 0.05, -0.62, -0.08), r: 0.03, SIMD3(0.2, 0.18, 0.15), sides: 3) }
                }
            }
            arms += [arm, fore]
        }
        capsules = [DinoCapsule(bone: pelvis, a: SIMD3(0, 0.2, 1.4), b: SIMD3(0, 0.1, -2.4), r: 1.15),
                    DinoCapsule(bone: neck[0], a: .zero, b: SIMD3(0, 0, -0.9), r: 0.65),
                    DinoCapsule(bone: head, a: SIMD3(0, 0, -0.1), b: SIMD3(0, -0.1, -1.4), r: 0.55),
                    DinoCapsule(bone: tail[0], a: .zero, b: SIMD3(0, 0, 1.3), r: 0.7),
                    DinoCapsule(bone: tail[2], a: .zero, b: SIMD3(0, 0, 1.2), r: 0.42),
                    DinoCapsule(bone: legs[0].thigh, a: SIMD3(0, 0, 0), b: SIMD3(0, -1.5, 0), r: 0.5),
                    DinoCapsule(bone: legs[1].thigh, a: SIMD3(0, 0, 0), b: SIMD3(0, -1.5, 0), r: 0.5)]
    }

    private func buildLongneck() {
        walk = 1.8; run = 4.2; turn = 0.35; stride = 0.36; bob = 0.12; length = 26
        neckDown = -1.45; neckUp = 0.32; jawOpen = 0.4
        scaleRange = 0.85...1.1
        let skin = Skin(back: SIMD3(0.37, 0.41, 0.34), belly: SIMD3(0.63, 0.62, 0.52), stripes: 0.35,
                        stripeColor: SIMD3(0.27, 0.3, 0.25), stripeFreq: 0.22, seed: 2.2)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.55, 2.7), SIMD3(0, 0.75, 1.6), SIMD3(0, 0.35, 0), SIMD3(0, 0.65, -2.0), SIMD3(0, 1.35, -3.6), SIMD3(0, 2.3, -4.6)],
                   [SIMD2(1.2, 1.35), SIMD2(1.95, 2.1), SIMD2(2.4, 2.55), SIMD2(2.3, 2.6), SIMD2(1.8, 2.2), SIMD2(1.1, 1.35)],
                   skin: skin, sides: far ? 9 : 16, drop: [0, 0.05, 0.12, 0.1, 0.04, 0])
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 1.0, -3.6))
        neck = chain("neck", parent: chest, at: SIMD3(0, 1.1, -1.0), lengths: [2.1, 2.1, 2.1, 2.0, 1.9],
                     radii: [SIMD2(1.0, 1.15), SIMD2(0.85, 0.95), SIMD2(0.72, 0.8), SIMD2(0.6, 0.66), SIMD2(0.5, 0.55), SIMD2(0.42, 0.46)],
                     skin: skin, rests: [0.95, -0.08, -0.08, -0.08, -0.08], backward: false, sides: 11)
        head = bone("head", parent: neck[4], at: SIMD3(0, 0, -1.85), rest: rotX(-0.95)) { m, far in
            m.loft([SIMD3(0, 0.05, 0.25), SIMD3(0, 0.12, -0.25), SIMD3(0, -0.02, -0.75), SIMD3(0, -0.1, -1.1)],
                   [SIMD2(0.36, 0.42), SIMD2(0.42, 0.5), SIMD2(0.32, 0.32), SIMD2(0.24, 0.2)], skin: skin, sides: far ? 6 : 11)
            m.ellipsoid(SIMD3(0, 0.42, -0.32), SIMD3(0.26, 0.24, 0.32), skin.back * 0.95, rings: far ? 2 : 4, sides: far ? 5 : 8)
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.3, 0.2, -0.25), r: 0.08, iris: SIMD3(0.45, 0.3, 0.15)) }
        }
        snout = SIMD3(0, -0.2, -1.15)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.22, -0.2)) { m, far in
            m.loft([SIMD3(0, 0, 0.1), SIMD3(0, -0.04, -0.85)], [SIMD2(0.3, 0.14), SIMD2(0.2, 0.1)], skin: Skin(back: SIMD3(0.5, 0.3, 0.28), belly: skin.belly),
                   sides: far ? 5 : 8)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.55, 2.6), lengths: [1.9, 1.8, 1.7, 1.6, 1.5, 1.5],
                     radii: [SIMD2(1.05, 1.2), SIMD2(0.85, 0.95), SIMD2(0.65, 0.72), SIMD2(0.46, 0.5), SIMD2(0.3, 0.32), SIMD2(0.16, 0.17), SIMD2(0.05, 0.05)],
                     skin: skin, rests: [0.22, -0.03, -0.04, -0.04, -0.05, -0.05], backward: true, sides: 11)
        tailTip = SIMD3(0, 0, 1.5)
        let toes: (inout MeshBuilder, Bool) -> Void = { m, far in DinoSpecies.padFoot(&m, far: far, r: 0.62, skin: skin.back * 0.8) }
        for (side, x, ph) in [("HL", Float(-1.15), Float(0)), ("HR", Float(1.15), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.4, 0.8), lengths: (2.4, 2.2, 0.5), radii: (1.0, 0.68, 0.56),
                            rests: (0.05, -0.12, 0.05), skin: skin, phase: ph, front: false, knee: -0.5, sole: 0.5, toes: toes))
        }
        for (side, x, ph) in [("FL", Float(-1.2), Float(0.25)), ("FR", Float(1.2), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.65, -0.1), lengths: (2.9, 2.6, 0.45), radii: (0.9, 0.64, 0.54),
                            rests: (-0.04, 0.1, -0.04), skin: skin, phase: ph, front: true, knee: -0.5, sole: 0.5, toes: toes))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.6, 2.2), b: SIMD3(0, 0.8, -3.6), r: 2.2),
                    DinoCapsule(bone: neck[0], a: .zero, b: SIMD3(0, 0, -2.1), r: 1.0),
                    DinoCapsule(bone: neck[1], a: .zero, b: SIMD3(0, 0, -2.1), r: 0.85),
                    DinoCapsule(bone: neck[2], a: .zero, b: SIMD3(0, 0, -2.1), r: 0.72),
                    DinoCapsule(bone: neck[3], a: .zero, b: SIMD3(0, 0, -2.0), r: 0.6),
                    DinoCapsule(bone: neck[4], a: .zero, b: SIMD3(0, 0, -1.9), r: 0.5),
                    DinoCapsule(bone: head, a: SIMD3(0, 0.1, 0), b: SIMD3(0, -0.05, -1.0), r: 0.42),
                    DinoCapsule(bone: tail[0], a: .zero, b: SIMD3(0, 0, 1.9), r: 1.05),
                    DinoCapsule(bone: tail[1], a: .zero, b: SIMD3(0, 0, 1.8), r: 0.85),
                    DinoCapsule(bone: tail[2], a: .zero, b: SIMD3(0, 0, 1.7), r: 0.65),
                    DinoCapsule(bone: tail[3], a: .zero, b: SIMD3(0, 0, 1.6), r: 0.46)]
        for l in legs { capsules.append(DinoCapsule(bone: l.thigh, a: .zero, b: SIMD3(0, -2.6, 0), r: 0.7)) }
        for l in legs { capsules.append(DinoCapsule(bone: l.shin, a: .zero, b: SIMD3(0, -2.4, 0), r: 0.5)) }
    }

    private func buildTrike() {
        walk = 1.7; run = 6.5; turn = 0.7; stride = 0.4; bob = 0.07; length = 8.5
        neckDown = -0.45; neckUp = 0.3; jawOpen = 0.45
        let skin = Skin(back: SIMD3(0.62, 0.45, 0.28), belly: SIMD3(0.84, 0.74, 0.57), stripes: 0.45,
                        stripeColor: SIMD3(0.42, 0.29, 0.19), stripeFreq: 0.7, seed: 0.7)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.28, 1.55), SIMD3(0, 0.38, 0.6), SIMD3(0, 0.02, -0.6), SIMD3(0, -0.1, -1.8), SIMD3(0, -0.15, -2.7), SIMD3(0, -0.15, -3.2)],
                   [SIMD2(0.65, 0.75), SIMD2(1.15, 1.2), SIMD2(1.35, 1.3), SIMD2(1.2, 1.18), SIMD2(0.95, 1.0), SIMD2(0.78, 0.82)],
                   skin: skin, sides: far ? 8 : 14, drop: [0, 0.06, 0.14, 0.1, 0.04, 0])
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, -0.2, -2.4))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0, -0.55), lengths: [0.75], radii: [SIMD2(0.78, 0.84), SIMD2(0.7, 0.76)],
                     skin: skin, rests: [-0.22], backward: false, sides: 12)
        let bone_ = SIMD3<Float>(0.9, 0.85, 0.72)
        let frill = SIMD3<Float>(0.78, 0.36, 0.18), spot = SIMD3<Float>(0.96, 0.84, 0.32)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.65), rest: rotX(-0.12)) { m, far in
            m.loft([SIMD3(0, 0, 0.25), SIMD3(0, -0.05, -0.5), SIMD3(0, -0.2, -1.1), SIMD3(0, -0.36, -1.55)],
                   [SIMD2(0.6, 0.66), SIMD2(0.56, 0.6), SIMD2(0.38, 0.42), SIMD2(0.18, 0.22)], skin: skin, sides: far ? 7 : 12)
            // Beak, nose horn, brow horns.
            m.horn(SIMD3(0, -0.36, -1.48), SIMD3(0, -0.66, -1.8), r: 0.16, SIMD3(0.26, 0.22, 0.2), sides: far ? 4 : 6)
            m.horn(SIMD3(0, 0.12, -1.0), SIMD3(0, 0.62, -1.25), r: 0.12, bone_, sides: far ? 4 : 6)
            for s: Float in [-1, 1] {
                m.horn(SIMD3(0.3 * s, 0.42, -0.35), SIMD3(0.48 * s, 1.15, -1.65), r: 0.14, bone_, tip: bone_ * 1.08, sides: far ? 4 : 7)
            }
            // The frill: a fan rising up and back from the skull, with a pale rim of knobs and two eye-spots.
            let c = SIMD3<Float>(0, 0.25, 0.25)
            let up = simd_normalize(SIMD3<Float>(0, 1, 0.55)), side = SIMD3<Float>(1, 0, 0)
            let nrm = simd_normalize(simd_cross(side, up))
            let steps = far ? 8 : 16
            for face: Float in [-1, 1] {
                let base = m.vertexCount
                let o = nrm * 0.06 * face
                m.vertex(c + o, nrm * face, frill * 0.8)
                for k in 0...steps {
                    let a = -1.9 + 3.8 * Float(k) / Float(steps)
                    let r: Float = 1.45 * (0.85 + 0.15 * cos(a * 2))
                    m.vertex(c + (side * sin(a) + up * cos(a)) * r + o, nrm * face, frill * (k % 2 == 0 ? 1 : 0.9))
                }
                for k in 0..<UInt32(steps) {
                    if face > 0 { m.tri(base, base + 2 + k, base + 1 + k) } else { m.tri(base, base + 1 + k, base + 2 + k) }
                }
                if !far {
                    // Two painted eye-spots on each face.
                    for s: Float in [-1, 1] {
                        let ss: Float = sin(0.75 * s) * 0.95, cc: Float = cos(0.75) * 0.95, off: Float = 0.075 * face
                        let e: SIMD3<Float> = c + side * ss + up * cc + nrm * off
                        m.ellipsoid(e, SIMD3(0.2, 0.2, 0.2) * SIMD3(1, 1, 1) - abs(nrm) * 0.17, spot, rings: 2, sides: 8)
                        m.ellipsoid(e + nrm * 0.02 * face, SIMD3(0.09, 0.09, 0.09) - abs(nrm) * 0.07, SIMD3(0.2, 0.12, 0.08), rings: 2, sides: 6)
                    }
                }
            }
            if !far {
                for k in 0...12 {
                    let a = -1.9 + 3.8 * Float(k) / 12
                    let r: Float = 1.45 * (0.85 + 0.15 * cos(a * 2))
                    m.horn(c + (side * sin(a) + up * cos(a)) * (r - 0.05), c + (side * sin(a) + up * cos(a)) * (r + 0.22), r: 0.09, bone_, sides: 4)
                }
                // Eye-spots on the frill (painted dots) and real eyes.
                DinoSpecies.eyes(&m, at: SIMD3(0.42, 0.12, -0.55), r: 0.09)
            }
        }
        snout = SIMD3(0, -0.6, -1.75)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.38, -0.35)) { m, far in
            m.loft([SIMD3(0, 0, 0.1), SIMD3(0, -0.05, -0.7), SIMD3(0, -0.06, -1.15)], [SIMD2(0.42, 0.22), SIMD2(0.32, 0.18), SIMD2(0.14, 0.1)],
                   skin: Skin(back: SIMD3(0.5, 0.28, 0.24), belly: skin.belly), sides: far ? 5 : 9)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.28, 1.5), lengths: [0.9, 0.85, 0.8, 0.7],
                     radii: [SIMD2(0.64, 0.72), SIMD2(0.5, 0.56), SIMD2(0.36, 0.4), SIMD2(0.22, 0.24), SIMD2(0.06, 0.06)],
                     skin: skin, rests: [0.25, 0.05, 0.02, 0.02], backward: true, sides: 10)
        tailTip = SIMD3(0, 0, 0.7)
        let toes: (inout MeshBuilder, Bool) -> Void = { m, far in DinoSpecies.padFoot(&m, far: far, r: 0.38, skin: skin.back * 0.8) }
        for (side, x, ph) in [("HL", Float(-0.85), Float(0)), ("HR", Float(0.85), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.25, 0.4), lengths: (1.1, 0.95, 0.32), radii: (0.66, 0.44, 0.36),
                            rests: (0.12, -0.3, 0.18), skin: skin, phase: ph, front: false, knee: -0.6, sole: 0.3, toes: toes))
        }
        for (side, x, ph) in [("FL", Float(-0.85), Float(0.25)), ("FR", Float(0.85), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.4, 0), lengths: (0.85, 0.8, 0.28), radii: (0.55, 0.4, 0.33),
                            rests: (-0.1, 0.25, -0.15), skin: skin, phase: ph, front: true, knee: -0.5, sole: 0.3, splay: x > 0 ? -0.12 : 0.12, toes: toes))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.2, 1.2), b: SIMD3(0, -0.1, -2.8), r: 1.25),
                    DinoCapsule(bone: head, a: SIMD3(0, 0.3, 0.2), b: SIMD3(0, -0.2, -1.3), r: 0.75),
                    DinoCapsule(bone: tail[0], a: .zero, b: SIMD3(0, 0, 1.6), r: 0.55)]
    }

    private func buildStego() {
        walk = 1.5; run = 4.6; turn = 0.65; stride = 0.38; bob = 0.06; length = 9
        neckDown = -0.35; neckUp = 0.25; jawOpen = 0.4
        let skin = Skin(back: SIMD3(0.47, 0.52, 0.34), belly: SIMD3(0.76, 0.74, 0.58), stripes: 0.35,
                        stripeColor: SIMD3(0.32, 0.36, 0.22), stripeFreq: 0.6, seed: 2.9)
        let plateC = SIMD3<Float>(0.84, 0.42, 0.2), rim = SIMD3<Float>(0.96, 0.76, 0.36)
        // Plates along the spine: (z, y, height), alternating sides.
        let spinePlates: [(Float, Float, Float)] = [(-2.6, -0.6, 0.38), (-2.1, -0.38, 0.55), (-1.5, -0.1, 0.72), (-0.9, 0.18, 0.88),
                                                     (-0.3, 0.38, 0.98), (0.3, 0.5, 1.0), (0.9, 0.55, 0.92), (1.45, 0.45, 0.78)]
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.25, 1.75), SIMD3(0, 0.42, 0.5), SIMD3(0, -0.1, -0.8), SIMD3(0, -0.62, -2.0), SIMD3(0, -0.92, -2.9)],
                   [SIMD2(0.62, 0.78), SIMD2(1.1, 1.35), SIMD2(1.15, 1.28), SIMD2(0.9, 0.98), SIMD2(0.58, 0.62)],
                   skin: skin, sides: far ? 8 : 14, drop: [0, 0.06, 0.12, 0.06, 0])
            for (k, (z, y, h)) in spinePlates.enumerated() {
                let side: Float = k % 2 == 0 ? -0.16 : 0.16
                let tiltUp = simd_normalize(SIMD3<Float>(side * 0.4, 1, 0))
                m.plate(base: SIMD3(side, y + 0.62 + h * 0.1, z), up: tiltUp, fwd: SIMD3(0, 0, -1), height: h, length: h * 0.95,
                        thick: 0.05, plateC, rim: rim)
            }
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, -0.85, -2.4))
        neck = chain("neck", parent: chest, at: SIMD3(0, -0.05, -0.45), lengths: [0.9], radii: [SIMD2(0.55, 0.58), SIMD2(0.4, 0.42)],
                     skin: skin, rests: [-0.18], backward: false, sides: 10)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.85), rest: rotX(-0.1)) { m, far in
            m.loft([SIMD3(0, 0, 0.12), SIMD3(0, -0.04, -0.45), SIMD3(0, -0.14, -0.85)], [SIMD2(0.34, 0.34), SIMD2(0.3, 0.29), SIMD2(0.16, 0.14)],
                   skin: skin, sides: far ? 6 : 10)
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.26, 0.1, -0.3), r: 0.07) }
        }
        snout = SIMD3(0, -0.15, -0.9)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.2, -0.15)) { m, far in
            m.loft([SIMD3(0, 0, 0.05), SIMD3(0, -0.04, -0.6)], [SIMD2(0.26, 0.12), SIMD2(0.12, 0.08)], skin: Skin(back: SIMD3(0.5, 0.3, 0.26), belly: skin.belly),
                   sides: far ? 5 : 8)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.25, 1.7), lengths: [1.0, 0.95, 0.9, 0.85, 0.8],
                     radii: [SIMD2(0.6, 0.72), SIMD2(0.48, 0.56), SIMD2(0.36, 0.42), SIMD2(0.26, 0.3), SIMD2(0.18, 0.2), SIMD2(0.1, 0.1)],
                     skin: skin, rests: [0.18, 0.04, 0.02, 0.0, -0.02], backward: true, sides: 10)
        // More plates down the tail, and the spikes at its end.
        for (k, b) in tail.enumerated() where k < 3 {
            var extra = MeshBuilder()
            let h: Float = 0.6 - Float(k) * 0.16
            let side: Float = k % 2 == 0 ? 0.12 : -0.12
            extra.plate(base: SIMD3(side, 0.45 - Float(k) * 0.1, 0.5), up: simd_normalize(SIMD3(side * 0.4, 1, 0)), fwd: SIMD3(0, 0, -1),
                        height: h, length: h, thick: 0.04, plateC, rim: rim)
            rig.near[b] = MeshTemplate(appending: rig.near[b], extra)
            rig.far[b] = MeshTemplate(appending: rig.far[b], extra)
        }
        var spikes = MeshBuilder()
        for s: Float in [-1, 1] {
            spikes.horn(SIMD3(0.08 * s, 0.08, 0.35), SIMD3(0.75 * s, 0.6, 0.85), r: 0.09, SIMD3(0.9, 0.84, 0.7), sides: 5)
            spikes.horn(SIMD3(0.08 * s, 0.04, 0.6), SIMD3(0.8 * s, 0.42, 1.2), r: 0.09, SIMD3(0.9, 0.84, 0.7), sides: 5)
        }
        rig.near[tail[4]] = MeshTemplate(appending: rig.near[tail[4]], spikes)
        rig.far[tail[4]] = MeshTemplate(appending: rig.far[tail[4]], spikes)
        tailTip = SIMD3(0, 0.3, 1.0)
        let toes: (inout MeshBuilder, Bool) -> Void = { m, far in DinoSpecies.padFoot(&m, far: far, r: 0.3, skin: skin.back * 0.8) }
        for (side, x, ph) in [("HL", Float(-0.8), Float(0)), ("HR", Float(0.8), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.25, 0.45), lengths: (1.25, 1.15, 0.3), radii: (0.64, 0.42, 0.35),
                            rests: (0.1, -0.25, 0.15), skin: skin, phase: ph, front: false, knee: -0.6, sole: 0.24, toes: toes))
        }
        for (side, x, ph) in [("FL", Float(-0.68), Float(0.25)), ("FR", Float(0.68), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.25, 0), lengths: (0.7, 0.62, 0.24), radii: (0.46, 0.34, 0.29),
                            rests: (-0.08, 0.2, -0.12), skin: skin, phase: ph, front: true, knee: -0.5, sole: 0.24, splay: x > 0 ? -0.1 : 0.1, toes: toes))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.3, 1.4), b: SIMD3(0, -0.7, -2.6), r: 1.2),
                    DinoCapsule(bone: 0, a: SIMD3(0, 1.3, 1.2), b: SIMD3(0, 0.6, -1.8), r: 0.7),
                    DinoCapsule(bone: tail[1], a: .zero, b: SIMD3(0, 0, 0.95), r: 0.5),
                    DinoCapsule(bone: tail[4], a: .zero, b: SIMD3(0, 0.3, 1.0), r: 0.6)]
    }

    private func buildPara() {
        biped = true
        walk = 2.0; run = 7.5; turn = 1.0; stride = 0.42; bob = 0.08; length = 9.5
        neckDown = -1.05; neckUp = 0.35; jawOpen = 0.45
        let skin = Skin(back: SIMD3(0.36, 0.5, 0.3), belly: SIMD3(0.8, 0.78, 0.6), stripes: 0.75,
                        stripeColor: SIMD3(0.88, 0.76, 0.32), stripeFreq: 0.85, seed: 0.2)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.22, 1.45), SIMD3(0, 0.28, 0.4), SIMD3(0, 0.0, -0.8), SIMD3(0, 0.12, -1.9), SIMD3(0, 0.45, -2.5)],
                   [SIMD2(0.58, 0.72), SIMD2(0.84, 1.05), SIMD2(0.9, 1.1), SIMD2(0.7, 0.9), SIMD2(0.48, 0.58)],
                   skin: skin, sides: far ? 8 : 13, drop: [0, 0.05, 0.1, 0.05, 0])
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 0.15, -1.9))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.35, -0.45), lengths: [0.8, 0.7],
                     radii: [SIMD2(0.45, 0.52), SIMD2(0.38, 0.44), SIMD2(0.32, 0.36)], skin: skin, rests: [0.75, -0.5], backward: false, sides: 10)
        let crest = SIMD3<Float>(0.86, 0.36, 0.2)
        head = bone("head", parent: neck[1], at: SIMD3(0, 0, -0.65), rest: rotX(-0.35)) { m, far in
            m.loft([SIMD3(0, 0.02, 0.12), SIMD3(0, -0.04, -0.4), SIMD3(0, -0.2, -0.85)], [SIMD2(0.29, 0.36), SIMD2(0.26, 0.3), SIMD2(0.22, 0.13)],
                   skin: skin, sides: far ? 6 : 10)
            // The long hollow crest sweeping back over the neck.
            let pts: [SIMD3<Float>] = [SIMD3(0, 0.2, -0.3), SIMD3(0, 0.4, 0.1), SIMD3(0, 0.62, 0.7), SIMD3(0, 0.78, 1.35)]
            m.loft(pts, [SIMD2(0.12, 0.16), SIMD2(0.13, 0.17), SIMD2(0.11, 0.14), SIMD2(0.07, 0.08)],
                   skin: Skin(back: crest, belly: crest * 0.8), sides: far ? 5 : 8)
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.24, 0.12, -0.18), r: 0.07) }
        }
        snout = SIMD3(0, -0.22, -0.9)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.2, -0.1)) { m, far in
            m.loft([SIMD3(0, 0, 0.05), SIMD3(0, -0.02, -0.72)], [SIMD2(0.24, 0.1), SIMD2(0.2, 0.06)], skin: Skin(back: SIMD3(0.5, 0.3, 0.26), belly: skin.belly),
                   sides: far ? 5 : 8)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.22, 1.4), lengths: [1.0, 0.95, 0.9, 0.85, 0.8],
                     radii: [SIMD2(0.56, 0.7), SIMD2(0.44, 0.56), SIMD2(0.32, 0.42), SIMD2(0.22, 0.28), SIMD2(0.13, 0.16), SIMD2(0.04, 0.04)],
                     skin: skin, rests: [0.1, 0.0, -0.02, -0.02, -0.02], backward: true, sides: 10)
        tailTip = SIMD3(0, 0, 0.8)
        for (side, x, ph) in [("L", Float(-0.62), Float(0)), ("R", Float(0.62), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.15, 0.2), lengths: (1.2, 1.1, 0.6), radii: (0.45, 0.26, 0.15),
                            rests: (0.25, -0.6, 0.5), skin: skin, phase: ph, front: false, knee: -1, sole: 0.09) { m, far in
                DinoSpecies.clawToes(&m, far: far, width: 0.16, length: 0.42, r: 0.1, skin: skin.back * 0.85, claw: SIMD3(0.3, 0.28, 0.25))
            })
            let arm = bone("arm\(side)", parent: chest, at: SIMD3(x * 0.85, -0.45, -0.1), rest: rotX(0.45)) { m, far in
                m.loft([SIMD3(0, 0.05, 0), SIMD3(0, -0.7, 0)], [SIMD2(0.16, 0.18), SIMD2(0.1, 0.1)], skin: skin, sides: far ? 4 : 6)
            }
            let fore = bone("forearm\(side)", parent: arm, at: SIMD3(0, -0.7, 0), rest: rotX(-0.6)) { m, far in
                m.loft([SIMD3(0, 0.03, 0), SIMD3(0, -0.62, 0)], [SIMD2(0.09, 0.09), SIMD2(0.08, 0.07)], skin: skin, sides: far ? 4 : 5)
                m.ellipsoid(SIMD3(0, -0.68, -0.04), SIMD3(0.09, 0.07, 0.12), skin.back * 0.8, rings: 2, sides: 5)
            }
            arms += [arm, fore]
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.2, 1.2), b: SIMD3(0, 0.1, -1.9), r: 0.95),
                    DinoCapsule(bone: head, a: SIMD3(0, 0, 0), b: SIMD3(0, 0.6, 1.2), r: 0.35),
                    DinoCapsule(bone: tail[0], a: .zero, b: SIMD3(0, 0, 1.9), r: 0.5)]
    }

    private func buildAnkylo() {
        walk = 1.2; run = 3.4; turn = 0.75; stride = 0.36; bob = 0.04; length = 7.5
        neckDown = -0.3; neckUp = 0.2; jawOpen = 0.4
        let skin = Skin(back: SIMD3(0.5, 0.43, 0.31), belly: SIMD3(0.74, 0.66, 0.52), stripes: 0.2,
                        stripeColor: SIMD3(0.34, 0.29, 0.21), stripeFreq: 0.9, seed: 1.1)
        let armor = SIMD3<Float>(0.62, 0.56, 0.44), spike = SIMD3<Float>(0.86, 0.8, 0.66)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.12, 1.45), SIMD3(0, 0.2, 0.5), SIMD3(0, 0.15, -0.6), SIMD3(0, 0.05, -1.7), SIMD3(0, -0.02, -2.3)],
                   [SIMD2(0.8, 0.6), SIMD2(1.45, 0.86), SIMD2(1.62, 0.92), SIMD2(1.4, 0.82), SIMD2(0.9, 0.6)],
                   skin: skin, sides: far ? 8 : 14, drop: [0, 0.03, 0.06, 0.03, 0])
            if !far {
                // Rows of bony studs over the back, spikes along the flanks.
                for row in 0..<5 {
                    let z = 1.1 - Float(row) * 0.75
                    let w: Float = [0.7, 1.25, 1.4, 1.2, 0.8][row]
                    for k in -2...2 {
                        let x = Float(k) / 2 * w * 0.75
                        let y: Float = [0.62, 1.0, 1.05, 0.9, 0.55][row] * cos(Float(k) / 2 * 0.9) + 0.12
                        m.ellipsoid(SIMD3(x, y, z), SIMD3(0.16, 0.1, 0.16), armor, rings: 2, sides: 5)
                    }
                    for s: Float in [-1, 1] {
                        let base = SIMD3(s * w * 1.0, 0.1, z)
                        m.horn(base, base + SIMD3(s * 0.5, -0.05, 0.12), r: 0.11, spike, sides: 4)
                    }
                }
            }
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, -0.05, -1.8))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.05, -0.4), lengths: [0.5], radii: [SIMD2(0.6, 0.45), SIMD2(0.5, 0.4)],
                     skin: skin, rests: [-0.08], backward: false, sides: 10)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.45)) { m, far in
            m.loft([SIMD3(0, 0, 0.12), SIMD3(0, -0.02, -0.45), SIMD3(0, -0.1, -0.8)], [SIMD2(0.56, 0.42), SIMD2(0.5, 0.36), SIMD2(0.28, 0.24)],
                   skin: skin, sides: far ? 6 : 10)
            for s: Float in [-1, 1] { m.horn(SIMD3(0.42 * s, 0.12, 0.05), SIMD3(0.75 * s, 0.18, 0.35), r: 0.12, spike, sides: far ? 4 : 5) }
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.4, 0.12, -0.3), r: 0.06) }
        }
        snout = SIMD3(0, -0.12, -0.85)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.24, -0.1)) { m, far in
            m.loft([SIMD3(0, 0, 0.05), SIMD3(0, -0.02, -0.6)], [SIMD2(0.36, 0.12), SIMD2(0.2, 0.08)], skin: Skin(back: SIMD3(0.5, 0.3, 0.26), belly: skin.belly),
                   sides: far ? 5 : 8)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.12, 1.4), lengths: [0.9, 0.85, 0.8, 0.75],
                     radii: [SIMD2(0.6, 0.48), SIMD2(0.46, 0.38), SIMD2(0.34, 0.28), SIMD2(0.24, 0.2), SIMD2(0.18, 0.16)],
                     skin: skin, rests: [0.1, 0.0, -0.02, -0.02], backward: true, sides: 9)
        // The club.
        var club = MeshBuilder()
        for s: Float in [-1, 1] { club.ellipsoid(SIMD3(0.2 * s, 0, 0.82), SIMD3(0.36, 0.26, 0.34), armor * 0.95, rings: 3, sides: 8) }
        club.ellipsoid(SIMD3(0, 0, 1.05), SIMD3(0.3, 0.22, 0.24), armor, rings: 3, sides: 7)
        rig.near[tail[3]] = MeshTemplate(appending: rig.near[tail[3]], club)
        rig.far[tail[3]] = MeshTemplate(appending: rig.far[tail[3]], club)
        tailTip = SIMD3(0, 0, 0.95)
        let toes: (inout MeshBuilder, Bool) -> Void = { m, far in DinoSpecies.padFoot(&m, far: far, r: 0.25, skin: skin.back * 0.8) }
        for (side, x, ph) in [("HL", Float(-0.95), Float(0)), ("HR", Float(0.95), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.25, 0.4), lengths: (0.65, 0.55, 0.22), radii: (0.5, 0.36, 0.3),
                            rests: (0.1, -0.25, 0.15), skin: skin, phase: ph, front: false, knee: -0.6, sole: 0.2, splay: x > 0 ? -0.12 : 0.12, toes: toes))
        }
        for (side, x, ph) in [("FL", Float(-0.9), Float(0.25)), ("FR", Float(0.9), Float(0.75))] {
            legs.append(leg(side, parent: chest, at: SIMD3(x, -0.25, 0), lengths: (0.55, 0.48, 0.2), radii: (0.44, 0.33, 0.28),
                            rests: (-0.08, 0.2, -0.12), skin: skin, phase: ph, front: true, knee: -0.5, sole: 0.2, splay: x > 0 ? -0.18 : 0.18, toes: toes))
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.2, 1.1), b: SIMD3(0, 0.1, -1.9), r: 1.3),
                    DinoCapsule(bone: tail[3], a: .zero, b: SIMD3(0, 0, 1.0), r: 0.45)]
    }

    private func buildRaptor() {
        biped = true
        walk = 3.2; run = 15; turn = 2.6; stride = 0.5; bob = 0.06; length = 4.4
        neckDown = -0.7; neckUp = 0.45; jawOpen = 0.7
        scaleRange = 0.9...1.05
        let skin = Skin(back: SIMD3(0.62, 0.47, 0.3), belly: SIMD3(0.88, 0.8, 0.64), stripes: 0.85,
                        stripeColor: SIMD3(0.27, 0.2, 0.14), stripeFreq: 1.5, seed: 3.1)
        let feather = SIMD3<Float>(0.3, 0.36, 0.52)
        let pelvis = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0.1, 0.6), SIMD3(0, 0.08, 0), SIMD3(0, -0.02, -0.55), SIMD3(0, 0.1, -0.95)],
                   [SIMD2(0.26, 0.3), SIMD2(0.32, 0.4), SIMD2(0.3, 0.38), SIMD2(0.21, 0.26)], skin: skin, sides: far ? 7 : 11)
        }
        chest = emptyBone("chest", parent: pelvis, at: SIMD3(0, 0.05, -0.8))
        neck = chain("neck", parent: chest, at: SIMD3(0, 0.12, -0.12), lengths: [0.38, 0.32],
                     radii: [SIMD2(0.18, 0.22), SIMD2(0.15, 0.18), SIMD2(0.13, 0.15)], skin: skin, rests: [0.95, -0.85], backward: false, sides: 8)
        head = bone("head", parent: neck[1], at: SIMD3(0, 0, -0.28), rest: rotX(-0.05)) { m, far in
            m.loft([SIMD3(0, 0.02, 0.08), SIMD3(0, 0.02, -0.22), SIMD3(0, -0.04, -0.55)], [SIMD2(0.13, 0.16), SIMD2(0.12, 0.13), SIMD2(0.06, 0.06)],
                   skin: skin, sides: far ? 6 : 9)
            if !far {
                DinoSpecies.eyes(&m, at: SIMD3(0.1, 0.07, -0.15), r: 0.04, iris: SIMD3(0.95, 0.7, 0.1))
                // A little feather crest.
                for k in 0..<3 {
                    let z = 0.05 + Float(k) * 0.07
                    m.horn(SIMD3(0, 0.13, z), SIMD3(0, 0.3 - Float(k) * 0.04, z + 0.12), r: 0.035, feather * 1.2, sides: 3)
                }
                DinoSpecies.teeth(&m, from: -0.22, to: -0.5, y: -0.1, x0: 0.09, x1: 0.05, count: 4, down: true, size: 0.04)
            }
        }
        snout = SIMD3(0, -0.04, -0.56)
        jaw = bone("jaw", parent: head, at: SIMD3(0, -0.08, -0.02)) { m, far in
            m.loft([SIMD3(0, 0, 0.04), SIMD3(0, -0.02, -0.48)], [SIMD2(0.1, 0.05), SIMD2(0.05, 0.03)], skin: Skin(back: SIMD3(0.55, 0.25, 0.22), belly: skin.belly),
                   sides: far ? 4 : 7)
        }
        tail = chain("tail", parent: pelvis, at: SIMD3(0, 0.1, 0.55), lengths: [0.55, 0.52, 0.5, 0.5],
                     radii: [SIMD2(0.24, 0.28), SIMD2(0.17, 0.2), SIMD2(0.11, 0.13), SIMD2(0.07, 0.08), SIMD2(0.03, 0.03)],
                     skin: skin, rests: [0.02, -0.01, -0.01, -0.01], backward: true, sides: 8)
        var fan = MeshBuilder()
        for k in -2...2 { fan.horn(SIMD3(0, 0, 0.3), SIMD3(Float(k) * 0.1, 0.02, 0.85), r: 0.05, feather, sides: 3) }
        rig.near[tail[3]] = MeshTemplate(appending: rig.near[tail[3]], fan)
        tailTip = SIMD3(0, 0, 0.5)
        for (side, x, ph) in [("L", Float(-0.26), Float(0)), ("R", Float(0.26), Float(0.5))] {
            legs.append(leg(side, parent: pelvis, at: SIMD3(x, -0.08, 0.05), lengths: (0.5, 0.5, 0.34), radii: (0.18, 0.1, 0.06),
                            rests: (0.35, -0.95, 0.7), skin: skin, phase: ph, front: false, knee: -1.1, sole: 0.04) { m, far in
                DinoSpecies.clawToes(&m, far: far, width: 0.06, length: 0.2, r: 0.04, skin: skin.back * 0.85)
                if !far { m.horn(SIMD3(-0.03, 0, -0.05), SIMD3(-0.03, 0.12, -0.18), r: 0.03, SIMD3(0.15, 0.13, 0.12), sides: 3) }
            })
            let arm = bone("arm\(side)", parent: chest, at: SIMD3(x * 0.7, -0.15, -0.05), rest: rotX(0.9) * rotZ(x > 0 ? -0.3 : 0.3)) { m, far in
                m.loft([SIMD3(0, 0.03, 0), SIMD3(0, -0.3, 0)], [SIMD2(0.07, 0.07), SIMD2(0.05, 0.05)], skin: skin, sides: far ? 3 : 5)
            }
            let fore = bone("forearm\(side)", parent: arm, at: SIMD3(0, -0.3, 0), rest: rotX(-1.2)) { m, far in
                m.loft([SIMD3(0, 0.02, 0), SIMD3(0, -0.3, 0)], [SIMD2(0.045, 0.045), SIMD2(0.035, 0.035)], skin: skin, sides: far ? 3 : 5)
                if !far {
                    // Wing feathers along the forearm.
                    for k in 0..<4 {
                        let y = -Float(k) * 0.08
                        m.horn(SIMD3(0, y, 0.02), SIMD3(x > 0 ? 0.05 : -0.05, y - 0.06, 0.32 - Float(k) * 0.03), r: 0.035, feather, sides: 3)
                    }
                }
            }
            arms += [arm, fore]
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0.05, 0.4), b: SIMD3(0, 0.05, -0.8), r: 0.42)]
    }

    private func buildPtero() {
        walk = 0; run = 0; length = 3
        let skin = Skin(back: SIMD3(0.48, 0.42, 0.38), belly: SIMD3(0.84, 0.8, 0.72), stripes: 0.2,
                        stripeColor: SIMD3(0.3, 0.26, 0.24), stripeFreq: 1.2, seed: 0.9)
        let membrane = SIMD3<Float>(0.66, 0.5, 0.4), crest = SIMD3<Float>(0.86, 0.38, 0.2)
        let body = bone("pelvis", parent: -1, at: .zero) { m, far in
            m.loft([SIMD3(0, 0, 0.55), SIMD3(0, 0.02, 0.1), SIMD3(0, 0.03, -0.35), SIMD3(0, 0.08, -0.6)],
                   [SIMD2(0.1, 0.1), SIMD2(0.2, 0.22), SIMD2(0.22, 0.24), SIMD2(0.13, 0.14)], skin: skin, sides: far ? 6 : 9)
            // Little legs trailing behind.
            for s: Float in [-1, 1] { m.tube(SIMD3(0.1 * s, -0.08, 0.2), SIMD3(0.18 * s, -0.12, 0.75), r0: 0.05, r1: 0.03, sides: 4, skin.back) }
        }
        neck = chain("neck", parent: body, at: SIMD3(0, 0.08, -0.55), lengths: [0.4], radii: [SIMD2(0.11, 0.12), SIMD2(0.08, 0.09)],
                     skin: skin, rests: [0.1], backward: false, sides: 7)
        head = bone("head", parent: neck[0], at: SIMD3(0, 0, -0.38)) { m, far in
            m.loft([SIMD3(0, 0, 0.08), SIMD3(0, -0.01, -0.3), SIMD3(0, -0.04, -1.05)], [SIMD2(0.09, 0.12), SIMD2(0.07, 0.09), SIMD2(0.012, 0.012)],
                   skin: Skin(back: SIMD3(0.8, 0.7, 0.45), belly: SIMD3(0.75, 0.65, 0.42)), sides: far ? 5 : 7)
            m.loft([SIMD3(0, 0.05, -0.05), SIMD3(0, 0.12, 0.35), SIMD3(0, 0.2, 0.8)], [SIMD2(0.03, 0.12), SIMD2(0.025, 0.1), SIMD2(0.01, 0.02)],
                   skin: Skin(back: crest, belly: crest * 0.85), sides: far ? 4 : 6)
            if !far { DinoSpecies.eyes(&m, at: SIMD3(0.07, 0.04, -0.06), r: 0.03) }
        }
        snout = SIMD3(0, -0.04, -1.05)
        // Wings: an inner bone to the wrist and an outer bone to the tip, with the membrane on each.
        for (side, s) in [("L", Float(-1)), ("R", Float(1))] {
            let inner = bone("wing\(side)", parent: body, at: SIMD3(0.16 * s, 0.08, -0.3)) { m, far in
                m.tube(.zero, SIMD3(1.55 * s, 0.05, 0.05), r0: 0.07, r1: 0.05, sides: far ? 3 : 5, skin.back)
                // A flat four-sided membrane from the body to the wrist, both faces.
                for face: Float in [-1, 1] {
                    let n = SIMD3<Float>(0, face, 0)
                    let i = m.vertexCount
                    let o = SIMD3<Float>(0, face * 0.01, 0)
                    m.vertex(SIMD3(0, 0, 0.05) + o, n, membrane); m.vertex(SIMD3(1.55 * s, 0.05, 0.05) + o, n, membrane * 1.05)
                    m.vertex(SIMD3(1.5 * s, 0.03, 0.42) + o, n, membrane * 0.95); m.vertex(SIMD3(0.05 * s, -0.05, 0.9) + o, n, membrane * 0.9)
                    let flip = (face > 0) != (s > 0)
                    if flip { m.tri(i, i + 1, i + 2); m.tri(i, i + 2, i + 3) } else { m.tri(i, i + 2, i + 1); m.tri(i, i + 3, i + 2) }
                }
            }
            let outer = bone("tip\(side)", parent: inner, at: SIMD3(1.55 * s, 0.05, 0.05)) { m, far in
                m.tube(.zero, SIMD3(2.0 * s, 0.0, 0.35), r0: 0.05, r1: 0.015, sides: far ? 3 : 4, skin.back)
                for face: Float in [-1, 1] {
                    let n = SIMD3<Float>(0, face, 0)
                    let i = m.vertexCount
                    let o = SIMD3<Float>(0, face * 0.01, 0)
                    m.vertex(o, n, membrane * 1.05); m.vertex(SIMD3(2.0 * s, 0, 0.35) + o, n, membrane * 1.1); m.vertex(SIMD3(-0.05 * s, -0.02, 0.37) + o, n, membrane)
                    let flip = (face > 0) != (s > 0)
                    if flip { m.tri(i, i + 1, i + 2) } else { m.tri(i, i + 2, i + 1) }
                }
            }
            wings += [inner, outer]
        }
        capsules = [DinoCapsule(bone: 0, a: SIMD3(0, 0, 0.4), b: SIMD3(0, 0, -0.5), r: 0.4),
                    DinoCapsule(bone: wings[0], a: .zero, b: SIMD3(-1.5, 0, 0.2), r: 0.3),
                    DinoCapsule(bone: wings[2], a: .zero, b: SIMD3(1.5, 0, 0.2), r: 0.3)]
        headHeight = 0
        hip = 0
    }
}

extension MeshTemplate {
    /// A template with another mesh's triangles added.
    init(appending t: MeshTemplate, _ m: MeshBuilder) {
        self = t
        let extra = MeshTemplate(m)
        let base = UInt32(pos.count)
        pos += extra.pos; nrm += extra.nrm; col += extra.col; uv += extra.uv
        idx += extra.idx.map { $0 + base }
    }
}
