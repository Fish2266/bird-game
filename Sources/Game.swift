import SceneKit
import simd

struct KeyInput {
    var left = false, right = false, up = false, down = false, flap = false, tuck = false
    var lastUsed: Double = -100
    var any: Bool { left || right || up || down || flap || tuck }
}

struct HUDStats {
    var speedKmh: Float = 0
    var altitude: Float = 0
    var agl: Float = 0
    var score = 0
    var ringDistance: Float = 0
    var ringBearing: Float = 0      // radians, + = to the right
    var ringAbove: Float = 0
    var control = ControlState()
    var usingKeyboard = false
    var autopilot = false
    var stalled: Float = 0
    var input = FlightInput()
    var fps: Float = 0
    var streak = 0
    var streakEnabled = false
    var threat: String?
}

final class Game {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private(set) var bird = BirdNode()
    let flight = FlightModel()
    let world: WorldInfo
    let visuals: WorldVisuals
    let terrain: TerrainManager
    let water: Water?
    let lava: LavaSurface?
    let clouds: CloudField
    let rings = RingCourse()
    let flock: Flock
    /// Hazards and special rules for challenge worlds (nil in World 1).
    let runtime: WorldRuntime?
    private let sun = SCNNode()
    private let moteEmitter = SCNNode()
    private let motes: SCNParticleSystem

    let controls: SharedControls
    var keys = KeyInput()
    var sound: SoundEngine? {
        didSet {
            sound?.resetWorld()
            sound?.setCaveAmbience(world.kind == .caves)
        }
    }
    var synchronousTerrain = false
    /// Set from the UI thread; the respawn happens on the render thread.
    var respawnRequested = false
    /// Pause freezes the flight; the camera slowly orbits the bird as a menu backdrop.
    var paused = false
    /// Called on the main queue each time a ring is flown through, with the current streak.
    var onRing: ((Int) -> Void)?
    /// Called on the main queue when a hazard hits the bird, with the coins it costs.
    var onHit: ((Int) -> Void)?
    private(set) var streak = 0
    private var pendingSpecies: (BirdLook, FlightTuning)?
    private var orbit: Float = 0

    private var lastTime: Double = -1
    private var input = FlightInput()
    private var camPos = SIMD3<Float>(0, 0, 0)
    private var camLook = SIMD3<Float>(0, 0, 0)
    private var camRoll: Float = 0
    private var camOffset = SIMD3<Float>(0, 1.5, 5)
    private var camLookOffset = SIMD3<Float>(0, 0, -5)
    private var shake: Float = 0
    private var lastWing: (Float, Float) = (0, 0)
    private var wingVel: (Float, Float) = (0, 0)
    private var kbPhase: Float = 0
    private var idlePhase: Float = 0
    private var autopilotAlt: Float = 150
    private var elapsed: Float = 0
    private var fpsAccum: (Float, Int) = (0, 0)

    private let statsLock = NSLock()
    private var _stats = HUDStats()
    var stats: HUDStats { statsLock.lock(); defer { statsLock.unlock() }; return _stats }

    init(controls: SharedControls, world id: WorldID = .meadow, terrainRadius: Int? = nil) {
        self.controls = controls
        world = WorldCatalog.info(id.rawValue)
        let provider: WorldTerrain
        switch id {
        case .meadow: visuals = .meadow; provider = MeadowTerrain(); runtime = nil
        case .volcano:
            visuals = .volcano
            let t = VolcanoTerrain(); provider = t; runtime = VolcanoRuntime(terrain: t)
        case .caves:
            visuals = .caves
            let t = CaveTerrain(); provider = t; runtime = CaveRuntime(terrain: t)
        case .dogfight: visuals = .dogfight; provider = FarmTerrain(); runtime = DogfightRuntime()
        }
        TerrainShape.active = provider
        terrain = TerrainManager(terrain: provider, radius: terrainRadius.map { min($0, provider.radius) })
        water = visuals.surface == .ocean ? Water() : nil
        lava = visuals.surface == .lava ? LavaSurface() : nil
        clouds = CloudField(count: visuals.cloudCount, heights: visuals.cloudHeight, tint: visuals.cloudTint)
        flock = Flock(count: visuals.flockCount)
        motes = makeMotes(visuals.motes)
        runtime?.configure(rings)
        buildScene()
        respawn()
    }

