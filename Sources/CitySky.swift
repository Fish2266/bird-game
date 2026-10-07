import SceneKit
import simd

/// What flies over Skyline City besides you: a news helicopter, a blimp, delivery drones and the odd airliner. Plus the
/// pigeons that scatter when you swoop down, and steam from the manholes.
final class CitySky {
    let root = SCNNode()
    private var rng = SplitMix64(seed: 0x5C1E)
    private static let mat = WorldMaterials.finishes()

    // MARK: Helicopter

    private let heli = SCNNode()
    private let rotor = SCNNode()
    private let tailRotor = SCNNode()
    private var heliCenter = SIMD3<Float>(0, 0, 0)
    private var heliAngle: Float = 0
    private(set) var heliPos = SIMD3<Float>(0, -1000, 0)
    private var heliReady = false
    private var heliHeight: Float = 160
    private var heliTarget: Float = 160
    private var heliTimer: Float = 0

    // MARK: Blimp

    private let blimp = SCNNode()
    private var blimpAngle: Float = 0
    private var blimpCenter = SIMD3<Float>(0, 0, 0)
    private(set) var blimpPos = SIMD3<Float>(0, -1000, 0)
    private var blimpReady = false

    // MARK: Drones

    private struct Drone {
        var node: SCNNode
        var pos: SIMD3<Float>
        var target: SIMD3<Float>
        var wait: Float
        var phase: Float
    }
    private var drones: [Drone] = []

    // MARK: Airliner

    private let jet = SCNNode()
    private var jetDir = SIMD3<Float>(1, 0, 0)
    private var jetTimer: Float = 25
    private var jetActive = false
    private let contrails: [SCNParticleSystem]

    // MARK: Pigeons

    struct Pigeon {
        var pos: SIMD3<Float>
        var vel = SIMD3<Float>(0, 0, 0)
        var yaw: Float
        var flying = false
        var phase: Float
        var peck: Float
    }
    struct Flock {
        var home: SIMD3<Float>
        var birds: [Pigeon]
        var scared: Float = 0
        var landing: SIMD3<Float>
    }
    private(set) var flocks: [Flock] = []
    private var flockTimer: Float = 0
    private(set) var flutter: Float = 0

    // MARK: Steam

    private var vents: [SCNNode] = []
    private var fountains: [SCNNode] = []

    init() {
        let trail = { () -> SCNParticleSystem in
            let ps = SCNParticleSystem()
            ps.birthRate = 160
            ps.particleLifeSpan = 9
            ps.particleSize = 5
            ps.particleSizeVariation = 2
            ps.particleColor = NSColor(white: 1, alpha: 0.5)
            ps.particleVelocity = 0
            ps.isLightingEnabled = false
            ps.blendMode = .alpha
            ps.emitterShape = SCNSphere(radius: 0.5)
            ps.particleImage = makeImage(width: 32, height: 32) { x, y in
                let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
                return SIMD4(1, 1, 1, max(0, 1 - d) * max(0, 1 - d))
            }
            let grow = CAKeyframeAnimation(); grow.values = [0.4, 1.6, 3]; grow.keyTimes = [0, 0.3, 1]
            let fade = CAKeyframeAnimation(); fade.values = [0, 0.6, 0.35, 0]; fade.keyTimes = [0, 0.05, 0.5, 1]
            ps.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
            ps.emissionDuration = 1
            ps.loops = true
            return ps
        }
        contrails = [trail(), trail()]
        buildHeli()
        buildBlimp()
        buildJet()
        for (k, ps) in contrails.enumerated() {
            let n = SCNNode()
            n.position = SCNVector3(k == 0 ? -9 : 9, -0.5, 4)
            n.addParticleSystem(ps)
            jet.addChildNode(n)
        }
        jet.isHidden = true
        for n in [heli, blimp, jet] { root.addChildNode(n) }
        for _ in 0..<4 { root.addChildNode(makeVent()) }
        for _ in 0..<2 { root.addChildNode(makeFountainSpray()) }
        for _ in 0..<4 {
            let d = makeDrone()
            root.addChildNode(d)
            drones.append(Drone(node: d, pos: SIMD3(0, -1000, 0), target: SIMD3(0, -1000, 0), wait: 0, phase: rng.float(0, 6)))
        }
    }

