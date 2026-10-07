import SceneKit
import simd

// Life in the Wild West: a steam train working the line between towns (stopping at each station), cowboys strolling
// the boardwalks, horses tied up out front and riders in the street, longhorns grazing the plateau, tumbleweeds
// rolling with the wind, dust devils that toss birds about, vultures wheeling over the canyon, saloon doors that
// swing when something goes through, longhorns that stampede when you buzz them, and gold glinting in the old mines.

final class SteamTrain {
    let node = SCNNode()
    var cars: [(node: SCNNode, length: Float)] = []
    var line: Int
    /// The locomotive's front, along x; heading east (+1) or west (−1).
    var x: Float
    var dir: Float
    var speed: Float = 14
    var dwell: Float = 0
    var lastStop = Int.min
    let smoke = SCNParticleSystem()
    var chuff: Float = 0
    var whistled = false
    /// From the locomotive's front back to the middle of the coaches: where the train stops, so the coaches stand along the platform.
    private(set) var stopOffset: Float = 40

    init(line: Int, x: Float, dir: Float) {
        self.line = line; self.x = x; self.dir = dir
        for (k, (g, len)) in SteamTrain.parts.enumerated() {
            let n = SCNNode(geometry: g)
            n.castsShadow = true
            node.addChildNode(n)
            cars.append((n, len))
            if k == 4 { stopOffset = cars.reduce(0) { $0 + $1.length + 0.6 } - 0.6 - (3 * 14.6 + 1.2) / 2 }
            if k == 0 {
                let stack = SCNNode()
                stack.position = SCNVector3(0, 4.7, -4.6)
                stack.addParticleSystem(smoke)
                n.addChildNode(stack)
            }
        }
        smoke.birthRate = 12
        smoke.emitterShape = SCNSphere(radius: 0.35)
        smoke.emittingDirection = SCNVector3(0, 1, 0)
        smoke.spreadingAngle = 12
        smoke.particleVelocity = 6
        smoke.particleLifeSpan = 5
        smoke.particleSize = 1.4
        smoke.particleColor = NSColor(white: 0.85, alpha: 0.75)
        smoke.particleImage = SteamTrain.puff
        smoke.blendMode = .alpha
        smoke.isLightingEnabled = false
        smoke.acceleration = SCNVector3(0, 0.8, 0)
        let grow = CAKeyframeAnimation(); grow.values = [0.8, 2.6, 5.5]; grow.keyTimes = [0, 0.3, 1]
        let fade = CAKeyframeAnimation(); fade.values = [0.9, 0.55, 0]; fade.keyTimes = [0, 0.4, 1]
        smoke.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
    }

    static let puff: CGImage = makeImage(width: 64, height: 64) { x, y in
        let d = simd_length(SIMD2(Float(x) - 31.5, Float(y) - 31.5)) / 32
        let a = max(0, 1 - d)
        return SIMD4(1, 1, 1, a * a * (3 - 2 * a))
    }

    /// Locomotive, tender, three coaches and a caboose (each built facing −z, front at z = −len/2).
    static let parts: [(SCNGeometry, Float)] = {
        let mat = WorldMaterials.finishes()
        func geo(_ m: MeshBuilder) -> SCNGeometry { let g = m.geometry(); g.materials = [mat]; return g }
        let black = SIMD3<Float>(0.09, 0.09, 0.1), red = SIMD3<Float>(0.62, 0.13, 0.09), brass = SIMD3<Float>(0.85, 0.68, 0.3)
        let gloss = SIMD2<Float>(1, 0), metal = SIMD2<Float>(3, 0), lit = SIMD2<Float>(4, 0)
        func wheels(_ m: inout MeshBuilder, at zs: [Float], r: Float, color: SIMD3<Float>) {
            for z in zs { for s: Float in [-1, 1] {
                m.tube(SIMD3(s * 0.72, r, z), SIMD3(s * 0.86, r, z), r0: r, r1: r, sides: 12, color, uv: gloss, cap: true)
                m.tube(SIMD3(s * 0.86, r, z), SIMD3(s * 0.72, r, z), r0: r * 0.3, r1: r * 0.3, sides: 6, black, cap: true)
            } }
        }
        // Locomotive (12 m)
        var loco = MeshBuilder()
        loco.tube(SIMD3(0, 2.25, -5.6), SIMD3(0, 2.25, 1.6), r0: 0.95, r1: 0.95, sides: 14, black, uv: gloss, cap: true)
        loco.tube(SIMD3(0, 2.25, -5.7), SIMD3(0, 2.25, -5.4), r0: 0.98, r1: 0.98, sides: 14, SIMD3(0.18, 0.18, 0.2), uv: metal, cap: true)
        for z: Float in [-3.4, -1.0, 0.8] { loco.tube(SIMD3(0, 2.25, z), SIMD3(0, 2.25, z + 0.12), r0: 1.0, r1: 1.0, sides: 14, brass, uv: metal) }
        // Smokestack (a flared funnel), domes, bell, headlamp.
        loco.cylinder(SIMD3(0, 3.0, -4.6), r0: 0.3, r1: 0.55, y0: 0, y1: 1.6, sides: 10, black, uv: gloss)
        loco.ellipsoid(SIMD3(0, 3.15, -2.2), SIMD3(0.42, 0.45, 0.42), brass, rings: 3, sides: 8, uv: metal)
        loco.ellipsoid(SIMD3(0, 3.15, -0.4), SIMD3(0.38, 0.38, 0.38), black, rings: 3, sides: 8, uv: gloss)
        loco.ellipsoid(SIMD3(0, 3.45, -1.3), SIMD3(0.2, 0.22, 0.2), brass, rings: 3, sides: 6, uv: metal)
        loco.box(SIMD3(0, 3.35, -5.75), SIMD3(0.35, 0.3, 0.3), black, uv: gloss)
        loco.ellipsoid(SIMD3(0, 3.35, -6.05), SIMD3(0.24, 0.24, 0.06), SIMD3(1, 0.92, 0.7), rings: 2, sides: 8, uv: lit)
        // Cab with a roof and windows; running boards; the cowcatcher.
        loco.box(SIMD3(0, 2.6, 3.2), SIMD3(1.35, 1.35, 1.6), red, uv: gloss)
        loco.box(SIMD3(0, 4.05, 3.2), SIMD3(1.55, 0.12, 1.85), black, uv: gloss)
        for s: Float in [-1, 1] { loco.box(SIMD3(s * 1.36, 3.0, 3.0), SIMD3(0.02, 0.45, 0.6), SIMD3(0.95, 0.85, 0.55), uv: lit) }
        loco.box(SIMD3(0, 1.2, -1.5), SIMD3(1.25, 0.08, 4.6), black, uv: gloss)
        loco.box(SIMD3(0, 0.95, -0.5), SIMD3(0.55, 0.3, 4.4), black, uv: gloss)
        for k in 0..<7 {
            let x = Float(k - 3) * 0.24
            loco.tube(SIMD3(x, 1.05, -6.0), SIMD3(x * 1.5, 0.15, -7.2), r0: 0.05, r1: 0.05, sides: 4, red, uv: gloss)
        }
        wheels(&loco, at: [-0.9, 0.9, 2.7], r: 0.82, color: red)
        wheels(&loco, at: [-4.6, -3.6], r: 0.45, color: red)
        for s: Float in [-1, 1] { loco.box(SIMD3(s * 0.92, 0.82, 0.9), SIMD3(0.04, 0.07, 1.9), SIMD3(0.6, 0.6, 0.62), uv: metal) }
        // Tender (6 m)
        var tender = MeshBuilder()
        tender.box(SIMD3(0, 1.85, 0), SIMD3(1.35, 1.0, 2.9), black, uv: gloss)
        tender.ellipsoid(SIMD3(0, 2.9, -0.6), SIMD3(1.1, 0.35, 1.8), SIMD3(0.06, 0.06, 0.06), rings: 3, sides: 8)
        tender.box(SIMD3(0, 2.0, 0), SIMD3(1.38, 0.08, 2.92), red, uv: gloss)
        wheels(&tender, at: [-2, -1, 1, 2], r: 0.45, color: red)
        // Coaches (14 m) in two liveries, and the caboose (8 m) with its cupola.
        func coach(_ body: SIMD3<Float>) -> MeshBuilder {
            var c = MeshBuilder()
            c.box(SIMD3(0, 2.2, 0), SIMD3(1.4, 1.2, 6.6), body, uv: gloss)
            c.box(SIMD3(0, 3.5, 0), SIMD3(1.5, 0.15, 6.8), SIMD3(0.25, 0.22, 0.2))
            c.box(SIMD3(0, 3.75, 0), SIMD3(0.8, 0.15, 6.2), SIMD3(0.25, 0.22, 0.2))
            c.box(SIMD3(0, 1.2, 0), SIMD3(1.42, 0.08, 6.62), brass, uv: metal)
            for k in 0..<9 {
                let z = -5.6 + Float(k) * 1.4
                for s: Float in [-1, 1] { c.box(SIMD3(s * 1.41, 2.5, z), SIMD3(0.02, 0.38, 0.42), SIMD3(0.95, 0.85, 0.6), uv: lit) }
            }
            for z: Float in [-7, 7] { c.box(SIMD3(0, 1.0, z), SIMD3(1.3, 0.08, 0.5), SIMD3(0.2, 0.2, 0.2)) }
            wheels(&c, at: [-5.4, -4.4, 4.4, 5.4], r: 0.45, color: SIMD3(0.2, 0.2, 0.22))
            return c
        }
        var caboose = MeshBuilder()
        caboose.box(SIMD3(0, 2.2, 0), SIMD3(1.4, 1.2, 3.6), SIMD3(0.7, 0.16, 0.1), uv: gloss)
        caboose.box(SIMD3(0, 3.6, 0.5), SIMD3(0.9, 0.5, 1.2), SIMD3(0.7, 0.16, 0.1), uv: gloss)
        caboose.box(SIMD3(0, 3.5, 0), SIMD3(1.5, 0.1, 3.8), SIMD3(0.22, 0.2, 0.18))
        for s: Float in [-1, 1] { caboose.box(SIMD3(s * 0.91, 3.65, 0.5), SIMD3(0.02, 0.25, 0.5), SIMD3(0.95, 0.85, 0.6), uv: lit) }
        wheels(&caboose, at: [-2.5, -1.5, 1.5, 2.5], r: 0.45, color: SIMD3(0.2, 0.2, 0.22))
        return [(geo(loco), 12.5), (geo(tender), 6.4), (geo(coach(SIMD3(0.22, 0.38, 0.26))), 14.6), (geo(coach(SIMD3(0.5, 0.18, 0.12))), 14.6),
                (geo(coach(SIMD3(0.22, 0.38, 0.26))), 14.6), (geo(caboose), 8.2)]
    }()
}