    private func buildScene() {
        let v = visuals
        let faces = world.kind == .meadow ? Sky.cachedFaces : Sky.cubeFaces(v)
        scene.background.contents = faces
        scene.lightingEnvironment.contents = faces
        scene.lightingEnvironment.intensity = v.envIntensity
        let fog = v.fogColor ?? v.horizon
        scene.fogColor = NSColor(srgbRed: CGFloat(fog.x), green: CGFloat(fog.y), blue: CGFloat(fog.z), alpha: 1)
        scene.fogStartDistance = v.fogStart
        scene.fogEndDistance = v.fogEnd
        scene.fogDensityExponent = 1.3

        let light = SCNLight()
        light.type = .directional
        light.intensity = v.sunIntensity
        light.color = v.sunColor
        light.castsShadow = v.shadows
        light.shadowMode = .deferred
        light.shadowColor = NSColor(white: 0, alpha: 0.55)
        light.shadowMapSize = CGSize(width: 2048, height: 2048)
        light.shadowCascadeCount = 3
        light.shadowCascadeSplittingFactor = 0.3
        light.maximumShadowDistance = 320
        light.automaticallyAdjustsShadowProjection = true
        light.shadowSampleCount = 8
        light.shadowRadius = 2
        sun.light = light
        sun.simdLook(at: -v.sunDir, up: kUp, localFront: SIMD3(0, 0, -1))
        if v.sunIntensity > 0 { scene.rootNode.addChildNode(sun) }

        scene.rootNode.addChildNode(terrain.root)
        if let water { scene.rootNode.addChildNode(water.node) }
        if let lava { scene.rootNode.addChildNode(lava.node) }
        if let runtime { scene.rootNode.addChildNode(runtime.root) }
        scene.rootNode.addChildNode(clouds.root)
        scene.rootNode.addChildNode(rings.root)
        scene.rootNode.addChildNode(bird.node)
        scene.rootNode.addChildNode(flock.root)

        moteEmitter.addParticleSystem(motes)
        scene.rootNode.addChildNode(moteEmitter)

        let cam = SCNCamera()
        cam.zNear = 0.25
        cam.zFar = Double(visuals.zFar)
        cam.fieldOfView = 60
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = visuals.exposure
        cam.bloomIntensity = 0.5
        cam.bloomThreshold = 1.1
        cam.bloomBlurRadius = 8
        cam.vignettingIntensity = 0.35
        cam.vignettingPower = 0.6
        cam.motionBlurIntensity = 0
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Start over a coastline with mountains in view.
    func respawn() {
        if let (start, yaw) = runtime?.spawnPoint() {
            flight.reset(at: start, yaw: yaw)
            flight.speed = 14
            autopilotAlt = start.y
            streak = 0
            rings.reset(from: start, heading: flight.forward)
            flock.reset(around: start, yaw: yaw, speed: flight.speed)
            camOffset = SIMD3(0, 1.5, 5)
            camLookOffset = SIMD3(0, 0, -5)
            terrain.update(center: start, synchronous: synchronousTerrain)
            Log.write("spawn at \(start) in \(world.name)")
            return
        }
        var best = SIMD3<Float>(0, 0, 0)
        var bestScore: Float = -1e9
        var rng = SplitMix64(seed: 3)
        for _ in 0..<400 {
            let x = rng.float(-3000, 3000), z = rng.float(-3000, 3000)
            let h = TerrainShape.height(x, z)
            // Prefer low land near water with high ground within ~1 km ahead (-Z).
            let ahead = TerrainShape.height(x, z - 900)
            let score = -abs(h - 12) * 2 + min(ahead, 260) * 0.5 - simd_length(SIMD2(x, z)) * 0.01
            if score > bestScore { bestScore = score; best = SIMD3(x, h, z) }
        }
        let start = SIMD3(best.x, max(best.y, 0) + 110, best.z + 250)
        flight.reset(at: start, yaw: 0)
        streak = 0
        autopilotAlt = start.y
        rings.reset(from: start, heading: flight.forward)
        flock.reset(around: start, yaw: 0, speed: flight.speed)
        camOffset = SIMD3(0, 1.5, 5)
        camLookOffset = SIMD3(0, 0, -5)
        terrain.update(center: start, synchronous: synchronousTerrain)
        Log.write("spawn at \(start)")
    }

    // MARK: Main loop

    func update(time: Double) {
        if respawnRequested { respawnRequested = false; respawn() }
        if lastTime < 0 { lastTime = time }
        let frameDt = Float(clamp(time - lastTime, 0, 0.1))
        lastTime = time
        applyPendingSpecies()
        if paused { updatePaused(frameDt); return }
        elapsed += frameDt
        fpsAccum.0 += frameDt; fpsAccum.1 += 1

        let c = controls.control
        let now = CACurrentMediaTime()
        if keys.any { keys.lastUsed = now }
        let keyboard = now - keys.lastUsed < 1.5
        let tracking = c.tracking && c.ready && !keyboard

        // Build target input.
        var target = FlightInput()
        var wingL = WingPose(), wingR = WingPose()
        var fold: Float = 0
        var autopilot = false
        if keyboard {
            target.roll = (keys.right ? 1 : 0) - (keys.left ? 1 : 0)
            target.pitch = (keys.up ? 1 : 0) - (keys.down ? 1 : 0)   // same as arms: up = climb
            target.tuck = keys.tuck ? 1 : 0
            if keys.flap {
                kbPhase += frameDt * 2 * .pi * 1.7
                let downstroke = cos(kbPhase) < 0 ? Float(0.9) : 0
                target.flapL = downstroke; target.flapR = downstroke
            } else {
                kbPhase = 0
            }
            let e = keys.flap ? 0.25 + 0.75 * sin(kbPhase) : target.pitch * 0.35
            wingL = WingPose(elevation: e + target.roll * 0.45, bend: keys.flap ? -0.3 * cos(kbPhase) : 0)
            wingR = WingPose(elevation: e - target.roll * 0.45, bend: keys.flap ? -0.3 * cos(kbPhase) : 0)
            fold = target.tuck
        } else if tracking {
            target.roll = c.roll
            target.pitch = c.pitch
            target.tuck = c.tuck
            target.flapL = c.flapL
            target.flapR = c.flapR
            wingL = c.wingL; wingR = c.wingR
            fold = c.tuck
            autopilotAlt = flight.pos.y
        } else {
            // Nobody in view: circle gently and hold altitude until the player shows up.
            autopilot = true
            if let steer = runtime?.autopilot(flight) {
                target.roll = steer.roll
                target.pitch = steer.pitch
                let flapNeed: Float = flight.speed < 11 ? 0.8 : 0
                idlePhase += frameDt * 2 * .pi * (flapNeed > 0 ? 1.6 : 0.25)
                let downstroke: Float = flapNeed > 0 && cos(idlePhase) < 0 ? flapNeed : 0
                target.flapL = downstroke; target.flapR = downstroke
                let e: Float = flapNeed > 0 ? 0.2 + 0.7 * sin(idlePhase) : 0.05 + 0.04 * sin(idlePhase)
                wingL = WingPose(elevation: e + steer.roll * 0.3, bend: 0); wingR = WingPose(elevation: e - steer.roll * 0.3, bend: 0)
            } else {
            let ground = TerrainShape.ground(flight.pos.x, flight.pos.z)
            let ahead = flight.pos + flight.forward * 120
            let groundAhead = TerrainShape.ground(ahead.x, ahead.z)
            autopilotAlt = max(autopilotAlt, max(ground, groundAhead) + 70)
            let err = autopilotAlt - flight.pos.y
            target.roll = 0.35
            target.pitch = clamp(err / 40, -0.4, 0.8)
            let flapNeed: Float = err > 10 || flight.speed < 11 ? 0.8 : 0
            idlePhase += frameDt * 2 * .pi * (flapNeed > 0 ? 1.6 : 0.25)
            let downstroke: Float = flapNeed > 0 && cos(idlePhase) < 0 ? flapNeed : 0
            target.flapL = downstroke; target.flapR = downstroke
            let e: Float = flapNeed > 0 ? 0.2 + 0.7 * sin(idlePhase) : 0.05 + 0.04 * sin(idlePhase)
            wingL = WingPose(elevation: e + 0.12, bend: 0); wingR = WingPose(elevation: e - 0.12, bend: 0)
            }
        }

        // Smooth the 30 Hz tracker output up to the render rate (fast, to keep latency low).
        let k = approach(18, frameDt)
        input.roll += (target.roll - input.roll) * k
        input.pitch += (target.pitch - input.pitch) * k
        input.tuck += (target.tuck - input.tuck) * approach(10, frameDt)
        input.flapL += (target.flapL - input.flapL) * approach(25, frameDt)
        input.flapR += (target.flapR - input.flapR) * approach(25, frameDt)


        // Physics in fixed sub-steps.
        let prevPos = flight.pos
        var remaining = frameDt
        var impact: Float = 0
        var hitWater = false
        while remaining > 0 {
            let h = min(remaining, 1.0 / 120.0)
            let ev = flight.step(h, input)
            impact = max(impact, ev.groundImpact)
            if let runtime { impact = max(impact, runtime.constrain(flight)) }
            hitWater = hitWater || ev.waterSkim
            remaining -= h
        }
        if impact > 2 { sound?.impact(impact, water: hitWater); shake = min(1, shake + impact / 15) }

        if let skipped = rings.update(prev: prevPos, now: flight.pos, time: elapsed) {
            flight.speed += world.ringBoost
            sound?.chime()
            if world.isChallenge { streak = skipped > 0 ? 1 : streak + 1 }
            let st = streak
            if let cb = onRing { DispatchQueue.main.async { cb(st) } }
        }

        // World hazards: knockback, lost streak, lost coins.
        if let runtime {
            for hit in runtime.update(dt: frameDt, time: elapsed, flight: flight, sound: sound) {
                if hit.impulse != .zero { flight.knock(hit.impulse) }
                shake = min(1, shake + 0.7)
                sound?.hit(hit.kind)
                streak = 0
                let coins = hit.coins
                if let cb = onHit { DispatchQueue.main.async { cb(coins) } }
            }
        }

        // Bird visuals
        bird.node.simdPosition = flight.pos
        bird.node.simdOrientation = flight.orientation
        bird.pose(left: wingL, right: wingR, fold: fold, pitchIn: input.pitch, rollIn: input.roll, dt: frameDt)

        // Wingbeat sound follows how fast the (displayed) wings actually move.
        let we = bird.wingElevations
        if frameDt > 0 {
            wingVel.0 += ((we.0 - lastWing.0) / frameDt - wingVel.0) * approach(30, frameDt)
            wingVel.1 += ((we.1 - lastWing.1) / frameDt - wingVel.1) * approach(30, frameDt)
        }
        lastWing = we
        sound?.setWings(downL: max(0, -wingVel.0), downR: max(0, -wingVel.1), upL: max(0, wingVel.0), upR: max(0, wingVel.1))

        flock.update(dt: frameDt, player: flight)
        updateCamera(frameDt)

        terrain.update(center: flight.pos, synchronous: synchronousTerrain)
        water?.follow(camPos)
        lava?.follow(camPos, time: elapsed)
        clouds.update(center: flight.pos)
        moteEmitter.simdPosition = flight.pos + flight.forward * 30
        motes.birthRate = CGFloat(150 + flight.speed * 18)

        let agl = flight.pos.y - TerrainShape.ground(flight.pos.x, flight.pos.z)
        sound?.setFlight(speed: flight.speed, tuck: input.tuck, stall: flight.stalled, roll: flight.roll,
                         ground: smoothstep(28, 2, agl))

        // Publish HUD stats.
        let ground = TerrainShape.ground(flight.pos.x, flight.pos.z)
        var s = HUDStats()
        s.speedKmh = flight.speed * 3.6
        s.altitude = flight.pos.y
        s.agl = flight.pos.y - ground
        s.score = rings.score
        if let r = rings.next {
            let to = r.center - flight.pos
            s.ringDistance = simd_length(to)
            let fwd = simd_normalize(SIMD3(flight.forward.x, 0, flight.forward.z))
            let flat = simd_normalize(SIMD3(to.x, 0, to.z))
            let cross = fwd.x * flat.z - fwd.z * flat.x
            s.ringBearing = atan2(cross, simd_dot(fwd, flat))
            s.ringAbove = to.y
        }
        s.control = c
        s.usingKeyboard = keyboard
        s.autopilot = autopilot
        s.stalled = flight.stalled
        s.input = input
        s.streak = streak
        s.streakEnabled = world.isChallenge
        s.threat = runtime?.threat
        if fpsAccum.0 > 0.5 { s.fps = Float(fpsAccum.1) / fpsAccum.0; fpsAccum = (0, 0) } else { s.fps = stats.fps }
        statsLock.lock(); _stats = s; statsLock.unlock()
    }

    /// Swap the player's bird model and flight stats (called from the UI thread; applied on the render thread).
    func setSpecies(_ look: BirdLook, tuning: FlightTuning) {
        statsLock.lock(); pendingSpecies = (look, tuning); statsLock.unlock()
    }

    private func applyPendingSpecies() {
        statsLock.lock(); let p = pendingSpecies; pendingSpecies = nil; statsLock.unlock()
        guard let (look, tuning) = p else { return }
        flight.tuning = tuning
        let fresh = BirdNode(look: look)
        fresh.node.simdPosition = bird.node.simdPosition
        fresh.node.simdOrientation = bird.node.simdOrientation
        bird.node.removeFromParentNode()
        scene.rootNode.addChildNode(fresh.node)
        bird = fresh
    }

    private func updatePaused(_ dt: Float) {
        sound?.setWings(downL: 0, downR: 0, upL: 0, upR: 0)
        orbit += dt * 0.22
        // Show the bird with its wings spread while the menu is open.
        bird.pose(left: WingPose(elevation: 0.12, bend: 0), right: WingPose(elevation: 0.12, bend: 0),
                  fold: 0, pitchIn: 0, rollIn: 0, dt: dt)
        let q = simd_quatf(angle: flight.yaw + .pi * 0.75 + orbit, axis: kUp)
        let target = q.act(SIMD3(0, 1.2, 5.5))
        camOffset += (target - camOffset) * approach(2.5, dt)
        camPos = flight.pos + camOffset
        if let runtime { camPos = runtime.constrainCamera(bird: flight.pos, cam: camPos) }
        camLook = flight.pos + SIMD3(0, 0.2, 0)
        camRoll += (0 - camRoll) * approach(3, dt)
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook, up: kUp, localFront: SIMD3(0, 0, -1))
        cameraNode.camera?.fieldOfView = 55
        camLookOffset = camLook - flight.pos
    }

