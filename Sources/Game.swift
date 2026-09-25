import SceneKit
import simd

struct KeyInput {
    var left = false, right = false, up = false, down = false, flap = false, tuck = false
    /// Attack key (Return / E); set on key down, consumed by the game.
    var attack = false
    var lastUsed: Double = -100
    var any: Bool { left || right || up || down || flap || tuck }
}

/// Another bird as shown on the HUD compass.
struct CompassMarker {
    var name: String
    var color: Int
    /// Radians relative to where the camera looks (+ = right).
    var bearing: Float
    var distance: Float
    var above: Float
}

enum MatchPhase: Equatable { case warmup, countdown, running, done }

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

    // Modes
    var mode = GameMode.freeRoam
    var multiplayer = false
    var phase = MatchPhase.warmup
    var countdown: Float = 0
    var raceTime: Double = 0
    var gateLabel = ""
    var penalty: Double = 0
    var split: String?
    var splitAhead = false
    var place: String?
    /// Seconds until you're put back on the course (0 = on course).
    var offCourse: Float = 0
    var banner: String?
    var ghost = false
    /// Gold / silver / bronze target times (races).
    var medals: [Double] = []
    /// Fights: seconds left and what the wall is doing.
    var fightTimeLeft: Float = 0
    var wallStatus = ""
    // Combat
    var combat = false
    var health: Float = Fighter.maxHealth
    var burning = false
    var alive = true
    var mouth: Float = 0
    var mouthSeen = false
    var reload: Float = 1
    var weaponName = ""
    var lives = 0
    var lockName: String?
    var lockInRange = false
    var fightersLeft = 0
    var fighters = 0
    var respawnIn: Float = 0
    // Other birds
    var showCompass = false
    var markers: [CompassMarker] = []
    var players = 0
}

/// What happened at the end of a single-player race or fight (the app turns it into coins and a results panel).
struct MatchOutcome {
    var mode: GameMode
    var world: WorldID
    var place: Int
    var of: Int
    var time: Double?
    var gates = 0
    var missed = 0
    var knockouts = 0
    var hits = 0
    var standings: [Standing] = []
    var ghost: GhostRun?
    /// Gold / silver / bronze target times (races).
    var medals: [Double] = []
}

final class Game {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private(set) var bird = BirdNode()
    let flight = FlightModel()
    let world: WorldInfo
    let worldID: WorldID
    let mode: GameMode
    let multiplayer: Bool
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
    /// Main queue: short message for the middle of the screen.
    var onNotice: ((String) -> Void)?
    /// Main queue: a single-player race or fight ended.
    var onMatchOver: ((MatchOutcome) -> Void)?
    /// Main queue: something the host's match director needs to know about (local player finished / was knocked out).
    var onLocalEvent: ((GameEvent) -> Void)?
    /// Main queue: this player knocked someone out (for coins).
    var onKnockout: ((String) -> Void)?
    private(set) var streak = 0
    private var pendingSpecies: (Species, [Int])?
    private var orbit: Float = 0

    private var lastTime: Double = -1
    var input = FlightInput()
    private var camPos = SIMD3<Float>(0, 0, 0)
    private var camLook = SIMD3<Float>(0, 0, 0)
    private var camRoll: Float = 0
    private var camOffset = SIMD3<Float>(0, 1.5, 5)
    private var camLookOffset = SIMD3<Float>(0, 0, -5)
    var shake: Float = 0
    private var lastWing: (Float, Float) = (0, 0)
    private var wingVel: (Float, Float) = (0, 0)
    private var kbPhase: Float = 0
    private var idlePhase: Float = 0
    private var autopilotAlt: Float = 150
    var elapsed: Float = 0
    private var fpsAccum: (Float, Int) = (0, 0)
    /// Where this world starts you (and where races and fights are built).
    let spawn: (SIMD3<Float>, Float)

    private let statsLock = NSLock()
    private var _stats = HUDStats()
    var stats: HUDStats { statsLock.lock(); defer { statsLock.unlock() }; return _stats }
    private var commands: [(Game) -> Void] = []

    // MARK: Identity & stats of the local bird

    var localId = 1
    var species = Catalog.all[0]
    var combatTuning = CombatTuning()
    /// Wing pose sent to other players.
    var wingState = SIMD4<Float>(0.1, 0.1, 0, 0)