final class WestLife {
    let root = SCNNode()
    let terrain: WestTerrain
    let mesh: DynamicMesh?
    var camera = SIMD3<Float>.zero
    private(set) var clock: Float = 0
    var notices: [String] = []
    var hits: [HazardHit] = []
    var rewards: [WorldReward] = []
    var threat: String?
    var quake: Float = 0
    /// Dust devils: lift and a shove for the player this frame.
    private(set) var devilLift: Float = 0
    private(set) var devilKick = SIMD3<Float>.zero
    private var rng = SplitMix64(seed: 0x3E57)

    // The train.
    private(set) var train: SteamTrain?
    // People and animals near the player.
    struct Cowboy {
        var pos: SIMD2<Float>
        var y: Float
        var yaw: Float
        var target: SIMD2<Float>
        var speed: Float
        var phase: Float
        var model: Int
        var hat: Int
        var bandana: SIMD3<Float>
        var wait: Float
        var lookUp: Float = 0
        var walkZ: Float
        var town: Int64
    }
    private(set) var cowboys: [Cowboy] = []
    final class Animal {
        let sp: DinoSpecies
        var pos: SIMD2<Float>
        var yaw: Float
        var speed: Float = 0
        var want: Float = 0
        var goal: SIMD2<Float>?
        var motion = DinoMotion()
        var pose: [simd_quatf] = []
        var mats: [simd_float4x4] = []
        let coat: SIMD3<Float>
        let scale: Float
        var rider: Int = -1
        /// The cowboy riding herd on the longhorns (rides after them when they stampede).
        var herder = false
        /// Seconds of stampede left, and which way it's running.
        var panic: Float = 0
        var flee = SIMD2<Float>(0, -1)
        var timer: Float = 0
        let home: SIMD2<Float>
        let tied: Bool
        let town: Int64
        init(_ sp: DinoSpecies, pos: SIMD2<Float>, yaw: Float, coat: SIMD3<Float>, scale: Float, tied: Bool, town: Int64) {
            self.sp = sp; self.pos = pos; self.yaw = yaw; self.coat = coat; self.scale = scale; self.tied = tied; home = pos; self.town = town
            motion.phase = Float(abs(Int(pos.x * 7 + pos.y))) .truncatingRemainder(dividingBy: 1)
        }
    }
    private(set) var animals: [Animal] = []
    private var townsAlive = Set<Int64>()
    struct Tumbleweed { var pos: SIMD3<Float>; var vel: SIMD3<Float>; var spin: Float; var size: Float; var hop: Float }
    private(set) var weeds: [Tumbleweed] = []
    final class DustDevil {
        let node = SCNNode()
        var pos: SIMD2<Float>
        var vel: SIMD2<Float>
        var life: Float
        init(pos: SIMD2<Float>, vel: SIMD2<Float>, life: Float) { self.pos = pos; self.vel = vel; self.life = life }
    }
    private(set) var devils: [DustDevil] = []
    private(set) var vultures: [Ptero] = []
    private var doors: [Int64: [(SCNNode, Float, Float)]] = [:]   // per saloon: (node, angle, velocity)
    private var wind = SIMD2<Float>(1, 0.2)
    private var whistleT: Float = 30
    private var bellT: Float = 40
    private var coyoteT: Float = 20
    private var mooT: Float = 8
    // Stampedes: per town, when the herd may bolt again; the dust they kick up; hoofbeats.
    private var stampedeCool: [Int64: Float] = [:]
    private let herdDust = SCNNode()
    private let herdDustPS = WestLife.stampedeDust()
    private(set) var stampedeAt: SIMD3<Float>?
    private var hoofT: Float = 0
    private var moos = 0
    private var rumbling = false
    // Gold in the old mines.
    private let goldMesh: DynamicMesh?
    private(set) var goldHere: [SIMD3<Float>] = []
    private var goldTaken: [Int64: Float] = [:]
    private var foundGold = false

