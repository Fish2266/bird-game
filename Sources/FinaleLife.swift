import SceneKit
import simd

// The kingdom turned out for the champion: crowds lining the road, the drawbridge, the courtyard and the great hall,
// guards on the walls, heralds with trumpets at the gate and the hall doors, the King and Queen on the dais, villagers
// milling round the plaza — all cheering as the guest of honour goes by — and fireworks over the towers all evening.

final class FinaleLife {
    let root = SCNNode()
    private let mesh: DynamicMesh?
    var camera = SIMD3<Float>.zero
    private(set) var clock: Float = 0
    /// The guest of honour (the player's bird, or the bird walking in the cutscene): people turn and cheer near it.
    var honoree = SIMD3<Float>(0, 0, 400)
    /// Everyone cheers harder (the crowning, the liftoff), 0…1.
    var celebrate: Float = 0
    /// Everyone looks up (the liftoff), 0…1.
    var lookUp: Float = 0
    /// The King lifting the crown high (0 down … 1 up), set by the cutscene.
    var kingLift: Float = 0
    /// The two attendants carrying the chest forward (0 at their places … 1 at the foot of the throne).
    var attendantsForward: Float = 0
    let fireworks: FinaleFireworks

    enum Role { case crowd, sentry, herald, king, queen, attendant, villager }
    struct Person {
        var pos: SIMD3<Float>
        var yaw: Float
        let model: Int
        let role: Role
        var phase: Float
        var cheer: Float = 0
        var hat: Int
        var flag: Int
        var target: SIMD3<Float>? = nil
        var home: SIMD3<Float>
    }
    private(set) var people: [Person] = []
    /// Everyone in the kingdom is drawn this much bigger than the city's bird people.
    static let scale: Float = 1.65
    private var rng = SplitMix64(seed: 0xF1_4A1E)
    /// Cheers heard this frame (for the crowd sound): how loud, near the camera.
    private(set) var roar: Float = 0

    init(fireworks: FinaleFireworks) {
        self.fireworks = fireworks
        mesh = DynamicMesh(maxVertices: 260_000, maxTriangles: 360_000, material: WorldMaterials.vertexColor(rough: 0.8))
        if let mesh {
            mesh.node.castsShadow = true
            root.addChildNode(mesh.node)
        }
        populate()
    }

    // MARK: Who stands where