    private func updateCamera(_ dt: Float) {
        let fwd = flight.forward
        var flat = SIMD3(fwd.x, 0, fwd.z)
        if simd_length(flat) < 0.2 { flat = SIMD3(-sin(flight.yaw), 0, -cos(flight.yaw)) }
        flat = simd_normalize(flat)
        let back = simd_normalize(simd_mix(flat, fwd, SIMD3(repeating: 0.4)))
        let speedT = smoothstep(10, 80, flight.speed)
        let dist: Float = 4.3 + speedT * 1.6
        // Smooth the camera *offset* from the bird (not its world position) so it never
        // falls behind at high speed, but still swings smoothly through turns.
        let desiredOffset = -back * dist + SIMD3(0, 1.45, 0)
        camOffset += (desiredOffset - camOffset) * approach(5.5, dt)
        camPos = flight.pos + camOffset
        let camGround = max(TerrainShape.height(camPos.x, camPos.z), TerrainShape.waterLevel)
        camPos.y = max(camPos.y, camGround + 1.2)
        if let runtime { camPos = runtime.constrainCamera(bird: flight.pos, cam: camPos) }
        let lookOffset = fwd * 5 + SIMD3(0, 0.35, 0)
        camLookOffset += (lookOffset - camLookOffset) * approach(9, dt)
        camLook = flight.pos + camLookOffset
        camRoll += (flight.roll * 0.4 - camRoll) * approach(5, dt)

        shake = max(0, shake - dt * 1.8)
        let speedShake = smoothstep(45, 100, flight.speed) * 0.06
        let amp = shake * 0.25 + speedShake
        let t = elapsed
        let jitter = SIMD3(sin(t * 37) + sin(t * 23), sin(t * 29) + sin(t * 41), 0) * amp * 0.5

        cameraNode.simdPosition = camPos + jitter
        let viewDir = simd_normalize(camLook - camPos)
        let up = simd_quatf(angle: camRoll, axis: viewDir).act(kUp)
        cameraNode.simdLook(at: camLook, up: up, localFront: SIMD3(0, 0, -1))
        cameraNode.camera?.fieldOfView = CGFloat(58 + speedT * 24)
    }
}