    // MARK: Match state (see GameMatch.swift)

    let track: RaceTrack?
    let arena: Arena?
    let combat = Combat()
    var rules = MatchRules()
    var phase = MatchPhase.warmup
    var countdownLeft: Float = 0
    var clock: Double = 0
    var nextGate = 0
    var gateStates: [Int: RaceTrack.GateState] = [:]
    var penalty: Double = 0
    var gatesPassed = 0
    var gatesMissed = 0
    var splits: [Double] = []
    var pathHint = 0
    var progressS: Float = 0
    var offCourseFor: Float = 0
    var lastSafeS: Float = 0
    var finishTime: Double?
    var splitText: String?
    var splitAhead = false
    var splitTimer: Float = 0
    var recording: GhostRun?
    var recordTimer: Float = 0
    var ghost: GhostBird?
    var bestTime: Double?
    var bestSplits: [Double] = []
    var bestRun: GhostRun?
    var matchId = 0
    var slot = 0
    var participating = true
    var banner: String?
    // Fight
    var fighter = Fighter()
    var bots: [BotPilot] = []
    var knockedOut: [Int] = []
    var knockouts = 0
    var hitsLanded = 0
    var spectating: Int?
    var respawnIn: Float = 0
    var fightClock: Float = 0
    var wallCooldown: Float = 0
    var lastAttackCount = -1
    /// Bird the attack is locked onto (fights).
    var lockTarget: Int?
    let reticle = Game.makeReticle()
    let orbs: HealthOrbs?
    /// Fights end after this long, most lives (then health) winning.
    static let fightLimit: Float = 300
    var ramCooldown: [Int: Float] = [:]
    var obstacleCooldown: Float = 0
    /// ← / → switch who you watch while out of a fight (edge detection).
    var spectateKeys = (false, false)
    /// The player's nametag color (bots avoid it).
    static var playerColor = -1
    // Network
    weak var link: NetLink?
    var others: [Int: OtherBird] = [:]
    let othersRoot = SCNNode()
    var peers: [PeerInfo] = []
    var stateTimer: Float = 0
    var matchWarning: String?

    var combatOn: Bool { mode == .pvp || (multiplayer && rules.pvp) }
    /// Test hook: overrides the player's input (used by the offscreen tests to fly courses).
    var debugSteer: ((Game) -> FlightInput?)?
    /// Test hook: combat events (hits taken, rams) as text.
    var debugEvent: ((String) -> Void)?