    init(terrain: WestTerrain) {
        self.terrain = terrain
        mesh = DynamicMesh(maxVertices: 160_000, maxTriangles: 200_000, material: WorldMaterials.vertexColor(rough: 0.8))
        if let mesh {
            mesh.node.castsShadow = true
            root.addChildNode(mesh.node)
        }
        goldMesh = DynamicMesh(maxVertices: 6_000, maxTriangles: 9_000, material: WorldMaterials.glow(1.5))
        if let goldMesh { root.addChildNode(goldMesh.node) }
        herdDust.simdPosition = SIMD3(0, -500, 0)
        herdDust.addParticleSystem(herdDustPS)
        root.addChildNode(herdDust)
    }

    // MARK: Update

    func update(dt: Float, player: FlightModel, sound: SoundEngine?, underground: Float) {
        clock += dt
        notices.removeAll(keepingCapacity: true)
        hits.removeAll(keepingCapacity: true)
        threat = nil
        quake = 0
        devilLift = 0
        devilKick = .zero
        let p = player.pos
        wind = SIMD2(cos(clock * 0.02), sin(clock * 0.02) * 0.4 + 0.2)
        updateTrain(dt, player, sound)
        if Int(clock * 2) != Int((clock - dt) * 2) { manageTowns(p) }
        updateCowboys(dt, player)
        updateAnimals(dt, player)
        stampedeEffects(dt, p)
        updateGold(p)
        updateWeeds(dt, p)
        updateDevils(dt, player)
        updateVultures(dt, p)
        updateDoors(dt, p)
        ambience(dt, player, sound, underground: underground)
        draw()
    }

    // MARK: The train

    /// Tests: take the train off so a fresh one is sent down the line.
    func resetTrain() { train?.node.removeFromParentNode(); train = nil }

    private func updateTrain(_ dt: Float, _ player: FlightModel, _ sound: SoundEngine?) {
        let p = player.pos
        let (k, dl) = WestLayout.nearestLine(p.z)
        if train == nil || (train!.line != k && dl < 900) {
            train?.node.removeFromParentNode()
            let dir: Float = rng.float() < 0.5 ? 1 : -1
            let t = SteamTrain(line: k, x: p.x - dir * rng.float(900, 1400), dir: dir)
            root.addChildNode(t.node)
            train = t
        }
        guard let t = train else { return }
        // Keep it within reach: if it's run far off, bring it back from the other side, heading this way.
        if abs(t.x - p.x) > 2600 { t.x = p.x - t.dir * 1700; t.lastStop = Int.min }
        // Stations: slow to a stop with the coaches along the platform, wait, whistle, go.
        var target: Float = 15
        let i0 = Int(floor(t.x / WestLayout.townSpacing))
        for i in [i0 - 1, i0, i0 + 1, i0 + 2] where i != t.lastStop {
            guard let town = WestLayout.town(line: t.line, i) else { continue }
            let stopX = town.center.x + t.dir * t.stopOffset
            let ahead = (stopX - t.x) * t.dir
            if ahead > -1 && ahead < 220 {
                target = min(target, sqrt(max(0, 2 * 0.55 * max(0, ahead))))
                if ahead < 1.2 && t.speed < 0.6 && t.dwell <= 0 { t.dwell = 9; t.lastStop = i; t.whistled = false }
            }
        }
        if t.dwell > 0 {
            t.dwell -= dt
            target = 0
            if t.dwell < 1.5 && !t.whistled { t.whistled = true; whistle(t, sound, p) }
        }
        t.speed += clamp(target - t.speed, -1.6 * dt, 0.7 * dt)
        t.speed = max(0, t.speed)
        t.x += t.dir * t.speed * dt
        // Place the cars along the track.
        var along = t.x
        let z = WestLayout.lineZ(t.line)
        for (n, len) in t.cars {
            let c = along - t.dir * len / 2
            let y0 = WestLayout.trackY(c - t.dir * len * 0.4, line: t.line), y1 = WestLayout.trackY(c + t.dir * len * 0.4, line: t.line)
            n.simdPosition = SIMD3(c, (y0 + y1) / 2 + 0.16, z)
            let pitch = atan2(y1 - y0, len * 0.8)
            n.simdOrientation = yawQuat(t.dir > 0 ? -.pi / 2 : .pi / 2) * rotX(pitch)
            along -= t.dir * (len + 0.6)
        }
        t.smoke.birthRate = CGFloat(6 + t.speed * 2.2 + (t.dwell > 0 ? 2 : 0))
        // Whistle when the bird's on the line ahead.
        whistleT -= dt
        let rel = (p.x - t.x) * t.dir
        if rel > 0 && rel < 160 && abs(p.z - z) < 8 && p.y < WestLayout.trackY(p.x, line: t.line) + 8 && whistleT <= 0 && t.speed > 4 {
            whistle(t, sound, p)
            threat = "Train coming!"
        }
        // Close to a train going by, you feel it.
        if t.speed > 3 {
            for (n, len) in t.cars where abs(n.simdPosition.x - p.x) < len / 2 + 14 {
                let d = simd_distance(n.simdPosition + SIMD3(0, 2, 0), p)
                if d < 22 { quake = max(quake, 0.12 * smoothstep(22, 5, d) * min(t.speed / 12, 1)) }
            }
        }
        // Racing alongside the locomotive.
        let loco = SIMD3(t.x - t.dir * 6, WestLayout.trackY(t.x, line: t.line) + 2.5, z)
        if t.speed > 9 && simd_distance(loco, p) < 14 {
            rewards.append(WorldReward(id: "west.train", title: "You raced the steam train!", coins: 30, once: true))
        }
        // Chuffing.
        let d = simd_distance(loco, camera == .zero ? p : camera)
        let right = SIMD3(cos(player.yaw), 0, -sin(player.yaw))
        let to = loco - p
        sound?.setTrain(gain: smoothstep(900, 30, d) * (0.4 + 0.6 * min(t.speed / 12, 1)), pan: simd_length(to) > 1 ? clamp(simd_dot(to / simd_length(to), right), -1, 1) : 0,
                        rate: max(0.4, t.speed * 0.6))
    }

    private func whistle(_ t: SteamTrain, _ sound: SoundEngine?, _ p: SIMD3<Float>) {
        whistleT = 12
        let loco = SIMD3(t.x, WestLayout.trackY(t.x, line: t.line), WestLayout.lineZ(t.line))
        if simd_distance(loco, p) < 1600 { sound?.steamWhistle(gain: smoothstep(1600, 50, simd_distance(loco, p))) }
    }

    /// The train's cars as boxes (collisions).
    func trainBoxes(near p: SIMD3<Float>) -> [OBox] {
        guard let t = train else { return [] }
        let z = WestLayout.lineZ(t.line)
        guard abs(p.z - z) < 12 else { return [] }
        var out: [OBox] = []
        for (n, len) in t.cars where abs(n.simdPosition.x - p.x) < len / 2 + 6 {
            out.append(OBox(center: n.simdPosition + SIMD3(0, 2.2, 0), rot: n.simdOrientation, half: SIMD3(1.45, 2.0, len / 2)))
        }
        return out
    }

    // MARK: Towns: cowboys, horses, cattle, saloon doors