    /// A news helicopter with turning rotors (also used by the race obstacle that hovers in the street).
    static func helicopter() -> SCNNode {
        let sky = CitySky.shared
        let n = SCNNode()
        n.addChildNode(sky.heli.clone())
        return n
    }
    private static let shared = CitySky()

    private func buildHeli() {
        var m = MeshBuilder()
        let body = SIMD3<Float>(0.95, 0.95, 0.95), red = SIMD3<Float>(0.85, 0.15, 0.12)
        m.ellipsoid(SIMD3(0, 1.4, 0), SIMD3(1.3, 1.25, 2.4), body, rings: 6, sides: 10) { u in u.y < -0.3 ? red : body }
        m.ellipsoid(SIMD3(0, 1.6, -1.3), SIMD3(1.05, 0.9, 1.2), SIMD3(0.1, 0.14, 0.18), rings: 4, sides: 8)
        m.tube(SIMD3(0, 1.6, 2.0), SIMD3(0, 2.1, 7.2), r0: 0.4, r1: 0.18, sides: 6, body)
        m.box(SIMD3(0, 2.8, 7.1), SIMD3(0.06, 0.9, 0.6), red)
        m.box(SIMD3(0, 2.1, 6.9), SIMD3(1.0, 0.05, 0.35), red)
        for s: Float in [-1, 1] {
            m.box(SIMD3(s * 1.1, 0.05, 0), SIMD3(0.07, 0.07, 1.8), SIMD3(0.2, 0.2, 0.22))
            m.tube(SIMD3(s * 1.1, 0.05, -1), SIMD3(s * 0.8, 0.7, -0.8), r0: 0.06, r1: 0.06, sides: 4, SIMD3(0.2, 0.2, 0.22))
            m.tube(SIMD3(s * 1.1, 0.05, 1), SIMD3(s * 0.8, 0.7, 0.8), r0: 0.06, r1: 0.06, sides: 4, SIMD3(0.2, 0.2, 0.22))
        }
        m.cylinder(SIMD3(0, 2.6, 0), r0: 0.3, r1: 0.2, y0: 0, y1: 0.6, sides: 6, SIMD3(0.3, 0.3, 0.32))
        // "NEWS" stripe
        for s: Float in [-1, 1] { m.box(SIMD3(s * 1.22, 1.6, 0.6), SIMD3(0.02, 0.22, 0.9), SIMD3(0.15, 0.3, 0.75)) }
        let g = m.geometry(); g.materials = [CitySky.mat]
        let bodyNode = SCNNode(geometry: g)
        heli.addChildNode(bodyNode)
        var r = MeshBuilder()
        for k in 0..<4 {
            let a = Float(k) * .pi / 2
            r.box(SIMD3(cos(a) * 3.3, 0, sin(a) * 3.3), SIMD3(3.3, 0.04, 0.2), SIMD3(0.15, 0.15, 0.16), rot: yawQuat(-a))
        }
        let rg = r.geometry(); rg.materials = [CitySky.mat]
        rotor.geometry = rg
        rotor.simdPosition = SIMD3(0, 3.25, 0)
        rotor.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.22)))
        heli.addChildNode(rotor)
        var tr = MeshBuilder()
        tr.box(.zero, SIMD3(0.04, 0.9, 0.12), SIMD3(0.15, 0.15, 0.16))
        tr.box(.zero, SIMD3(0.04, 0.12, 0.9), SIMD3(0.15, 0.15, 0.16))
        let tg = tr.geometry(); tg.materials = [CitySky.mat]
        tailRotor.geometry = tg
        tailRotor.simdPosition = SIMD3(0.25, 2.5, 7.3)
        tailRotor.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: 0, duration: 0.09)))
        heli.addChildNode(tailRotor)
        let beacon = SCNNode(geometry: SCNSphere(radius: 0.15))
        beacon.geometry?.materials = [glowMat(rgb(1, 0.1, 0.1), 3)]
        beacon.simdPosition = SIMD3(0, 2.7, 7.5)
        beacon.runAction(.repeatForever(.sequence([.fadeOpacity(to: 1, duration: 0.05), .wait(duration: 0.15), .fadeOpacity(to: 0, duration: 0.05),
                                                   .wait(duration: 0.85)])))
        heli.addChildNode(beacon)
        heli.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    private func buildBlimp() {
        let body = SCNNode()
        func radius(_ u: Float) -> Float { 6.5 * pow(max(sin(.pi * u), 0), 0.6) * (0.75 + 0.25 * u) }
        let prof = (0...20).map { k -> SIMD2<Float> in let u = Float(k) / 20; return SIMD2(radius(u), -22 + 44 * u) }
        let hull = SCNNode(geometry: Shapes.lathe(prof, segments: 24, crease: 2))
        hull.geometry?.materials = [pbr(rgb(0.9, 0.9, 0.92), rough: 0.4)]
        hull.eulerAngles.x = -.pi / 2
        body.addChildNode(hull)
        for k in 0..<4 {
            let f = SCNNode(geometry: SCNBox(width: 0.4, height: 5, length: 6, chamferRadius: 0.2))
            f.geometry?.materials = [pbr(rgb(0.15, 0.35, 0.8), rough: 0.5)]
            let a = Float(k) * .pi / 2
            f.simdPosition = SIMD3(cos(a) * 3.6, sin(a) * 3.6, 17)
            f.simdOrientation = simd_quatf(angle: a, axis: SIMD3(0, 0, 1))
            body.addChildNode(f)
        }
        let gondola = SCNNode(geometry: SCNBox(width: 2.4, height: 1.6, length: 6, chamferRadius: 0.6))
        gondola.geometry?.materials = [pbr(rgb(0.2, 0.22, 0.25), rough: 0.4)]
        gondola.simdPosition = SIMD3(0, -6.8, -2)
        body.addChildNode(gondola)
        // Banners down both sides.
        let banner = SCNMaterial()
        banner.lightingModel = .physicallyBased
        banner.diffuse.contents = signImage("BIRD GAME 0.4", width: 1024, height: 200, background: NSColor(srgbRed: 0.12, green: 0.32, blue: 0.78, alpha: 1),
                                            color: .white, font: NSFont.systemFont(ofSize: 120, weight: .heavy))
        banner.roughness.contents = 0.5
        for s: Float in [-1, 1] {
            let p = SCNNode(geometry: SCNPlane(width: 26, height: 5))
            p.geometry?.materials = [banner]
            p.simdPosition = SIMD3(s * 6.2, 0, -1)
            p.simdOrientation = yawQuat(s * .pi / 2)
            body.addChildNode(p)
        }
        blimp.addChildNode(body)
        blimp.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    private func buildJet() {
        var m = MeshBuilder()
        let white = SIMD3<Float>(0.95, 0.95, 0.96), blue = SIMD3<Float>(0.2, 0.3, 0.6)
        m.tube(SIMD3(0, 0, -16), SIMD3(0, 0, 16), r0: 1.9, r1: 1.6, sides: 10, white, cap: true)
        m.ellipsoid(SIMD3(0, 0, -16), SIMD3(1.9, 1.9, 3), white, rings: 4, sides: 10)
        m.box(SIMD3(0, -0.5, 0), SIMD3(17, 0.25, 3.2), white, rot: yawQuat(0))
        m.box(SIMD3(0, 0, 14.5), SIMD3(5.5, 0.15, 1.6), white)
        m.box(SIMD3(0, 3, 14.5), SIMD3(0.15, 3, 2), blue)
        for s: Float in [-7, 7] { m.tube(SIMD3(s, -1.5, -2.5), SIMD3(s, -1.5, 1.5), r0: 0.9, r1: 0.8, sides: 8, SIMD3(0.7, 0.72, 0.75), cap: true) }
        let g = m.geometry(); g.materials = [CitySky.mat]
        let n = SCNNode(geometry: g)
        jet.addChildNode(n)
    }

    private func makeDrone() -> SCNNode {
        let n = SCNNode()
        var m = MeshBuilder()
        m.box(.zero, SIMD3(0.22, 0.08, 0.22), SIMD3(0.2, 0.2, 0.22))
        for k in 0..<4 {
            let a = Float(k) * .pi / 2 + .pi / 4
            let tip = SIMD3(cos(a) * 0.5, 0.04, sin(a) * 0.5)
            m.tube(.zero, tip, r0: 0.03, r1: 0.03, sides: 4, SIMD3(0.2, 0.2, 0.22))
            m.cylinder(tip, r0: 0.22, r1: 0.22, y0: 0.04, y1: 0.06, sides: 8, SIMD3(0.55, 0.58, 0.62))
        }
        // A parcel underneath.
        m.box(SIMD3(0, -0.28, 0), SIMD3(0.16, 0.13, 0.16), SIMD3(0.72, 0.55, 0.36))
        let g = m.geometry(); g.materials = [CitySky.mat]
        n.geometry = g
        let light = SCNNode(geometry: SCNSphere(radius: 0.05))
        light.geometry?.materials = [glowMat(rgb(0.3, 1, 0.5), 3)]
        light.simdPosition = SIMD3(0, 0.1, -0.24)
        light.runAction(.repeatForever(.sequence([.fadeOpacity(to: 1, duration: 0.05), .wait(duration: 0.3), .fadeOpacity(to: 0.1, duration: 0.05),
                                                  .wait(duration: 0.4)])))
        n.addChildNode(light)
        n.scale = SCNVector3(1.6, 1.6, 1.6)
        return n
    }

    private func makeVent() -> SCNNode {
        let ps = SCNParticleSystem()
        ps.birthRate = 14
        ps.particleLifeSpan = 3.5
        ps.particleSize = 1.2
        ps.particleSizeVariation = 0.5
        ps.particleVelocity = 1.6
        ps.spreadingAngle = 18
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.particleColor = NSColor(white: 0.95, alpha: 0.35)
        ps.isLightingEnabled = false
        ps.blendMode = .alpha
        ps.emitterShape = SCNSphere(radius: 0.3)
        ps.particleImage = makeImage(width: 32, height: 32) { x, y in
            let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
            return SIMD4(1, 1, 1, max(0, 1 - d) * max(0, 1 - d))
        }
        let grow = CAKeyframeAnimation(); grow.values = [0.5, 2.5, 4]; grow.keyTimes = [0, 0.5, 1]
        let fade = CAKeyframeAnimation(); fade.values = [0, 0.5, 0]; fade.keyTimes = [0, 0.25, 1]
        ps.propertyControllers = [.size: SCNParticlePropertyController(animation: grow), .opacity: SCNParticlePropertyController(animation: fade)]
        ps.acceleration = SCNVector3(0.4, 0.3, 0)
        let n = SCNNode()
        n.addParticleSystem(ps)
        n.simdPosition = SIMD3(0, -1000, 0)
        vents.append(n)
        return n
    }

    private func makeFountainSpray() -> SCNNode {
        let ps = SCNParticleSystem()
        ps.birthRate = 160
        ps.particleLifeSpan = 1.4
        ps.particleSize = 0.12
        ps.particleVelocity = 6.5
        ps.particleVelocityVariation = 1
        ps.spreadingAngle = 12
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.acceleration = SCNVector3(0, -9.8, 0)
        ps.particleColor = NSColor(srgbRed: 0.85, green: 0.93, blue: 1.0, alpha: 0.75)
        ps.isLightingEnabled = false
        ps.blendMode = .additive
        ps.emitterShape = SCNSphere(radius: 0.2)
        let n = SCNNode()
        n.addParticleSystem(ps)
        n.simdPosition = SIMD3(0, -1000, 0)
        fountains.append(n)
        return n
    }

    // MARK: Update

    func update(dt: Float, clock: Float, player: FlightModel) {
        let p = player.pos
        // Helicopter: circles over the city near the player, drifting along.
        heliTimer -= dt
        if !heliReady || simd_distance(heliCenter, p) > 900 {
            heliCenter = SIMD3(p.x + rng.float(-300, 300), 0, p.z + rng.float(-300, 300))
            heliHeight = max(CityLayout.skyline(heliCenter.x, heliCenter.z, radius: 260) + 55, 160)
            heliReady = true
        }
        heliCenter += (SIMD3(p.x, 0, p.z) - heliCenter) * approach(0.02, dt)
        heliAngle += dt * 0.11
        if heliTimer <= 0 {
            heliTimer = 2
            heliTarget = max(CityLayout.skyline(heliCenter.x, heliCenter.z, radius: 260) + 55, 160)
        }
        heliHeight += (heliTarget - heliHeight) * approach(0.3, dt)
        let hr: Float = 210
        let tangent = SIMD3(-sin(heliAngle), 0, cos(heliAngle))
        heliPos = SIMD3(heliCenter.x + cos(heliAngle) * hr, heliHeight, heliCenter.z + sin(heliAngle) * hr)
        heli.simdPosition = heliPos
        heli.simdOrientation = yawQuat(atan2(-tangent.x, -tangent.z)) * simd_quatf(angle: 0.12, axis: SIMD3(0, 0, 1)) *
            simd_quatf(angle: -0.08, axis: SIMD3(1, 0, 0))

        // Blimp: a slow lap at 300 m.
        if !blimpReady || simd_distance(blimpCenter, p) > 1600 {
            blimpCenter = SIMD3(p.x + rng.float(-500, 500), 0, p.z + rng.float(-500, 500))
            blimpReady = true
        }
        blimpAngle += dt * 0.012
        let br: Float = 520
        blimpPos = SIMD3(blimpCenter.x + cos(blimpAngle) * br, 330 + 6 * sin(clock * 0.1), blimpCenter.z + sin(blimpAngle) * br)
        blimp.simdPosition = blimpPos
        let bt = SIMD3(-sin(blimpAngle), 0, cos(blimpAngle))
        blimp.simdOrientation = yawQuat(atan2(-bt.x, -bt.z))

        updateDrones(dt: dt, player: p)
        updateJet(dt: dt, player: p)
        updatePigeons(dt: dt, player: player)
        placeVents(p, clock: clock)
    }

    private func updateDrones(dt: Float, player p: SIMD3<Float>) {
        for k in drones.indices {
            var d = drones[k]
            if simd_distance(d.pos, p) > 600 || d.pos.y < -500 {
                d.pos = randomRoof(near: p, radius: 400) + SIMD3(0, 8, 0)
                d.target = d.pos
                d.wait = 0
            }
            let to = d.target - d.pos
            let dist = simd_length(to)
            if dist < 1 {
                d.wait -= dt
                if d.wait <= 0 {
                    d.target = randomRoof(near: d.pos, radius: 220) + SIMD3(0, rng.float(6, 14), 0)
                    d.wait = rng.float(1, 4)
                }
            } else {
                d.pos += to / dist * min(dist, 11 * dt)
            }
            d.phase += dt
            d.node.simdPosition = d.pos + SIMD3(0, 0.15 * sin(d.phase * 3), 0)
            if dist > 1 { d.node.simdOrientation = yawQuat(atan2(-to.x, -to.z)) * simd_quatf(angle: -0.15, axis: SIMD3(1, 0, 0)) }
            drones[k] = d
        }
    }

    private func randomRoof(near p: SIMD3<Float>, radius r: Float) -> SIMD3<Float> {
        for _ in 0..<8 {
            let a = rng.float(0, 6.28), d = rng.float(40, r)
            let x = p.x + cos(a) * d, z = p.z + sin(a) * d
            let top = CityLayout.roofHeight(x, z)
            if top - CityLayout.ground(x, z) > 15 { return SIMD3(x, top, z) }
        }
        return SIMD3(p.x, CityLayout.skyline(p.x, p.z, radius: 50) + 20, p.z)
    }

    private func updateJet(dt: Float, player p: SIMD3<Float>) {
        if !jetActive {
            jetTimer -= dt
            if jetTimer <= 0 {
                jetActive = true
                let a = rng.float(0, 6.28)
                jetDir = SIMD3(cos(a), 0, sin(a))
                jet.simdPosition = p - jetDir * 3500 + SIMD3(rng.float(-600, 600), 1150, rng.float(-600, 600))
                jet.simdOrientation = yawQuat(atan2(-jetDir.x, -jetDir.z))
                jet.isHidden = false
                for c in contrails { c.birthRate = 160 }
            }
            return
        }
        jet.simdPosition += jetDir * 120 * dt
        if simd_distance(SIMD2(jet.simdPosition.x, jet.simdPosition.z), SIMD2(p.x, p.z)) > 3800 && simd_dot(jet.simdPosition - p, jetDir) > 0 {
            jetActive = false
            jet.isHidden = true
            for c in contrails { c.birthRate = 0 }
            jetTimer = rng.float(60, 110)
        }
    }

    private func placeVents(_ p: SIMD3<Float>, clock: Float) {
        // Steam rises from a few manholes near the player (the same ones every time).
        let G = CityLayout.pitch
        var spots: [(Float, SIMD3<Float>)] = []
        let ci = Int((p.x / G).rounded()), cj = Int((p.z / G).rounded())
        for j in (cj - 2)...(cj + 2) {
            for i in (ci - 2)...(ci + 2) where hfloat(i, j, 0x57EA) < 0.35 && CityLayout.nodeExists(i, j) {
                let q = CityLayout.nodePosition(i, j) + SIMD2(hfloat(i, j, 1) * 6 - 3, CityLayout.lineZ(j).halfRoad + 9)
                let v = SIMD3(q.x, CityLayout.ground(q.x, q.y) + 0.2, q.y)
                spots.append((simd_distance(v, p), v))
            }
        }
        spots.sort { $0.0 < $1.0 }
        for (k, n) in vents.enumerated() { n.simdPosition = k < spots.count ? spots[k].1 : SIMD3(0, -1000, 0) }
        // Fountain spray at the nearest fountains.
        var fs: [(Float, SIMD3<Float>)] = []
        for b in CityLayout.blocks(near: p.x, p.z, radius: 260) {
            guard let f = b.fountain else { continue }
            let top = f + SIMD3(0, b.kind == .plaza ? 3.0 : 3.0, 0)
            fs.append((simd_distance(top, p), top))
        }
        fs.sort { $0.0 < $1.0 }
        for (k, n) in fountains.enumerated() { n.simdPosition = k < fs.count && fs[k].0 < 260 ? fs[k].1 : SIMD3(0, -1000, 0) }
    }

    // MARK: Pigeons

    private func updatePigeons(dt: Float, player: FlightModel) {
        let p = player.pos
        flutter = max(0, flutter - dt * 1.5)
        flockTimer -= dt
        if flockTimer <= 0 {
            flockTimer = 2
            flocks.removeAll { simd_distance($0.home, p) > 260 }
            while flocks.count < 5 {
                guard let spot = pigeonSpot(near: p) else { break }
                var birds: [Pigeon] = []
                for _ in 0..<Int(rng.float(7, 15)) {
                    let o = SIMD3(rng.float(-3, 3), 0, rng.float(-3, 3))
                    birds.append(Pigeon(pos: spot + o, yaw: rng.float(0, 6.28), phase: rng.float(0, 6), peck: rng.float(0, 3)))
                }
                flocks.append(Flock(home: spot, birds: birds, landing: spot))
            }
        }
        for f in flocks.indices {
            var fl = flocks[f]
            // Something big swooping in? Everyone up.
            let close = simd_distance(p, fl.home) < 24 && player.speed > 7
            if close && fl.scared <= 0 {
                fl.scared = rng.float(6, 9)
                fl.landing = pigeonSpot(near: fl.home + SIMD3(rng.float(-90, 90), 0, rng.float(-90, 90))) ?? fl.home
                flutter = 1
                for k in fl.birds.indices {
                    fl.birds[k].flying = true
                    let away = simd_normalize(SIMD3(fl.birds[k].pos.x - p.x, 0, fl.birds[k].pos.z - p.z) + SIMD3(rng.float(-0.5, 0.5), 0, rng.float(-0.5, 0.5)))
                    fl.birds[k].vel = away * rng.float(5, 9) + SIMD3(0, rng.float(5, 9), 0)
                }
            }
            fl.scared -= dt
            for k in fl.birds.indices {
                var b = fl.birds[k]
                b.phase += dt
                if b.flying {
                    // Circle up, then glide down to the new spot.
                    var want: SIMD3<Float>
                    if fl.scared > 2.5 {
                        let goal = fl.landing + SIMD3(cos(b.phase * 0.9) * 14, 16, sin(b.phase * 0.9) * 14)
                        want = simd_normalize(goal - b.pos + SIMD3(0, 0.001, 0)) * 9
                    } else {
                        want = (fl.landing + SIMD3(cos(Float(k)) * 2.5, 0, sin(Float(k)) * 2.5) - b.pos) * 1.2
                    }
                    b.vel += (want - b.vel) * approach(2.2, dt)
                    b.pos += b.vel * dt
                    let g = CityLayout.ground(b.pos.x, b.pos.z)
                    if fl.scared <= 0.5 && b.pos.y < g + 0.3 {
                        b.flying = false
                        b.pos.y = g
                    }
                    if simd_length(SIMD2(b.vel.x, b.vel.z)) > 0.5 { b.yaw = atan2(-b.vel.x, -b.vel.z) }
                } else {
                    b.peck -= dt
                    if b.peck < -0.6 { b.peck = rng.float(0.5, 3); if rng.float() < 0.3 { b.yaw += rng.float(-1, 1) } }
                }
                fl.birds[k] = b
            }
            if fl.scared < -1 { fl.home = fl.landing }
            flocks[f] = fl
        }
    }

    private func pigeonSpot(near q: SIMD3<Float>) -> SIMD3<Float>? {
        // A sidewalk corner or a plaza.
        let G = CityLayout.pitch
        for _ in 0..<6 {
            let i = Int((q.x / G).rounded()) + Int(rng.float(-2, 2.99)), j = Int((q.z / G).rounded()) + Int(rng.float(-2, 2.99))
            guard CityLayout.nodeExists(i, j) else { continue }
            let lx = CityLayout.lineX(i), lz = CityLayout.lineZ(j)
            let sx: Float = rng.float() < 0.5 ? 1 : -1, sz: Float = rng.float() < 0.5 ? 1 : -1
            let c = CityLayout.nodePosition(i, j) + SIMD2(sx * (lx.halfRoad + 2.5), sz * (lz.halfRoad + 6 + rng.float(0, 10)))
            return SIMD3(c.x, CityLayout.ground(c.x, c.y), c.y)
        }
        return nil
    }

    static let pigeonBody: MeshTemplate = {
        var m = MeshBuilder()
        let grey = SIMD3<Float>(0.52, 0.54, 0.58)
        m.ellipsoid(SIMD3(0, 0.15, 0.02), SIMD3(0.085, 0.085, 0.15), grey, rings: 4, sides: 6) { u in u.y < -0.3 ? grey * 1.1 : grey }
        m.ellipsoid(SIMD3(0, 0.235, -0.09), SIMD3(0.06, 0.05, 0.06), SIMD3(0.32, 0.5, 0.42), rings: 3, sides: 6)
        m.ellipsoid(SIMD3(0, 0.29, -0.12), SIMD3(0.05, 0.05, 0.055), SIMD3(0.38, 0.40, 0.46), rings: 3, sides: 6)
        m.tube(SIMD3(0, 0.285, -0.17), SIMD3(0, 0.275, -0.2), r0: 0.012, r1: 0.003, sides: 4, SIMD3(0.2, 0.2, 0.2))
        m.box(SIMD3(0, 0.13, 0.19), SIMD3(0.045, 0.01, 0.07), SIMD3(0.3, 0.32, 0.36))
        for s: Float in [-1, 1] { m.tube(SIMD3(s * 0.03, 0.08, 0.01), SIMD3(s * 0.03, 0, 0), r0: 0.008, r1: 0.008, sides: 3, SIMD3(0.85, 0.4, 0.45)) }
        return MeshTemplate(m)
    }()
    static let pigeonWing: MeshTemplate = {
        var m = MeshBuilder()
        m.box(SIMD3(0.15, 0, 0), SIMD3(0.15, 0.008, 0.065), SIMD3(0.45, 0.47, 0.52))
        m.box(SIMD3(0.27, 0.001, 0.02), SIMD3(0.05, 0.009, 0.06), SIMD3(0.2, 0.2, 0.22))
        return MeshTemplate(m)
    }()

    func drawPigeons(into mesh: DynamicMesh, camera: SIMD3<Float>) {
        for f in flocks {
            for b in f.birds {
                guard simd_distance(b.pos, camera) < 140 else { continue }
                let peckDown: Float = !b.flying && b.peck < 0 ? 0.5 : 0
                let base = trs(b.pos, yawQuat(b.yaw) * simd_quatf(angle: -peckDown, axis: SIMD3(1, 0, 0)), 1.3)
                mesh.add(CitySky.pigeonBody, base)
                if b.flying {
                    let flap = sin(b.phase * 26) * 0.9
                    mesh.add(CitySky.pigeonWing, base * trs(SIMD3(0.06, 0.19, 0), simd_quatf(angle: flap, axis: SIMD3(0, 0, 1))))
                    mesh.add(CitySky.pigeonWing, base * trs(SIMD3(-0.06, 0.19, 0), simd_quatf(angle: .pi - flap, axis: SIMD3(0, 0, 1))))
                } else {
                    // Folded along the back.
                    for s: Float in [-1, 1] {
                        mesh.add(CitySky.pigeonWing, base * trs(SIMD3(s * 0.075, 0.2, -0.1),
                                                                yawQuat(-.pi / 2 + s * 0.05) * simd_quatf(angle: -0.12, axis: SIMD3(0, 0, 1)), 0.68))
                    }
                }
            }
        }
    }

    // MARK: Collisions

    func solids(near p: SIMD3<Float>) -> [CitySolid] {
        var out: [CitySolid] = []
        if simd_distance(p, heliPos) < 30 {
            out.append(.capsule(Capsule(a: heliPos + SIMD3(0, 1.4, -2), b: heliPos + SIMD3(0, 1.8, 6.5), r: 1.4)))
            out.append(.cylinder(c: SIMD2(heliPos.x, heliPos.z), r: 6.4, y0: heliPos.y + 3.1, y1: heliPos.y + 3.4))
        }
        if simd_distance(p, blimpPos) < 50 {
            let f = blimp.simdOrientation.act(SIMD3(0, 0, -1))
            out.append(.capsule(Capsule(a: blimpPos + f * 16, b: blimpPos - f * 16, r: 6.2)))
        }
        return out
    }
}