    private func populate() {
        let L = FinaleLayout.self
        let g = L.ground
        func add(_ p: SIMD3<Float>, facing f: SIMD3<Float>, _ role: Role, model: Int? = nil) {
            let m = model ?? Int(rng.float(0, Float(PersonModel.all.count) - 0.01))
            let hat = role == .crowd && rng.float() < 0.3 ? Int(rng.float(0, 3.99)) : -1
            let flag = role == .crowd && rng.float() < 0.35 ? Int(rng.float(0, 4.99)) : -1
            people.append(Person(pos: p, yaw: atan2(-f.x, -f.z), model: m, role: role, phase: rng.float(0, 6.28), hat: hat, flag: flag, home: p))
        }
        // Along the road and over the drawbridge: two deep on each side, facing the way in.
        for z in stride(from: Float(150), to: 236, by: 3.4) {
            let y = (L.roadY(0, z)?.y ?? g)
            for s: Float in [-1, 1] {
                for row: Float in [0, 1] {
                    let x = s * (8.6 + row * 1.6) + rng.float(-0.3, 0.3)
                    add(SIMD3(x, y, z + rng.float(-0.6, 0.6) + row * 1.2), facing: SIMD3(-s, 0, 0), .crowd)
                }
            }
        }
        // The courtyard: behind the hedges and lamp posts on both sides of the path.
        for z in stride(from: L.gateZ - 12, to: L.hallSouth + 8, by: -2.6) where abs(z - 50) > 7 {
            for s: Float in [-1, 1] {
                add(SIMD3(s * (10.4 + rng.float(-0.4, 0.6)), g, z + rng.float(-0.5, 0.5)), facing: SIMD3(-s, 0, 0), .crowd)
                if rng.float() < 0.55 { add(SIMD3(s * (12.2 + rng.float(-0.3, 0.6)), g, z + rng.float(-0.8, 0.8)), facing: SIMD3(-s, 0, 0), .crowd) }
            }
        }
        // Little groups round the fountains and the tents.
        for c in [SIMD3<Float>(-30, g, 50), SIMD3(30, g, 50), SIMD3(-46, g, 22), SIMD3(46, g, 22), SIMD3(-48, g, 82), SIMD3(48, g, 82)] {
            for k in 0..<7 {
                let a = Float(k) / 7 * 2 * .pi + rng.float(-0.2, 0.2)
                let p = c + SIMD3(cos(a), 0, sin(a)) * rng.float(7.5, 10)
                add(p, facing: SIMD3(-p.x, 0, 0) + SIMD3(0, 0, 0.01), .crowd)
            }
        }
        // In the great hall: between the columns and the walls, both sides of the carpet, facing in.
        for z in stride(from: L.hallSouth - 5, to: L.daisFront + 2, by: -2.2) {
            for s: Float in [-1, 1] {
                add(SIMD3(s * (5.6 + rng.float(-0.2, 0.4)), g + 0.12, z), facing: SIMD3(-s, 0, 0), .crowd)
                add(SIMD3(s * (12.6 + rng.float(-0.3, 0.3)), g + 0.12, z + 1), facing: SIMD3(-s, 0, 0), .crowd)
                if rng.float() < 0.7 { add(SIMD3(s * (14.6 + rng.float(-0.3, 0.3)), g + 0.12, z), facing: SIMD3(-s, 0, 0), .crowd) }
            }
        }
        // Guards on the wall walk, facing out; heralds at the gate and the hall doors.
        let cs = L.corners
        for k in 0..<8 {
            let A = cs[k], B = cs[(k + 1) % 8]
            let out = simd_normalize(SIMD3((A.x + B.x) / 2, 0, (A.z + B.z) / 2))
            for u: Float in [0.33, 0.67] {
                var p = simd_mix(A, B, SIMD3(repeating: u)) - out * 0.6
                if abs(out.z - 1) < 0.02 && abs(p.x) < 16 { continue }
                p.y = g + L.wallHeight
                add(p, facing: out, .sentry, model: 9)
            }
        }
        for x: Float in [-7.5, 7.5] { add(SIMD3(x, g, L.gateZ + 9), facing: SIMD3(0, 0, 1), .herald, model: 10) }
        for x: Float in [-9, -11.5, 9, 11.5] { add(SIMD3(x, g, L.hallSouth + 3), facing: SIMD3(0, 0, 1), .herald, model: x < 0 ? 4 : 3) }
        // The King (a golden eagle of a bird: the owl look in royal robes) and the Queen; the attendants with the chest.
        add(SIMD3(0, g + L.daisHeight, -68.5), facing: SIMD3(0, 0, 1), .king, model: 8)
        add(SIMD3(4.6, g + L.daisHeight, -70), facing: SIMD3(-0.3, 0, 1), .queen, model: 7)
        add(SIMD3(-7, g + L.daisHeight, -67), facing: SIMD3(1, 0, 0.4), .attendant, model: 12)
        add(SIMD3(7, g + L.daisHeight, -67), facing: SIMD3(-1, 0, 0.4), .attendant, model: 12)
        // Villagers round the plaza.
        for _ in 0..<34 {
            let a = rng.float(0, 6.28), r = rng.float(8, 50)
            let p = SIMD3(L.village.x + cos(a) * r, L.villageY, L.village.y + sin(a) * r)
            add(p, facing: SIMD3(cos(a), 0, sin(a)), .villager)
        }
    }

