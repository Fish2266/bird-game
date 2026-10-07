import SceneKit
import simd

/// What a bird person looks like.
struct PersonLook {
    enum Gait { case walk, waddle, bob }
    var body: SIMD3<Float>
    var belly: SIMD3<Float>
    var head: SIMD3<Float>
    var beak: SIMD3<Float>
    var legs: SIMD3<Float>
    var wing: SIMD3<Float>
    var neck: SIMD3<Float>? = nil
    var mask: SIMD3<Float>? = nil
    var crest: SIMD3<Float>? = nil
    var height: Float = 1
    var fat: Float = 1
    var beakLen: Float = 1
    var flatBill = false
    var legLen: Float = 1
    var gait = Gait.walk
    var bigEyes = false

    static let all: [PersonLook] = [
        // Pigeon: grey, a shimmering neck, pink feet; bobs its head as it walks.
        PersonLook(body: SIMD3(0.52, 0.54, 0.58), belly: SIMD3(0.62, 0.62, 0.66), head: SIMD3(0.40, 0.42, 0.48), beak: SIMD3(0.25, 0.25, 0.27),
                   legs: SIMD3(0.85, 0.42, 0.45), wing: SIMD3(0.45, 0.47, 0.52), neck: SIMD3(0.30, 0.55, 0.45), fat: 1.08, beakLen: 0.6, gait: .bob),
        // Sparrow
        PersonLook(body: SIMD3(0.55, 0.40, 0.26), belly: SIMD3(0.82, 0.76, 0.64), head: SIMD3(0.46, 0.44, 0.42), beak: SIMD3(0.25, 0.22, 0.2),
                   legs: SIMD3(0.65, 0.5, 0.4), wing: SIMD3(0.48, 0.34, 0.22), height: 0.92, beakLen: 0.6),
        // Robin
        PersonLook(body: SIMD3(0.36, 0.30, 0.26), belly: SIMD3(0.88, 0.42, 0.16), head: SIMD3(0.20, 0.18, 0.17), beak: SIMD3(0.9, 0.75, 0.2),
                   legs: SIMD3(0.55, 0.45, 0.35), wing: SIMD3(0.32, 0.27, 0.24)),
        // Cardinal: red with a black mask and a crest.
        PersonLook(body: SIMD3(0.78, 0.10, 0.08), belly: SIMD3(0.85, 0.16, 0.12), head: SIMD3(0.82, 0.12, 0.09), beak: SIMD3(0.95, 0.55, 0.2),
                   legs: SIMD3(0.6, 0.4, 0.35), wing: SIMD3(0.65, 0.08, 0.07), mask: SIMD3(0.08, 0.06, 0.06), crest: SIMD3(0.82, 0.12, 0.09), beakLen: 0.7),
        // Blue jay
        PersonLook(body: SIMD3(0.22, 0.42, 0.78), belly: SIMD3(0.92, 0.92, 0.94), head: SIMD3(0.26, 0.46, 0.82), beak: SIMD3(0.12, 0.12, 0.13),
                   legs: SIMD3(0.2, 0.2, 0.22), wing: SIMD3(0.18, 0.38, 0.75), crest: SIMD3(0.26, 0.46, 0.82)),
        // Mallard: green head, white collar, chestnut chest; waddles.
        PersonLook(body: SIMD3(0.62, 0.60, 0.56), belly: SIMD3(0.50, 0.30, 0.20), head: SIMD3(0.12, 0.42, 0.22), beak: SIMD3(0.95, 0.8, 0.2),
                   legs: SIMD3(0.98, 0.55, 0.15), wing: SIMD3(0.55, 0.52, 0.48), neck: SIMD3(0.95, 0.95, 0.95), fat: 1.18, beakLen: 1.1,
                   flatBill: true, legLen: 0.8, gait: .waddle),
        // Penguin: dressed for the office; waddles.
        PersonLook(body: SIMD3(0.07, 0.07, 0.09), belly: SIMD3(0.95, 0.95, 0.95), head: SIMD3(0.07, 0.07, 0.09), beak: SIMD3(0.95, 0.5, 0.12),
                   legs: SIMD3(0.95, 0.5, 0.12), wing: SIMD3(0.07, 0.07, 0.09), height: 0.95, fat: 1.15, beakLen: 0.8, legLen: 0.55, gait: .waddle),
        // Flamingo: long pink legs.
        PersonLook(body: SIMD3(0.95, 0.52, 0.62), belly: SIMD3(0.98, 0.65, 0.72), head: SIMD3(0.95, 0.55, 0.65), beak: SIMD3(0.15, 0.12, 0.12),
                   legs: SIMD3(0.95, 0.45, 0.55), wing: SIMD3(0.9, 0.42, 0.52), height: 1.1, fat: 0.85, beakLen: 1.3, legLen: 1.7),
        // Owl: big eyes, a short hooked beak.
        PersonLook(body: SIMD3(0.48, 0.36, 0.24), belly: SIMD3(0.80, 0.70, 0.55), head: SIMD3(0.52, 0.40, 0.28), beak: SIMD3(0.3, 0.28, 0.25),
                   legs: SIMD3(0.75, 0.68, 0.55), wing: SIMD3(0.42, 0.30, 0.20), fat: 1.2, beakLen: 0.45, legLen: 0.7, bigEyes: true),
        // Crow
        PersonLook(body: SIMD3(0.08, 0.08, 0.1), belly: SIMD3(0.12, 0.12, 0.15), head: SIMD3(0.08, 0.08, 0.1), beak: SIMD3(0.15, 0.15, 0.17),
                   legs: SIMD3(0.12, 0.12, 0.13), wing: SIMD3(0.06, 0.06, 0.08), height: 1.02, beakLen: 1.1),
        // Seagull
        PersonLook(body: SIMD3(0.90, 0.90, 0.92), belly: SIMD3(0.96, 0.96, 0.97), head: SIMD3(0.95, 0.95, 0.96), beak: SIMD3(0.98, 0.8, 0.2),
                   legs: SIMD3(0.95, 0.75, 0.5), wing: SIMD3(0.62, 0.66, 0.72), beakLen: 1.0),
        // Toucan: an enormous colourful beak.
        PersonLook(body: SIMD3(0.07, 0.07, 0.08), belly: SIMD3(0.98, 0.92, 0.6), head: SIMD3(0.07, 0.07, 0.08), beak: SIMD3(1.0, 0.55, 0.08),
                   legs: SIMD3(0.3, 0.45, 0.8), wing: SIMD3(0.06, 0.06, 0.07), beakLen: 2.4),
        // Parrot
        PersonLook(body: SIMD3(0.15, 0.62, 0.22), belly: SIMD3(0.9, 0.8, 0.15), head: SIMD3(0.85, 0.15, 0.12), beak: SIMD3(0.9, 0.88, 0.8),
                   legs: SIMD3(0.4, 0.4, 0.42), wing: SIMD3(0.15, 0.4, 0.8), beakLen: 0.8),
    ]
}