    private func townID(_ t: WestLayout.Town) -> Int64 { (Int64(t.line) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: t.index))) }

    private func manageTowns(_ p: SIMD3<Float>) {
        let near = WestLayout.towns(near: SIMD2(p.x, p.z), radius: 700)
        let ids = Set(near.map(townID))
        // Drop towns we've left behind.
        for id in townsAlive where !ids.contains(id) {
            cowboys.removeAll { $0.town == id }
            animals.removeAll { $0.town == id }
            doors[id]?.forEach { $0.0.removeFromParentNode() }
            doors.removeValue(forKey: id)
        }
        townsAlive = townsAlive.intersection(ids)
        for t in near where !townsAlive.contains(townID(t)) {
            townsAlive.insert(townID(t))
            populate(t)
        }
    }

    private static let coats: [SIMD3<Float>] = [SIMD3(0.42, 0.26, 0.16), SIMD3(0.82, 0.68, 0.42), SIMD3(0.12, 0.1, 0.09), SIMD3(0.88, 0.86, 0.82),
                                                SIMD3(0.55, 0.36, 0.22), SIMD3(0.62, 0.6, 0.58)]
    private static let steerCoats: [SIMD3<Float>] = [SIMD3(0.5, 0.3, 0.18), SIMD3(0.85, 0.82, 0.76), SIMD3(0.18, 0.14, 0.12), SIMD3(0.7, 0.42, 0.24)]

    private func populate(_ t: WestLayout.Town) {
        let id = townID(t)
        var r = SplitMix64(seed: UInt64(bitPattern: id) | 1)
        let plan = WestTown.plan(t)
        let cx = t.center.x, cz = t.center.y
        let hw = WestLayout.streetHalfWidth, L = WestLayout.streetHalfLength
        // Folk on the boardwalks and in the street.
        for _ in 0..<18 {
            let side: Float = r.float() < 0.5 ? 1 : -1
            let walkZ = cz + side * (hw + 1.6)
            let x = cx + r.float(-L + 5, L - 5)
            cowboys.append(Cowboy(pos: SIMD2(x, walkZ), y: t.ground + 0.35, yaw: r.float() < 0.5 ? -.pi / 2 : .pi / 2, target: SIMD2(cx + r.float(-L, L), walkZ),
                                  speed: r.float(0.9, 1.4), phase: r.float(0, 6), model: Int(r.float(0, Float(PersonModel.all.count) - 0.01)),
                                  hat: Int(r.float(0, 3.99)), bandana: [SIMD3<Float>(0.75, 0.15, 0.12), SIMD3(0.2, 0.3, 0.65), SIMD3(0.9, 0.85, 0.75)][Int(r.float(0, 2.99))],
                                  wait: r.float(0, 6), walkZ: walkZ, town: id))
        }
        // Horses tied at the rails, a couple of riders in the street.
        let horse = DinoSpecies.all[.horse]!
        for (k, (pt, _)) in plan.hitching.enumerated() {
            let a = Animal(horse, pos: SIMD2(pt.x + (k % 2 == 0 ? -0.8 : 0.8), pt.z + (pt.z > cz ? -1.6 : 1.6)), yaw: pt.z > cz ? 0 : .pi,
                           coat: WestLife.coats[Int(r.float(0, Float(WestLife.coats.count) - 0.01))], scale: r.float(0.95, 1.05), tied: true, town: id)
            animals.append(a)
        }
        for _ in 0..<2 {
            let a = Animal(horse, pos: SIMD2(cx + r.float(-L, L), cz + r.float(-4, 4)), yaw: r.float() < 0.5 ? -.pi / 2 : .pi / 2,
                           coat: WestLife.coats[Int(r.float(0, Float(WestLife.coats.count) - 0.01))], scale: 1, tied: false, town: id)
            a.rider = Int(r.float(0, Float(PersonModel.all.count) - 0.01))
            animals.append(a)
        }
        // Longhorns grazing out past the corral, with a rider keeping an eye on them.
        let steer = DinoSpecies.all[.steer]!
        let herd = SIMD2(cx - L - 120, cz + r.float(-60, 80))
        if terrain.open(herd.x, herd.y) {
            for _ in 0..<Int(r.float(6, 11)) {
                let q = herd + SIMD2(r.float(-30, 30), r.float(-25, 25))
                guard terrain.open(q.x, q.y) else { continue }
                animals.append(Animal(steer, pos: q, yaw: r.float(0, 6.28), coat: WestLife.steerCoats[Int(r.float(0, 3.99))], scale: r.float(0.9, 1.1),
                                      tied: false, town: id))
            }
            let rider = Animal(horse, pos: herd + SIMD2(40, 0), yaw: 0, coat: WestLife.coats[0], scale: 1, tied: false, town: id)
            rider.rider = 2
            rider.herder = true
            animals.append(rider)
        }
        // The saloon's doors (front and back).
        if let s = plan.saloon {
            var list: [(SCNNode, Float, Float)] = []
            let mid = (s.lo.x + s.hi.x) / 2
            for z in [s.lo.z, s.hi.z] {
                for side: Float in [-1, 1] {
                    let hinge = SCNNode()
                    let dh = WestTown.doorHalf
                    hinge.simdPosition = SIMD3(mid + side * (dh - 0.05), s.lo.y + 1.0, z)
                    let leaf = SCNNode(geometry: SCNBox(width: CGFloat(dh - 0.1), height: 1.6, length: 0.08, chamferRadius: 0.02))
                    leaf.geometry?.materials = [WestTown.wood]
                    leaf.simdPosition = SIMD3(-side * (dh - 0.1) / 2, 0.8, 0)
                    hinge.addChildNode(leaf)
                    root.addChildNode(hinge)
                    list.append((hinge, 0, 0))
                }
            }
            doors[id] = list
        }
    }

    private func updateCowboys(_ dt: Float, _ player: FlightModel) {
        let bird = player.pos
        for i in cowboys.indices {
            var c = cowboys[i]
            let toBird = SIMD2(bird.x - c.pos.x, bird.z - c.pos.y)
            let close = simd_length(toBird) < 26 && bird.y - c.y < 18
            c.lookUp += ((close ? 1 : 0) - c.lookUp) * min(1, dt * 3)
            if c.wait > 0 {
                c.wait -= dt
            } else {
                let to = c.target - c.pos
                let d = simd_length(to)
                if d < 0.6 {
                    c.wait = rng.float(1, 8)
                    c.target = SIMD2(c.pos.x + rng.float(-60, 60), c.walkZ)
                    // Keep to the street's length.
                    if let t = WestLayout.towns(near: c.pos, radius: 200).first {
                        c.target.x = clamp(c.target.x, t.center.x - WestLayout.streetHalfLength + 3, t.center.x + WestLayout.streetHalfLength - 3)
                    }
                } else {
                    let want = atan2(-to.x, -to.y)
                    var dy = want - c.yaw
                    while dy > .pi { dy -= 2 * .pi }
                    while dy < -.pi { dy += 2 * .pi }
                    c.yaw += clamp(dy, -4 * dt, 4 * dt)
                    if c.lookUp < 0.5 {
                        c.pos += SIMD2(-sin(c.yaw), -cos(c.yaw)) * c.speed * dt
                        c.phase += dt * c.speed * 6.5
                    }
                }
            }
            cowboys[i] = c
        }
    }

    private func updateAnimals(_ dt: Float, _ player: FlightModel) {
        // Buzz the longhorns low and fast (or let a dust devil through them) and the whole herd bolts.
        let bird = SIMD2(player.pos.x, player.pos.z)
        for a in animals where a.sp.kind == .steer && a.panic <= 0 {
            if simd_distance(a.pos, bird) < 15 && player.pos.y - terrain.height(a.pos.x, a.pos.y) < 10 && player.speed > 9 {
                stampede(a.town, from: bird, byBird: true)
                break
            }
            if let dv = devils.first(where: { simd_distance($0.pos, a.pos) < 24 }) {
                stampede(a.town, from: dv.pos, byBird: false)
                break
            }
        }
        var herd = SIMD2<Float>.zero, running = 0
        for a in animals where a.panic > 0 && a.speed > 2 { herd += a.pos; running += 1 }
        let herdMid: SIMD2<Float>? = running > 0 ? herd / Float(running) : nil
        for a in animals {
            a.timer -= dt
            a.motion.time += dt
            if a.panic > 0 {
                // Stampeding: flat out, together, away — swinging along a canyon's rim (or round the town) rather than
                // over it or through it.
                a.panic -= dt
                func clear(_ d: SIMD2<Float>) -> Bool {
                    let q = a.pos + d * 16
                    return terrain.open(q.x, q.y) && (WestLayout.townBlend(q.x, q.y)?.1 ?? 0) < 0.5
                }
                if !clear(a.flee) {
                    let l = SIMD2(-a.flee.y, a.flee.x)
                    if clear(simd_normalize(a.flee + l)) { a.flee = simd_normalize(a.flee + l * 0.5) }
                    else if clear(simd_normalize(a.flee - l)) { a.flee = simd_normalize(a.flee - l * 0.5) }
                    else { a.flee = -a.flee }
                }
                a.goal = a.pos + a.flee * 30
                a.want = a.panic > 1.5 ? a.sp.run * 1.1 : a.sp.walk
                if a.panic <= 0 { a.goal = nil; a.timer = rng.float(2, 5) }
            } else if a.herder, let mid = herdMid, simd_distance(mid, a.pos) < 160 {
                // The cowboy rides after them.
                a.goal = mid
                a.want = a.sp.run
                a.timer = 4
            } else if a.tied {
                // Shift about, swish tails, nibble.
                a.want = 0
                if a.timer <= 0 { a.timer = rng.float(3, 9); a.motion.neck = rng.float() < 0.4 ? -0.8 : 0 }
            } else if a.rider >= 0 {
                // Riders amble up and down the street (or circle the herd).
                if a.goal == nil || simd_distance(a.goal!, a.pos) < 3 || a.timer <= 0 {
                    a.timer = rng.float(15, 30)
                    let span: Float = a.sp.kind == .horse ? 90 : 40
                    a.goal = a.home + SIMD2(rng.float(-span, span), rng.float(-8, 8))
                }
                a.want = a.sp.walk * 1.5
            } else {
                // Cattle graze and drift.
                if a.timer <= 0 {
                    a.timer = rng.float(6, 18)
                    if rng.float() < 0.5 { a.goal = a.home + SIMD2(rng.float(-35, 35), rng.float(-30, 30)); a.motion.neck = 0 } else { a.goal = nil; a.motion.neck = -0.9 }
                }
                a.want = a.goal == nil ? 0 : a.sp.walk
            }
            if let g = a.goal, a.want > 0 {
                let to = g - a.pos
                if simd_length(to) < 2 { a.goal = nil; a.want = 0 } else {
                    let want = atan2(-to.x, -to.y)
                    var dy = want - a.yaw
                    while dy > .pi { dy -= 2 * .pi }
                    while dy < -.pi { dy += 2 * .pi }
                    let turnRate = a.sp.turn * (a.panic > 0 ? 1.8 : 1)
                    let turn = clamp(dy, -turnRate * dt, turnRate * dt)
                    a.yaw += turn
                    a.motion.turning = turn / max(dt, 1e-4)
                }
            }
            a.speed += clamp(a.want - a.speed, -2 * dt, (a.panic > 0 || (a.herder && a.want > a.sp.walk * 2) ? 4 : 1.2) * dt)
            a.pos += SIMD2(-sin(a.yaw), -cos(a.yaw)) * a.speed * dt
            a.motion.speed = a.speed
            a.motion.step(a.sp, dt: dt, scale: a.scale)
            a.motion.lookYaw = sin(a.motion.time * 0.3 + a.home.x) * 0.3
        }
    }

    /// The dust cloud over a running herd (left hanging behind it), and the ground shaking under the bird.
    private func stampedeEffects(_ dt: Float, _ p: SIMD3<Float>) {
        var mid = SIMD2<Float>.zero, n = 0
        for a in animals where a.panic > 0 && a.speed > 2 { mid += a.pos; n += 1 }
        guard n > 0 else {
            stampedeAt = nil
            herdDustPS.birthRate = 0
            return
        }
        mid /= Float(n)
        let at = SIMD3(mid.x, terrain.height(mid.x, mid.y), mid.y)
        stampedeAt = at
        herdDust.simdPosition = at + SIMD3(0, 0.5, 0)
        herdDustPS.birthRate = CGFloat(10 * n)
        let d = simd_distance(at, p)
        if d < 45 && p.y - at.y < 20 { quake = max(quake, 0.14 * smoothstep(45, 8, d)) }
    }

    /// Tests and the tour: set the nearest herd running.
    func debugStampede() {
        guard let a = animals.first(where: { $0.sp.kind == .steer }) else { return }
        stampede(a.town, from: a.pos + SIMD2(40, 10), byBird: false)
    }

    private func stampede(_ town: Int64, from threat: SIMD2<Float>, byBird: Bool) {
        if let until = stampedeCool[town], clock < until { return }
        let herd = animals.filter { $0.town == town && $0.sp.kind == .steer }
        guard !herd.isEmpty else { return }
        let c = herd.reduce(SIMD2<Float>.zero) { $0 + $1.pos } / Float(herd.count)
        var away = c - threat
        if simd_length(away) < 0.1 { away = SIMD2(1, 0) }
        away = simd_normalize(away)
        for a in herd {
            a.panic = rng.float(9, 13)
            let j = rng.float(-0.25, 0.25)
            a.flee = SIMD2(away.x * cos(j) - away.y * sin(j), away.x * sin(j) + away.y * cos(j))
            a.motion.neck = 0
        }
        stampedeCool[town] = clock + 30
        moos = 3
        if byBird {
            notices.append("Stampede!")
            rewards.append(WorldReward(id: "west.stampede", title: "You started a stampede!", coins: 30, once: true))
        }
    }

    private static func stampedeDust() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 0
        s.emitterShape = SCNCylinder(radius: 12, height: 1)
        s.birthLocation = .volume
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 55
        s.particleVelocity = 2.5
        s.particleVelocityVariation = 1.5
        s.particleLifeSpan = 5
        s.particleLifeSpanVariation = 1.5
        s.particleSize = 4
        s.particleSizeVariation = 1.5
        s.acceleration = SCNVector3(0.4, 0.35, 0.1)
        s.particleImage = SteamTrain.puff
        s.particleColor = NSColor(srgbRed: 0.76, green: 0.62, blue: 0.46, alpha: 0.6)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        let grow = CAKeyframeAnimation(); grow.values = [0.6, 1.8, 3.2]; grow.keyTimes = [0, 0.35, 1]
        let fade = CAKeyframeAnimation(); fade.values = [0, 0.75, 0.45, 0]; fade.keyTimes = [0, 0.12, 0.6, 1]
        s.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
        return s
    }

    /// Nuggets in the mines near the bird; flying through one takes it (they're back after a few minutes).
    private func updateGold(_ p: SIMD3<Float>) {
        goldHere.removeAll(keepingCapacity: true)
        let c = camera == .zero ? p : camera
        for m in WestMine.near(c.x, c.z, terrain) where simd_distance(m.mid, c) < m.length / 2 + 160 {
            for (k, at) in WestMine.nuggets(m).enumerated() {
                let id = Int64(ihash(Int(m.a.x.rounded()), Int(m.a.z.rounded()), UInt32(k)))
                if let t = goldTaken[id], clock - t < 300 { continue }
                if simd_distance(at, p) < 2.0 {
                    goldTaken[id] = clock
                    rewards.append(WorldReward(id: "west.nugget", title: "Gold nugget", coins: 3, once: false))
                    if !foundGold {
                        foundGold = true
                        rewards.append(WorldReward(id: "west.gold", title: "Gold! You found a nugget in the old mine", coins: 20, once: true))
                    }
                    continue
                }
                goldHere.append(at)
            }
        }
    }

    private func updateWeeds(_ dt: Float, _ p: SIMD3<Float>) {
        weeds.removeAll { simd_distance(SIMD2($0.pos.x, $0.pos.z), SIMD2(p.x, p.z)) > 700 }
        var tries = 0
        while weeds.count < 14 && tries < 30 {
            tries += 1
            // Upwind of the bird, on the open plateau.
            let a = atan2(-wind.y, -wind.x) + rng.float(-1.2, 1.2)
            let q = SIMD2(p.x, p.z) + SIMD2(cos(a), sin(a)) * rng.float(120, 500)
            guard terrain.open(q.x, q.y) else { continue }
            weeds.append(Tumbleweed(pos: SIMD3(q.x, terrain.height(q.x, q.y) + 0.8, q.y), vel: SIMD3(wind.x, 0, wind.y) * 5, spin: 0,
                                    size: rng.float(0.6, 1.1), hop: 0))
        }
        for i in weeds.indices {
            var w = weeds[i]
            let gust = 4 + 3 * sin(clock * 0.7 + w.pos.x * 0.01)
            w.vel.x += (wind.x * gust - w.vel.x) * min(1, dt * 0.8)
            w.vel.z += (wind.y * gust - w.vel.z) * min(1, dt * 0.8)
            w.vel.y -= 9.8 * dt
            w.pos += w.vel * dt
            let g = terrain.height(w.pos.x, w.pos.z) + w.size * 0.8
            if w.pos.y < g {
                w.pos.y = g
                // Bounce along.
                w.vel.y = rng.float() < 0.08 ? rng.float(2.5, 4.5) : abs(w.vel.y) * 0.3
            }
            w.spin += simd_length(SIMD2(w.vel.x, w.vel.z)) * dt / max(w.size, 0.3)
            weeds[i] = w
        }
    }

    private func updateDevils(_ dt: Float, _ player: FlightModel) {
        let p = player.pos
        devils.removeAll { d in
            let gone = d.life <= 0 || simd_distance(d.pos, SIMD2(p.x, p.z)) > 1800
            if gone { d.node.removeFromParentNode() }
            return gone
        }
        var tries = 0
        while devils.count < 2 && tries < 12 {
            tries += 1
            let a = rng.float(0, 6.28), r = rng.float(300, 1100)
            let q = SIMD2(p.x, p.z) + SIMD2(cos(a), sin(a)) * r
            guard terrain.open(q.x, q.y), WestLayout.townBlend(q.x, q.y) == nil else { continue }
            let d = DustDevil(pos: q, vel: SIMD2(rng.float(-3, 3), rng.float(-3, 3)) + wind * 2, life: rng.float(60, 140))
            d.node.addParticleSystem(WestLife.devilDust())
            d.node.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 1.6)))
            root.addChildNode(d.node)
            devils.append(d)
        }
        for d in devils {
            d.life -= dt
            d.vel += SIMD2(rng.float(-1, 1), rng.float(-1, 1)) * dt
            d.vel = simd_clamp(d.vel, SIMD2(repeating: -5), SIMD2(repeating: 5))
            var next = d.pos + d.vel * dt
            if !terrain.open(next.x, next.y) { d.vel = -d.vel; next = d.pos }
            d.pos = next
            let g = terrain.height(d.pos.x, d.pos.y)
            d.node.simdPosition = SIMD3(d.pos.x, g, d.pos.y)
            // Too close: it lifts you, spins you and spits you out.
            let flat = SIMD2(p.x - d.pos.x, p.z - d.pos.y)
            let dist = simd_length(flat)
            let agl = p.y - g
            if dist < 60 && agl < 70 { threat = "Dust devil!" }
            if dist < 9 && agl < 55 && agl > -2 {
                devilLift = max(devilLift, 7)
                let spin = SIMD2(-flat.y, flat.x) / max(dist, 0.1)
                devilKick = SIMD3(spin.x, 0.6, spin.y) * 14 + SIMD3(flat.x, 0, flat.y) / max(dist, 0.1) * 6
                quake = max(quake, 0.25)
            }
        }
    }

    private static func devilDust() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.birthRate = 150
        s.emitterShape = SCNCone(topRadius: 10, bottomRadius: 1.5, height: 60)
        s.birthLocation = .surface
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.spreadingAngle = 15
        s.particleVelocity = 5
        s.particleLifeSpan = 4
        s.particleSize = 4.5
        s.particleSizeVariation = 2
        s.particleImage = SteamTrain.puff
        s.particleColor = NSColor(srgbRed: 0.74, green: 0.58, blue: 0.42, alpha: 0.6)
        s.blendMode = .alpha
        s.isLightingEnabled = false
        s.isLocal = true
        let fade = CAKeyframeAnimation(); fade.values = [0, 0.7, 0]; fade.keyTimes = [0, 0.3, 1]
        s.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        s.warmupDuration = 3
        return s
    }

    private func updateVultures(_ dt: Float, _ p: SIMD3<Float>) {
        vultures.removeAll { simd_distance(SIMD2($0.pos.x, $0.pos.z), SIMD2(p.x, p.z)) > 1800 }
        while vultures.count < 6 {
            let a = rng.float(0, 6.28), r = rng.float(200, 900)
            let c = SIMD2(p.x + cos(a) * r, p.z + sin(a) * r)
            let center = SIMD3(c.x, max(terrain.height(c.x, c.y), WestLayout.rim) + rng.float(40, 140), c.y)
            vultures.append(Ptero(center: center, radius: rng.float(40, 90), dir: rng.float() < 0.5 ? -1 : 1, angle: rng.float(0, 6.28), scale: rng.float(1.2, 1.5),
                                  cooldown: 0, drift: SIMD3(rng.float(-2, 2), 0, rng.float(-2, 2)), callT: 0))
        }
        for v in vultures {
            v.angle += v.dir * dt * 9 / v.radius
            v.center += v.drift * dt
            let target = v.center + SIMD3(cos(v.angle) * v.radius, sin(clock * 0.2 + v.radius) * 6, sin(v.angle) * v.radius)
            let desired = simd_normalize(target - v.pos) * 9
            let prevYaw = v.yaw
            v.vel += (desired - v.vel) * min(1, dt * 1.2)
            v.pos += v.vel * dt
            v.yaw = atan2(-v.vel.x, -v.vel.z)
            var turn = v.yaw - prevYaw
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            v.bank += (clamp(turn / max(dt, 1e-4) * 0.9, -0.7, 0.7) - v.bank) * min(1, dt * 2)
            v.motion.flap = sin(clock * 0.37 + v.radius) > 0.93 ? 0.5 : 0
            v.motion.phase += dt * 1.2 * max(v.motion.flap, 0.02)
            if v.motion.phase > 1 { v.motion.phase -= 1 }
            v.motion.time += dt
        }
    }

    private func updateDoors(_ dt: Float, _ p: SIMD3<Float>) {
        for key in Array(doors.keys) {
            guard var list = doors[key] else { continue }
            for k in list.indices {
                var (n, ang, vel) = list[k]
                let hinge = n.simdPosition
                // Swing open when something passes through; spring back.
                var push: Float = 0
                let doorCenter = hinge + SIMD3(k % 2 == 0 ? 0.85 : -0.85, 0.2, 0)
                if simd_distance(doorCenter, p) < 2.2 { push = (p.z > hinge.z ? -1 : 1) * 6 }
                for c in cowboys where abs(c.pos.x - doorCenter.x) < 1.2 && abs(c.pos.y - hinge.z) < 1 { push = 3 }
                vel += (push - ang * 9 - vel * 2.2) * dt
                ang = clamp(ang + vel * dt, -1.6, 1.6)
                n.simdOrientation = yawQuat(k % 2 == 0 ? ang : -ang)
                list[k] = (n, ang, vel)
            }
            doors[key] = list
        }
    }

    // MARK: Sounds of the West

    private func ambience(_ dt: Float, _ player: FlightModel, _ sound: SoundEngine?, underground: Float) {
        guard let sound else { return }
        let p = player.pos
        // The saloon piano, from the nearest saloon.
        var piano: Float = 0
        for t in WestLayout.towns(near: SIMD2(p.x, p.z), radius: 160) {
            if let s = WestTown.plan(t).saloon {
                let d = simd_distance(s.center, p)
                piano = max(piano, smoothstep(140, 6, d))
            }
        }
        sound.setPiano(piano * (1 - underground))
        // Crickets on the plateau, wind in the canyon.
        let g = terrain.height(p.x, p.z)
        sound.setJungle(smoothstep(120, 10, p.y - max(g, 0)) * 0.35, water: smoothstep(4, -1, g) * smoothstep(50, 4, p.y))
        // Now and then: a coyote, the church bell, cattle.
        coyoteT -= dt
        if coyoteT <= 0 {
            coyoteT = rng.float(25, 60)
            sound.coyote(gain: rng.float(0.25, 0.5), pan: rng.float(-0.8, 0.8))
        }
        bellT -= dt
        if bellT <= 0 {
            bellT = rng.float(60, 120)
            if let t = WestLayout.towns(near: SIMD2(p.x, p.z), radius: 500).first {
                let church = SIMD3(t.center.x + WestLayout.streetHalfLength + 15, t.ground + 15, t.center.y)
                sound.churchBell(gain: smoothstep(600, 40, simd_distance(church, p)))
            }
        }
        // A stampede: thundering hooves, a rumble you can feel, and bellowing.
        if let at = stampedeAt {
            let d = simd_distance(at, p)
            sound.setRumble(0.4 * smoothstep(320, 20, d))
            rumbling = true
            hoofT -= dt
            if hoofT <= 0 {
                hoofT = rng.float(0.05, 0.12)
                let right = SIMD3(cos(player.yaw), 0, -sin(player.yaw))
                let pan = d > 1 ? clamp(simd_dot((at - p) / d, right), -1, 1) : 0
                if d < 300 { sound.dinoCall(.stomp, gain: smoothstep(300, 12, d) * rng.float(0.2, 0.35), pan: pan, pitch: rng.float(1.7, 2.3)) }
            }
            if moos > 0 && rng.float() < dt * 2.5 {
                moos -= 1
                if d < 400 { sound.dinoCall(.bellow, gain: smoothstep(400, 10, d) * 0.7, pan: 0, pitch: rng.float(1.5, 1.8)) }
            }
        } else if rumbling {
            rumbling = false
            sound.setRumble(0)
        }
        mooT -= dt
        if mooT <= 0 {
            mooT = rng.float(6, 15)
            if let a = animals.filter({ $0.sp.kind == .steer }).min(by: { simd_distance(SIMD2(p.x, p.z), $0.pos) < simd_distance(SIMD2(p.x, p.z), $1.pos) }) {
                let d = simd_distance(SIMD2(p.x, p.z), a.pos)
                if d < 300 { sound.dinoCall(.bellow, gain: smoothstep(300, 10, d) * 0.6, pan: 0, pitch: 1.6) }
            }
        }
    }

    // MARK: Drawing

    private static let cowboyHats: [MeshTemplate] = {
        var out: [MeshTemplate] = []
        for c in [SIMD3<Float>(0.72, 0.56, 0.36), SIMD3(0.14, 0.12, 0.1), SIMD3(0.92, 0.9, 0.84), SIMD3(0.45, 0.3, 0.2)] {
            var m = MeshBuilder()
            // A wide brim turned up at the sides, a creased crown, a band.
            m.ellipsoid(SIMD3(0, 0.0, 0), SIMD3(0.36, 0.04, 0.32), c, rings: 3, sides: 12)
            for s: Float in [-1, 1] { m.ellipsoid(SIMD3(s * 0.3, 0.05, 0), SIMD3(0.09, 0.06, 0.26), c, rings: 2, sides: 6) }
            m.cylinder(SIMD3(0, 0.02, 0), r0: 0.16, r1: 0.14, y0: 0, y1: 0.18, sides: 10, c)
            m.ellipsoid(SIMD3(0, 0.19, 0), SIMD3(0.13, 0.04, 0.11), c * 0.9, rings: 2, sides: 8)
            m.cylinder(SIMD3(0, 0.03, 0), r0: 0.163, r1: 0.16, y0: 0, y1: 0.04, sides: 10, c * 0.4, top: false)
            out.append(MeshTemplate(m))
        }
        return out
    }()

    private static let bandana: MeshTemplate = {
        var m = MeshBuilder()
        m.cylinder(.zero, r0: 0.16, r1: 0.15, y0: -0.03, y1: 0.03, sides: 8, SIMD3(1, 1, 1))
        m.quad(SIMD3(-0.12, 0, -0.14), SIMD3(0.12, 0, -0.14), SIMD3(0, -0.16, -0.16), SIMD3(0, -0.16, -0.16), SIMD3(1, 1, 1), facing: SIMD3(0, 0, -1))
        return MeshTemplate(m)
    }()

    private static let tumbleweed: MeshTemplate = {
        var m = MeshBuilder()
        var r = SplitMix64(seed: 0x7E_ED)
        for _ in 0..<26 {
            let a = simd_normalize(SIMD3(r.float(-1, 1), r.float(-1, 1), r.float(-1, 1)))
            let b = simd_normalize(SIMD3(r.float(-1, 1), r.float(-1, 1), r.float(-1, 1)))
            m.tube(a * 0.9, b * 0.9, r0: 0.025, r1: 0.025, sides: 3, SIMD3(0.62, 0.52, 0.36) * r.float(0.8, 1.1))
        }
        m.ellipsoid(.zero, SIMD3(repeating: 0.45), SIMD3(0.5, 0.42, 0.3), rings: 3, sides: 6)
        return MeshTemplate(m)
    }()

    /// A gold nugget (shading baked in: it's drawn unlit, to glint in the dark) with a little star of a glint.
    private static let nugget: MeshTemplate = {
        var m = MeshBuilder()
        let gold = SIMD3<Float>(1, 0.72, 0.18)
        let light = simd_normalize(SIMD3<Float>(0.4, 1, 0.3))
        func shade(_ u: SIMD3<Float>) -> SIMD3<Float> {
            let k = max(0, simd_dot(simd_normalize(u), light))
            return gold * (0.45 + 0.55 * k) + SIMD3(repeating: pow(k, 12) * 0.6)
        }
        m.ellipsoid(.zero, SIMD3(0.34, 0.25, 0.3), gold, rings: 4, sides: 8, shade: shade)
        m.ellipsoid(SIMD3(0.22, 0.09, 0.1), SIMD3(0.21, 0.17, 0.19), gold, rings: 3, sides: 7, shade: shade)
        m.ellipsoid(SIMD3(-0.17, 0.11, -0.13), SIMD3(0.18, 0.15, 0.17), gold, rings: 3, sides: 7, shade: shade)
        let w = SIMD3<Float>(1, 0.95, 0.7)
        m.ellipsoid(SIMD3(0, 0.12, 0), SIMD3(0.75, 0.035, 0.035), w, rings: 2, sides: 4)
        m.ellipsoid(SIMD3(0, 0.12, 0), SIMD3(0.035, 0.75, 0.035), w, rings: 2, sides: 4)
        return MeshTemplate(m)
    }()

    private func draw() {
        if let goldMesh {
            goldMesh.begin()
            for g in goldHere where simd_distance(g, camera) < 140 {
                let glint = 0.9 + 0.6 * max(0, sin(clock * 3.1 + g.x * 0.7))
                goldMesh.add(WestLife.nugget, trs(g + SIMD3(0, sin(clock * 2 + g.z) * 0.12, 0), yawQuat(clock * 1.4 + g.x)), tint: glint)
            }
            goldMesh.end()
        }
        guard let mesh else { return }
        mesh.begin()
        let cam = camera
        // Cowboys.
        for c in cowboys {
            let d = simd_distance(SIMD3(c.pos.x, c.y, c.pos.y), cam)
            guard d < 200 else { continue }
            let model = PersonModel.all[c.model]
            let moving = c.wait <= 0 && c.lookUp < 0.5
            let swing = moving ? sin(c.phase) * 0.55 : 0
            let base = trs(SIMD3(c.pos.x, c.y + (moving ? abs(sin(c.phase)) * 0.03 : 0), c.pos.y), yawQuat(c.yaw), 1.05)
            mesh.add(model.body, base)
            var headQ = yawQuat(sin(clock * 0.4 + c.phase) * 0.3 * (1 - c.lookUp))
            if c.lookUp > 0 { headQ = headQ * rotX(0.8 * c.lookUp) }
            let headM = base * trs(model.neck, headQ)
            mesh.add(model.head, headM)
            let hr: Float = 0.19 * (model.look.bigEyes ? 1.12 : 1)
            mesh.add(WestLife.cowboyHats[c.hat], headM * trs(SIMD3(0, hr * 1.62, -0.02), simd_quatf(angle: 0, axis: kUp), 1.15))
            mesh.add(WestLife.bandana, base * trs(model.neck - SIMD3(0, 0.04, 0), simd_quatf(angle: 0, axis: kUp)), paint: c.bandana)
            mesh.add(model.leg, base * trs(model.hipL, rotX(swing)))
            mesh.add(model.leg, base * trs(model.hipR, rotX(-swing)))
            mesh.add(model.wingL, base * trs(model.shoulderL, rotX(-swing * 0.6)))
            mesh.add(model.wingR, base * trs(model.shoulderR, c.lookUp > 0.6 ? rotX(-2.4) : rotX(swing * 0.6)))
        }
        // Horses, riders and cattle.
        for a in animals {
            let d = simd_distance(SIMD3(a.pos.x, 0, a.pos.y), SIMD3(cam.x, 0, cam.z))
            guard d < 600 else { continue }
            a.sp.pose(a.motion, into: &a.pose)
            let g = terrain.height(a.pos.x, a.pos.y)
            let root = trs(SIMD3(a.pos.x, g + (a.sp.hip - a.motion.bob(a.sp)) * a.scale, a.pos.y), yawQuat(a.yaw), a.scale)
            a.sp.rig.solve(root: root, pose: a.pose, into: &a.mats)
            a.sp.rig.draw(a.mats, into: mesh, far: d > 120, paint: a.coat)
            if a.rider >= 0 {
                // A cowboy in the saddle.
                let model = PersonModel.all[a.rider % PersonModel.all.count]
                let seat = a.mats[0] * trs(SIMD3(0, 0.38, -0.15), simd_quatf(angle: 0, axis: kUp), 1 / a.scale)
                let base = seat * trs(SIMD3(0, -0.45, 0), simd_quatf(angle: 0, axis: kUp), 1.05)
                mesh.add(model.body, base)
                let headM = base * trs(model.neck, simd_quatf(angle: 0, axis: kUp))
                mesh.add(model.head, headM)
                mesh.add(WestLife.cowboyHats[(a.rider + 1) % 4], headM * trs(SIMD3(0, 0.19 * 1.62, -0.02), simd_quatf(angle: 0, axis: kUp), 1.15))
                mesh.add(model.leg, base * trs(model.hipL + SIMD3(-0.12, 0, 0), rotZ(0.9)))
                mesh.add(model.leg, base * trs(model.hipR + SIMD3(0.12, 0, 0), rotZ(-0.9)))
                mesh.add(model.wingL, base * trs(model.shoulderL, rotX(-0.6)))
                mesh.add(model.wingR, base * trs(model.shoulderR, rotX(-0.6)))
            }
        }
        // Tumbleweeds.
        for w in weeds where simd_distance(w.pos, cam) < 400 {
            let axis = simd_normalize(SIMD3(-w.vel.z, 0, w.vel.x) + SIMD3(0.0001, 0, 0))
            mesh.add(WestLife.tumbleweed, trs(w.pos, simd_quatf(angle: -w.spin, axis: axis), w.size))
        }
        // Vultures.
        let vsp = DinoSpecies.all[.vulture]!
        for v in vultures where simd_distance(v.pos, cam) < 1400 {
            vsp.pose(v.motion, into: &v.pose)
            let root = trs(v.pos, yawQuat(v.yaw) * rotZ(-v.bank), v.scale)
            vsp.rig.solve(root: root, pose: v.pose, into: &v.mats)
            vsp.rig.draw(v.mats, into: mesh, far: simd_distance(v.pos, cam) > 150)
        }
        mesh.end()
    }
}
