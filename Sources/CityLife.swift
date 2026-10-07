import SceneKit
import simd

/// Everything that moves in Skyline City: traffic, bird people, trains, boats, helicopters, drones and pigeons.
/// Cars, people and pigeons share two batched meshes (bodies, and lights that glow).
final class CityLife {
    let root = SCNNode()
    private(set) var threat: String?
    private var notices: [String] = []
    private var hits: [HazardHit] = []
    let traffic = CityTraffic()
    let people = CityPeople()
    let transit = CityTransit()
    let sky = CitySky()
    let subway = CitySubwayLife()
    private let bodies: DynamicMesh?
    private let lights: DynamicMesh?
    private var hitCooldown: Float = 0
    private var clock: Float = 0
    private var sirenPhase: Float = 0
    /// Last frame's camera (cars and people are detailed near it).
    var camera: SIMD3<Float>?

    private static let carNear: [MeshTemplate] = CarKind.allCases.map { MeshTemplate(CityVehicles.body($0)) }
    private static let carFar: [MeshTemplate] = CarKind.allCases.map { MeshTemplate(CityVehicles.simpleBody($0)) }
    private static let heads: [MeshTemplate] = CarKind.allCases.map { MeshTemplate(CityVehicles.lights($0).head) }
    private static let tails: [MeshTemplate] = CarKind.allCases.map { MeshTemplate(CityVehicles.lights($0).tail) }

    init() {
        bodies = DynamicMesh(maxVertices: 150_000, maxTriangles: 130_000, material: WorldMaterials.finishes())
        lights = DynamicMesh(maxVertices: 12_000, maxTriangles: 10_000, material: WorldMaterials.glow(2.4))
        if let b = bodies { b.node.castsShadow = true; root.addChildNode(b.node) }
        if let l = lights { l.node.castsShadow = false; root.addChildNode(l.node) }
        root.addChildNode(transit.root)
        root.addChildNode(sky.root)
        root.addChildNode(subway.root)
    }

    func update(dt: Float, clock: Float, player: FlightModel, sound: SoundEngine?, underground: Float = 0) {
        self.clock = clock
        let p = player.pos
        for h in subway.update(dt: dt, player: player, underground: underground) where hitCooldown == 0 {
            hits.append(h)
            hitCooldown = 1.5
            notices.append("Hit by a subway train!")
        }
        traffic.update(dt: dt, clock: clock, player: p)
        people.update(dt: dt, clock: clock, player: player)
        transit.update(dt: dt, player: p, sound: sound)
        sky.update(dt: dt, clock: clock, player: player)
        hitCooldown = max(0, hitCooldown - dt)

        // Skim the street and the cars honk at you.
        let agl = p.y - CityLayout.ground(p.x, p.z)
        if agl < 7 && player.speed > 6 { traffic.honkAt(p, velocity: player.velocity) }

        // Trains and helicopter rotors knock you flying.
        threat = nil
        for t in transit.trainSolids(near: p, radius: 40) {
            if let push = t.push(p, 1.0), hitCooldown == 0 {
                let away = simd_length(push) > 1e-3 ? simd_normalize(push) : kUp
                hits.append(HazardHit(impulse: away * 14 + SIMD3(0, 9, 0), coins: 3, kind: .wall))
                hitCooldown = 1.5
                notices.append("Hit by a train!")
            }
        }
        if transit.hornNow { threat = "Train coming — get off the tracks!" }
        if subway.hornNow { threat = "Train coming — move to the other track!" }
        for s in sky.solids(near: p) {
            if s.push(p, 1.0) != nil, hitCooldown == 0, simd_distance(p, sky.heliPos) < 30 {
                hits.append(HazardHit(impulse: simd_normalize(p - sky.heliPos + SIMD3(0, 0.01, 0)) * 15, coins: 3, kind: .wall))
                hitCooldown = 1.5
                notices.append("Watch the rotor!")
            }
        }
        if simd_distance(p, sky.heliPos) < 45 && threat == nil { threat = "Helicopter!" }

        draw(camera: camera ?? p, bird: p)

        // Sound: the city's hum, horns, sirens, the el, the chopper, a murmur of voices, pigeons.
        if let sound {
            let low = smoothstep(90, 8, agl)
            let above = 1 - underground * 0.85   // the street goes quiet down in the tunnels
            let train = subway.trainSound.gain > transit.trainSound.gain ? subway.trainSound : transit.trainSound
            sound.setCity(traffic: min(1, traffic.hum * 0.02) * (0.35 + 0.65 * low) * above, crowd: min(1, people.nearby * 0.06) * low,
                          train: train.gain, trainPan: train.pan,
                          heli: smoothstep(320, 20, simd_distance(p, sky.heliPos)), heliPan: clamp((sky.heliPos.x - p.x) / 80, -1, 1))
            for (at, g) in traffic.honks { sound.horn(gain: g, pan: clamp((at.x - p.x) / 20, -1, 1)) }
            if let s = traffic.sirens.min(by: { simd_distance($0, p) < simd_distance($1, p) }) {
                sound.setSiren(gain: smoothstep(380, 20, simd_distance(s, p)) * 0.7, pan: clamp((s.x - p.x) / 60, -1, 1))
            } else {
                sound.setSiren(gain: 0, pan: 0)
            }
            if transit.hornNow || subway.hornNow { sound.trainHorn() }
            if sky.flutter > 0.95 { sound.flutter() }
            if !people.flashes.isEmpty { sound.shutter() }
        }
    }

    private func draw(camera: SIMD3<Float>, bird: SIMD3<Float>) {
        guard let bodies, let lights else { return }
        bodies.begin()
        lights.begin()
        sirenPhase += 1.0 / 60
        let flashA = Int(clock * 6) % 2 == 0
        for c in traffic.cars {
            let d = simd_distance(c.pos, camera)
            let m = trs(c.pos, yawQuat(c.yaw) * simd_quatf(angle: c.pitch, axis: SIMD3(1, 0, 0)))
            let k = c.kind.rawValue
            bodies.add(d < 170 ? CityLife.carNear[k] : CityLife.carFar[k], m, paint: c.paint)
            if d < 420 {
                lights.add(CityLife.heads[k], m, tint: 0.75)
                lights.add(CityLife.tails[k], m, tint: c.braking ? 1.6 : 0.4)
                if c.siren {
                    lights.add(CityVehicles.policeRed, m, tint: flashA ? 2.6 : 0.15)
                    lights.add(CityVehicles.policeBlue, m, tint: flashA ? 0.15 : 2.6)
                }
            }
        }
        people.draw(into: bodies, glow: lights, camera: camera, bird: bird)
        subway.draw(into: lights, camera: camera)
        sky.drawPigeons(into: bodies, camera: camera)
        bodies.end()
        lights.end()
    }

    /// Solid things that move: cars (when you're down at their level) and the blimp.
    func solids(near p: SIMD3<Float>) -> [CitySolid] {
        var out: [CitySolid] = []
        if p.y - CityLayout.ground(p.x, p.z) < 8 { out += traffic.solids(near: p, radius: 14) }
        if simd_distance(p, sky.blimpPos) < 50 {
            out += sky.solids(near: p).filter { if case .capsule(let c) = $0 { return c.r > 5 }; return false }
        }
        return out
    }

    func drainNotices() -> [String] { defer { notices.removeAll() }; return notices }
    func drainRewards() -> [WorldReward] { subway.drainRewards() }
    func drainHits() -> [HazardHit] { defer { hits.removeAll() }; return hits }
}