/// A bird person's mesh, split into the parts that move.
struct PersonModel {
    var body: MeshTemplate
    var head: MeshTemplate
    var leg: MeshTemplate
    var wingL: MeshTemplate
    var wingR: MeshTemplate
    /// Pivots in the person's own space (scaled by height).
    var neck: SIMD3<Float>
    var hipL: SIMD3<Float>, hipR: SIMD3<Float>
    var shoulderL: SIMD3<Float>, shoulderR: SIMD3<Float>
    var look: PersonLook

    static let accessoryHats: [MeshTemplate] = {
        var out: [MeshTemplate] = []
        // Cap, fedora, beanie, hard hat
        var cap = MeshBuilder()
        cap.ellipsoid(SIMD3(0, 0.03, 0), SIMD3(0.16, 0.09, 0.17), SIMD3(0.15, 0.25, 0.6), rings: 3, sides: 8)
        cap.box(SIMD3(0, 0.0, -0.17), SIMD3(0.1, 0.012, 0.08), SIMD3(0.15, 0.25, 0.6))
        out.append(MeshTemplate(cap))
        var fedora = MeshBuilder()
        fedora.cylinder(.zero, r0: 0.24, r1: 0.24, y0: 0, y1: 0.02, sides: 10, SIMD3(0.25, 0.2, 0.16))
        fedora.cylinder(.zero, r0: 0.14, r1: 0.12, y0: 0, y1: 0.16, sides: 10, SIMD3(0.25, 0.2, 0.16))
        fedora.cylinder(SIMD3(0, 0.03, 0), r0: 0.145, r1: 0.145, y0: 0, y1: 0.03, sides: 10, SIMD3(0.08, 0.06, 0.05), top: false)
        out.append(MeshTemplate(fedora))
        var beanie = MeshBuilder()
        beanie.ellipsoid(SIMD3(0, 0.04, 0), SIMD3(0.155, 0.12, 0.165), SIMD3(0.8, 0.2, 0.25), rings: 3, sides: 8)
        beanie.ellipsoid(SIMD3(0, 0.17, 0), SIMD3(repeating: 0.045), SIMD3(0.95, 0.95, 0.92), rings: 2, sides: 5)
        out.append(MeshTemplate(beanie))
        var hard = MeshBuilder()
        hard.ellipsoid(SIMD3(0, 0.02, 0), SIMD3(0.17, 0.11, 0.18), SIMD3(1.0, 0.8, 0.1), rings: 3, sides: 8)
        hard.cylinder(SIMD3(0, 0.0, 0), r0: 0.21, r1: 0.21, y0: -0.01, y1: 0.01, sides: 10, SIMD3(1.0, 0.8, 0.1))
        out.append(MeshTemplate(hard))
        return out
    }()