    /// Where the attendants stand (the cutscene puts the chest between them).
    var chestPosition: SIMD3<Float> {
        let L = FinaleLayout.self
        return simd_mix(SIMD3(0, L.ground + L.daisHeight, -67), SIMD3(0, L.ground + L.daisHeight, -64.4), SIMD3(repeating: attendantsForward))
    }

    // MARK: Update

    func update(dt: Float, sound: SoundEngine?) {
        clock += dt
        var loud: Float = 0
        for i in people.indices {
            var p = people[i]
            p.phase += dt * (2 + p.cheer * 5)
            let d = simd_distance(p.pos, honoree)
            var want: Float = smoothstep(26, 6, d)
            if p.role == .crowd || p.role == .villager { want = max(want, celebrate * smoothstep(160, 40, d) + celebrate * 0.4) }
            if p.role == .sentry { want = celebrate * 0.6 }
            p.cheer += (want - p.cheer) * min(1, dt * 3)
            if p.role == .villager {
                // Wander round the plaza.
                if p.target == nil || simd_distance(p.pos, p.target!) < 0.8 {
                    let a = rng.float(0, 6.28), r = rng.float(8, 50)
                    p.target = SIMD3(FinaleLayout.village.x + cos(a) * r, p.pos.y, FinaleLayout.village.y + sin(a) * r)
                }
                if let t = p.target, p.cheer < 0.5 {
                    let to = t - p.pos
                    let want = atan2(-to.x, -to.z)
                    var dy = want - p.yaw
                    while dy > .pi { dy -= 2 * .pi }
                    while dy < -.pi { dy += 2 * .pi }
                    p.yaw += clamp(dy, -3 * dt, 3 * dt)
                    p.pos += SIMD3(-sin(p.yaw), 0, -cos(p.yaw)) * 1.1 * dt
                }
            }
            if p.role == .attendant {
                let side: Float = p.home.x < 0 ? -1 : 1
                let c = chestPosition
                p.pos = simd_mix(p.home, c + SIMD3(side * 1.4, 0, 0), SIMD3(repeating: smoothstep(0, 1, attendantsForward)))
            }
            let toCam = simd_distance(p.pos, camera)
            if toCam < 90 { loud += p.cheer * (1 - toCam / 90) }
            people[i] = p
        }
        roar = min(1, loud / 18)
        draw()
    }

    // MARK: Drawing

    private static let crown: MeshTemplate = {
        var m = MeshBuilder()
        let gold = SIMD3<Float>(1.0, 0.78, 0.3)
        m.cylinder(.zero, r0: 0.15, r1: 0.16, y0: 0, y1: 0.09, sides: 12, gold, top: false)
        for k in 0..<6 {
            let a = Float(k) / 6 * 2 * .pi
            let p = SIMD3(cos(a) * 0.155, 0.09, sin(a) * 0.155)
            m.tube(p, p + SIMD3(0, 0.12, 0), r0: 0.035, r1: 0.005, sides: 4, gold)
            m.ellipsoid(p + SIMD3(0, 0.13, 0), SIMD3(repeating: 0.022), SIMD3(0.9, 0.12, 0.2), rings: 2, sides: 4)
        }
        return MeshTemplate(m)
    }()

    /// A royal robe: a long cloak behind the body, red with white trim.
    private static let robe: MeshTemplate = {
        var m = MeshBuilder()
        let red = SIMD3<Float>(0.64, 0.06, 0.1), white = SIMD3<Float>(0.96, 0.95, 0.92)
        let top: Float = 0.78, w0: Float = 0.24, w1: Float = 0.5
        m.quad(SIMD3(-w0, top, 0.2), SIMD3(w0, top, 0.2), SIMD3(w1, 0.02, 0.5), SIMD3(-w1, 0.02, 0.5), red, facing: SIMD3(0, 0, 1))
        m.quad(SIMD3(-w0, top, 0.19), SIMD3(w0, top, 0.19), SIMD3(w1, 0.02, 0.49), SIMD3(-w1, 0.02, 0.49), red * 0.8, facing: SIMD3(0, 0, -1))
        m.tube(SIMD3(-w1, 0.04, 0.5), SIMD3(w1, 0.04, 0.5), r0: 0.05, r1: 0.05, sides: 5, white)
        m.tube(SIMD3(-w0 - 0.03, top, 0.18), SIMD3(w0 + 0.03, top, 0.18), r0: 0.07, r1: 0.07, sides: 6, white)
        return MeshTemplate(m)
    }()