    init(controls: SharedControls, world id: WorldID = .meadow, mode: GameMode = .freeRoam, multiplayer: Bool = false,
         species sp: Species? = nil, points: [Int]? = nil, terrainRadius: Int? = nil) {
        self.controls = controls
        if let sp { species = sp }
        self.mode = mode
        self.multiplayer = multiplayer
        worldID = id
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
        case .dogfight:
            visuals = .dogfight; provider = FarmTerrain()
            runtime = DogfightRuntime()
        }
        TerrainShape.active = provider
        terrain = TerrainManager(terrain: provider, radius: terrainRadius.map { min($0, provider.radius) })
        water = visuals.surface == .ocean ? Water() : nil
        lava = visuals.surface == .lava ? LavaSurface() : nil
        clouds = CloudField(count: visuals.cloudCount, heights: visuals.cloudHeight, tint: visuals.cloudTint)
        flock = Flock(count: mode == .freeRoam ? visuals.flockCount : 0)
        motes = makeMotes(visuals.motes)
        runtime?.configure(rings)
        spawn = Game.defaultSpawn(runtime)
        track = mode.isRace ? RaceTrack(mode: mode, world: id, spawn: spawn, terrain: provider) : nil
        let a = mode == .pvp ? Arena(spawn: spawn.0, world: id) : nil
        arena = a
        let yaw = spawn.1
        orbs = a.map { HealthOrbs(arena: $0, spawnYaw: yaw, caves: id == .caves) }
        buildScene()
        if let sp, let points { setSpecies(sp, points: points); applyPendingSpecies() }
        if mode == .freeRoam {
            respawn()
        } else {
            rings.root.isHidden = true
            if multiplayer { enterWarmup() } else { restartMatch() }
        }
    }

    /// Run `block` on the render thread before the next frame.
    func enqueue(_ block: @escaping (Game) -> Void) {
        statsLock.lock(); commands.append(block); statsLock.unlock()
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
        if let track { scene.rootNode.addChildNode(track.root) }
        if let arena { scene.rootNode.addChildNode(arena.root) }
        if let orbs { scene.rootNode.addChildNode(orbs.root) }
        scene.rootNode.addChildNode(reticle)
        scene.rootNode.addChildNode(combat.root)
        scene.rootNode.addChildNode(othersRoot)
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

    /// The world's starting spot: its own, or (open worlds) low land by the water with high ground ahead.
    static func defaultSpawn(_ runtime: WorldRuntime?) -> (SIMD3<Float>, Float) {
        if let s = runtime?.spawnPoint() { return s }
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
        return (SIMD3(best.x, max(best.y, 0) + 110, best.z + 250), 0)
    }

    /// Start over at the world's spawn (free roam), offset a little per player in LAN games.
    func respawn() {
        let custom = runtime?.spawnPoint() != nil
        var (start, yaw) = spawn
        if multiplayer && slot > 0 {
            let side = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let lateral = Float((slot + 1) / 2) * (slot % 2 == 0 ? 1 : -1) * (custom && worldID == .caves ? 2.5 : 9)
            start += side * lateral + SIMD3(0, worldID == .caves ? 0 : Float(slot % 3) * 3, 0)
        }
        place(at: start, yaw: yaw)
        if custom { flight.speed = 14 }
        autopilotAlt = start.y
        streak = 0
        rings.reset(from: start, heading: flight.forward)
        flock.reset(around: start, yaw: yaw, speed: flight.speed)
        Log.write("spawn at \(start) in \(world.name)")
    }

    /// Teleport the local bird and snap the camera behind it.
    func place(at p: SIMD3<Float>, yaw: Float, speed: Float? = nil) {
        flight.reset(at: p, yaw: yaw)
        if let speed { flight.speed = speed }
        autopilotAlt = p.y
        camOffset = SIMD3(0, 1.5, 5)
        camLookOffset = SIMD3(0, 0, -5)
        terrain.update(center: p, synchronous: synchronousTerrain)
    }

    // MARK: Main loop

    func update(time: Double) {
        statsLock.lock(); let cmds = commands; commands.removeAll(); statsLock.unlock()
        for c in cmds { c(self) }
        if respawnRequested { respawnRequested = false; requestRestart() }
        if lastTime < 0 { lastTime = time }
        let frameDt = Float(clamp(time - lastTime, 0, 0.1))
        lastTime = time
        applyPendingSpecies()
        if paused {
            if multiplayer {
                tickNetwork(dt: frameDt, now: time)
                // Everyone else keeps racing, so your clock does too.
                if phase == .countdown {
                    countdownLeft -= frameDt
                    if countdownLeft <= 0 { phase = .running; clock = 0 }
                } else if phase == .running {
                    clock += Double(frameDt)
                    fightClock += frameDt
                }
            }
            updatePaused(frameDt)
            if multiplayer { updateOthers(dt: frameDt, now: time); publishState(dt: frameDt) }
            return
        }
        elapsed += frameDt
        fpsAccum.0 += frameDt; fpsAccum.1 += 1
        if multiplayer { tickNetwork(dt: frameDt, now: time) }

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
        if let steer = debugSteer?(self) {
            target = steer
            kbPhase += frameDt * 2 * .pi * 1.7
            let e = steer.flapL > 0 ? 0.25 + 0.75 * sin(kbPhase) : steer.pitch * 0.35
            wingL = WingPose(elevation: e + steer.roll * 0.45, bend: 0)
            wingR = WingPose(elevation: e - steer.roll * 0.45, bend: 0)
            fold = steer.tuck
        } else if keyboard {
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

        // Physics in fixed sub-steps (held still on the start grid during a countdown).
        let prevPos = flight.pos
        var impact: Float = 0
        var hitWater = false
        let frozen = phase == .countdown || isKnockedOut
        if frozen {
            holdStill(frameDt)
        } else {
            var remaining = frameDt
            while remaining > 0 {
                let h = min(remaining, 1.0 / 120.0)
                let ev = flight.step(h, input)
                impact = max(impact, ev.groundImpact)
                if let runtime { impact = max(impact, runtime.constrain(flight)) }
                hitWater = hitWater || ev.waterSkim
                remaining -= h
            }
        }
        if impact > 2 { sound?.impact(impact, water: hitWater); shake = min(1, shake + impact / 15) }

        if mode == .freeRoam, let skipped = rings.update(prev: prevPos, now: flight.pos, time: elapsed) {
            flight.speed += world.ringBoost
            sound?.chime()
            if world.isChallenge { streak = skipped > 0 ? 1 : streak + 1 }
            let st = streak
            if let cb = onRing { DispatchQueue.main.async { cb(st) } }
        }

        // World hazards: knockback, lost streak, lost coins (coins only in free roam).
        if let runtime {
            for hit in runtime.update(dt: frameDt, time: elapsed, flight: flight, sound: sound) where !frozen {
                if mode == .freeRoam {
                    if hit.impulse != .zero { flight.knock(hit.impulse) }
                } else {
                    flight.nudge(hit.impulse * combatTuning.knockTaken)
                    // Lava and bullets hurt in a fight.
                    if combatOn && hit.kind != .wall { applyToMe(HitReport(from: 0, to: localId, damage: 8, impulse: .zero, source: .hazard)) }
                }
                shake = min(1, shake + 0.7)
                sound?.hit(hit.kind)
                streak = 0
                let coins = hit.coins
                if mode == .freeRoam, let cb = onHit { DispatchQueue.main.async { cb(coins) } }
            }
        }

        // Races, fights, other birds.
        updateMatch(dt: frameDt, prev: prevPos)
        updateOthers(dt: frameDt, now: time)

        // Bird visuals
        wingState = SIMD4(wingL.elevation, wingR.elevation, (wingL.bend + wingR.bend) * 0.5, fold)
        bird.node.isHidden = isKnockedOut || !participating && mode == .pvp && phase == .running
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
        if let s = spectating, let o = others[s] ?? bots.first(where: { $0.id == s })?.avatar {
            updateCamera(frameDt, pos: o.pos, fwd: o.forward, roll: 0, speed: simd_length(o.vel), yaw: atan2(-o.forward.x, -o.forward.z))
        } else {
            updateCamera(frameDt, pos: flight.pos, fwd: flight.forward, roll: flight.roll, speed: flight.speed, yaw: flight.yaw)
        }

        var focus = flight.pos
        if let sp = spectating { focus = others[sp]?.pos ?? bots.first(where: { $0.id == sp })?.flight.pos ?? flight.pos }
        terrain.update(center: focus, synchronous: synchronousTerrain)
        water?.follow(camPos)
        lava?.follow(camPos, time: elapsed)
        clouds.update(center: focus)
        moteEmitter.simdPosition = flight.pos + flight.forward * 30
        motes.birthRate = CGFloat(150 + flight.speed * 18)

        let agl = flight.pos.y - TerrainShape.ground(flight.pos.x, flight.pos.z)
        sound?.setFlight(speed: frozen ? 0 : flight.speed, tuck: input.tuck, stall: frozen ? 0 : flight.stalled, roll: flight.roll,
                         ground: smoothstep(28, 2, agl))
        if multiplayer { publishState(dt: frameDt) }

        // Publish HUD stats.
        let ground = TerrainShape.ground(flight.pos.x, flight.pos.z)
        var s = HUDStats()
        s.speedKmh = flight.speed * 3.6
        s.altitude = flight.pos.y
        s.agl = flight.pos.y - ground
        s.score = rings.score
        if mode == .freeRoam, let r = rings.next {
            (s.ringDistance, s.ringBearing, s.ringAbove) = pointer(to: r.center)
        }
        s.control = c
        s.usingKeyboard = keyboard
        s.autopilot = autopilot
        s.stalled = frozen ? 0 : flight.stalled
        s.input = input
        s.streak = streak
        s.streakEnabled = world.isChallenge && mode == .freeRoam
        s.threat = runtime?.threat
        fillMatchStats(&s)
        if fpsAccum.0 > 0.5 { s.fps = Float(fpsAccum.1) / fpsAccum.0; fpsAccum = (0, 0) } else { s.fps = stats.fps }
        statsLock.lock(); _stats = s; statsLock.unlock()
    }

    /// Distance, bearing (+ = right) and height difference from the bird to a point, for the HUD arrow.
    func pointer(to p: SIMD3<Float>) -> (Float, Float, Float) {
        let to = p - flight.pos
        let fwd = simd_normalize(SIMD3(flight.forward.x, 0, flight.forward.z))
        let flat = simd_normalize(SIMD3(to.x, 0, to.z))
        let cross = fwd.x * flat.z - fwd.z * flat.x
        return (simd_length(to), atan2(cross, simd_dot(fwd, flat)), to.y)
    }

    /// Countdown / knocked out: hover in place with the wings still moving.
    private func holdStill(_ dt: Float) {
        flight.speed = 14
        flight.pitch += (0 - flight.pitch) * approach(4, dt)
        flight.roll += (0 - flight.roll) * approach(4, dt)
    }

    /// Swap the player's bird model and stats (called from the UI thread; applied on the render thread).
    func setSpecies(_ sp: Species, points: [Int]) {
        statsLock.lock(); pendingSpecies = (sp, points); statsLock.unlock()
    }

    private func applyPendingSpecies() {
        statsLock.lock(); let p = pendingSpecies; pendingSpecies = nil; statsLock.unlock()
        guard let (sp, points) = p else { return }
        flight.tuning = FlightTuning(points: points)
        combatTuning = CombatTuning(points: points)
        species = sp
        let fresh = BirdNode(look: sp.look)
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

    private func updateCamera(_ dt: Float, pos: SIMD3<Float>, fwd: SIMD3<Float>, roll: Float, speed: Float, yaw: Float) {
        var flat = SIMD3(fwd.x, 0, fwd.z)
        if simd_length(flat) < 0.2 { flat = SIMD3(-sin(yaw), 0, -cos(yaw)) }
        flat = simd_normalize(flat)
        let back = simd_normalize(simd_mix(flat, fwd, SIMD3(repeating: 0.4)))
        let speedT = smoothstep(10, 80, speed)
        let dist: Float = (4.3 + speedT * 1.6) * (spectating != nil ? 1.6 : 1)
        // Smooth the camera *offset* from the bird (not its world position) so it never
        // falls behind at high speed, but still swings smoothly through turns.
        let desiredOffset = -back * dist + SIMD3(0, 1.45, 0)
        camOffset += (desiredOffset - camOffset) * approach(5.5, dt)
        camPos = pos + camOffset
        let camGround = max(TerrainShape.height(camPos.x, camPos.z), TerrainShape.waterLevel)
        camPos.y = max(camPos.y, camGround + 1.2)
        if let runtime { camPos = runtime.constrainCamera(bird: pos, cam: camPos) }
        let lookOffset = fwd * 5 + SIMD3(0, 0.35, 0)
        camLookOffset += (lookOffset - camLookOffset) * approach(9, dt)
        camLook = pos + camLookOffset
        camRoll += (roll * 0.4 - camRoll) * approach(5, dt)

        shake = max(0, shake - dt * 1.8)
        let speedShake = smoothstep(45, 100, speed) * 0.06
        let amp = shake * 0.25 + speedShake
        let t = elapsed
        let jitter = SIMD3(sin(t * 37) + sin(t * 23), sin(t * 29) + sin(t * 41), 0) * amp * 0.5

        cameraNode.simdPosition = camPos + jitter
        let viewDir = simd_normalize(camLook - camPos)
        let up = simd_quatf(angle: camRoll, axis: viewDir).act(kUp)
        cameraNode.simdLook(at: camLook, up: up, localFront: SIMD3(0, 0, -1))
        cameraNode.camera?.fieldOfView = CGFloat(58 + speedT * 24)
    }

    /// Lock-on brackets drawn around the targeted bird (fights).
    static func makeReticle() -> SCNNode {
        let img = makeImage(width: 128, height: 128) { x, y in
            let u = abs(Float(x) - 63.5) / 64, v = abs(Float(y) - 63.5) / 64
            let edge = (u > 0.86 && u < 0.97 && v > 0.45 && v < 0.97) || (v > 0.86 && v < 0.97 && u > 0.45 && u < 0.97)
            return edge ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 0)
        }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.multiply.contents = NSColor.white
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        let n = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        n.geometry?.materials = [m]
        let bb = SCNBillboardConstraint(); bb.freeAxes = .all
        n.constraints = [bb]
        n.renderingOrder = 1100
        n.isHidden = true
        n.castsShadow = false
        return n
    }

    /// Where the camera is looking (for the compass).
    var cameraForward: SIMD3<Float> { camLook - camPos }
    var cameraPosition: SIMD3<Float> { camPos }
}