    static let bag: MeshTemplate = {
        var m = MeshBuilder()
        m.box(SIMD3(0, -0.12, 0), SIMD3(0.04, 0.11, 0.15), SIMD3(0.28, 0.18, 0.1))
        m.box(SIMD3(0, 0.02, 0), SIMD3(0.012, 0.03, 0.05), SIMD3(0.15, 0.1, 0.06))
        return MeshTemplate(m)
    }()
    static let cup: MeshTemplate = {
        var m = MeshBuilder()
        m.cylinder(.zero, r0: 0.035, r1: 0.045, y0: -0.05, y1: 0.07, sides: 6, SIMD3(0.95, 0.93, 0.88))
        m.cylinder(SIMD3(0, 0.07, 0), r0: 0.047, r1: 0.044, y0: 0, y1: 0.02, sides: 6, SIMD3(0.2, 0.15, 0.1))
        return MeshTemplate(m)
    }()
    static let backpack: MeshTemplate = {
        var m = MeshBuilder()
        m.box(.zero, SIMD3(0.15, 0.17, 0.07), SIMD3(0.25, 0.45, 0.35))
        m.box(SIMD3(0, -0.06, 0.06), SIMD3(0.11, 0.07, 0.03), SIMD3(0.2, 0.38, 0.3))
        return MeshTemplate(m)
    }()
    static let phone: MeshTemplate = {
        var m = MeshBuilder()
        m.box(.zero, SIMD3(0.04, 0.07, 0.008), SIMD3(0.1, 0.1, 0.12))
        return MeshTemplate(m)
    }()
    static let flash: MeshTemplate = {
        var m = MeshBuilder()
        m.ellipsoid(.zero, SIMD3(repeating: 0.12), SIMD3(1, 1, 1), rings: 2, sides: 5)
        return MeshTemplate(m)
    }()

    static let all: [PersonModel] = PersonLook.all.map { PersonModel(look: $0) }

    init(look L: PersonLook) {
        look = L
        // Cartoon proportions: a round body, a big head, short legs and big feet.
        let H: Float = 1.3 * L.height
        let legH = 0.2 * H * L.legLen
        let rb = SIMD3<Float>(0.25 * L.fat, 0.3 * H * 0.78, 0.23 * L.fat)
        let torsoC = SIMD3<Float>(0, legH + rb.y * 0.92, 0)
        var b = MeshBuilder()
        b.ellipsoid(torsoC, rb, L.body, rings: 7, sides: 10) { u in
            // A belly patch on the front (-z), the back colour behind and on top.
            let front = smoothstep(0.05, -0.55, u.z) * smoothstep(0.8, 0.25, u.y)
            return simd_mix(L.body, L.belly, SIMD3(repeating: front))
        }
        if let n = L.neck {
            b.cylinder(torsoC + SIMD3(0, rb.y * 0.68, 0), r0: rb.x * 0.7, r1: rb.x * 0.56, y0: 0, y1: 0.09, sides: 10, n, top: false)
        }
        // A little fan of a tail.
        for k in -1...1 {
            let a = Float(k) * 0.35
            b.box(torsoC + SIMD3(sin(a) * 0.06, -rb.y * 0.5, rb.z * 0.95 + 0.05), SIMD3(0.045, 0.012, 0.12), L.wing,
                  rot: yawQuat(a) * simd_quatf(angle: -0.55, axis: SIMD3(1, 0, 0)))
        }
        body = MeshTemplate(b)
        neck = torsoC + SIMD3(0, rb.y * 0.82, -0.02)
        // Head (built around the neck pivot): big, round, cartoon eyes.
        var h = MeshBuilder()
        let hr: Float = 0.19 * (L.bigEyes ? 1.12 : 1)
        let hc = SIMD3<Float>(0, hr * 0.85, -0.02)
        h.ellipsoid(hc, SIMD3(hr * 0.97, hr, hr * 1.02), L.head, rings: 6, sides: 9)
        if let m = L.mask {
            h.ellipsoid(hc + SIMD3(0, -0.03, -hr * 0.6), SIMD3(hr * 0.72, hr * 0.42, hr * 0.48), m, rings: 3, sides: 7)
        }
        if let c = L.crest {
            h.tube(hc + SIMD3(0, hr * 0.75, 0.0), hc + SIMD3(0, hr * 1.7, 0.16), r0: 0.06, r1: 0.006, sides: 5, c)
            h.tube(hc + SIMD3(0, hr * 0.7, 0.05), hc + SIMD3(0, hr * 1.45, 0.24), r0: 0.045, r1: 0.005, sides: 5, c)
        }
        let beakBase = hc + SIMD3(0, -hr * 0.18, -hr * 0.88)
        if L.flatBill {
            h.box(beakBase + SIMD3(0, -0.01, -0.075 * L.beakLen), SIMD3(0.06, 0.024, 0.085 * L.beakLen), L.beak)
        } else {
            h.tube(beakBase, beakBase + SIMD3(0, -0.025 * L.beakLen, -0.15 * L.beakLen), r0: 0.048 * min(L.beakLen, 1.5), r1: 0.006, sides: 6, L.beak)
        }
        for s: Float in [-1, 1] {
            let e = hc + SIMD3(s * hr * 0.42, hr * 0.2, -hr * 0.8)
            let white: SIMD3<Float> = L.bigEyes ? SIMD3(0.98, 0.84, 0.25) : SIMD3(0.97, 0.97, 0.97)
            h.ellipsoid(e, SIMD3(0.062, 0.07, 0.04) * (L.bigEyes ? 1.3 : 1), white, rings: 3, sides: 6)
            h.ellipsoid(e + SIMD3(0, 0, -0.03), SIMD3(0.034, 0.04, 0.02) * (L.bigEyes ? 1.3 : 1), SIMD3(0.02, 0.02, 0.025), rings: 2, sides: 5)
            h.ellipsoid(e + SIMD3(s * -0.012, 0.015, -0.046), SIMD3(repeating: 0.008), SIMD3(1, 1, 1), rings: 2, sides: 4)
        }
        head = MeshTemplate(h)
        // Leg (from the hip pivot down to a big foot)
        var l = MeshBuilder()
        l.tube(SIMD3(0, 0.02, 0), SIMD3(0, -legH + 0.03, 0), r0: 0.045, r1: 0.035, sides: 5, L.legs)
        for a: Float in [-0.45, 0, 0.45] {
            l.box(SIMD3(sin(a) * 0.05, -legH + 0.015, -0.06 * cos(a) - 0.01), SIMD3(0.022, 0.014, 0.07), L.legs, rot: yawQuat(-a))
        }
        leg = MeshTemplate(l)
        hipL = SIMD3(-0.1 * L.fat, legH, 0.01); hipR = SIMD3(0.1 * L.fat, legH, 0.01)
        // Wings hang at the sides like arms: rounded paddles.
        func wing(_ s: Float) -> MeshTemplate {
            var w = MeshBuilder()
            w.ellipsoid(SIMD3(s * 0.02, -0.15 * L.height, 0.03), SIMD3(0.055, 0.18 * L.height, 0.12), L.wing, rings: 4, sides: 7)
            return MeshTemplate(w)
        }
        wingL = wing(-1); wingR = wing(1)
        shoulderL = torsoC + SIMD3(-rb.x * 0.95, rb.y * 0.4, 0.02)
        shoulderR = torsoC + SIMD3(rb.x * 0.95, rb.y * 0.4, 0.02)
    }
}