    private static let helmet: MeshTemplate = {
        var m = MeshBuilder()
        let steel = SIMD3<Float>(0.78, 0.8, 0.84)
        m.ellipsoid(SIMD3(0, 0.03, 0), SIMD3(0.2, 0.15, 0.21), steel, rings: 4, sides: 8)
        m.cylinder(.zero, r0: 0.23, r1: 0.23, y0: -0.02, y1: 0.01, sides: 10, steel * 0.9)
        m.tube(SIMD3(0, 0.15, 0.02), SIMD3(0, 0.34, 0.14), r0: 0.05, r1: 0.02, sides: 5, SIMD3(0.85, 0.1, 0.12))
        return MeshTemplate(m)
    }()

    private static let spear: MeshTemplate = {
        var m = MeshBuilder()
        m.tube(SIMD3(0, -0.5, 0), SIMD3(0, 1.8, 0), r0: 0.025, r1: 0.025, sides: 4, SIMD3(0.42, 0.3, 0.2))
        m.tube(SIMD3(0, 1.8, 0), SIMD3(0, 2.05, 0), r0: 0.06, r1: 0.003, sides: 4, SIMD3(0.85, 0.86, 0.9))
        return MeshTemplate(m)
    }()

    /// A long herald's trumpet with its little banner (held up from the beak, pointing along −z).
    private static let trumpet: MeshTemplate = {
        var m = MeshBuilder()
        let gold = SIMD3<Float>(1.0, 0.8, 0.32)
        m.tube(.zero, SIMD3(0, 0, -0.9), r0: 0.018, r1: 0.022, sides: 5, gold)
        m.tube(SIMD3(0, 0, -0.88), SIMD3(0, 0, -1.02), r0: 0.03, r1: 0.12, sides: 8, gold)
        m.quad(SIMD3(-0.001, -0.02, -0.3), SIMD3(-0.001, -0.02, -0.75), SIMD3(-0.001, -0.42, -0.72), SIMD3(-0.001, -0.42, -0.33), SIMD3(0.14, 0.24, 0.62),
               facing: SIMD3(-1, 0, 0))
        m.quad(SIMD3(0.001, -0.02, -0.3), SIMD3(0.001, -0.02, -0.75), SIMD3(0.001, -0.42, -0.72), SIMD3(0.001, -0.42, -0.33), SIMD3(0.14, 0.24, 0.62),
               facing: SIMD3(1, 0, 0))
        m.ellipsoid(SIMD3(0, -0.22, -0.52), SIMD3(0.004, 0.08, 0.08), SIMD3(1.0, 0.8, 0.3), rings: 2, sides: 5)
        return MeshTemplate(m)
    }()

    private static let partyHats: [MeshTemplate] = [SIMD3<Float>(0.95, 0.3, 0.55), SIMD3(0.3, 0.6, 0.95), SIMD3(0.98, 0.8, 0.2), SIMD3(0.35, 0.8, 0.4)].map { c in
        var m = MeshBuilder()
        m.cylinder(.zero, r0: 0.11, r1: 0.005, y0: 0, y1: 0.3, sides: 8, c)
        m.ellipsoid(SIMD3(0, 0.31, 0), SIMD3(repeating: 0.035), SIMD3(1, 1, 1), rings: 2, sides: 4)
        return MeshTemplate(m)
    }