/// Bird people on the sidewalks and in the parks around the player.
final class CityPeople {
    enum Mode { case walk, waitCross, cross, idle, park, sit, platform }
    struct Person {
        var model: Int
        var scale: Float
        var pos: SIMD2<Float>
        var y: Float = 0
        var yaw: Float = 0
        var target: SIMD2<Float>
        var mode: Mode
        var speed: Float
        var phase: Float
        // Where on the network: the line (x-line when !alongX), which side, which way.
        var alongX: Bool
        var line: Int
        var side: Float
        var dir: Float
        var lateral: Float
        var timer: Float = 0
        var hat: Int = -1
        var bag = false, cup = false, pack = false
        var jogger = false
        var kid = false
        var inPark = false
        /// Waiting on a subway platform: its height, the station and which platform.
        var stationY: Float?
        var station: (Int, Int, Bool) = (0, 0, false)
        var platformSide: Float = 1
        // Reactions to the player.
        var lookUp: Float = 0
        var point: Float = 0
        var photo: Float = 0
        var cower: Float = 0
        var headYaw: Float = 0
        var block: (Int, Int) = (0, 0)
    }

    private(set) var people: [Person] = []
    private var rng = SplitMix64(seed: 0xB1D5)
    private var maintain: Float = 0
    let radius: Float = 200
    let maxPeople = 260
    private(set) var flashes: [SIMD3<Float>] = []
    /// How many are looking at the bird (for a "crowd" sound).
    private(set) var watching = 0
    private(set) var nearby: Float = 0

    // MARK: Network helpers

    private func cityLine(_ alongX: Bool, _ k: Int) -> CityLine { alongX ? CityLayout.lineZ(k) : CityLayout.lineX(k) }

    /// World point for a person on a sidewalk: `a` along the line.
    private func walkPoint(_ p: Person, along a: Float) -> SIMD2<Float> {
        let l = cityLine(p.alongX, p.line)
        let off = p.side * (l.halfRoad + 0.7 + p.lateral)
        let c = Float(p.line) * CityLayout.pitch + off
        return p.alongX ? SIMD2(a, c) : SIMD2(c, a)
    }

    private func along(_ p: Person) -> Float { p.alongX ? p.pos.x : p.pos.y }

    /// The next corner ahead on the current sidewalk: the node, where to stop (the cross street's curb) and its line.
    private func nextCorner(_ p: Person) -> (node: Int, a: Float, cross: CityLine) {
        let G = CityLayout.pitch
        let a = along(p)
        var n = p.dir > 0 ? Int(floor(a / G)) : Int(ceil(a / G))
        for _ in 0..<3 {
            let cross = cityLine(!p.alongX, n)
            let stop = Float(n) * G - p.dir * (cross.halfRoad + 0.9)
            if (stop - a) * p.dir > -0.5 { return (n, stop, cross) }
            n += p.dir > 0 ? 1 : -1
        }
        let cross = cityLine(!p.alongX, n)
        return (n, Float(n) * G - p.dir * (cross.halfRoad + 0.9), cross)
    }

    // MARK: Update

    func update(dt: Float, clock: Float, player: FlightModel) {
        flashes.removeAll(keepingCapacity: true)
        maintain -= dt
        if maintain <= 0 || people.isEmpty {
            maintain = 0.5
            manage(player.pos, fill: people.isEmpty)
        }
        let bird = player.pos
        var watching = 0
        var nearby: Float = 0
        for k in people.indices {
            var p = people[k]
            let toBird = SIMD2(bird.x - p.pos.x, bird.z - p.pos.y)
            let flat = simd_length(toBird)
            let above = bird.y - p.y
            // Reactions: look up, point, take a photo, duck.
            let close = flat < 16 && above < 18 && above > -2
            if close {
                p.lookUp = min(1, p.lookUp + dt * 3)
                if p.point == 0 && p.photo == 0 && rng.float() < dt * 0.6 {
                    if rng.float() < 0.45 { p.photo = rng.float(2.5, 4) } else { p.point = rng.float(1.5, 3) }
                }
                if flat < 5 && above < 4 { p.cower = 1.2 }
                watching += 1
            } else {
                p.lookUp = max(0, p.lookUp - dt * 0.8)
            }
            p.point = max(0, p.point - dt)
            if p.photo > 0 {
                p.photo = max(0, p.photo - dt)
                if Int(p.photo * 3) != Int((p.photo + dt) * 3) && rng.float() < 0.5 {
                    let fwd = SIMD2(-sin(p.yaw), -cos(p.yaw))
                    flashes.append(SIMD3(p.pos.x + fwd.x * 0.25, p.y + 1.3 * p.scale, p.pos.y + fwd.y * 0.25))
                }
            }
            p.cower = max(0, p.cower - dt)
            nearby += 1 / (1 + flat * flat * 0.01)
            let stand = p.lookUp > 0.3 || p.cower > 0
            // Movement
            var moving = false
            switch p.mode {
            case .walk, .cross, .park, .platform:
                if stand && p.mode != .cross { break }
                let to = p.target - p.pos
                let d = simd_length(to)
                let sp = p.speed
                if d < 0.3 {
                    arrive(&p, clock: clock)
                } else {
                    p.pos += to / d * min(d, sp * dt)
                    moving = true
                    let want = atan2(-to.x, -to.y)
                    p.yaw += wrapAngle(want - p.yaw) * approach(8, dt)
                }
            case .waitCross:
                let axis = p.alongX ? 0 : 1
                let (n, _, _) = nextCorner(p)
                let (ni, nj) = p.alongX ? (n, p.line) : (p.line, n)
                p.timer += dt
                if CityLayout.signal(ni, nj, axis: axis, time: clock) == 0 || p.timer > 30 {
                    p.mode = .cross
                    p.timer = 0
                    let G = CityLayout.pitch
                    let cross = cityLine(!p.alongX, n)
                    p.target = walkPoint(p, along: Float(n) * G + p.dir * (cross.halfRoad + 0.9))
                }
            case .idle, .sit:
                p.timer -= dt
                if p.timer <= 0 && !stand {
                    p.mode = p.inPark ? .park : (p.stationY != nil ? .platform : .walk)
                    arrive(&p, clock: clock, resume: true)
                }
            }
            if stand {
                // Turn to face the bird.
                let want = atan2(-toBird.x, -toBird.y)
                p.yaw += wrapAngle(want - p.yaw) * approach(3, dt) * p.lookUp
            }
            if moving { p.phase += dt * p.speed * (p.jogger ? 3.4 : 5.2) / max(p.scale, 0.5) } else { p.phase += dt * 0.6 }
            p.headYaw = sin(p.phase * 0.31 + Float(k)) * 0.35 * (moving ? 0.3 : 1)
            if let y = p.stationY {
                p.y = y
            } else if !moving || Int(p.phase * 2) % 3 == 0 {
                p.y = groundY(p.pos)
            }
            // Step around the subway stairs (squeeze past on the curb side).
            if p.stationY == nil && moving && CitySubway.nearLine(p.pos.x, p.pos.y) && CitySubway.isHole(p.pos.x, p.pos.y) {
                let toLine = p.alongX ? SIMD2<Float>(0, Float(p.line) * CityLayout.pitch - p.pos.y) : SIMD2<Float>(Float(p.line) * CityLayout.pitch - p.pos.x, 0)
                if simd_length(toLine) > 0.1 { p.pos += simd_normalize(toLine) * min(3 * dt, simd_length(toLine)) }
            }
            people[k] = p
        }
        self.watching = watching
        self.nearby = nearby
    }