    private static let pennants: [MeshTemplate] = [SIMD3<Float>(0.75, 0.1, 0.12), SIMD3(0.14, 0.26, 0.66), SIMD3(1.0, 0.78, 0.25), SIMD3(0.2, 0.6, 0.3),
                                                    SIMD3(0.95, 0.95, 0.95)].map { c in
        var m = MeshBuilder()
        m.tube(SIMD3(0, -0.1, 0), SIMD3(0, 0.75, 0), r0: 0.012, r1: 0.012, sides: 4, SIMD3(0.45, 0.35, 0.25))
        m.quad(SIMD3(0, 0.75, 0), SIMD3(0, 0.45, 0), SIMD3(0.38, 0.6, 0), SIMD3(0.38, 0.6, 0), c, facing: SIMD3(0, 0, -1))
        m.quad(SIMD3(0, 0.45, 0), SIMD3(0, 0.75, 0), SIMD3(0.38, 0.6, 0), SIMD3(0.38, 0.6, 0), c, facing: SIMD3(0, 0, 1))
        return MeshTemplate(m)
    }

    private func draw() {
        guard let mesh else { return }
        mesh.begin()
        let cam = camera
        for p in people {
            let d = simd_distance(p.pos, cam)
            guard d < 260 else { continue }
            let model = PersonModel.all[p.model % PersonModel.all.count]
            let L = model.look
            let royal = p.role == .king || p.role == .queen
            // Grand people for a grand castle (the hall is cathedral-sized).
            let s: Float = (p.role == .king ? 1.25 : (royal ? 1.12 : (p.role == .sentry ? 1.05 : 1))) * FinaleLife.scale
            let ch = p.cheer
            let hop = (p.role == .crowd || p.role == .villager) ? abs(sin(p.phase * 1.6)) * 0.22 * ch * ch : 0
            let walking = p.role == .villager && p.target != nil && ch < 0.5
            let bob = walking ? abs(sin(p.phase * 2.2)) * 0.04 : 0
            // Turn a little toward the guest of honour.
            var yaw = p.yaw
            let to = honoree - p.pos
            if ch > 0.05 && p.role != .sentry {
                let want = atan2(-to.x, -to.z)
                var dy = want - yaw
                while dy > .pi { dy -= 2 * .pi }
                while dy < -.pi { dy += 2 * .pi }
                yaw += clamp(dy, -0.8, 0.8) * ch
            }
            let base = trs(p.pos + SIMD3(0, hop + bob, 0), yawQuat(yaw), s)
            mesh.add(model.body, base)
            var headQ = yawQuat(sin(clock * 0.5 + p.phase) * 0.25 * (1 - ch))
            let up = max(lookUp, ch * 0.3)
            if up > 0 {
                let pitchUp = clamp(atan2(to.y + 2, max(simd_length(SIMD2(to.x, to.z)), 1)) + lookUp * 0.9, -0.2, 1.2)
                headQ = headQ * simd_quatf(angle: pitchUp * up, axis: SIMD3(1, 0, 0))
            }
            let headM = base * trs(model.neck, headQ)
            mesh.add(model.head, headM)
            let hr: Float = 0.19 * (L.bigEyes ? 1.12 : 1)
            let headTop = headM * trs(SIMD3(0, hr * 1.62, -0.02), simd_quatf(angle: 0, axis: kUp), 1.15)
            switch p.role {
            case .king, .queen: mesh.add(FinaleLife.crown, headTop)
            case .sentry: mesh.add(FinaleLife.helmet, headM * trs(SIMD3(0, hr * 1.1, -0.02), simd_quatf(angle: 0, axis: kUp), 1.1))
            default: if p.hat >= 0 { mesh.add(FinaleLife.partyHats[p.hat % 4], headTop) }
            }
            if royal { mesh.add(FinaleLife.robe, base) }
            // Legs: walking villagers step; everyone else stands (hopping when they cheer).
            let swing = walking ? sin(p.phase * 2.2) * 0.5 : 0
            mesh.add(model.leg, base * trs(model.hipL, simd_quatf(angle: swing, axis: SIMD3(1, 0, 0))))
            mesh.add(model.leg, base * trs(model.hipR, simd_quatf(angle: -swing, axis: SIMD3(1, 0, 0))))
            // Wings: cheering waves them overhead; heralds hold trumpets up; guards hold spears; the King lifts the crown.
            var wl = simd_quatf(angle: -swing * 0.6, axis: SIMD3(1, 0, 0))
            var wr = simd_quatf(angle: swing * 0.6, axis: SIMD3(1, 0, 0))
            if ch > 0.02 && (p.role == .crowd || p.role == .villager || p.role == .queen) {
                let wave = sin(p.phase * 3) * 0.35
                wl = simd_quatf(angle: -2.7 * ch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: (0.35 + wave) * ch, axis: SIMD3(0, 0, 1))
                wr = simd_quatf(angle: -2.7 * ch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: (-0.35 + wave) * ch, axis: SIMD3(0, 0, 1))
            }
            if p.role == .herald {
                let sway = sin(clock * 3 + p.phase) * 0.05
                wl = simd_quatf(angle: -1.5 + sway, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1))
                wr = simd_quatf(angle: -1.5 + sway, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.5, axis: SIMD3(0, 0, 1))
                // The trumpet, up from the beak.
                mesh.add(FinaleLife.trumpet, headM * trs(SIMD3(0, hr * 0.6, -hr * 1.05), simd_quatf(angle: 0.45 + sway, axis: SIMD3(1, 0, 0))))
            }
            if p.role == .sentry {
                wr = simd_quatf(angle: -0.25 - 0.8 * ch, axis: SIMD3(1, 0, 0))
            }
            if p.role == .king {
                wr = simd_quatf(angle: -2.9 * kingLift, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.25 * kingLift, axis: SIMD3(0, 0, 1))
                wl = simd_quatf(angle: -0.4, axis: SIMD3(1, 0, 0))
            }
            if p.role == .attendant {
                // Holding the chest out in front.
                wl = simd_quatf(angle: -1.3, axis: SIMD3(1, 0, 0)); wr = wl
            }
            let wingLM = base * trs(model.shoulderL, wl), wingRM = base * trs(model.shoulderR, wr)
            mesh.add(model.wingL, wingLM)
            mesh.add(model.wingR, wingRM)
            let handR = wingRM * trs(SIMD3(0.02, -0.32 * L.height, -0.02), simd_quatf(angle: 0, axis: kUp))
            if p.role == .sentry { mesh.add(FinaleLife.spear, handR) }
            if p.flag >= 0 && p.role == .crowd { mesh.add(FinaleLife.pennants[p.flag % 5], handR) }
        }
        mesh.end()
    }
}