    private func groundY(_ p: SIMD2<Float>) -> Float {
        // On a bridge over the river, stand on the deck.
        let g = CityLayout.ground(p.x, p.y)
        if g < 4 {
            let s = CityLayout.nearestStreet(p.x, p.y)
            let G = CityLayout.pitch
            let alongX = s.alongX
            let k = Int(floor((alongX ? p.x : p.y) / G))
            if let e = CityLayout.edge(alongX: alongX, alongX ? k : s.index, alongX ? s.index : k), let b = e.bridge { return b.deck }
        }
        return g
    }

    /// Reached a waypoint: decide what's next.
    private func arrive(_ p: inout Person, clock: Float, resume: Bool = false) {
        let G = CityLayout.pitch
        if p.stationY != nil {
            // Pacing the platform, waiting for a train.
            if !resume && rng.float() < 0.5 { p.mode = .idle; p.timer = rng.float(3, 10); return }
            guard let seg = CitySubway.segment(alongX: p.station.2, p.station.0, p.station.1) else { return }
            let q = seg.world(rng.float(33, 87), p.platformSide * rng.float(7.2, 11.4), 0)
            p.target = SIMD2(q.x, q.z)
            p.mode = .platform
            return
        }
        if p.mode == .park {
            if !resume && rng.float() < 0.25 { p.mode = .idle; p.timer = rng.float(2, 7); return }
            let b = CityLayout.block(p.block.0, p.block.1)
            let c = b.center
            // Along the paths: to the centre, or out along an arm of the cross.
            if simd_distance(p.pos, c) < 3 {
                let arm = Int(rng.float(0, 3.99))
                let ext = [SIMD2<Float>(b.lo.x + 3, c.y), SIMD2(b.hi.x - 3, c.y), SIMD2(c.x, b.lo.y + 3), SIMD2(c.x, b.hi.y - 3)][arm]
                p.target = ext + SIMD2(rng.float(-0.8, 0.8), rng.float(-0.8, 0.8))
            } else {
                p.target = c + SIMD2(rng.float(-1, 1), rng.float(-1, 1))
            }
            p.mode = .park
            return
        }
        if p.mode == .cross {
            // Across the street: carry on along the same sidewalk.
            p.mode = .walk
        }
        if !resume && rng.float() < 0.08 { p.mode = .idle; p.timer = rng.float(1.5, 5); return }
        p.mode = .walk
        let (n, stopA, cross) = nextCorner(p)
        let a = along(p)
        if abs(a - stopA) > 1 {
            p.target = walkPoint(p, along: stopA)
            return
        }
        // At a corner: cross (wait for the light), turn the corner, or turn back.
        let r = rng.float()
        let ni = p.alongX ? n : p.line, nj = p.alongX ? p.line : n
        let crossExists = CityLayout.nodeExists(ni, nj)
        if r < 0.5 && crossExists {
            p.mode = .waitCross
            p.timer = 0
            p.target = p.pos
        } else if r < 0.92 && crossExists {
            // Turn onto the cross street, staying on this block's corner: into the corner square, then along the
            // new sidewalk, away from the street we were on.
            var q = p
            q.alongX = !p.alongX
            q.line = n
            q.side = -p.dir
            q.dir = p.side
            q.lateral = rng.float(0, max(0.2, cross.halfWidth - cross.halfRoad - 1.5))
            q.target = walkPoint(q, along: Float(p.line) * G + q.dir * (cityLine(p.alongX, p.line).halfRoad + 1.2))
            p = q
        } else {
            p.dir = -p.dir
            p.target = walkPoint(p, along: nextCorner(p).a)
        }
    }

    // MARK: Spawning

    private func manage(_ player: SIMD3<Float>, fill: Bool) {
        people.removeAll { simd_length(SIMD2($0.pos.x - player.x, $0.pos.y - player.z)) > radius + 40 }
        populateStations(player)
        let D = CityLayout.district(player.x, player.z)
        let target = Int(Float(maxPeople) * (0.55 + 0.45 * D))
        var tries = 0
        while people.count < target && tries < (fill ? 500 : 30) {
            tries += 1
            let a = rng.float(0, 2 * .pi)
            let r = fill ? sqrt(rng.float(0, 1)) * radius : rng.float(radius * 0.72, radius)
            let at = SIMD2(player.x + cos(a) * r, player.z + sin(a) * r)
            spawn(near: at)
        }
    }

    /// Passengers on the platforms of stations near the player.
    private func populateStations(_ player: SIMD3<Float>) {
        for seg in CitySubway.segments(near: player.x, player.z, radius: 150) where seg.station {
            let key = (seg.i, seg.j, seg.alongX)
            if people.contains(where: { $0.stationY != nil && $0.station == key }) { continue }
            let y = seg.floor(60) + CitySubway.platformY
            for k in 0..<12 {
                let side: Float = k % 2 == 0 ? 1 : -1
                let q = seg.world(rng.float(33, 87), side * rng.float(7.2, 11.4), y)
                var p = Person(model: Int(rng.float(0, Float(PersonModel.all.count) - 0.01)), scale: rng.float(0.9, 1.12), pos: SIMD2(q.x, q.z),
                               target: SIMD2(q.x, q.z), mode: .idle, speed: rng.float(0.9, 1.3), phase: rng.float(0, 6),
                               alongX: seg.alongX, line: 0, side: 1, dir: 1, lateral: 0)
                p.stationY = y
                p.y = y
                p.station = key
                p.platformSide = side
                p.timer = rng.float(0, 8)
                p.bag = rng.float() < 0.35
                p.cup = !p.bag && rng.float() < 0.2
                p.hat = rng.float() < 0.3 ? Int(rng.float(0, Float(PersonModel.accessoryHats.count) - 0.01)) : -1
                p.yaw = rng.float(0, 6.28)
                people.append(p)
            }
        }
    }

    private func spawn(near at: SIMD2<Float>) {
        let G = CityLayout.pitch
        let m = Int(rng.float(0, Float(PersonModel.all.count) - 0.01))
        var p = Person(model: m, scale: rng.float(0.9, 1.12), pos: at, target: at, mode: .walk, speed: rng.float(1.0, 1.5), phase: rng.float(0, 6),
                       alongX: true, line: 0, side: 1, dir: 1, lateral: 0)
        if rng.float() < 0.12 { p.kid = true; p.scale = rng.float(0.55, 0.7); p.speed *= 1.1 }
        let r = rng.float()
        if r < 0.32 { p.hat = Int(rng.float(0, Float(PersonModel.accessoryHats.count) - 0.01)) }
        p.bag = rng.float() < 0.3 && !p.kid
        p.cup = !p.bag && rng.float() < 0.15
        p.pack = rng.float() < 0.15
        let (bi, bj) = CityLayout.blockIndex(at.x, at.y)
        let b = CityLayout.block(bi, bj)
        if b.kind == .park && !CityLayout.onStreet(at.x, at.y) && rng.float() < 0.7 {
            // In a park: stroll (or jog) the paths, which cross in the middle.
            p.mode = .park
            p.inPark = true
            p.block = (bi, bj)
            let c = b.center
            p.pos = rng.float() < 0.5 ? SIMD2(clamp(c.x + rng.float(-45, 45), b.lo.x + 3, b.hi.x - 3), c.y)
                                      : SIMD2(c.x, clamp(c.y + rng.float(-45, 45), b.lo.y + 3, b.hi.y - 3))
            p.target = c
            if rng.float() < 0.2 { p.jogger = true; p.speed = rng.float(2.6, 3.3); p.bag = false; p.cup = false }
            p.y = CityLayout.ground(p.pos.x, p.pos.y)
            people.append(p)
            return
        }
        // On a sidewalk of the nearest street.
        let s = CityLayout.nearestStreet(at.x, at.y)
        p.alongX = s.alongX
        p.line = s.index
        let l = cityLine(p.alongX, p.line)
        p.side = rng.float() < 0.5 ? 1 : -1
        p.dir = rng.float() < 0.5 ? 1 : -1
        p.lateral = rng.float(0, max(0.2, l.halfWidth - l.halfRoad - 1.6))
        var a = p.alongX ? at.x : at.y
        // Not in the middle of an intersection.
        let k = (a / G).rounded()
        let cross = cityLine(!p.alongX, Int(k))
        if abs(a - k * G) < cross.halfRoad + 1.5 { a = k * G + (cross.halfRoad + 3) * (rng.float() < 0.5 ? 1 : -1) }
        p.pos = walkPoint(p, along: a)
        guard !CityLayout.isWater(p.pos.x, p.pos.y) || CityLayout.edge(alongX: p.alongX, p.alongX ? Int(floor(a / G)) : p.line,
                                                                       p.alongX ? p.line : Int(floor(a / G)))?.bridge != nil else { return }
        p.target = walkPoint(p, along: nextCorner(p).a)
        p.y = groundY(p.pos)
        if rng.float() < 0.12 { p.mode = .idle; p.timer = rng.float(1, 6) }
        p.yaw = atan2(-(p.target - p.pos).x, -(p.target - p.pos).y)
        people.append(p)
    }

    // MARK: Drawing