/// Fireworks over the castle: rockets burst into coloured stars every second or two (more when there's something to
/// celebrate). Looping emitters switched on for an instant (one-shot particle systems misbehave mid-game).
final class FinaleFireworks {
    let root = SCNNode()
    private var shells: [(node: SCNNode, ps: SCNParticleSystem, sparkle: SCNParticleSystem, off: Float)] = []
    private var next = 0
    private var clock: Float = 0
    private var timer: Float = 1
    private var rng = SplitMix64(seed: 0xF1_8E)
    /// More of them, faster (the cutscene's big moments).
    var intensity: Float = 0
    /// Bursts this frame: where and how big (for sounds).
    private(set) var bursts: [SIMD3<Float>] = []

    private static let star: CGImage = makeImage(width: 32, height: 32) { x, y in
        let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, pow(a, 1.6))
    }

    private static let palette: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1), NSColor(srgbRed: 1, green: 0.82, blue: 0.3, alpha: 1),
        NSColor(srgbRed: 0.4, green: 1, blue: 0.5, alpha: 1), NSColor(srgbRed: 0.45, green: 0.6, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 0.5, blue: 0.9, alpha: 1), NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    ]

    init() {
        for _ in 0..<10 {
            let n = SCNNode()
            n.simdPosition = SIMD3(0, -500, 0)
            let ps = SCNParticleSystem()
            ps.birthRate = 0
            ps.emitterShape = SCNSphere(radius: 0.5)
            ps.birthLocation = .surface
            ps.emittingDirection = SCNVector3(0, 1, 0)
            ps.spreadingAngle = 180
            ps.particleVelocity = 22
            ps.particleVelocityVariation = 4
            ps.particleLifeSpan = 2.1
            ps.particleLifeSpanVariation = 0.5
            ps.particleSize = 1.5
            ps.particleSizeVariation = 0.4
            ps.acceleration = SCNVector3(0, -7, 0)
            ps.particleImage = FinaleFireworks.star
            ps.blendMode = .additive
            ps.isLightingEnabled = false
            let fade = CAKeyframeAnimation(); fade.values = [1, 0.9, 0]; fade.keyTimes = [0, 0.6, 1]
            ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
            n.addParticleSystem(ps)
            // Twinkling sparks left hanging after the burst.
            let sp = SCNParticleSystem()
            sp.birthRate = 0
            sp.emitterShape = SCNSphere(radius: 14)
            sp.birthLocation = .volume
            sp.particleVelocity = 1
            sp.particleLifeSpan = 1.4
            sp.particleLifeSpanVariation = 0.5
            sp.particleSize = 0.5
            sp.particleImage = FinaleFireworks.star
            sp.blendMode = .additive
            sp.isLightingEnabled = false
            sp.acceleration = SCNVector3(0, -3, 0)
            let tw = CAKeyframeAnimation(); tw.values = [0, 1, 0.2, 1, 0]; tw.keyTimes = [0, 0.2, 0.5, 0.7, 1]
            sp.propertyControllers = [.opacity: SCNParticlePropertyController(animation: tw)]
            n.addParticleSystem(sp)
            root.addChildNode(n)
            shells.append((n, ps, sp, 0))
        }
    }

    /// A burst right now (the cutscene's cues), or on the timer.
    func burst(at p: SIMD3<Float>) {
        let k = next
        next = (next + 1) % shells.count
        let c = FinaleFireworks.palette[Int(rng.float(0, Float(FinaleFireworks.palette.count) - 0.01))]
        shells[k].node.simdPosition = p
        shells[k].ps.particleColor = c
        shells[k].ps.particleColorVariation = SCNVector4(0.04, 0.1, 0.1, 0)
        shells[k].ps.particleVelocity = CGFloat(rng.float(17, 26))
        shells[k].ps.birthRate = 2600
        shells[k].sparkle.particleColor = c
        shells[k].sparkle.birthRate = 0
        shells[k].off = clock + 0.05
        bursts.append(p)
    }

    func update(dt: Float, around center: SIMD3<Float>) {
        clock += dt
        bursts.removeAll(keepingCapacity: true)
        for k in shells.indices where shells[k].off > 0 {
            if clock >= shells[k].off {
                shells[k].ps.birthRate = 0
                // Then a short twinkle where it burst.
                if shells[k].sparkle.birthRate == 0 && clock < shells[k].off + 0.5 { shells[k].sparkle.birthRate = 160 }
                if clock >= shells[k].off + 0.6 { shells[k].sparkle.birthRate = 0; shells[k].off = 0 }
            }
        }
        timer -= dt * (1 + intensity * 3)
        if timer <= 0 {
            timer = rng.float(0.8, 2.4)
            let a = rng.float(0, 6.28), r = rng.float(20, 150)
            burst(at: center + SIMD3(cos(a) * r, rng.float(110, 210), sin(a) * r))
        }
    }
}