    /// Stamp everyone into the batched mesh (and camera flashes into the glow mesh).
    func draw(into mesh: DynamicMesh, glow: DynamicMesh, camera: SIMD3<Float>, bird: SIMD3<Float>) {
        for p in people {
            let d = simd_distance(SIMD3(p.pos.x, p.y, p.pos.y), camera)
            guard d < 170 else { continue }
            let model = PersonModel.all[p.model]
            let L = model.look
            let s = p.scale
            let walking = p.mode == .walk || p.mode == .cross || p.mode == .park
            let moving = walking && p.lookUp < 0.3 && p.cower == 0
            let ph = p.phase
            let stride: Float = moving ? (p.jogger ? 0.9 : 0.55) : 0
            let bob = moving ? abs(sin(ph)) * 0.035 * s : 0
            let crouch: Float = p.cower > 0 ? -0.18 * s : 0
            let hop: Float = p.kid && p.lookUp > 0.5 ? abs(sin(ph * 4)) * 0.25 : 0
            var roll: Float = 0
            if moving && L.gait == .waddle { roll = sin(ph) * 0.13 }
            let base = trs(SIMD3(p.pos.x, p.y + bob + crouch + hop, p.pos.y),
                           yawQuat(p.yaw) * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: p.jogger && moving ? -0.18 : 0, axis: SIMD3(1, 0, 0)), s)
            mesh.add(model.body, base)
            // Head: looks around, bobs (pigeons), looks up at the bird.
            var headQ = yawQuat(p.headYaw * (1 - p.lookUp))
            if p.lookUp > 0 {
                let to = bird - SIMD3(p.pos.x, p.y + 1.3 * s, p.pos.y)
                let pitchUp = atan2(to.y, max(simd_length(SIMD2(to.x, to.z)), 0.5))
                headQ = headQ * simd_quatf(angle: clamp(pitchUp, -0.2, 1.1) * p.lookUp, axis: SIMD3(1, 0, 0))
            }
            var neck = model.neck
            if moving && L.gait == .bob { neck.z += -0.06 * sin(ph * 2) }
            if p.cower > 0 { headQ = headQ * simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0)) }
            let headM = base * trs(neck, headQ)
            mesh.add(model.head, headM)
            if p.hat >= 0 {
                let hr: Float = 0.19 * (L.bigEyes ? 1.12 : 1)
                mesh.add(PersonModel.accessoryHats[p.hat], headM * trs(SIMD3(0, hr * 1.62, -0.02), simd_quatf(angle: 0, axis: kUp), 1.2))
            }
            // Legs swing; wings swing the other way (or point / hold up a phone).
            let swing = sin(ph) * stride
            mesh.add(model.leg, base * trs(model.hipL, simd_quatf(angle: swing, axis: SIMD3(1, 0, 0))))
            mesh.add(model.leg, base * trs(model.hipR, simd_quatf(angle: -swing, axis: SIMD3(1, 0, 0))))
            var wl = simd_quatf(angle: -swing * 0.6, axis: SIMD3(1, 0, 0))
            var wr = simd_quatf(angle: swing * 0.6, axis: SIMD3(1, 0, 0))
            if p.point > 0 { wr = simd_quatf(angle: -2.4, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.2, axis: SIMD3(0, 0, 1)) }
            if p.photo > 0 {
                wl = simd_quatf(angle: -1.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: 0.35, axis: SIMD3(0, 0, 1))
                wr = simd_quatf(angle: -1.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.35, axis: SIMD3(0, 0, 1))
            }
            if p.cower > 0 {
                wl = simd_quatf(angle: -2.6, axis: SIMD3(1, 0, 0)); wr = wl
            }
            let wingLM = base * trs(model.shoulderL, wl), wingRM = base * trs(model.shoulderR, wr)
            mesh.add(model.wingL, wingLM)
            mesh.add(model.wingR, wingRM)
            let handL = wingLM * trs(SIMD3(-0.02, -0.32 * L.height, -0.02), simd_quatf(angle: 0, axis: kUp))
            let handR = wingRM * trs(SIMD3(0.02, -0.32 * L.height, -0.02), simd_quatf(angle: 0, axis: kUp))
            if p.photo > 0 {
                mesh.add(PersonModel.phone, handR * trs(SIMD3(-0.06, 0, 0), simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))))
            } else {
                if p.bag { mesh.add(PersonModel.bag, handR) }
                if p.cup { mesh.add(PersonModel.cup, handL) }
            }
            if p.pack {
                let rb = 0.2 * L.fat
                mesh.add(PersonModel.backpack, base * trs(SIMD3(0, model.neck.y - 0.25, rb + 0.06), simd_quatf(angle: 0, axis: kUp)))
            }
        }
        for f in flashes { glow.add(PersonModel.flash, trs(f, simd_quatf(angle: 0, axis: kUp), 1), tint: 3) }
    }
}
